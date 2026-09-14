import XCTest
import Combine // #483: assert route events observe committed state.
@testable import olcrtc_ios

// #477: the system tunnel is this app's OWN packet-tunnel extension, and it can
// come up without `connect()` ever running — the user flips the profile on in
// iOS Settings or Control Centre, or it was left running across a launch.
//
// The bridge used to drop those notifications (`guard activeMode == .vpn`), so
// the in-app proxy kept its own session open and the SAME clientID sat in the
// carrier room twice. The server records the collision plainly —
// `Current peers count: 2, Devices: [default, default]` — and two peers sharing
// one identity break each other: the proxy session went silent
// (`control missed pong` → `reason=liveness`), recovery re-entered a room whose
// identity was taken, spent its budget, and landed in `.failed`. That is the
// "Connection failed" that lasted until the VPN was switched off.
//
// #483 was: adoption itself integration-only and proxy tests launched Go.
// Injected engine/profile boundaries now exercise adoption, ordered teardown and
// observable redials; only Apple's actual routing/signing remains integration-only.
@MainActor
final class SystemTunnelAdoptionTests: XCTestCase {

    private var savedLanguage = ""
    private var savedModePreference: ConnectionModePreference = .automatic // #487
    private var savedTunnelMode: TunnelMode = .proxy
    private var savedDNS = "" // #483: VPN lifecycle tests require supported deterministic DNS.
    private let healthKey = "olcrtc_health_v1"
    private var healthSnapshot: Data?
    // boc #483
    private var managers: [TunnelManager] = []
    private var savedShared: TunnelManager?
    private var lifecycleSnapshot: TunnelManager.LifecycleSnapshot?

    private func makeManager(engine: LifecycleEngine = LifecycleEngine(),
                             profile: LifecycleProfile? = nil,
                             teardownWaitSeconds: Double = 15) -> TunnelManager {
        let profile = profile ?? LifecycleProfile() // #483: actor-isolated construction, not a default argument.
        let vpn = VPNController(loadProfiles: { [profile] }, makeProfile: { profile })
        let manager = TunnelManager(vpn: vpn, engine: engine, runtimeEffectsEnabled: false,
                                    verify: { true }, portIsFree: { _ in true },
                                    teardownWaitSeconds: teardownWaitSeconds)
        managers.append(manager)
        return manager
    }
    // eoc #483

    override func setUp() {
        super.setUp()
        savedLanguage   = SettingsStore.shared.language
        savedModePreference = SettingsStore.shared.connectionModePreference // #487
        savedTunnelMode = SettingsStore.shared.tunnelMode
        SettingsStore.shared.language = "en"
        savedDNS = SettingsStore.shared.dnsServer
        SettingsStore.shared.dnsServer = "1.1.1.1"
        healthSnapshot = UserDefaults.standard.data(forKey: healthKey)
        // #483: restore app-intent wiring and lock-backed lifecycle snapshots.
        savedShared = TunnelManager.shared
        lifecycleSnapshot = TunnelManager.lifecycleSnapshot()
    }

    override func tearDown() async throws { // #483: join all work before restoring globals.
        for manager in managers {
            manager.disconnect()
            try await manager.waitForTeardown()
        }
        managers.removeAll()
        TunnelManager.shared = savedShared
        if let lifecycleSnapshot { TunnelManager.restoreLifecycleSnapshot(lifecycleSnapshot) }
        SettingsStore.shared.tunnelMode = savedTunnelMode
        SettingsStore.shared.connectionModePreference = savedModePreference // #487: legacy write must not leave an override.
        SettingsStore.shared.language   = savedLanguage
        SettingsStore.shared.dnsServer = savedDNS
        SettingsStore.flushPendingWrites()
        HealthCoordinator.shared._resetForTesting()
        HealthCoordinator.flushPendingWrites()
        if let d = healthSnapshot { UserDefaults.standard.set(d, forKey: healthKey) }
        else { UserDefaults.standard.removeObject(forKey: healthKey) }
        try await super.tearDown()
    }

