import XCTest
@testable import olcrtc_ios

// Tests for TunnelManager's connection-state machine — the observable parts.
//
// What this file covers (Group 1 + Group 2 in the test plan):
//   1. Initial state on a fresh instance.
//   2. Direct writes to `state` (the property is `internal`, so @testable
//      can drive transitions without going through the full connect flow).
//   3. The `didSet` no-op guard (writing the same value twice should not
//      re-fire side-effects).
//   4. `connect(record:)` with INVALID params: takes the synchronous
//      validate → .failed path inside preflight() without ever launching
//      the detached MobileStart task.
//   5. #483 was: every busy connect is a no-op. Only SAME record/backend calls
//      are idempotent; different/unknown identity tears down and observably redials.
//
// #483: the historical limitations below described pre-injection tests. This
// suite now uses LifecycleEngine with runtime observers/verification disabled;
// SystemTunnelAdoptionTests/VPNControllerLifecycleTests cover async orchestration.
// Actual Apple routes, signatures and extension execution still require a device.
// #483 was: listed recovery/start/stop as untestable and proposed a future FSM
// extraction. Injecting the existing engine and OS-profile boundaries gives
// async coverage without replacing the real orchestration with a second model.

@MainActor
final class TunnelManagerStateTests: XCTestCase {

    private let validKey = String(repeating: "a", count: 64)

    // Use a fresh instance per test so state from one test cannot leak
    // into the next. The app holds a single `@StateObject TunnelManager()`
    // at the App level (see App.swift), but the class itself isn't a hard
    // singleton — `init` is internal and the constructor only installs a
    // log writer (idempotent across instances).
    // boc #483: every valid connect is fake, and every test joins teardown.
    private var managers: [TunnelManager] = []
    private var savedShared: TunnelManager?
    private var lifecycleSnapshot: TunnelManager.LifecycleSnapshot?
    private var savedModePreference: ConnectionModePreference = .automatic // #487
    private var savedTunnelMode: TunnelMode = .proxy
    private func makeManager() -> TunnelManager {
        let manager = TunnelManager(engine: LifecycleEngine(), runtimeEffectsEnabled: false,
                                    verify: { true })
        managers.append(manager)
        return manager
    }
    // eoc #483

    private func validParams() -> OlcrtcConnection {
        OlcrtcConnection(
            carrier:   "telemost",
            transport: "datachannel",
            roomID:    "room-1",
            key:       validKey,
            clientID:  "ios-test"
        )
    }

    private func invalidParams() -> OlcrtcConnection {
        // Empty clientID — fastest path through validate() into .failed.
        var p = validParams()
        p.clientID = ""
        return p
    }

    private func record(with params: OlcrtcConnection) -> ConnectionRecord {
        ConnectionRecord(name: "test", details: .olcrtc(params))
    }

