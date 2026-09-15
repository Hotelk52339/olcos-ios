import XCTest
@testable import olcrtc_ios

// The persisted per-host snapshot the Servers tab shows before its first
// probe of the session, and the throttle that decides whether to re-probe.
//
// Invariants:
//   • a host with no snapshot displays as `.unknown` ("checking"), never
//     "stopped" — the base for a never-probed host is not guessed;
//   • the snapshot carries no secret: base, clock, three machine strings and
//     a ping — nothing else is encoded;
//   • a snapshot younger than `HostSnapshotPolicy.recheckSeconds` suppresses
//     an automatic re-check unless the caller forces it (pull-to-refresh);
//   • corrupt persisted data decodes to an empty map, never to a throw;
//   • entries older than the forget window are dropped on load.

@MainActor
final class HostSnapshotTests: XCTestCase {

    private let snapshotKey = "olcrtc_host_snapshot_v1"
    private var saved: Data?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.data(forKey: snapshotKey)
        UserDefaults.standard.removeObject(forKey: snapshotKey)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: snapshotKey)
        } else {
            UserDefaults.standard.removeObject(forKey: snapshotKey)
        }
        super.tearDown()
    }

    // MARK: Throttle

    func testRecheckRuleForcedAlwaysProbes() {
        let now = Date()
        XCTAssertTrue(HostSnapshotPolicy.shouldRecheck(lastProbedAt: now, force: true, now: now))
    }

    func testRecheckRuleNeverProbedProbes() {
        XCTAssertTrue(HostSnapshotPolicy.shouldRecheck(lastProbedAt: nil, force: false, now: Date()))
    }

    func testRecheckRuleYoungSnapshotSkips() {
        let now = Date()
        let young = now.addingTimeInterval(-(HostSnapshotPolicy.recheckSeconds - 1))
        XCTAssertFalse(HostSnapshotPolicy.shouldRecheck(lastProbedAt: young, force: false, now: now))
    }

    func testRecheckRuleOldSnapshotProbes() {
        let now = Date()
        let old = now.addingTimeInterval(-(HostSnapshotPolicy.recheckSeconds + 1))
        XCTAssertTrue(HostSnapshotPolicy.shouldRecheck(lastProbedAt: old, force: false, now: now))
    }

    // MARK: Coordinator API

    func testNoteAndReadSnapshot() {
        let health = HealthCoordinator(loadPersisted: false)
        let id = UUID()
        XCTAssertNil(health.hostSnapshot(for: id))
        let snap = HostSnapshot(base: .running, probedAt: Date(), disk: "3.1G/25G",
                                ram: "407M/1967M", uptime: "3 days", pingMs: 42)
        health.noteHostSnapshot(snap, for: id)
        XCTAssertEqual(health.hostSnapshot(for: id), snap)
        XCTAssertFalse(health.shouldRecheckHost(id, force: false))
        XCTAssertTrue(health.shouldRecheckHost(id, force: true))
        health.forgetHost(id)
        XCTAssertNil(health.hostSnapshot(for: id))
        XCTAssertTrue(health.shouldRecheckHost(id, force: false))
    }

    func testSnapshotBaseMapsToDisplayBase() {
        let health = HealthCoordinator(loadPersisted: false)
        let id = UUID()
        health.noteHostSnapshot(HostSnapshot(base: .stopped, probedAt: Date()), for: id)
        XCTAssertEqual(HostBase(snapshot: health.hostSnapshot(for: id)!.base), .stopped)
    }

    // MARK: Persistence contract

    func testEncodedSnapshotCarriesNoSecretFields() throws {
        let snap = HostSnapshot(base: .running, probedAt: Date(), disk: "d", ram: "r",
                                uptime: "u", pingMs: 1)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(["k": snap]), encoding: .utf8))
        for forbidden in ["password", "privateKey", "passphrase", "secret", "host\"", "user\""] {
            XCTAssertFalse(json.contains(forbidden), "snapshot must not encode \(forbidden)")
        }
    }

    func testDecodeRoundTrip() throws {
        let now = Date()
        let id = UUID().uuidString
        let snap = HostSnapshot(base: .imageReady, probedAt: now.addingTimeInterval(-30),
                                disk: nil, ram: nil, uptime: nil, pingMs: nil)
        let data = try JSONEncoder().encode([id: snap])
        let decoded = HealthCoordinator.decodeHostSnapshots(data, now: now)
        XCTAssertEqual(decoded[id]?.base, .imageReady)
        XCTAssertNil(decoded[id]?.pingMs)
    }

    func testDecodeCorruptDataIsEmpty() {
        XCTAssertTrue(HealthCoordinator.decodeHostSnapshots(Data("nope".utf8), now: Date()).isEmpty)
        XCTAssertTrue(HealthCoordinator.decodeHostSnapshots(nil, now: Date()).isEmpty)
    }

    func testDecodeDropsForgottenEntries() throws {
        let now = Date()
        let stale = HostSnapshot(base: .running,
                                 probedAt: now.addingTimeInterval(-(HostSnapshotPolicy.forgetSeconds + 60)))
        let fresh = HostSnapshot(base: .running, probedAt: now.addingTimeInterval(-60))
        let data = try JSONEncoder().encode(["stale": stale, "fresh": fresh])
        let decoded = HealthCoordinator.decodeHostSnapshots(data, now: now)
        XCTAssertNil(decoded["stale"])
        XCTAssertNotNil(decoded["fresh"])
    }

    func testResetClearsSnapshots() {
        let health = HealthCoordinator(loadPersisted: false)
        let id = UUID()
        health.noteHostSnapshot(HostSnapshot(base: .running, probedAt: Date()), for: id)
        health._resetForTesting()
        XCTAssertNil(health.hostSnapshot(for: id))
    }
}
