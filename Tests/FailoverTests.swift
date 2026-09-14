import XCTest
@testable import olcrtc_ios

// #453: unit tests for the auto-failover pure helpers on TunnelManager
// (nextFailoverCandidate / failoverRank) and the store-backed candidate
// resolver (computeFailoverCandidates).
//
// The async reconnect loop that consumes these helpers (requestReconnect's
// failover hop) is integration-only — it launches a real engine task and can't
// be driven deterministically in the test host — so it is intentionally NOT
// covered here; only the pure decision surface is.
//
// computeFailoverCandidates reads the two @MainActor stores, whose didSet
// persists to UserDefaults, so this suite snapshots + restores
// `olcrtc_records_v2` and `olcrtc_server_hosts`. All records use empty secrets,
// so ConnectionStore.save() never writes the Keychain (it only upserts
// non-empty ones).
@MainActor
final class FailoverTests: XCTestCase {

    private let recordsKey = "olcrtc_records_v2"
    private let hostsKey    = "olcrtc_server_hosts"
    // #456: computeFailoverCandidates now reads HealthCoordinator.shared, whose
    // map persists — snapshot + reset it so observed evidence never leaks
    // between tests (or in from a previous run).
    private let healthKey   = "olcrtc_health_v1"
    private var recordsSnapshot: Data?
    private var hostsSnapshot: Data?
    private var healthSnapshot: Data?

    override func setUp() {
        super.setUp()
        recordsSnapshot = UserDefaults.standard.data(forKey: recordsKey)
        hostsSnapshot   = UserDefaults.standard.data(forKey: hostsKey)
        healthSnapshot  = UserDefaults.standard.data(forKey: healthKey)   // #456
        HealthCoordinator.shared._resetForTesting()                       // #456
    }

    override func tearDown() {
        // #456
        HealthCoordinator.shared._resetForTesting()
        HealthCoordinator.flushPendingWrites()
        if let d = recordsSnapshot { UserDefaults.standard.set(d, forKey: recordsKey) }
        else { UserDefaults.standard.removeObject(forKey: recordsKey) }
        if let d = hostsSnapshot { UserDefaults.standard.set(d, forKey: hostsKey) }
        else { UserDefaults.standard.removeObject(forKey: hostsKey) }
        if let d = healthSnapshot { UserDefaults.standard.set(d, forKey: healthKey) }   // #456
        else { UserDefaults.standard.removeObject(forKey: healthKey) }
        super.tearDown()
    }

    // MARK: helpers

    private func record(_ name: String, carrier: String = "jitsi",
                        transport: String = "datachannel") -> ConnectionRecord {
        let conn = OlcrtcConnection(carrier: carrier, transport: transport,
                                    roomID: "room-\(name)", key: "", clientID: "default")
        return ConnectionRecord(name: name, details: .olcrtc(conn))
    }

    // MARK: nextFailoverCandidate

    func testNextFailoverSkipsCurrentAndTried() {
        let a = record("a"), b = record("b"), c = record("c")
        // current is `a`; `a` and `b` already tried → next is `c`.
        let next = TunnelManager.nextFailoverCandidate(
            current: a, candidates: [a, b, c], tried: [a.id, b.id])
        XCTAssertEqual(next?.id, c.id)
    }

    func testNextFailoverPreservesOrder() {
        let a = record("a"), b = record("b"), c = record("c")
        // nothing tried but the seed (current); first non-current wins.
        let next = TunnelManager.nextFailoverCandidate(
            current: a, candidates: [a, b, c], tried: [a.id])
        XCTAssertEqual(next?.id, b.id)
    }

    func testNextFailoverNilWhenExhausted() {
        let a = record("a"), b = record("b")
        let next = TunnelManager.nextFailoverCandidate(
            current: a, candidates: [a, b], tried: [a.id, b.id])
        XCTAssertNil(next)
    }

    func testNextFailoverNilWhenNoCandidates() {
        let a = record("a")
        XCTAssertNil(TunnelManager.nextFailoverCandidate(
            current: a, candidates: [], tried: [a.id]))
    }