    // Lock the language for any message comparisons.
    private var savedLanguage: String = ""
    // #456: a real connect attempt now records measured evidence into
    // HealthCoordinator.shared (runEngine / keep-alive chokepoints), which
    // persists to `olcrtc_health_v1`. These tests launch real engine tasks that
    // fail asynchronously in the test host, so snapshot + restore that key like
    // every other one this suite touches.
    private let healthKey = "olcrtc_health_v1"
    private var healthSnapshot: Data?
    // #470: every valid `connect()` below launches a REAL engine task, and a
    // raw `state = .disconnected` (the tidy-up these tests use) does not stop
    // it — only `disconnect()` does. The previous test's Go runtime, or a real
    // daemon on the dev Mac, could therefore still hold the shared default
    // port (8808) when the next preflight ran its synchronous `isFree` check,
    // which failed the attempt with OLC-1026 — `.connecting`, the epoch bump
    // and `boundPort` all asserted false, intermittently, by scheduling order.
    // The #313 tests already reserve a fresh free port each; now every test
    // starts on one (the #313 tests still override it for their own reasons).
    private var savedSocksPort = 0
    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        // #483: force the backend under test; preserve app-hosted global state.
        savedShared = TunnelManager.shared
        lifecycleSnapshot = TunnelManager.lifecycleSnapshot()
        savedModePreference = SettingsStore.shared.connectionModePreference // #487
        savedTunnelMode = SettingsStore.shared.tunnelMode
        SettingsStore.shared.tunnelMode = .proxy
        SettingsStore.shared.language = "en"
        healthSnapshot = UserDefaults.standard.data(forKey: healthKey)   // #456
        savedSocksPort = SettingsStore.shared.socksPort                  // #470
        if let free = someFreePort() { SettingsStore.shared.socksPort = free }
    }
    override func tearDown() async throws { // #483 was: restore while detached Go tasks were live.
        for manager in managers {
            manager.disconnect()
            try await manager.waitForTeardown()
        }
        managers.removeAll()
        TunnelManager.shared = savedShared
        if let lifecycleSnapshot { TunnelManager.restoreLifecycleSnapshot(lifecycleSnapshot) }
        // #456
        HealthCoordinator.shared._resetForTesting()
        HealthCoordinator.flushPendingWrites()
        if let d = healthSnapshot { UserDefaults.standard.set(d, forKey: healthKey) }
        else { UserDefaults.standard.removeObject(forKey: healthKey) }
        SettingsStore.shared.socksPort = savedSocksPort   // #470
        SettingsStore.shared.language = savedLanguage
        SettingsStore.shared.tunnelMode = savedTunnelMode
        SettingsStore.shared.connectionModePreference = savedModePreference // #487: legacy write must not leave an override.
        SettingsStore.flushPendingWrites()
        try await super.tearDown()
    }

    // MARK: Initial state

    // A freshly constructed TunnelManager must report .disconnected.
    // Anything else would mean the singleton has hidden persisted state
    // from a previous session, which would surface as a confusing
    // "already connected on launch" UI bug.
    func testInitialStateIsDisconnected() {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .disconnected)
    }

    // MARK: Direct state writes

    // The setter is reachable via @testable import — `state` has default
    // (internal) access. Driving transitions directly is the only way to
    // exercise the state machine without booting Mobile.xcframework.
    func testCanTransitionThroughHappyPath() {
        let manager = makeManager()
        manager.state = .connecting
        XCTAssertEqual(manager.state, .connecting)
        manager.state = .connected
        XCTAssertEqual(manager.state, .connected)
        manager.state = .disconnected
        XCTAssertEqual(manager.state, .disconnected)
    }

    // The failure variant carries a String payload — exercising it makes
    // sure the associated value round-trips through the @Published setter
    // unchanged (no accidental trimming, no localization rewrite).
    func testFailedStateCarriesItsReasonString() {
        let manager = makeManager()
        manager.state = .failed("boom")
        XCTAssertEqual(manager.state, .failed("boom"))
    }

    // The `.waitingForNetwork` holding state (#269) must round-trip through the
    // @Published setter and be distinct from connected/connecting: ConnectionsView
    // renders it via `== .waitingForNetwork` (not isConnected/isConnecting), and
    // the global toggle stays ON for it. The `description` feeds LogStore.
    func testWaitingForNetworkStateRoundTrips() {
        let manager = makeManager()
        manager.state = .waitingForNetwork
        XCTAssertEqual(manager.state, .waitingForNetwork)
        XCTAssertFalse(manager.state.isConnected)
        XCTAssertFalse(manager.state.isConnecting)
        XCTAssertEqual(manager.state.description, "waitingForNetwork")
        // Tidy up: `.waitingForNetwork` keeps bgKeeper running by design, so
        // drive back to .disconnected to release it (didSet's cleanup branch).
        manager.state = .disconnected
    }

    // didSet has a `guard state != oldValue else { return }` so that
    // re-writing the current state is a no-op. The user-visible reason this
    // matters: keep-alive task is started in didSet when entering .connected.
    // Without the guard, a re-write of .connected would cancel the running
    // keep-alive task and start a fresh one — exactly the race we don't
    // want. We can't observe the private task from here, but we CAN observe
    // that the published value stays consistent across the redundant write.
    func testRewritingSameStateIsObservablyANoOp() {
        let manager = makeManager()
        manager.state = .connecting
        manager.state = .connecting
        XCTAssertEqual(manager.state, .connecting)
    }

    // MARK: connect() with invalid params

    // preflight() runs validate() synchronously on MainActor and, on the
    // first error, sets state = .failed and returns nil — no Task.detached,
    // no MobileStart. This is a real end-to-end FSM transition we CAN test
    // without booting Mobile.xcframework: caller passes a bad record,
    // manager moves .disconnected → .failed with the validation message.
    func testConnectWithInvalidParamsTransitionsToFailed() {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .disconnected)
        manager.connect(record: record(with: invalidParams()))
        XCTAssertEqual(manager.state, .failed(L10n.validateClientIDEmpty.localized()))
    }

    // The "Retry on the error banner" UX (see the comment on connect()):
    // connect() must accept .failed as a starting state, not just
    // .disconnected. Verify by chaining a second invalid connect after the
    // first one — it should transition .failed → .failed(same message)
    // again rather than being ignored.
    func testConnectFromFailedStateIsAllowed() {
        let manager = makeManager()
        manager.state = .failed("previous error")
        manager.connect(record: record(with: invalidParams()))
        XCTAssertEqual(manager.state, .failed(L10n.validateClientIDEmpty.localized()))
    }

    // MARK: connect() guard on busy states

    // The double-tap guard at the top of connect() is SAME-RECORD idempotence
    // (pinned in testMultipleConnectCallsWhileConnectingDoNotStackStates and
    // SystemTunnelAdoptionTests). A live state with NO record is different:
    // #477 was: treated as "never tear down a session we cannot identify" — but
    // an adopted system tunnel reaches exactly this shape in production, and
    // swallowing the tap meant nothing could be connected while it ran. It is
    // torn down and redialled now.
    func testConnectWhileConnectingWithNoRecordTearsDownAndRedials() {
        let manager = makeManager()
        manager.state = .connecting
        manager.connect(record: record(with: invalidParams()))
        // #483/E1: with no runtime to drain, the replacement MUST reach validation.
        // A broken disconnect(); return implementation cannot pass this pin.
        XCTAssertEqual(manager.state, .failed(L10n.validateClientIDEmpty.localized()))
    }

    // Same shape from the .connected side.
    func testConnectWhileConnectedWithNoRecordTearsDownAndRedials() {
        let manager = makeManager()
        manager.state = .connected
        manager.connect(record: record(with: invalidParams()))
        XCTAssertEqual(manager.state, .failed(L10n.validateClientIDEmpty.localized())) // #483/E1
        // Clean up so the .connected didSet's keep-alive task doesn't
        // outlive the test (the .disconnected write above already ran the
        // cancel path; keep the explicit tidy for symmetry with the rest).
        manager.state = .disconnected
    }

    // MARK: disconnect() from .connected

    // disconnect() cancels tasks, stops the background keeper, calls
    // MobileStop(), clears lastRecord, and sets state = .disconnected.
    //
    // Calling MobileStop() without a prior MobileStart() is documented in
    // the file header as "technically defined behavior in Go (nil-checked
    // cancel var)" but this test file deliberately avoids taking a hard
    // dependency on that contract from a unit test — if the Go runtime
    // is not linked or behaves differently in the test host the call may
    // crash or produce undefined results.
    //
    // Therefore we skip when Mobile.xcframework is not available in the
    // test environment, and otherwise verify only the observable outcome:
    // state transitions from .connected to .disconnected.
    func testDisconnectFromConnectedTransitionsToDisconnected() throws {
        // Guard: MobileStop() is defined in the Go binding's Objective-C
        // header. If the test host does not have a properly initialised Go
        // runtime the call will silently no-op (cancel is nil-checked on
        // the Go side) — that is the contract we rely on here.
        // If future evidence shows this is unsafe in the test environment,
        // replace the body with:
        //   throw XCTSkip("MobileStop() unsafe without Go runtime")
        let manager = makeManager()
        manager.state = .connected
        manager.disconnect()
        XCTAssertEqual(manager.state, .disconnected)
    }

    // MARK: connect() with valid params — synchronous .connecting transition

    // startOlcrtc() runs preflight() synchronously on MainActor, and on
    // success sets state = .connecting *before* launching the detached
    // MobileStart Task. Because this whole method body runs on MainActor
    // and the detached Task is — by definition — deferred to a later
    // scheduling point, we can assert .connecting synchronously right
    // after connect() returns, without awaiting anything.
    //
    // Note: the detached Task will eventually call MobileStartWithTransport
    // on a background thread. In the test host that call will fail (no real
    // Go runtime / signalling server) and post manager.state = .failed back
    // to MainActor, but only on a subsequent run-loop turn — invisible to
    // this synchronous assertion.
    func testConnectFromDisconnectedWithValidParamsTransitionsToConnecting() {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .disconnected)
        manager.connect(record: record(with: validParams()))
        // Synchronously observable: preflight succeeded → state = .connecting
        // was set before Task.detached was enqueued.
        XCTAssertEqual(manager.state, .connecting)
        // Tidy up: cancel any lingering recoveryTask / keepAliveTask by driving
        // state to .disconnected. The private tasks are not observable but
        // the cancellation code path in didSet runs.
        manager.state = .disconnected
    }

    // MARK: Multiple connect() calls while already connecting

    // The switch guard at the top of connect() returns early when state
    // is .connecting. Calling connect() three times in a row must not
    // stack additional detached Tasks or produce any state other than
    // .connecting. The first call flips state to .connecting (via the
    // same synchronous-preflight path verified above); the subsequent two
    // calls hit the early-return and are silent no-ops.
    func testMultipleConnectCallsWhileConnectingDoNotStackStates() {
        let manager = makeManager()
        // #469: a double-tap is the SAME record. `record(with:)` mints a fresh id
        // per call, and a different id is a protocol switch now (see the test
        // below), so the repeat calls reuse one record.
        let same = record(with: validParams())
        manager.connect(record: same)
        XCTAssertEqual(manager.state, .connecting, "first call must flip to .connecting")
        manager.connect(record: same)
        XCTAssertEqual(manager.state, .connecting, "second call must not change state")
        manager.connect(record: same)
        XCTAssertEqual(manager.state, .connecting, "third call must not change state")
        // Tidy up.
        manager.state = .disconnected
    }

    // #469: the user's complaint — tapping ANOTHER protocol while a session is
    // up used to do nothing (connect returned on every live state). A different
    // record is a switch: the live attempt is torn down synchronously, and the
    // new one dials once the engine has stopped (asynchronously, off-actor).
    func testConnectWithADifferentRecordWhileConnectingSwitches() async { // #483/E1
        let manager = makeManager()
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting)
        var other = validParams()
        other.roomID = "room-2"
        let next = record(with: other)
        manager.connect(record: next)
        // The old attempt is gone the moment the switch is requested; the new
        // dial waits for the teardown, so it is not observable synchronously.
        XCTAssertEqual(manager.state, .connecting, "hold the toggle on while teardown drains") // #483
        await lifecycleEventually { manager.boundPort != nil && manager.engagedRecord?.id == next.id }
        XCTAssertEqual(manager.engagedRecord?.id, next.id, "replacement must reach preflight")
        manager.disconnect()
    }

    // #469 pinned "a live state without a record is never torn down" here.
    // #477 inverts that on purpose — an adopted system tunnel holds exactly this
    // shape, and the tap must not be swallowed. The replacement pin lives in
    // SystemTunnelAdoptionTests.testConnectIsNotSwallowedWhileALiveStateHasNoRecord.

    // MARK: Connect epoch (#272)

    // Each launched connect attempt must advance the monotonic `connectEpoch`, so
    // a detached `runEngine` from a superseded attempt can tell it is stale and
    // bail instead of aliasing a newer attempt's `.connecting`. The aliasing race
    // itself needs the full async engine flow (not unit-testable here), but the
    // counter it relies on is observable.
    func testEachConnectAttemptAdvancesTheEpoch() {
        let manager = makeManager()
        let e0 = manager.connectEpoch
        manager.connect(record: record(with: validParams()))
        let e1 = manager.connectEpoch
        XCTAssertGreaterThan(e1, e0, "a launched attempt must bump the epoch")
        // Back to .disconnected so a second connect is allowed, then verify the
        // epoch advances again (strictly monotonic across attempts).
        manager.state = .disconnected
        manager.connect(record: record(with: validParams()))
        XCTAssertGreaterThan(manager.connectEpoch, e1)
        manager.state = .disconnected
    }

    // #483 was: invalid attempts did not advance epochs. A new user request
    // supersedes old work BEFORE validation, even if the replacement is invalid.
    func testInvalidConnectInvalidatesThePreviousEpoch() {
        let manager = makeManager()
        let e0 = manager.connectEpoch
        manager.connect(record: record(with: invalidParams()))
        XCTAssertEqual(manager.state, .failed(L10n.validateClientIDEmpty.localized()))
        XCTAssertGreaterThan(manager.connectEpoch, e0, "invalid replacement still supersedes old work") // #483
    }

    // boc #313
    // MARK: Bound port (#313)
    //
    // `boundPort` is the port the live attempt actually bound — the snapshot
    // preflight reserved (#308: the engine binds exactly it or the attempt
    // fails). The Settings port check compares against it, so its lifecycle is
    // part of the UI contract: nil while idle, the snapshot while
    // connecting/connected (even after a live Settings edit), nil again the
    // moment the session ends. Like the epoch tests above, preflight runs
    // synchronously on MainActor, so `boundPort` is observable right after
    // connect() returns, before the detached engine task gets a turn.

    // Preflight probes the configured port with PortAvailability.isFree and
    // fails the attempt on a busy one, so the tests below must configure a
    // genuinely free port first.
    private func someFreePort() -> Int? {
        for _ in 0..<20 {
            let candidate = UInt16.random(in: 20_000...60_000)
            if PortAvailability.isFree(candidate) { return Int(candidate) }
        }
        return nil
    }

    func testBoundPortIsNilOnFreshInstance() {
        XCTAssertNil(makeManager().boundPort)
    }

    // The core #313 fix: the snapshot must NOT follow a later Settings edit.
    // The old check assumed configured == bound, so while connected any value
    // typed into the port field was labeled "in use by olcrtc tunnel".
    func testBoundPortTracksTheSnapshotNotTheLiveSetting() throws {
        let s = SettingsStore.shared
        let saved = s.socksPort
        defer { s.socksPort = saved }
        let free = try XCTUnwrap(someFreePort(), "no free local port to test on")

        s.socksPort = free
        let manager = makeManager()
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting)
        XCTAssertEqual(manager.boundPort, free, "preflight must publish the reserved port")

        // Live port edit while the attempt is up: the snapshot stands.
        s.socksPort = free == 8808 ? 8809 : 8808
        XCTAssertEqual(manager.boundPort, free,
                       "boundPort must keep the connect-time snapshot, not track Settings")
        manager.state = .disconnected
    }

    // Session over → no port held. All three terminal/holding transitions clear
    // the snapshot: .disconnected, .failed, and .waitingForNetwork (the path
    // monitor stops the engine before entering the hold, releasing the listener).
    func testBoundPortClearsWhenTheSessionEnds() throws {
        let s = SettingsStore.shared
        let saved = s.socksPort
        defer { s.socksPort = saved }

        for terminal in [ConnectionState.disconnected,
                         .failed("boom"),
                         .waitingForNetwork] {
            let manager = makeManager() // #483: independent session, not an unawaited restart.
            // A fresh free port per attempt: the previous iteration's detached
            // engine task may still (briefly) hold its port, and preflight
            // fails the attempt on a busy one.
            s.socksPort = try XCTUnwrap(someFreePort(), "no free local port to test on")
            manager.state = .disconnected     // connect() requires an idle state
            manager.connect(record: record(with: validParams()))
            XCTAssertNotNil(manager.boundPort, "attempt must publish a bound port")
            manager.state = terminal
            XCTAssertNil(manager.boundPort, "\(terminal) must clear boundPort")
        }
        // Tidy up: .waitingForNetwork keeps bgKeeper alive by design.
        // #483: async tearDown disconnects and joins every manager above.
    }
    // eoc #313

    // MARK: nonisolated bound-port mirror + activeSocksPort (#351)
    //
    // SOCKSSession builds tunnel-mode sessions off MainActor, so it can't read the
    // @Published `boundPort`. #351 mirrors every write into a nonisolated
    // `liveBoundPort`, and `activeSocksPort` prefers it over the configured port
    // while a session is live — otherwise a live port edit while connected would
    // point keep-alive's verify probe at the wrong port and tear down a healthy
    // tunnel (#313 follow-up). The mirror's lifecycle must match `boundPort`.

    func testActiveSocksPortFallsBackToConfiguredWhenIdle() throws {
        let s = SettingsStore.shared
        let saved = s.socksPort
        defer { s.socksPort = saved }
        let free = try XCTUnwrap(someFreePort(), "no free local port to test on")

        // Drive a full connect→disconnect so the mirror is deterministically
        // cleared (the static `liveBoundPort` is shared across instances/tests,
        // so a prior connect could otherwise leave it set).
        s.socksPort = free
        let manager = makeManager()
        manager.connect(record: record(with: validParams()))
        manager.state = .disconnected
        XCTAssertNil(TunnelManager.liveBoundPort, "mirror must clear when the session ends")
        // No live session → activeSocksPort falls back to the configured port.
        XCTAssertEqual(TunnelManager.activeSocksPort, free)
    }

    func testActiveSocksPortPrefersBoundPortWhileConnectedAfterLiveEdit() throws {
        let s = SettingsStore.shared
        let saved = s.socksPort
        defer { s.socksPort = saved }
        let free = try XCTUnwrap(someFreePort(), "no free local port to test on")

        s.socksPort = free
        let manager = makeManager()
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting)
        // The mirror tracks the reserved snapshot and activeSocksPort prefers it.
        XCTAssertEqual(TunnelManager.liveBoundPort, free)
        XCTAssertEqual(TunnelManager.activeSocksPort, free)

        // Live port edit while up: in-app SOCKS traffic must still target the
        // port the session actually bound, not the freshly-typed setting (#351).
        let other = free == 8808 ? 8809 : 8808
        s.socksPort = other
        XCTAssertEqual(TunnelManager.activeSocksPort, free,
                       "activeSocksPort must stay on the bound port, not the edited setting")

        // Session over → mirror clears → activeSocksPort falls back to configured.
        manager.state = .disconnected
        XCTAssertNil(TunnelManager.liveBoundPort)
        XCTAssertEqual(TunnelManager.activeSocksPort, other)
    }

    // MARK: lastTunnelActivityDate — lock-backed get/set/reset (#372)
    //
    // The activity marker is now backed by an OSAllocatedUnfairLock instead of a
    // `nonisolated(unsafe)` raw static. The Date? surface must round-trip a value
    // (sub-millisecond precision is lost going through Double, so compare with a
    // tolerance), reset to nil, and stay consistent under concurrent writes/reads
    // (no crash, no torn read — the previous unsynchronised static was UB).

    func testActivityDateRoundTripsAndResets() throws {
        let now = Date()
        TunnelManager.lastTunnelActivityDate = now
        let read = try XCTUnwrap(TunnelManager.lastTunnelActivityDate)
        XCTAssertEqual(read.timeIntervalSinceReferenceDate,
                       now.timeIntervalSinceReferenceDate, accuracy: 0.001)
        // #333 reset-on-disconnect semantics.
        TunnelManager.lastTunnelActivityDate = nil
        XCTAssertNil(TunnelManager.lastTunnelActivityDate)
    }

    func testActivityDateConcurrentAccessIsSafe() {
        // Hammer the lock-backed store from many tasks at once; the assertion is
        // simply that this completes without a crash / sanitizer trap and leaves
        // a readable (non-torn) value behind. Under the old raw static this was a
        // data race; ThreadSanitizer would flag it.
        let exp = expectation(description: "concurrent activity writes")
        exp.expectedFulfillmentCount = 64
        for i in 0..<64 {
            DispatchQueue.global().async {
                if i % 2 == 0 {
                    TunnelManager.lastTunnelActivityDate = Date()
                } else {
                    _ = TunnelManager.lastTunnelActivityDate
                }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 5)
        // Leave a clean baseline for any later test reading the shared static.
        TunnelManager.lastTunnelActivityDate = nil
    }

    // MARK: liveBoundPort — lock-backed concurrent access (#382)
    //
    // #351's `liveBoundPort` mirror was a `nonisolated(unsafe)` static written on
    // MainActor (via boundPort.didSet) but read off MainActor by SOCKSSession (from
    // the detached verifyTunnel task) — a genuine data race. It's now backed by an
    // OSAllocatedUnfairLock; hammering it from many tasks must not crash / trap, and
    // the nonisolated getter must round-trip the value the MainActor setter wrote.

    // #470 was: 64 off-actor READS and no write at all (`_ = i` was a leftover)
    // — a reads-only loop over a static cannot race even with the old
    // `nonisolated(unsafe)` implementation, so the test could not detect the
    // #382 bug it exists for. The setter is `private`; the MainActor paths that
    // write it are `connect()` (preflight publishes the reserved port) and the
    // session-ending `state` transitions (`didSet` clears `boundPort`, and every
    // assignment mirrors into the static — `.failed("a")` → `.failed("b")` is a
    // change, so each one is a write). Interleave those with the reads.
    func testLiveBoundPortConcurrentAccessIsSafe() throws {
        let s = SettingsStore.shared
        let saved = s.socksPort
        defer { s.socksPort = saved }
        let free = try XCTUnwrap(someFreePort(), "no free local port to test on")
        s.socksPort = free
        let manager = makeManager()
        manager.connect(record: record(with: validParams()))   // MainActor write: `free`
        XCTAssertEqual(TunnelManager.liveBoundPort, free)

        let exp = expectation(description: "concurrent liveBoundPort access")
        exp.expectedFulfillmentCount = 64
        for i in 0..<64 {
            DispatchQueue.global().async {
                _ = TunnelManager.liveBoundPort   // off-actor read, racing the write below
                exp.fulfill()
            }
            manager.state = .failed("race \(i)")   // MainActor write: nil, through the lock
        }
        wait(for: [exp], timeout: 5)
        manager.state = .disconnected
        XCTAssertNil(TunnelManager.liveBoundPort, "the last write must be the one that reads back")
    }

    func testLiveBoundPortMirrorsBoundPortAcrossASession() throws {
        let s = SettingsStore.shared
        let saved = s.socksPort
        defer { s.socksPort = saved }
        let free = try XCTUnwrap(someFreePort(), "no free local port to test on")
        s.socksPort = free
        let manager = makeManager()
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(TunnelManager.liveBoundPort, free,
                       "the lock-backed mirror must track the reserved port")
        manager.state = .disconnected
        XCTAssertNil(TunnelManager.liveBoundPort,
                     "the mirror must clear when the session ends")
    }

    // MARK: connectedRecord — live node, not the UI selection (#388/#389)
    //
    // The live node is whatever `connect()` last started, exposed only while the
    // session is up. Distinct from the UI's `store.primary`, which a no-reconnect
    // row tap moves without changing the live session. nil unless `.connected`.

    func testConnectedRecordNilUntilConnected() {
        let manager = makeManager()
        XCTAssertNil(manager.connectedRecord, "no session → nil")
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting)
        XCTAssertNil(manager.connectedRecord, "connecting (not yet verified) → still nil")
        manager.state = .disconnected
    }

    func testConnectedRecordIsTheStartedRecordWhileConnected() {
        let manager = makeManager()
        let r = record(with: validParams())
        manager.connect(record: r)
        // Drive to .connected directly (the real verify path needs a Go runtime).
        manager.state = .connected
        XCTAssertEqual(manager.connectedRecord?.id, r.id,
                       "connectedRecord must surface the node the tunnel holds")
        manager.state = .disconnected
        XCTAssertNil(manager.connectedRecord, "cleared once the session ends")
    }

    // MARK: secretsLocked guard moved into connect() (#393)
    //
    // The locked-secrets short-circuit used to live in ConnectionsView.connectGuarded,
    // which auto-connect-on-launch bypassed. It now lives in TunnelManager.connect, so
    // EVERY caller gets the actionable unlock message instead of the misleading
    // "Key must be 64 hex characters (got: 0)".

    func testConnectShortCircuitsWhenSecretsLocked() {
        let manager = makeManager()
        manager.secretsLocked = { true }
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .failed(L10n.errorSecretsLocked.localized()),
                       "a locked-secrets connect must surface the unlock message")
    }

    func testConnectProceedsPastGuardWhenSecretsUnlocked() {
        let manager = makeManager()
        manager.secretsLocked = { false }   // unlocked → normal preflight
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting,
                       "an unlocked connect must run preflight as usual")
        manager.state = .disconnected
    }
}
