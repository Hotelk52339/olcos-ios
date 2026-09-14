import XCTest
@testable import olcrtc_ios

// #472: two field reports, one root each.
//
//  1. "I create a key in the app, it is added, but I have to press Verify by
//     hand before it works." — nothing dropped the health verdict when a
//     record's connection changed, so the row kept quoting a measurement of a
//     deployment that no longer existed (usually "Key no longer matches").
//  2. "On jitsi, turn the VPN on, and Yandex Telemost starts saying the service
//     refused." — the probe guard only fired once the app's own state machine
//     reached `.connected`, but the system installs the VPN routes earlier. In
//     that window a Telemost probe left through the tunnel, reached Yandex from
//     the SERVER's address and was refused.
//
// Both fixes are pure rules, so they are tested as rules. The probe itself is
// integration-only (it drives the Go core).
@MainActor
final class Review472Tests: XCTestCase {

    private let key = String(repeating: "a", count: 64)

    private func record(carrier: String = "telemost", transport: String = "vp8channel",
                        room: String = "room-1", clientID: String = "default",
                        key overrideKey: String? = nil) -> ConnectionRecord {
        ConnectionRecord(name: "n", details: .olcrtc(OlcrtcConnection(
            carrier: carrier, transport: transport, roomID: room,
            key: overrideKey ?? key, clientID: clientID)))
    }

    // MARK: the fingerprint decides what a verdict is about

    func testFingerprintIgnoresEverythingThatCannotChangeTheOutcome() {
        var a = record()
        var b = a
        b.name = "renamed"
        b.groupName = "another group"
        XCTAssertEqual(HealthCoordinator.fingerprint(a), HealthCoordinator.fingerprint(b),
                       "a rename cannot make a working node stop working")
        // The room stamp is bookkeeping, not connection identity.
        if case .olcrtc(var p) = a.details { p.roomCreatedAt = Date(); a.details = .olcrtc(p) }
        XCTAssertEqual(HealthCoordinator.fingerprint(a), HealthCoordinator.fingerprint(b))
    }

    func testFingerprintChangesWithEveryFieldTheHandshakeDependsOn() {
        let base = HealthCoordinator.fingerprint(record())
        XCTAssertNotEqual(base, HealthCoordinator.fingerprint(record(carrier: "jitsi")))
        XCTAssertNotEqual(base, HealthCoordinator.fingerprint(record(transport: "datachannel")))
        XCTAssertNotEqual(base, HealthCoordinator.fingerprint(record(room: "room-2")))
        XCTAssertNotEqual(base, HealthCoordinator.fingerprint(record(clientID: "other")))
        XCTAssertNotEqual(base, HealthCoordinator.fingerprint(record(key: String(repeating: "b", count: 64))),
                          "a rotated key is a different deployment — this is the reported bug")
    }

    func testFingerprintNeverCarriesTheKeyItself() {
        // NodeHealth is persisted to UserDefaults; a secret must never be able to
        // reach it through this value.
        let fp = HealthCoordinator.fingerprint(record()) ?? ""
        XCTAssertFalse(fp.contains(key), "the key is hashed, never embedded")
    }

    // MARK: a changed record drops its verdict, so the row stops lying

    func testUpdatingAKeyForgetsTheVerdictThatMeasuredTheOldOne() {
        let store = ConnectionStore()
        let rec = record()
        store.add(rec)
        defer { store.remove(id: rec.id); ConnectionSecretStore.remove(connectionID: rec.id) }

        HealthCoordinator.shared.noteLiveVerified(recordID: rec.id, rttMs: 120)
        XCTAssertTrue(HealthCoordinator.shared.display(for: rec.id).isVerified)

        var rotated = rec
        if case .olcrtc(var p) = rotated.details {
            p.key = String(repeating: "b", count: 64)
            rotated.details = .olcrtc(p)
        }
        store.update(rotated)
        XCTAssertEqual(HealthCoordinator.shared.display(for: rec.id), .never,
                       "the old verdict measured the old key — it is not evidence about this record")
    }

    func testARenameKeepsTheVerdict() {
        let store = ConnectionStore()
        let rec = record()
        store.add(rec)
        defer { store.remove(id: rec.id); ConnectionSecretStore.remove(connectionID: rec.id) }

        HealthCoordinator.shared.noteLiveVerified(recordID: rec.id, rttMs: 120)
        var renamed = rec
        renamed.name = "my server"
        store.update(renamed)
        XCTAssertTrue(HealthCoordinator.shared.display(for: rec.id).isVerified,
                      "renaming measures nothing — the verdict still stands")
    }
}

// #476: container logs are keyed by the container, not by the host. A host runs
// one container per protocol, and they all wrote into a single per-host buffer —
// so the Logs picker changed which container was FETCHED but never what was
// shown, and a sibling protocol's output could not be read at all.
@MainActor
final class ContainerLogKeyTests: XCTestCase {

    func testTwoProtocolsOnOneHostGetDifferentBuckets() {
        let primary = LogStore.containerKey(prefix: "nl", container: "olcrtc-server-abc")
        let sibling = LogStore.containerKey(prefix: "nl", container: "olcrtc-server-abc-telemost")
        XCTAssertNotEqual(primary, sibling, "this equality is the bug: one buffer for both")
    }

    func testTheSameContainerOnTwoHostsStaysApart() {
        XCTAssertNotEqual(LogStore.containerKey(prefix: "nl", container: "olcrtc-server-abc"),
                          LogStore.containerKey(prefix: "de", container: "olcrtc-server-abc"))
    }

    func testTheKeyIsUsableAsAFileName() {
        // It becomes `<key>_container.log`, so nothing in it may be a path
        // separator or a character the file system argues about.
        let key = LogStore.containerKey(prefix: "nl", container: "olcrtc/server:abc 1")
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains(":"))
        XCTAssertFalse(key.contains(" "))
    }

    func testTheKeyIsStable() {
        XCTAssertEqual(LogStore.containerKey(prefix: "nl", container: "olcrtc-server-abc"),
                       LogStore.containerKey(prefix: "nl", container: "olcrtc-server-abc"))
    }
}