    // MARK: failoverRank

    func testFailoverRankOrdersBestFirst() {
        // Exact ranks track CarrierTransportMatrix, so assert the ORDERING, not
        // the integers. Combos with genuinely distinct ranks: jitsi/datachannel
        // is recommended (rank 0); jitsi/vp8channel is ok (rank 1);
        // wbstream/datachannel is unstable (rank 2). (telemost/vp8channel is ALSO
        // recommended = rank 0 — vp8channel is telemost's only stable transport —
        // so it can't stand in for the "ok" tier here.)
        let rec = TunnelManager.failoverRank(carrier: "jitsi", transport: "datachannel")
        let ok  = TunnelManager.failoverRank(carrier: "jitsi", transport: "vp8channel")
        let bad = TunnelManager.failoverRank(carrier: "wbstream", transport: "datachannel")
        XCTAssertLessThan(rec, ok)
        XCTAssertLessThan(ok, bad)
        XCTAssertGreaterThanOrEqual(rec, 0)
        XCTAssertLessThanOrEqual(bad, 3)
    }

    func testFailoverRankFailCombosAreWorst() {
        // telemost/datachannel is a broken combo (matrix .fail → rank 3).
        XCTAssertEqual(TunnelManager.failoverRank(carrier: "telemost", transport: "datachannel"), 3)
    }

    // MARK: computeFailoverCandidates

    func testComputeCandidatesMatchesHostViaPrimaryAndExtras() {
        let store = ConnectionStore()
        let serverStore = ServerHostStore()

        let primary = record("primary", carrier: "wbstream", transport: "vp8channel")
        let extra1  = record("extra1",  carrier: "jitsi",    transport: "datachannel")
        let extra2  = record("extra2",  carrier: "telemost", transport: "vp8channel")
        let unrelated = record("unrelated")
        store.connections = [primary, extra1, extra2, unrelated]

        var host = ServerHost(label: "H", host: "1.2.3.4")
        host.lastConnectionID  = primary.id
        host.extraConnectionIDs = [extra1.id, extra2.id]
        serverStore.hosts = [host]

        // From `primary`: the two extras, best-first by matrix rank. Both are
        // rank 0 here (jitsi/datachannel and telemost/vp8channel are each their
        // carrier's recommended combo), so the tie falls to the displayName
        // order — extra1 before extra2. `unrelated` (not on the host) and
        // `primary` itself are excluded.
        let cands = TunnelManager.computeFailoverCandidates(primary, store: store, serverStore: serverStore)
        XCTAssertEqual(cands.map(\.id), [extra1.id, extra2.id])
    }

    func testComputeCandidatesFromAnExtraExcludesItself() {
        let store = ConnectionStore()
        let serverStore = ServerHostStore()
        let primary = record("primary", carrier: "jitsi",    transport: "datachannel")
        let extra   = record("extra",   carrier: "telemost", transport: "vp8channel")
        store.connections = [primary, extra]
        var host = ServerHost(label: "H", host: "1.2.3.4")
        host.lastConnectionID = primary.id
        host.extraConnectionIDs = [extra.id]
        serverStore.hosts = [host]

        // Matching the host via an EXTRA id, `extra` is excluded, `primary` remains.
        let cands = TunnelManager.computeFailoverCandidates(extra, store: store, serverStore: serverStore)
        XCTAssertEqual(cands.map(\.id), [primary.id])
    }

    func testComputeCandidatesEmptyWhenNoHostMatches() {
        let store = ConnectionStore()
        let serverStore = ServerHostStore()
        let lonely = record("lonely")
        store.connections = [lonely]
        serverStore.hosts = []   // no host links this record
        XCTAssertTrue(TunnelManager.computeFailoverCandidates(lonely, store: store, serverStore: serverStore).isEmpty)
    }

