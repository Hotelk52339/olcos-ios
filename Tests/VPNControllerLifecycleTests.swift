import XCTest
import Combine
@testable import olcrtc_ios

// boc #483: exercises the real controller/reducer with injected, suspendable OS
// operations. No entitlement, real VPN profile or Mobile runtime is touched.
@MainActor
final class VPNControllerLifecycleTests: XCTestCase {
    private var savedModePreference: ConnectionModePreference = .automatic // #487
    private var savedMode: TunnelMode = .proxy
    private var savedDNS = ""
    private var savedShared: TunnelManager?
    private var lifecycleSnapshot: TunnelManager.LifecycleSnapshot?
    private var managers: [TunnelManager] = []

    override func setUp() {
        super.setUp()
        savedModePreference = SettingsStore.shared.connectionModePreference // #487
        savedMode = SettingsStore.shared.tunnelMode
        savedShared = TunnelManager.shared
        lifecycleSnapshot = TunnelManager.lifecycleSnapshot()
        SettingsStore.shared.tunnelMode = .vpn
        savedDNS = SettingsStore.shared.dnsServer
        SettingsStore.shared.dnsServer = "1.1.1.1"
    }

    override func tearDown() async throws {
        for manager in managers {
            manager.disconnect()
            try await manager.waitForTeardown()
        }
        managers.removeAll()
        SettingsStore.shared.tunnelMode = savedMode
        SettingsStore.shared.connectionModePreference = savedModePreference // #487: legacy write must not leave an override.
        SettingsStore.shared.dnsServer = savedDNS
        SettingsStore.flushPendingWrites()
        TunnelManager.shared = savedShared
        if let lifecycleSnapshot { TunnelManager.restoreLifecycleSnapshot(lifecycleSnapshot) }
        try await super.tearDown()
    }

    private func config(room: String = "room") -> VPNConfig {
        VPNConfig(from: params(room: room), dns: "1.1.1.1", timeoutMs: 1_000,
                  fallbackVP8FPS: 10, fallbackVP8Batch: 1)
    }
    private func params(room: String) -> OlcrtcConnection {
        OlcrtcConnection(carrier: "jitsi", transport: "datachannel", roomID: room,
                         key: String(repeating: "a", count: 64), clientID: "test")
    }
    private func controller(_ profile: LifecycleProfile) -> VPNController {
        VPNController(loadProfiles: { [profile] }, makeProfile: { profile })
    }
    private func manager(_ vpn: VPNController) -> TunnelManager {
        let manager = TunnelManager(vpn: vpn, engine: LifecycleEngine(),
                                    runtimeEffectsEnabled: false, verify: { true },
                                    portIsFree: { _ in true })
        managers.append(manager)
        return manager
    }

    func testConcurrentAdoptionCoalescesAndFiltersToOwnActiveProfile() async {
        let gate = LifecycleGate()
        let foreign = LifecycleProfile()
        foreign.providerIdentifier = "other.vendor.tunnel"
        foreign.status = .connected
        let idle = LifecycleProfile()
        let live = LifecycleProfile()
        live.status = .reasserting
        var loads = 0
        let vpn = VPNController(loadProfiles: {
            loads += 1
            await gate.wait()
            return [foreign, idle, live]
        })
        let first = Task { await vpn.adoptRunningTunnel() }
        await lifecycleEventually { gate.entered }
        let second = Task { await vpn.adoptRunningTunnel() }
        await Task.yield()
        XCTAssertEqual(loads, 1)
        gate.release()
        await first.value
        await second.value
        XCTAssertEqual(vpn.status, .reasserting)
        await vpn.adoptRunningTunnel()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(foreign.stopCount, 0)
    }

    func testAdoptionLoadCannotReplaceNewerStartManager() async throws {
        let gate = LifecycleGate()
        let stale = LifecycleProfile()
        stale.status = .connected
        let current = LifecycleProfile()
        var loads = 0
        let vpn = VPNController(loadProfiles: {
            loads += 1
            if loads == 1 {
                await gate.wait()
                return [stale]
            }
            return [current]
        })
        let adoption = Task { await vpn.adoptRunningTunnel() }
        await lifecycleEventually { gate.entered }
        try await vpn.start(config())
        gate.release()
        await adoption.value
        XCTAssertEqual(vpn.status, .connecting)
        XCTAssertEqual(current.startCount, 1)
        stale.emit(.connected)
        XCTAssertEqual(vpn.status, .connecting)
        vpn.stop()
        try await vpn.stopAndWait()
    }