    private func params(transport: String = "vp8channel") -> OlcrtcConnection {
        OlcrtcConnection(carrier: "jitsi", transport: transport,
                         roomID: "room-1", key: String(repeating: "a", count: 64),
                         clientID: "ios-test")
    }

    // MARK: - The verdict table

    // In PROXY mode the app's own state says nothing about a tunnel it did not
    // start, so the observed NEVPNStatus is the only evidence there is.
    func testProxyModeReadsTheObservedVPNStatus() {
        for status: VPNController.Status in [.connected, .connecting, .reasserting, .disconnecting] { // #483
            XCTAssertTrue(
                TunnelManager.systemTunnelIsUp(activeMode: .proxy, state: .disconnected,
                                               vpnStatus: status),
                "\(status) carries the device even though this app runs the proxy")
        }
        for status: VPNController.Status in [.invalid, .disconnected] { // #483
            XCTAssertFalse(
                TunnelManager.systemTunnelIsUp(activeMode: .proxy, state: .connected,
                                               vpnStatus: status),
                "\(status) is not a live tunnel")
        }
    }

    // #472's rule survives: iOS installs the routes when the provider answers
    // `startTunnel`, which is BEFORE the app reaches `.connected`, so only
    // `.disconnected`/`.failed` are provably route-free.
    func testVPNModeStillYieldsOnEveryStateThatMayHoldRoutes() {
        for state: ConnectionState in [.connecting, .connected, .waitingForNetwork] {
            XCTAssertTrue(
                TunnelManager.systemTunnelIsUp(activeMode: .vpn, state: state,
                                               vpnStatus: .invalid),
                "\(state) may already own the routes")
        }
        for state: ConnectionState in [.disconnected, .failed("x")] {
            XCTAssertFalse(
                TunnelManager.systemTunnelIsUp(activeMode: .vpn, state: state,
                                               vpnStatus: .invalid),
                "\(state) is provably route-free")
        }
    }

    // The regression this whole task exists for: proxy mode + a tunnel someone
    // else started must NOT read as "no tunnel", which is what sent probes out
    // through it and let the proxy keep a duplicate identity in the room.
    func testAProxySessionUnderAnExternallyStartedTunnelIsNotTreatedAsUntunnelled() {
        XCTAssertTrue(
            TunnelManager.systemTunnelIsUp(activeMode: .proxy, state: .connected,
                                           vpnStatus: .connected),
            "#477 was: `activeMode == .vpn` only — the app's belief, not the device's routes")
    }

    // MARK: - connect() treats a backend switch as a switch

    // #477 was: `guard let live = lastRecord, live.id != record.id else { return }`
    // compared the record alone, so flipping the mode and reconnecting to the
    // same record silently left the user on the old backend.
    func testSwitchingBackendOnTheSameRecordActuallySwitches() async { // #483
        SettingsStore.shared.tunnelMode = .proxy
        let engine = LifecycleEngine()
        let manager = makeManager(engine: engine) // #483: never starts Go.
        // videochannel is valid for the proxy and refused by the appex, so the
        // VPN branch answers synchronously and no NetworkExtension call happens.
        let record = ConnectionRecord(name: "same", details: .olcrtc(params(transport: "videochannel")))

        manager.connect(record: record)
        XCTAssertEqual(manager.state, .connecting)
        XCTAssertEqual(manager.activeMode, .proxy)
        await lifecycleEventually { engine.startCount == 1 } // #483: prove the first dial.

        SettingsStore.shared.tunnelMode = .vpn
        manager.connect(record: record)          // same record, different backend
        XCTAssertEqual(manager.activeMode, .vpn, "the switch must actually happen")
        XCTAssertEqual(manager.state, .connecting) // #483: keep the toggle on during drain.
        await lifecycleEventually { manager.state == .failed(L10n.vpnVideochannelUnsupported.localized()) }
        XCTAssertEqual(manager.state, .failed(L10n.vpnVideochannelUnsupported.localized()),
                       "and the VPN branch must be the one that answered")
        manager.disconnect()
    }

