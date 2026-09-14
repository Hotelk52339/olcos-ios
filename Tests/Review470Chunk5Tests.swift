import XCTest
@testable import olcrtc_ios

// #470: regression pins for review chunk 5 — pure functions and one store's
// load path. The behavioural fixes (the relay-once route memory in
// SSHRunner.connect, the speed test's listener gate, the Telemost direct
// retry, the token lock in OlcrtcEngine) are integration-only and documented
// at their sites.
final class Review470Chunk5Tests: XCTestCase {

    private let key64 = String(repeating: "b", count: 64)

    // MARK: Recover keeps the wbstream auth.token

    func testRecoverParsesWBStreamToken() throws {
        let output = """
        OLCRTC_RECOVER_YAML_BEGIN
        mode: srv
        auth:
          provider: "wbstream"
          token: "wb-secret-token"
        room:
          id: "room-1"
        crypto:
          key: "\(key64)"
        net:
          transport: "datachannel"
          dns: "77.88.8.8:53"
        data: data
        debug: false
        OLCRTC_RECOVER_YAML_END
        OLCRTC_RECOVER_KEY=\(key64)
        """
        let cfg = try SSHRunner.parseRecoveredConfig(from: output)
        XCTAssertEqual(cfg.carrier, "wbstream")
        // The server authenticates with this token; a recovered record without
        // it dialled a protocol it could not join.
        XCTAssertEqual(cfg.wbToken, "wb-secret-token")
    }

    func testRecoverTokenIsEmptyWhenAbsentAndForOtherCarriers() throws {
        let noToken = """
        OLCRTC_RECOVER_YAML_BEGIN
        auth:
          provider: "wbstream"
        room:
          id: "room-2"
        crypto:
          key: "\(key64)"
        net:
          transport: "vp8channel"
        OLCRTC_RECOVER_YAML_END
        OLCRTC_RECOVER_KEY=\(key64)
        """
        XCTAssertEqual(try SSHRunner.parseRecoveredConfig(from: noToken).wbToken, "")

        // A `token:` under another provider is not something the client should
        // start sending — same carrier gate as SSHRunner.installEnv.
        let otherCarrier = """
        OLCRTC_RECOVER_YAML_BEGIN
        auth:
          provider: "telemost"
          token: "stray"
        room:
          id: "room-3"
        crypto:
          key: "\(key64)"
        net:
          transport: "datachannel"
        OLCRTC_RECOVER_YAML_END
        OLCRTC_RECOVER_KEY=\(key64)
        """
        XCTAssertEqual(try SSHRunner.parseRecoveredConfig(from: otherCarrier).wbToken, "")
    }

    // MARK: DNS field — mirrors master's validateHostPort (net.SplitHostPort, port 1…65535)

    func testResolverValidatorAcceptsWhatTheCoreAccepts() {
        // Every shipped preset must pass, or the picker would write a value the
        // free-form field then flags.
        for preset in AppConstants.dnsPresets {
            XCTAssertTrue(DNSSettingsView.isValidResolver(preset.value), preset.value)
        }
        for preset in AppConstants.ruCarrierDnsPresets {
            XCTAssertTrue(DNSSettingsView.isValidResolver(preset.value), preset.value)
        }
        XCTAssertTrue(DNSSettingsView.isValidResolver("[::1]:53"))
        XCTAssertTrue(DNSSettingsView.isValidResolver("[2001:db8::1]:5353"))
        XCTAssertTrue(DNSSettingsView.isValidResolver("dns.example.net:53"))
        XCTAssertTrue(DNSSettingsView.isValidResolver("1.1.1.1:65535"))
    }

    func testResolverValidatorRejectsWhatTheCoreRejects() {
        // Each of these made master's SetDNS throw, i.e. failed every connect.
        let rejected = [
            "",
            "8.8.8.8",          // no port — the finding's headline case
            "8.8.8.8:",
            ":53",
            "8.8.8.8:0",
            "8.8.8.8:65536",
            "8.8.8.8:5x",
            "8.8.8.8:53 ",      // the field trims before validating; the raw value is invalid
            "8.8.8.8 :53",
            "::1:53",           // unbracketed IPv6 — "too many colons"
            "[::1:53",
        ]
        for value in rejected {
            XCTAssertFalse(DNSSettingsView.isValidResolver(value), value.debugDescription)
        }
    }

    // MARK: ServerHostStore — an unreadable VPS list is parked, never wiped

    @MainActor
    func testUnreadableHostListIsParkedNotWiped() {
        let d = UserDefaults.standard
        let liveKey = "olcrtc_server_hosts"
        let backupKey = "olcrtc_server_hosts.unreadable"
        let savedLive = d.data(forKey: liveKey)
        let savedBackup = d.data(forKey: backupKey)
        defer {
            if let savedLive { d.set(savedLive, forKey: liveKey) } else { d.removeObject(forKey: liveKey) }
            if let savedBackup { d.set(savedBackup, forKey: backupKey) } else { d.removeObject(forKey: backupKey) }
        }

        let garbage = Data("[{\"id\":\"not-a-uuid\"".utf8)   // truncated JSON
        d.set(garbage, forKey: liveKey)
        d.removeObject(forKey: backupKey)

        let store = ServerHostStore()
        XCTAssertTrue(store.hosts.isEmpty, "a failed decode still yields an empty list")
        XCTAssertEqual(d.data(forKey: backupKey), garbage, "the unreadable bytes are parked under the side key")
        XCTAssertEqual(d.data(forKey: liveKey), garbage, "load() itself never overwrites the originals")
    }
}