    func testStopDuringPreferenceLoadPreventsAnySaveOrStart() async {
        let gate = LifecycleGate()
        let profile = LifecycleProfile()
        let vpn = VPNController(loadProfiles: { await gate.wait(); return [profile] })
        let attempt = Task { try await vpn.start(config()) }
        await lifecycleEventually { gate.entered }
        vpn.stop()
        gate.release()
        do { try await attempt.value; XCTFail("superseded start must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(profile.saveCount, 0)
        XCTAssertEqual(profile.startCount, 0)
    }

    func testStopDuringMandatoryReloadPreventsStart() async {
        let gate = LifecycleGate()
        let profile = LifecycleProfile()
        profile.onReload = { await gate.wait() }
        let vpn = controller(profile)
        let attempt = Task { try await vpn.start(config()) }
        await lifecycleEventually { gate.entered }
        vpn.stop()
        gate.release()
        _ = await attempt.result
        try? await vpn.stopAndWait()
        XCTAssertEqual(profile.reloadCount, 1)
        XCTAssertEqual(profile.startCount, 0)
        await lifecycleEventually {
            VPNConfig.secretConfigKeys.allSatisfy { (profile.configuration[$0] as? String ?? "").isEmpty }
        }
    }

    func testSupersededSaveFailureCannotFailOrStartOverNewAttempt() async {
        let gate = LifecycleGate()
        let profile = LifecycleProfile()
        profile.onSave = { [weak profile] in
            if profile?.saveCount == 1 {
                await gate.wait()
                throw VPNController.VPNControllerError("obsolete save failure")
            }
        }
        let vpn = controller(profile)
        let tunnel = manager(vpn)
        let first = ConnectionRecord(name: "first", details: .olcrtc(params(room: "first")))
        let second = ConnectionRecord(name: "second", details: .olcrtc(params(room: "second")))
        tunnel.connect(record: first)
        await lifecycleEventually { gate.entered }
        tunnel.connect(record: second)
        XCTAssertEqual(tunnel.state, .connecting)
        XCTAssertEqual(profile.startCount, 0)
        gate.release()
        await lifecycleEventually { profile.startCount == 1 }
        XCTAssertEqual(profile.configuredRooms.last, "second")
        XCTAssertEqual(tunnel.engagedRecord?.id, second.id)
        XCTAssertEqual(tunnel.state, .connecting)
        profile.emit(.connected)
        XCTAssertEqual(tunnel.connectedRecord?.id, second.id)
    }

    func testForegroundDropUsesReducerFetchesReasonAndScrubsSecrets() async throws {
        let profile = LifecycleProfile()
        let vpn = controller(profile)
        try await vpn.start(config())
        profile.emit(.connected)
        profile.onError = { "provider failed while suspended" }
        profile.status = .disconnected // no notification while suspended
        await vpn.adoptRunningTunnel()
        await lifecycleEventually { vpn.lastDisconnectReason != nil }
        XCTAssertEqual(vpn.lastDisconnectReason, "provider failed while suspended")
        await lifecycleEventually {
            VPNConfig.secretConfigKeys.allSatisfy { (profile.configuration[$0] as? String ?? "").isEmpty }
        }
    }

    func testExternalNewSessionClearsOldReasonAndDelayedOldFetchCannotLeak() async {
        let gate = LifecycleGate()
        let profile = LifecycleProfile()
        profile.status = .connected
        let vpn = controller(profile)
        await vpn.adoptRunningTunnel()
        profile.onError = { await gate.wait(); return "old failure" }
        profile.emit(.disconnected)
        await lifecycleEventually { gate.entered }
        profile.emit(.connecting)
        profile.emit(.connected)
        gate.release()
        await Task.yield()
        XCTAssertNil(vpn.lastDisconnectReason)
        profile.onError = { nil }
        profile.emit(.disconnected)
        await Task.yield()
        XCTAssertNil(vpn.lastDisconnectReason)
    }

    func testExternalStartClearsPreviouslyPublishedReason() async {
        let profile = LifecycleProfile()
        let vpn = controller(profile)
        let tunnel = manager(vpn)
        let record = ConnectionRecord(name: "old app record", details: .olcrtc(params(room: "old")))
        tunnel.connect(record: record)
        await lifecycleEventually { profile.startCount == 1 }
        profile.emit(.connected)
        XCTAssertEqual(tunnel.connectedRecord?.id, record.id)
        profile.onError = { "previous failure" }
        profile.emit(.disconnected)
        await lifecycleEventually { vpn.lastDisconnectReason != nil }
        XCTAssertEqual(tunnel.state, .failed("previous failure"))
        profile.emit(.reasserting)
        XCTAssertNil(vpn.lastDisconnectReason)
        XCTAssertNil(tunnel.engagedRecord, "a new external session cannot inherit the earlier app record")
        profile.onError = { nil }
        profile.emit(.disconnected)
        XCTAssertEqual(tunnel.state, .disconnected)
    }

    func testUnchangedForegroundIdleDoesNotEraseStartFailure() async {
        let profile = LifecycleProfile()
        profile.startError = VPNController.VPNControllerError("start failed")
        let vpn = controller(profile)
        let tunnel = manager(vpn)
        tunnel.connect(record: ConnectionRecord(name: "x", details: .olcrtc(params(room: "x"))))
        await lifecycleEventually { tunnel.state == .failed("start failed") }
        await vpn.adoptRunningTunnel()
        await vpn.adoptRunningTunnel()
        XCTAssertEqual(tunnel.state, .failed("start failed"))
    }

    func testHandshakeTailIdleRereadDoesNotTurnToggleOff() async {
        let profile = LifecycleProfile()
        profile.startStatus = .disconnected // accepted start, connecting notification not here yet
        let vpn = controller(profile)
        let tunnel = manager(vpn)
        tunnel.connect(record: ConnectionRecord(name: "x", details: .olcrtc(params(room: "x"))))
        await lifecycleEventually { profile.startCount == 1 }
        await Task.yield()
        await vpn.adoptRunningTunnel()
        XCTAssertEqual(tunnel.state, .connecting)
        XCTAssertFalse((profile.configuration["keyHex"] as? String ?? "").isEmpty,
                       "pre-start/handshake-tail idle snapshots must not scrub credentials")
        profile.emit(.connecting)
        profile.emit(.connected)
        XCTAssertEqual(tunnel.state, .connected)
    }

    func testRealTerminalNotificationAfterAcceptedStartFetchesFailure() async {
        let profile = LifecycleProfile()
        profile.startStatus = .disconnected
        profile.onError = { "provider rejected start" }
        let vpn = controller(profile)
        let tunnel = manager(vpn)
        tunnel.connect(record: ConnectionRecord(name: "x", details: .olcrtc(params(room: "x"))))
        await lifecycleEventually { profile.startCount == 1 }
        await Task.yield()
        // A notification is new evidence; unlike a reread it can finish a
        // pending start even if NE never exposed an intermediate connecting.
        profile.emit(.disconnected)
        await lifecycleEventually { tunnel.state == .failed("provider rejected start") }
    }

    // #485: unsupported packet DNS is rejected in the app, before NE consent/start.
    func testUnsupportedPacketDNSFailsBeforeStartingProvider() {
        SettingsStore.shared.dnsServer = "2001:4860:4860::8888"
        let profile = LifecycleProfile()
        let tunnel = manager(controller(profile))
        tunnel.connect(record: ConnectionRecord(name: "x", details: .olcrtc(params(room: "x"))))
        XCTAssertEqual(tunnel.state, .failed(L10n.vpnPacketDNSUnsupported.localized()))
        XCTAssertEqual(profile.startCount, 0)
        XCTAssertEqual(profile.saveCount, 0)
    }

    func testLocalDisconnectCannotBeReadoptedByLateConnected() async {
        let profile = LifecycleProfile()
        profile.status = .connected
        profile.stopImmediately = false
        let vpn = controller(profile)
        let tunnel = manager(vpn)
        await vpn.adoptRunningTunnel()
        tunnel.disconnect()
        profile.emit(.connected)
        XCTAssertEqual(tunnel.state, .disconnected)
        XCTAssertEqual(tunnel.activeMode, .proxy)
        XCTAssertTrue(tunnel.systemTunnelIsUp, "routes are unsafe for probes while draining")
        profile.emit(.disconnected)
        try? await tunnel.waitForTeardown()
        XCTAssertEqual(tunnel.state, .disconnected)
        profile.emit(.reasserting) // genuinely new external session after terminal down
        XCTAssertEqual(tunnel.activeMode, .vpn)
        XCTAssertEqual(tunnel.state, .connecting)
        profile.stopImmediately = true
    }
}
// eoc #483