    // The same record on the same backend stays idempotent — a double tap must
    // not tear a live session down.
    func testSameRecordSameBackendIsStillANoOp() async { // #483
        SettingsStore.shared.tunnelMode = .proxy
        let engine = LifecycleEngine()
        let manager = makeManager(engine: engine)
        let record = ConnectionRecord(name: "same", details: .olcrtc(params()))
        manager.connect(record: record)
        await lifecycleEventually { engine.startCount == 1 } // #483
        let epoch = manager.connectEpoch
        XCTAssertEqual(manager.state, .connecting)
        manager.connect(record: record)
        XCTAssertEqual(manager.state, .connecting, "a repeat tap changes nothing")
        XCTAssertEqual(manager.activeMode, .proxy)
        XCTAssertEqual(manager.connectEpoch, epoch) // #483: no duplicate attempt.
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.stopCount, 0)
        manager.disconnect() // #483 was: state-only cleanup leaked the runtime.
    }

    // An adopted tunnel holds a live state with NO record of its own. Connecting
    // to something while it runs used to hit the same early return and do
    // nothing at all — the user tapped a protocol and the app ignored them.
    func testConnectIsNotSwallowedWhileALiveStateHasNoRecord() async { // #483
        SettingsStore.shared.tunnelMode = .proxy
        let engine = LifecycleEngine()
        let profile = LifecycleProfile()
        profile.status = .connected
        let manager = makeManager(engine: engine, profile: profile)
        await manager.vpn.adoptRunningTunnel() // #483: real bridge, not a synthetic state write.
        XCTAssertEqual(manager.state, .connected)
        XCTAssertNil(manager.connectedRecord)
        let record = ConnectionRecord(name: "x", details: .olcrtc(params()))
        manager.connect(record: record)
        XCTAssertEqual(manager.state, .connecting)
        await lifecycleEventually { engine.startCount == 1 }
        XCTAssertEqual(profile.stopCount, 1)
        XCTAssertEqual(manager.engagedRecord?.id, record.id)
        engine.completeStart()
        await lifecycleEventually { manager.state == .connected }
        XCTAssertEqual(manager.connectedRecord?.id, record.id, "E1: teardown alone cannot pass")
    }

    // boc #483
    func testProxyToVPNAwaitsNativeStopBeforeJoiningRoom() async {
        SettingsStore.shared.tunnelMode = .proxy
        let engine = LifecycleEngine()
        let barrier = DispatchSemaphore(value: 0)
        engine.stopBarrier = barrier
        defer { barrier.signal() }
        let profile = LifecycleProfile()
        let manager = makeManager(engine: engine, profile: profile)
        let record = ConnectionRecord(name: "x", details: .olcrtc(params()))
        manager.connect(record: record)
        await lifecycleEventually { engine.startCount == 1 }
        SettingsStore.shared.tunnelMode = .vpn
        manager.connect(record: record)
        await lifecycleEventually { engine.stopCount == 1 }
        XCTAssertEqual(profile.startCount, 0)
        XCTAssertEqual(manager.state, .connecting)
        barrier.signal()
        await lifecycleEventually { profile.startCount == 1 }
        XCTAssertFalse(engine.isRunning())
    }

    func testTimedOutProxyDrainFailsVisiblyWithoutReleasingIdentity() async {
        SettingsStore.shared.tunnelMode = .proxy
        let engine = LifecycleEngine()
        let barrier = DispatchSemaphore(value: 0)
        engine.stopBarrier = barrier
        defer { barrier.signal() }
        let profile = LifecycleProfile()
        let manager = makeManager(engine: engine, profile: profile, teardownWaitSeconds: 0.01)
        let record = ConnectionRecord(name: "x", details: .olcrtc(params()))
        manager.connect(record: record)
        await lifecycleEventually { engine.startCount == 1 }
        SettingsStore.shared.tunnelMode = .vpn
        manager.connect(record: record)
        await lifecycleEventually { manager.state == .failed(L10n.errorRuntimeStillStopping.localized()) }
        XCTAssertEqual(profile.startCount, 0, "timeout is not permission to join the same room")
        XCTAssertNil(manager.engagedRecord)
        barrier.signal()
        try? await manager.waitForTeardown()
        manager.connect(record: record)
        await lifecycleEventually { profile.startCount == 1 }
        XCTAssertFalse(engine.isRunning())
    }

    func testDisconnectDuringDrainCancelsQueuedVPNStart() async {
        SettingsStore.shared.tunnelMode = .proxy
        let engine = LifecycleEngine()
        let barrier = DispatchSemaphore(value: 0)
        engine.stopBarrier = barrier
        defer { barrier.signal() }
        let profile = LifecycleProfile()
        let manager = makeManager(engine: engine, profile: profile)
        let record = ConnectionRecord(name: "x", details: .olcrtc(params()))
        manager.connect(record: record)
        await lifecycleEventually { engine.startCount == 1 }
        SettingsStore.shared.tunnelMode = .vpn
        manager.connect(record: record)
        await lifecycleEventually { engine.stopCount == 1 }
        manager.disconnect()
        barrier.signal()
        try? await manager.waitForTeardown()
        await Task.yield()
        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertEqual(profile.startCount, 0)
        XCTAssertFalse(engine.isRunning())
    }

    func testVPNToProxyAwaitsTerminalStatusAndIgnoresLateConnected() async {
        SettingsStore.shared.tunnelMode = .vpn
        let engine = LifecycleEngine()
        let profile = LifecycleProfile()
        profile.stopImmediately = false
        let manager = makeManager(engine: engine, profile: profile)
        let record = ConnectionRecord(name: "x", details: .olcrtc(params()))
        manager.connect(record: record)
        await lifecycleEventually { profile.startCount == 1 }
        profile.emit(.connected)
        SettingsStore.shared.tunnelMode = .proxy
        manager.connect(record: record)
        profile.emit(.connected) // queued success from the stopped session.
        XCTAssertEqual(manager.activeMode, .proxy)
        XCTAssertEqual(manager.state, .connecting)
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertTrue(manager.systemTunnelIsUp)
        profile.emit(.disconnected)
        await lifecycleEventually { engine.startCount == 1 }
        XCTAssertEqual(manager.engagedRecord?.id, record.id)
    }

    func testAdoptionInvalidatesProxyOutcomeAndClearsIdentity() async {
        SettingsStore.shared.tunnelMode = .proxy
        let engine = LifecycleEngine()
        let profile = LifecycleProfile()
        let manager = makeManager(engine: engine, profile: profile)
        let record = ConnectionRecord(name: "proxy", details: .olcrtc(params()))
        manager.connect(record: record)
        await lifecycleEventually { engine.startCount == 1 }
        let epoch = manager.connectEpoch
        profile.status = .reasserting
        await manager.vpn.adoptRunningTunnel()
        XCTAssertGreaterThan(manager.connectEpoch, epoch)
        XCTAssertEqual(manager.activeMode, .vpn)
        XCTAssertNil(manager.engagedRecord)
        try? await manager.waitForTeardown()
        XCTAssertEqual(manager.state, .connecting, "stopped proxy cannot overwrite adopted VPN")
        XCTAssertNil(HealthCoordinator.shared.health(for: record.id),
                     "adoption-induced teardown is not evidence that the proxy node is broken")
        XCTAssertFalse(engine.isRunning())
        profile.emit(.connected)
        XCTAssertNil(manager.connectedRecord)
        manager.requestReconnect(reason: "late proxy wedge")
        manager.observeCoreLine("keeping listener up")
        XCTAssertEqual(manager.activeMode, .vpn)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertFalse(manager.hasPendingRecovery)
    }

    func testRecoverySinkRejectsAppStartedVPNWithKnownRecord() async {
        SettingsStore.shared.tunnelMode = .vpn
        let profile = LifecycleProfile()
        let manager = makeManager(profile: profile)
        manager.connect(record: ConnectionRecord(name: "x", details: .olcrtc(params())))
        await lifecycleEventually { profile.startCount == 1 }
        profile.emit(.connected)
        XCTAssertNotNil(manager.connectedRecord)
        manager.requestReconnect(reason: "late engine line")
        XCTAssertFalse(manager.hasPendingRecovery, "backend gate must work even with lastRecord present")
    }

    func testEngagedRecordExcludesIdleAndTerminalFailureButIncludesRecovery() async {
        SettingsStore.shared.tunnelMode = .proxy
        let manager = makeManager()
        let record = ConnectionRecord(name: "x", details: .olcrtc(params()))
        XCTAssertNil(manager.engagedRecord)
        manager.connect(record: record)
        XCTAssertEqual(manager.engagedRecord?.id, record.id)
        manager.state = .waitingForNetwork
        XCTAssertEqual(manager.engagedRecord?.id, record.id)
        manager.state = .failed("terminal")
        XCTAssertNil(manager.engagedRecord)
        manager.requestReconnect(reason: "recover")
        XCTAssertEqual(manager.engagedRecord?.id, record.id)
        manager.disconnect()
        XCTAssertNil(manager.engagedRecord)
    }

    func testForeignOrObservedRoutesOverrideTerminalAppState() {
        for state: ConnectionState in [.disconnected, .failed("stale")] {
            XCTAssertTrue(TunnelManager.systemTunnelIsUp(activeMode: .vpn, state: state,
                                                        vpnStatus: .disconnecting))
            XCTAssertTrue(TunnelManager.systemTunnelIsUp(activeMode: .vpn, state: state,
                                                        vpnStatus: .invalid, foreignTunnel: true))
        }
    }

    func testRouteRevisionPublishesCommittedChangesAndSkipsStateNoop() {
        let manager = makeManager()
        var observed: [ConnectionState] = []
        let sink = manager.$routeRevision.dropFirst().sink { _ in observed.append(manager.state) }
        let first = manager.routeRevision
        manager.state = .connecting
        XCTAssertGreaterThan(manager.routeRevision, first)
        XCTAssertEqual(observed, [.connecting], "publisher must see the new state, not willSet's old state")
        let revision = manager.routeRevision
        manager.state = .connecting
        XCTAssertEqual(manager.routeRevision, revision)
        manager.state = .disconnected
        XCTAssertGreaterThan(manager.routeRevision, revision, "up/down history must not collapse to idle equality")
        sink.cancel()
    }

    func testRouteRevisionTracksIdentityModeAndObservedDrain() async {
        SettingsStore.shared.tunnelMode = .proxy
        let profile = LifecycleProfile()
        let manager = makeManager(profile: profile)
        let before = manager.routeRevision
        let record = ConnectionRecord(name: "x", details: .olcrtc(params()))
        manager.connect(record: record)
        XCTAssertGreaterThan(manager.routeRevision, before)
        let connectedRevision = manager.routeRevision
        manager.connect(record: record)
        XCTAssertEqual(manager.routeRevision, connectedRevision, "same identity/backend is not a route change")
        profile.status = .connected
        await manager.vpn.adoptRunningTunnel()
        XCTAssertGreaterThan(manager.routeRevision, connectedRevision)
        let adopted = manager.routeRevision
        profile.emit(.disconnecting)
        XCTAssertGreaterThan(manager.routeRevision, adopted, "transition-only NE events invalidate route work too")
    }
    // eoc #483
}