    func testComputeCandidatesEmptyWhenStoresNil() {
        let lonely = record("lonely")
        XCTAssertTrue(TunnelManager.computeFailoverCandidates(lonely, store: nil, serverStore: nil).isEmpty)
    }

    // MARK: observed evidence outranks the matrix (#456)

    /// #456: the pure rank itself. Measured proof first, "we don't know" in the
    /// middle, "we just watched it fail" last.
    func testObservedRankPrefersMeasuredProof() {
        XCTAssertLessThan(TunnelManager.observedRank(.verified(ms: 20, age: 5)),
                          TunnelManager.observedRank(.fading(ms: 20, age: 600)))
        XCTAssertLessThan(TunnelManager.observedRank(.fading(ms: 20, age: 600)),
                          TunnelManager.observedRank(.never))
        XCTAssertLessThan(TunnelManager.observedRank(.never),
                          TunnelManager.observedRank(.broken(.keyMismatch, age: 5)))
        // "Couldn't check" must NOT be punished like a failure.
        XCTAssertEqual(TunnelManager.observedRank(.inconclusive(.hostUnreachable, age: 5)),
                       TunnelManager.observedRank(.never))
        // Neither must "connects but no data" — it is unknown, not proven dead.
        XCTAssertEqual(TunnelManager.observedRank(.handshakeOnly(age: 5)),
                       TunnelManager.observedRank(.never))
    }

    /// #456: with NO recorded evidence every candidate ranks the same (2), so the
    /// static matrix still decides — the pre-existing ordering is preserved.
    func testWithoutEvidenceTheMatrixStillDecides() {
        let store = ConnectionStore()
        let serverStore = ServerHostStore()
        let primary = record("primary", carrier: "wbstream", transport: "vp8channel")
        let best    = record("best",    carrier: "jitsi", transport: "datachannel")  // matrix rank 0
        let worse   = record("worse",   carrier: "jitsi", transport: "vp8channel")   // matrix rank 1
        store.connections = [primary, best, worse]
        var host = ServerHost(label: "H", host: "1.2.3.4")
        host.lastConnectionID = primary.id
        host.extraConnectionIDs = [worse.id, best.id]
        serverStore.hosts = [host]

        let cands = TunnelManager.computeFailoverCandidates(primary, store: store, serverStore: serverStore)
        XCTAssertEqual(cands.map(\.id), [best.id, worse.id])
    }

    /// #456: THE regression this exists for — a node the user just watched fail
    /// must stop being tried first, even though the compile-time matrix calls it
    /// the recommended combo.
    func testRecentlyBrokenSortsAfterVerifiedDespiteBetterMatrixRank() {
        let store = ConnectionStore()
        let serverStore = ServerHostStore()
        let primary  = record("primary",  carrier: "wbstream", transport: "vp8channel")
        let broken   = record("broken",   carrier: "jitsi", transport: "datachannel")  // matrix rank 0
        let verified = record("verified", carrier: "jitsi", transport: "vp8channel")   // matrix rank 1
        store.connections = [primary, broken, verified]
        var host = ServerHost(label: "H", host: "1.2.3.4")
        host.lastConnectionID = primary.id
        host.extraConnectionIDs = [broken.id, verified.id]
        serverStore.hosts = [host]

        // Evidence: the "recommended" one just failed a handshake; the "ok" one
        // passed an end-to-end probe seconds ago.
        HealthCoordinator.shared.noteFailure(recordID: broken.id,
                                             raw: "handshake client: read welcome: EOF",
                                             source: "probe")
        HealthCoordinator.shared.noteLiveVerified(recordID: verified.id, rttMs: 44)
        XCTAssertEqual(HealthCoordinator.shared.display(for: broken.id).tone, .error)
        XCTAssertTrue(HealthCoordinator.shared.display(for: verified.id).isVerified)

        let cands = TunnelManager.computeFailoverCandidates(primary, store: store, serverStore: serverStore)
        XCTAssertEqual(cands.map(\.id), [verified.id, broken.id],
                       "measured proof must outrank the static matrix")
    }
}
