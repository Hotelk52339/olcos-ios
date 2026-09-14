// Offline identity, atomic persistence and NIO delegate tests. No SSH sockets.
import XCTest
import NIO
import NIOSSH
@testable import olcrtc_ios

final class SSHHostKeyVerificationTests: XCTestCase {
    // Public RFC8032 test-vector key; no private credential is stored here.
    private let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINdamAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea"
    private let fingerprint = "SHA256:bbXpuKG6zhzdmnxq256TlqzFBzRl2f6OOg722cYNbU8"
    private var different: String {
        "SHA256:" + Data(repeating: 0, count: 32).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    private func fileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-tofu-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("trust.json")
    }

    private func makeStore() -> SSHHostKeyTrustStore {
        SSHHostKeyTrustStore(fileURL: fileURL())
    }

    func testCanonicalDNSEndpointIncludesPort() {
        XCTAssertEqual(SSHHostKeyVerification.endpoint(host: " VPS.Example. \n", port: 22),
                       "vps.example:22")
        XCTAssertNotEqual(SSHHostKeyVerification.endpoint(host: "vps.example", port: 22),
                          SSHHostKeyVerification.endpoint(host: "vps.example", port: 2222))
    }

    func testIPv6AliasesShareAnUnambiguousEndpoint() throws {
        let endpoint = SSHHostKeyVerification.endpoint(host: "[2001:DB8::1]", port: 2222)
        XCTAssertEqual(endpoint, "[2001:db8:0:0:0:0:0:1]:2222")
        XCTAssertEqual(endpoint, SSHHostKeyVerification.endpoint(
            host: "2001:0db8:0000:0000:0000:0000:0000:0001", port: 2222))
        XCTAssertEqual(SSHHostKeyVerification.endpoint(host: "192.0.2.1", port: 22),
                       "192.0.2.1:22")
        let store = makeStore()
        try store.validate(presented: fingerprint,
                           for: store.prepare(host: "[2001:DB8::1]", port: 2222))
        try store.validate(presented: fingerprint, for: store.prepare(
            host: "2001:0db8:0000:0000:0000:0000:0000:0001", port: 2222))
    }

    func testMalformedEndpointsCannotAcquireTrust() {
        let store = makeStore()
        for host in ["", " ", "https://vps.example", "host:22", "a/b", "user@host",
                     "host\nname", "vps..example", ".example", "-host", "[bad]"] {
            XCTAssertNil(SSHHostKeyVerification.endpoint(host: host, port: 22), host)
            XCTAssertThrowsError(try store.prepare(host: host, port: 22))
            XCTAssertFalse(store.hasTrust(host: host, port: 22))
        }
        for port in [-1, 0, 65536] {
            XCTAssertThrowsError(try store.prepare(host: "vps.example", port: port))
        }
    }

    func testFingerprintNormalizationRejectsWrongLengthAndNonCanonicalBase64() {
        XCTAssertEqual(SSHHostKeyVerification.normalizedFingerprint("\n\(fingerprint) "), fingerprint)
        XCTAssertEqual(SSHHostKeyVerification.normalizedFingerprint(fingerprint + "="), fingerprint)
        for value in ["", "MD5:00:01", "sha256:" + String(repeating: "A", count: 43),
                      "SHA256:abc", fingerprint + "==", fingerprint + " extra",
                      String(fingerprint.dropLast()) + "9"] {
            XCTAssertNil(SSHHostKeyVerification.normalizedFingerprint(value), value)
        }
    }

