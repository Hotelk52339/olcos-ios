import XCTest
@testable import olcrtc_ios

// #470 (review, chunk 3): regression pins for the fixes that have a pure or
// synchronous surface. The rest — the recovery-loop generation guard, the
// keep-alive re-read, the exit-geo epoch guard, the VPN start counter and the
// reason-less VPN stop mapping — live inside private async loops or behind the
// NEVPN status bridge and are integration-only; each is documented at its site
// in App/Core/TunnelManager.swift.
@MainActor
final class Review470Chunk3Tests: XCTestCase {

    private var savedLanguage = ""
    private var savedModePreference: ConnectionModePreference = .automatic // #487
    private var savedTunnelMode: TunnelMode = .proxy
    // A connect attempt records evidence into HealthCoordinator.shared, which
    // persists under this key — snapshot and restore it like every suite that
    // touches the manager.
    private let healthKey = "olcrtc_health_v1"
    private var healthSnapshot: Data?

    override func setUp() {
        super.setUp()
        savedLanguage   = SettingsStore.shared.language
        savedModePreference = SettingsStore.shared.connectionModePreference // #487
        savedTunnelMode = SettingsStore.shared.tunnelMode
        SettingsStore.shared.language = "en"
        healthSnapshot = UserDefaults.standard.data(forKey: healthKey)
    }

    override func tearDown() {
        SettingsStore.shared.tunnelMode = savedTunnelMode
        SettingsStore.shared.connectionModePreference = savedModePreference // #487: legacy write must not leave an override.
        SettingsStore.shared.language   = savedLanguage
        SettingsStore.flushPendingWrites()
        HealthCoordinator.shared._resetForTesting()
        HealthCoordinator.flushPendingWrites()
        if let d = healthSnapshot { UserDefaults.standard.set(d, forKey: healthKey) }
        else { UserDefaults.standard.removeObject(forKey: healthKey) }
        super.tearDown()
    }

    // MARK: VPN connect validates BEFORE touching NetworkExtension

    func testVPNConnectRefusesABlankKeyBeforeStartingTheTunnel() {
        SettingsStore.shared.tunnelMode = .vpn
        let manager = TunnelManager()
        let params = OlcrtcConnection(carrier: "telemost", transport: "vp8channel",
                                      roomID: "room-1", key: "", clientID: "ios-test")
        manager.connect(record: ConnectionRecord(name: "test", details: .olcrtc(params)))
        // Synchronous: the structural check now runs before `state = .connecting`,
        // so nothing reaches the appex. The old path handed the blank key to the
        // extension, whose `setKey` threw, and the user saw the generic
        // "VPN tunnel disconnected" with no hint that the key was the problem.
        // The same structural message the proxy path produces (language locked
        // to "en" in setUp): a 0-character key.
        XCTAssertEqual(manager.state, .failed(L10n.validateKeyLength_fmt.formatted(0)))
        XCTAssertEqual(manager.state, .failed(TunnelManager.validate(params: params) ?? "<valid>"))
        XCTAssertNil(manager.connectedRecord)
        // Tidy: VPN-mode disconnect never touches the Go runtime.
        manager.disconnect()
        XCTAssertEqual(manager.state, .disconnected)
    }

    func testVPNConnectStillRefusesVideochannel() {
        SettingsStore.shared.tunnelMode = .vpn
        let manager = TunnelManager()
        let params = OlcrtcConnection(carrier: "jitsi", transport: "videochannel",
                                      roomID: "room-1", key: String(repeating: "a", count: 64),
                                      clientID: "ios-test")
        manager.connect(record: ConnectionRecord(name: "test", details: .olcrtc(params)))
        XCTAssertEqual(manager.state, .failed(L10n.vpnVideochannelUnsupported.localized()))
        manager.disconnect()
    }

    // MARK: Background-entry line under the system VPN

    func testBackgroundEnterUnderSystemVPNDoesNotAskForBackgroundAudio() {
        let msg = TunnelManager.backgroundEnterMessage(connected: true, keeperRunning: false,
                                                       systemVPN: true)
        XCTAssertFalse(msg.contains("⚠"))
        XCTAssertFalse(msg.contains("Background audio"), "no in-app keeper exists to enable")
        XCTAssertTrue(msg.contains("extension"), "names who keeps the tunnel alive")
        XCTAssertEqual(LogStore.classify(msg), .info)
        // The proxy-mode lines are untouched (the parameter defaults to false).
        XCTAssertTrue(TunnelManager.backgroundEnterMessage(connected: true, keeperRunning: false)
                        .contains("⚠"))
        // Not connected reads the same in either mode.
        XCTAssertTrue(TunnelManager.backgroundEnterMessage(connected: false, keeperRunning: false,
                                                           systemVPN: true)
                        .contains("not connected"))
    }

    // MARK: Plain olcrtc:// import dedup

    func testPlainLinkImportFindsTheSameNodeOnlyWhenAllFiveFieldsMatch() {
        let key = String(repeating: "b", count: 64)
        let base = OlcrtcConnection(carrier: "telemost", transport: "vp8channel",
                                    roomID: "r1", key: key, clientID: "default")
        let saved = ConnectionRecord(name: "Saved", details: .olcrtc(base))
        XCTAssertEqual(MainTabView.existingRecord(matching: base, in: [saved])?.id, saved.id)

        // Any connection-defining field differing means a different node.
        var other = base; other.transport = "videochannel"
        XCTAssertNil(MainTabView.existingRecord(matching: other, in: [saved]))
        other = base; other.clientID = "phone-2"
        XCTAssertNil(MainTabView.existingRecord(matching: other, in: [saved]))
        other = base; other.roomID = "r2"
        XCTAssertNil(MainTabView.existingRecord(matching: other, in: [saved]))
        other = base; other.key = String(repeating: "c", count: 64)
        XCTAssertNil(MainTabView.existingRecord(matching: other, in: [saved]))
        other = base; other.carrier = "wbstream"
        XCTAssertNil(MainTabView.existingRecord(matching: other, in: [saved]))

        // Display metadata is not identity: a renamed record is the same node.
        var renamed = saved
        renamed.name = "Renamed"
        XCTAssertEqual(MainTabView.existingRecord(matching: base, in: [renamed])?.id, saved.id)
        XCTAssertNil(MainTabView.existingRecord(matching: base, in: []))
    }
}