    func testFingerprintMatchesOpenSSHWireBlobDigest() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: publicKey)
        XCTAssertEqual(try SSHHostKeyVerification.fingerprint(of: key), fingerprint)
    }

    func testFirstKeyIsAutomaticAndReconnectSurvivesNewStoreInstance() throws {
        let url = fileURL()
        let store = SSHHostKeyTrustStore(fileURL: url)
        let context = try store.prepare(host: "vps.example", port: 22)
        XCTAssertFalse(store.hasTrust(host: "vps.example", port: 22), "Preparing a dial is not trust")
        try store.validate(presented: fingerprint, for: context)
        XCTAssertFalse(store.hasMismatch(host: "vps.example", port: 22))
        XCTAssertTrue(store.hasTrust(host: "VPS.EXAMPLE.", port: 22))
        let reopened = SSHHostKeyTrustStore(fileURL: url)
        try reopened.validate(presented: fingerprint,
                              for: reopened.prepare(host: "VPS.EXAMPLE.", port: 22))
        XCTAssertTrue(reopened.hasTrust(host: "vps.example", port: 22))
    }

    func testMismatchAndNewAlgorithmNeverReplaceRememberedIdentity() throws {
        let url = fileURL()
        let store = SSHHostKeyTrustStore(fileURL: url)
        let context = try store.prepare(host: "vps.example", port: 22)
        try store.validate(presented: fingerprint, for: context)
        let before = try Data(contentsOf: url)
        // Any different wire-key digest, including an algorithm change, fails.
        for _ in 0..<3 {
            XCTAssertThrowsError(try store.validate(presented: different, for: context)) {
                XCTAssertEqual($0 as? SSHHostKeyError, .mismatch)
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(store.hasMismatch(host: "VPS.EXAMPLE.", port: 22))
        XCTAssertFalse(store.hasMismatch(host: "vps.example", port: 2222))
        XCTAssertTrue(SSHHostKeyTrustStore(fileURL: url).hasMismatch(host: "vps.example", port: 22))
        try store.validate(presented: fingerprint, for: context)
        XCTAssertTrue(store.hasMismatch(host: "vps.example", port: 22),
                      "A matching connection must not silently erase an earlier warning")
    }

    func testHostAndPortAreIndependentAndRelayLocalhostIsNeverTrusted() throws {
        let store = makeStore()
        let original = try store.prepare(host: "vps.example", port: 22)
        XCTAssertEqual(original.endpoint, "vps.example:22")
        // Exactly this context travels through SSHRunner's relay/dial changes.
        try store.validate(presented: fingerprint, for: original)
        XCTAssertFalse(store.hasTrust(host: "127.0.0.1", port: 49152))
        XCTAssertFalse(store.hasTrust(host: "127.0.0.1", port: 49153))
        XCTAssertFalse(store.hasTrust(host: "localhost", port: 22))
        XCTAssertFalse(store.hasTrust(host: "different.example", port: 22))
        XCTAssertFalse(store.hasTrust(host: "vps.example", port: 2222))
        for (host, port) in [("different.example", 22), ("vps.example", 2222)] {
            try store.validate(presented: different, for: store.prepare(host: host, port: port))
        }
        try store.validate(presented: fingerprint, for: original)
    }

    func testLegacyMultiKeyPinMigratesWithoutTrustingAnUnknownKey() throws {
        let store = makeStore()
        let pin = SSHHostKeyPin(endpoint: "vps.example:22", fingerprints: [fingerprint, different])
        let context = try store.prepare(host: "VPS.EXAMPLE.", port: 22, legacyPin: pin)
        XCTAssertTrue(store.hasTrust(host: "vps.example", port: 22))
        try store.validate(presented: fingerprint, for: context)
        try store.validate(presented: different, for: context)
        let unknown = "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try store.validate(presented: unknown, for: context)) {
            XCTAssertEqual($0 as? SSHHostKeyError, .mismatch)
        }
    }

    func testDuplicateModelWithoutPinCannotBeatSavedExplicitTrustToFirstUse() throws {
        let pin = SSHHostKeyPin(endpoint: "vps.example:22", fingerprints: [fingerprint])
        let store = SSHHostKeyTrustStore(fileURL: fileURL(), legacyPins: { [pin] })
        // This row has no pin, but another stored UUID at this endpoint does.
        let context = try store.prepare(host: "vps.example", port: 22)
        XCTAssertThrowsError(try store.validate(presented: different, for: context)) {
            XCTAssertEqual($0 as? SSHHostKeyError, .mismatch)
        }
        try store.validate(presented: fingerprint, for: context)
    }

    func testEditedEndpointRetainsOldLegacyTrustWithoutTransferringIt() throws {
        let store = makeStore()
        let pin = SSHHostKeyPin(endpoint: "old.example:22", fingerprints: [fingerprint])
        let edited = try store.prepare(host: "new.example", port: 2222, legacyPin: pin)
        XCTAssertTrue(store.hasTrust(host: "old.example", port: 22))
        XCTAssertFalse(store.hasTrust(host: "new.example", port: 2222))
        try store.validate(presented: different, for: edited)
        let old = try store.prepare(host: "old.example", port: 22)
        XCTAssertThrowsError(try store.validate(presented: different, for: old))
        try store.validate(presented: fingerprint, for: old)
    }

    func testConflictingAndMalformedLegacyPinsFailClosed() throws {
        let store = makeStore()
        let context = try store.prepare(host: "vps.example", port: 22)
        try store.validate(presented: fingerprint, for: context)
        let conflicting = SSHHostKeyPin(endpoint: context.endpoint, fingerprints: [different])
        XCTAssertThrowsError(try store.prepare(host: "vps.example", port: 22, legacyPin: conflicting)) {
            XCTAssertEqual($0 as? SSHHostKeyError, .mismatch)
        }
        for malformed in [
            SSHHostKeyPin(endpoint: context.endpoint, fingerprints: ["SHA256:invalid"]),
            SSHHostKeyPin(endpoint: context.endpoint, fingerprints: []),
            SSHHostKeyPin(endpoint: "invalid:0", fingerprints: [fingerprint])
        ] {
            XCTAssertThrowsError(try store.prepare(host: "vps.example", port: 22, legacyPin: malformed))
        }
        try store.validate(presented: fingerprint, for: context)
    }

    func testUnrelatedLegacyConflictDoesNotMisreportCurrentHostAsChanged() throws {
        let url = fileURL()
        let initial = SSHHostKeyTrustStore(fileURL: url)
        try initial.validate(presented: fingerprint,
                             for: initial.prepare(host: "other.example", port: 22))
        let conflict = SSHHostKeyPin(endpoint: "other.example:22", fingerprints: [different])
        let malformed = SSHHostKeyPin(endpoint: "broken.example:22", fingerprints: ["bad"])
        let store = SSHHostKeyTrustStore(fileURL: url, legacyPins: { [conflict, malformed] })
        let target = try store.prepare(host: "vps.example", port: 22)
        XCTAssertFalse(store.hasMismatch(host: "vps.example", port: 22))
        XCTAssertTrue(store.hasMismatch(host: "other.example", port: 22))
        XCTAssertFalse(store.hasMismatch(host: "broken.example", port: 22))
        try store.validate(presented: fingerprint, for: target)
        XCTAssertThrowsError(try store.prepare(host: "other.example", port: 22)) {
            XCTAssertEqual($0 as? SSHHostKeyError, .mismatch)
        }
        XCTAssertThrowsError(try store.prepare(host: "broken.example", port: 22)) {
            XCTAssertEqual($0 as? SSHHostKeyError, .verificationRequired)
        }
        // An explicit reset of the actual conflicting endpoint resolves only it.
        try store.resetTrust(host: "other.example", port: 22)
        XCTAssertFalse(store.hasMismatch(host: "other.example", port: 22))
        try store.validate(presented: different, for: store.prepare(host: "other.example", port: 22))
        try store.validate(presented: fingerprint, for: target)
    }

    func testExplicitResetPersistsAndStaleLegacyModelsCannotReseedOldPin() throws {
        let url = fileURL()
        let pin = SSHHostKeyPin(endpoint: "vps.example:22", fingerprints: [fingerprint])
        let store = SSHHostKeyTrustStore(fileURL: url, legacyPins: { [pin] })
        let old = try store.prepare(host: "vps.example", port: 22, legacyPin: pin)
        try store.validate(presented: fingerprint, for: old)
        try store.resetTrust(host: "VPS.EXAMPLE.", port: 22)
        XCTAssertFalse(store.hasTrust(host: "vps.example", port: 22))
        XCTAssertThrowsError(try store.validate(presented: fingerprint, for: old)) {
            XCTAssertEqual($0 as? SSHHostKeyError, .mismatch)
        }
        XCTAssertFalse(store.hasMismatch(host: "vps.example", port: 22),
                       "A generation-invalidated dial is not a new changed-key observation")
        let reopened = SSHHostKeyTrustStore(fileURL: url, legacyPins: { [pin] })
        let fresh = try reopened.prepare(host: "vps.example", port: 22, legacyPin: pin)
        try reopened.validate(presented: different, for: fresh)
        XCTAssertThrowsError(try reopened.validate(presented: fingerprint, for: fresh))
    }

    func testResetInvalidatesUnfinishedFirstDialButDoesNotAffectOtherEndpoints() throws {
        let store = makeStore()
        let unfinished = try store.prepare(host: "vps.example", port: 22)
        let other = try store.prepare(host: "vps.example", port: 2222)
        try store.validate(presented: fingerprint, for: other)
        try store.resetTrust(host: "vps.example", port: 22)
        XCTAssertThrowsError(try store.validate(presented: fingerprint, for: unfinished))
        try store.validate(presented: fingerprint, for: other)
        try store.validate(presented: different, for: store.prepare(host: "vps.example", port: 22))
    }

    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var accepted = Set<String>()
        private(set) var successCount = 0
        private(set) var failures: [SSHHostKeyError?] = []
        func record(_ fingerprint: String, error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            if let error { failures.append(error as? SSHHostKeyError) }
            else { accepted.insert(fingerprint); successCount += 1 }
        }
    }

    func testConcurrentDifferentFirstKeysHaveExactlyOneWinnerAcrossStoreInstances() throws {
        let url = fileURL()
        let stores = [SSHHostKeyTrustStore(fileURL: url), SSHHostKeyTrustStore(fileURL: url)]
        let keys = [fingerprint, different]
        let observations = Observations()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let store = stores[index % 2]
            let presented = keys[index % 2]
            do {
                let context = try store.prepare(host: "vps.example", port: 22)
                try store.validate(presented: presented, for: context)
                observations.record(presented, error: nil)
            } catch { observations.record(presented, error: error) }
        }
        XCTAssertEqual(observations.accepted.count, 1)
        XCTAssertEqual(observations.successCount, 32)
        XCTAssertEqual(observations.failures.count, 32)
        XCTAssertTrue(observations.failures.allSatisfy { $0 == .mismatch })
        let reopened = SSHHostKeyTrustStore(fileURL: url)
        try reopened.validate(presented: XCTUnwrap(observations.accepted.first),
                              for: reopened.prepare(host: "vps.example", port: 22))
    }

    func testConcurrentDistinctEndpointsDoNotLoseWrites() throws {
        let url = fileURL()
        let key = fingerprint
        let observations = Observations()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            let store = SSHHostKeyTrustStore(fileURL: url)
            do {
                try store.validate(presented: key, for: store.prepare(host: "vps.example", port: 2200 + index))
                observations.record(key, error: nil)
            } catch { observations.record(key, error: error) }
        }
        XCTAssertEqual(observations.successCount, 24)
        XCTAssertTrue(observations.failures.isEmpty)
        let reopened = SSHHostKeyTrustStore(fileURL: url)
        for index in 0..<24 {
            XCTAssertTrue(reopened.hasTrust(host: "vps.example", port: 2200 + index))
        }
    }

    func testCorruptOrUnsupportedStorageNeverBecomesFirstTrustOrGetsOverwritten() throws {
        let url = fileURL()
        let store = SSHHostKeyTrustStore(fileURL: url)
        _ = try store.prepare(host: "vps.example", port: 22)
        for text in ["{broken", "{\"version\":2,\"entries\":{}}",
                     "{\"version\":1,\"entries\":{\"vps.example:22\":{\"fingerprints\":[\"bad\"],"
                     + "\"generation\":\"FA03DBF4-BB93-4A97-9ED5-705EB02DD41A\",\"ignoresLegacy\":false}}}"] {
            let data = Data(text.utf8)
            try data.write(to: url, options: .atomic)
            XCTAssertThrowsError(try store.prepare(host: "vps.example", port: 22)) {
                XCTAssertEqual($0 as? SSHHostKeyError, .trustStoreUnavailable)
            }
            XCTAssertThrowsError(try store.resetTrust(host: "vps.example", port: 22))
            XCTAssertFalse(store.hasTrust(host: "vps.example", port: 22))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testInaccessibleStorageFailsClosed() throws {
        let url = fileURL()
        // A directory cannot be decoded/read as the atomic trust document.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = SSHHostKeyTrustStore(fileURL: url)
        XCTAssertThrowsError(try store.prepare(host: "vps.example", port: 22)) {
            XCTAssertEqual($0 as? SSHHostKeyError, .trustStoreUnavailable)
        }
        XCTAssertFalse(store.hasTrust(host: "vps.example", port: 22))
        XCTAssertFalse(store.hasMismatch(host: "vps.example", port: 22))
    }

    func testFailedResetDoesNotClearMismatchWarning() throws {
        let url = fileURL()
        let store = SSHHostKeyTrustStore(fileURL: url)
        let context = try store.prepare(host: "vps.example", port: 22)
        try store.validate(presented: fingerprint, for: context)
        XCTAssertThrowsError(try store.validate(presented: different, for: context))
        try Data("{broken".utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.resetTrust(host: "vps.example", port: 22))
        XCTAssertTrue(store.hasMismatch(host: "vps.example", port: 22))
    }

    func testMismatchStatusNotifiesOnMainQueueWithoutFingerprintPayload() async throws {
        let store = makeStore()
        let context = try store.prepare(host: "vps.example", port: 22)
        try store.validate(presented: fingerprint, for: context)
        // Earlier synchronous tests may have queued global status notifications.
        // Drain them before observing this test's event, without blocking main.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        let changed = expectation(description: "Changed-key recovery status notification")
        let observer = NotificationCenter.default.addObserver(
            forName: SSHHostKeyTrustStore.statusDidChange, object: nil, queue: .main
        ) { notification in
            guard store.hasMismatch(host: "vps.example", port: 22) else { return }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(notification.userInfo)
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertThrowsError(try store.validate(presented: different, for: context))
        await fulfillment(of: [changed], timeout: 2)
    }

    func testDelegateRunsOnNIOThreadAndPersistsBeforeSuccess() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let key = try NIOSSHPublicKey(openSSHPublicKey: publicKey)
        let store = makeStore()
        let context = try store.prepare(host: "vps.example", port: 22)
        let validator = SSHAutomaticHostKeyValidator(context: context, store: store)
        let loop = group.next()
        let accepted = loop.makePromise(of: Void.self)
        loop.execute { validator.validateHostKey(hostKey: key, validationCompletePromise: accepted) }
        XCTAssertNoThrow(try accepted.futureResult.wait())
        XCTAssertNil(validator.rejection)
        XCTAssertTrue(store.hasTrust(host: "vps.example", port: 22))
        let rekey = loop.makePromise(of: Void.self)
        loop.execute { validator.validateHostKey(hostKey: key, validationCompletePromise: rekey) }
        XCTAssertNoThrow(try rekey.futureResult.wait())

        let otherStore = makeStore()
        let pinned = try otherStore.prepare(host: "vps.example", port: 22, legacyPin:
            SSHHostKeyPin(endpoint: "vps.example:22", fingerprints: [different]))
        let mismatch = SSHAutomaticHostKeyValidator(context: pinned, store: otherStore)
        let rejected = loop.makePromise(of: Void.self)
        loop.execute { mismatch.validateHostKey(hostKey: key, validationCompletePromise: rejected) }
        XCTAssertThrowsError(try rejected.futureResult.wait()) {
            XCTAssertEqual($0 as? SSHHostKeyError, .mismatch)
        }
        XCTAssertEqual(mismatch.rejection, .mismatch,
                       "The typed reason survives a generic Citadel/channel error")
    }

    func testLegacyHostDecodesAndUUIDChangesDoNotDiscardEndpointTrust() throws {
        let legacy = """
        {"id":"FA03DBF4-BB93-4A97-9ED5-705EB02DD41A","label":"VPS",
         "host":"vps.example","port":22,"username":"root"}
        """
        var host = try JSONDecoder().decode(ServerHost.self, from: Data(legacy.utf8))
        XCTAssertNil(host.sshHostKeyPin)
        let store = makeStore()
        try store.validate(presented: fingerprint, for: store.prepare(host: host.host, port: host.port))
        host.id = UUID()
        host.username = "another-user"
        XCTAssertTrue(store.hasTrust(host: host.host, port: host.port))
        host.sshHostKeyPin = SSHHostKeyPin(endpoint: "vps.example:22", fingerprints: [fingerprint])
        XCTAssertEqual(try JSONDecoder().decode(ServerHost.self, from: JSONEncoder().encode(host)), host)
    }
}
