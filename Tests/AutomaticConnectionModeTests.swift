import XCTest
import NetworkExtension
@testable import olcrtc_ios

// boc #487: pure preference contracts; capabilities are session evidence, never stored.
final class ConnectionModePreferenceTests: XCTestCase {
    func testFreshAndCorruptPreferencesAreVPNFirst() {
        for raw in [nil, "", "invalid"] as [String?] {
            let preference = ConnectionModePreference.restored(preference: raw, legacyMode: nil)
            XCTAssertEqual(preference, .automatic)
            XCTAssertEqual(preference.effectiveMode(vpnUnavailable: false), .vpn)
            XCTAssertEqual(preference.effectiveMode(vpnUnavailable: true), .proxy)
        }
    }

    func testLegacyChoicesMigrateButNewAutomaticWinsOverLegacyMirror() {
        XCTAssertEqual(ConnectionModePreference.restored(preference: nil, legacyMode: "proxy"), .proxy)
        XCTAssertEqual(ConnectionModePreference.restored(preference: nil, legacyMode: "vpn"), .vpn)
        XCTAssertEqual(ConnectionModePreference.restored(preference: "automatic", legacyMode: "proxy"), .automatic)
    }

    func testExplicitSOCKSSurvivesCapabilityUpgradeAndRelaunch() {
        let persisted = ConnectionModePreference.proxy.rawValue
        for unavailable in [true, false, true, false] {
            let restored = ConnectionModePreference.restored(preference: persisted, legacyMode: nil)
            XCTAssertEqual(restored.effectiveMode(vpnUnavailable: unavailable), .proxy)
        }
        XCTAssertEqual(ConnectionModePreference.vpn.effectiveMode(vpnUnavailable: true), .vpn)
    }

    func testAutomaticRecomputesForEachSignatureSessionWithoutSavingFallback() {
        let persisted = ConnectionModePreference.automatic.rawValue
        let restored = ConnectionModePreference.restored(preference: persisted, legacyMode: "proxy")
        XCTAssertEqual(restored.effectiveMode(vpnUnavailable: true), .proxy)
        XCTAssertEqual(restored.effectiveMode(vpnUnavailable: false), .vpn)
        XCTAssertEqual(restored.rawValue, "automatic")
    }
}

// Real coordinator + controller, fake OS profile + fake engine. No NE manager,
// Mobile runtime, DNS/socket/HTTP probe, audio or path monitor is invoked.
@MainActor
final class AutomaticConnectionModeTests: XCTestCase {
    private var savedPreference: ConnectionModePreference = .automatic
    private var savedDNS = ""
    private var savedShared: TunnelManager?
    private var lifecycleSnapshot: TunnelManager.LifecycleSnapshot?
    private var diskSnapshot: [String: Any] = [:]
    private var managers: [TunnelManager] = []
    private var profiles: [LifecycleProfile] = []
    private let preferenceKeys = ["settings.connectionModePreference", "settings.tunnelMode", "settings.dnsServer"]

    override func setUp() {
        super.setUp()
        SettingsStore.flushPendingWrites()
        for key in preferenceKeys { diskSnapshot[key] = UserDefaults.standard.object(forKey: key) }
        savedPreference = SettingsStore.shared.connectionModePreference
        savedDNS = SettingsStore.shared.dnsServer
        savedShared = TunnelManager.shared
        lifecycleSnapshot = TunnelManager.lifecycleSnapshot()
        SettingsStore.shared.connectionModePreference = .automatic
        SettingsStore.shared.dnsServer = "1.1.1.1"
    }

    override func tearDown() async throws {
        for profile in profiles { profile.stopImmediately = true; profile.onSave = nil }
        for manager in managers { manager.disconnect(); try await manager.waitForTeardown() }
        SettingsStore.shared.connectionModePreference = savedPreference
        SettingsStore.shared.dnsServer = savedDNS
        SettingsStore.flushPendingWrites()
        for key in preferenceKeys {
            if let value = diskSnapshot[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        TunnelManager.shared = savedShared
        if let lifecycleSnapshot { TunnelManager.restoreLifecycleSnapshot(lifecycleSnapshot) }
        try await super.tearDown()
    }

    private var denied: NSError {
        NSError(domain: "NEConfigurationErrorDomain", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "permission denied"])
    }
    private func record(_ room: String = "first", key: String = String(repeating: "a", count: 64)) -> ConnectionRecord {
        ConnectionRecord(name: room, details: .olcrtc(OlcrtcConnection(
            carrier: "jitsi", transport: "datachannel", roomID: room,
            key: key, clientID: "same-client-identity")))
    }
    private func setup(profile: LifecycleProfile, loadError: Error? = nil) -> (TunnelManager, LifecycleEngine) {
        profiles.append(profile)
        let vpn = VPNController(loadProfiles: {
            if let loadError { throw loadError }
            return [profile]
        }, makeProfile: { profile })
        let engine = LifecycleEngine()
        let manager = TunnelManager(vpn: vpn, engine: engine, runtimeEffectsEnabled: false,
                                    verify: { true }, portIsFree: { _ in true })
        managers.append(manager)
        return (manager, engine)
    }

    func testUnknownDefaultsToVPNAndSuccessfulSaveEstablishesCapability() async {
        let profile = LifecycleProfile()
        let (tunnel, engine) = setup(profile: profile)
        XCTAssertEqual(tunnel.effectiveModeForNextConnection, .vpn)
        XCTAssertNil(tunnel.automaticModeFallbackReason)
        tunnel.connect(record: record())
        await lifecycleEventually { profile.startCount == 1 }
        XCTAssertEqual(tunnel.vpn.capability, .available)
        XCTAssertEqual(tunnel.activeMode, .vpn)
        XCTAssertEqual(engine.startCount, 0)
    }

    func testIdleProfileDoesNotProveCurrentSignatureCapability() async {
        let profile = LifecycleProfile()
        let (tunnel, _) = setup(profile: profile)
        await tunnel.vpn.probeCapability()
        XCTAssertEqual(tunnel.vpn.capability, .unknown)
        XCTAssertEqual(profile.saveCount, 0, "probing never triggers consent")
    }

    func testPermissionDeniedFallsBackOnlyAfterTerminalStopWithSameIdentity() async {
        let profile = LifecycleProfile()
        profile.stopImmediately = false
        profile.onSave = { throw self.denied }
        let (tunnel, engine) = setup(profile: profile)
        let original = record()
        tunnel.connect(record: original)
        await lifecycleEventually { profile.stopCount > 0 }
        XCTAssertEqual(tunnel.activeMode, .vpn)
        XCTAssertEqual(engine.startCount, 0, "no SOCKS client while VPN stop is unconfirmed")
        XCTAssertEqual(tunnel.engagedRecord?.id, original.id)
        profile.emit(.disconnected)
        await lifecycleEventually { engine.startCount == 1 }
        XCTAssertEqual(profile.startCount, 0)
        XCTAssertEqual(engine.startedRooms, ["first"])
        XCTAssertEqual(tunnel.engagedRecord?.id, original.id)
        XCTAssertEqual(tunnel.activeMode, .proxy)
        XCTAssertEqual(tunnel.effectiveModeForNextConnection, .proxy)
        XCTAssertNotNil(tunnel.automaticModeFallbackReason)
        XCTAssertEqual(SettingsStore.shared.connectionModePreference, .automatic)
    }

    func testPermissionFailureDuringLoadUsesSameFallbackPolicy() async {
        let profile = LifecycleProfile()
        let (tunnel, engine) = setup(profile: profile, loadError: denied)
        tunnel.connect(record: record())
        await lifecycleEventually { engine.startCount == 1 }
        XCTAssertEqual(profile.saveCount, 0)
        XCTAssertNotNil(tunnel.automaticModeFallbackReason)
    }

    func testDisconnectDuringDeniedSaveCannotLaunchStaleFallback() async {
        let gate = LifecycleGate()
        let profile = LifecycleProfile()
        profile.onSave = { await gate.wait(); throw self.denied }
        let (tunnel, engine) = setup(profile: profile)
        tunnel.connect(record: record())
        await lifecycleEventually { gate.entered }
        tunnel.disconnect()
        gate.release()
        try? await tunnel.waitForTeardown()
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertEqual(profile.startCount, 0)
        XCTAssertEqual(tunnel.state, .disconnected)
        XCTAssertEqual(tunnel.vpn.capability, .unknown, "stale error cannot poison current capability")
    }

    func testDisconnectWhileFallbackStopIsPendingPreventsSOCKSStart() async {
        let profile = LifecycleProfile()
        profile.stopImmediately = false
        profile.onSave = { throw self.denied }
        let (tunnel, engine) = setup(profile: profile)
        tunnel.connect(record: record())
        await lifecycleEventually { profile.stopCount > 0 }
        tunnel.disconnect()
        profile.emit(.disconnected)
        try? await tunnel.waitForTeardown()
        await Task.yield()
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertEqual(tunnel.state, .disconnected)
    }

    func testRecordSwitchDuringFallbackStopOnlyStartsNewRecordOnce() async {
        let profile = LifecycleProfile()
        profile.stopImmediately = false
        profile.onSave = { throw self.denied }
        let (tunnel, engine) = setup(profile: profile)
        tunnel.connect(record: record())
        await lifecycleEventually { profile.stopCount > 0 }
        let second = record("second")
        tunnel.connect(record: second)
        XCTAssertEqual(engine.startCount, 0)
        profile.emit(.disconnected)
        await lifecycleEventually { engine.startCount == 1 }
        XCTAssertEqual(engine.startedRooms, ["second"])
        XCTAssertEqual(tunnel.engagedRecord?.id, second.id)
    }

    func testFallbackWaitsForPersistedSecretScrub() async {
        let gate = LifecycleGate()
        let profile = LifecycleProfile()
        profile.configuration = ["keyHex": String(repeating: "b", count: 64)]
        profile.onSave = { [weak profile] in
            if profile?.saveCount == 1 { throw self.denied }
            await gate.wait()
        }
        let (tunnel, engine) = setup(profile: profile)
        tunnel.connect(record: record())
        await lifecycleEventually { gate.entered }
        XCTAssertEqual(engine.startCount, 0, "terminal NE status alone does not release the scrub barrier")
        XCTAssertEqual(tunnel.activeMode, .vpn)
        gate.release()
        await lifecycleEventually { engine.startCount == 1 }
        XCTAssertTrue(VPNConfig.secretConfigKeys.allSatisfy {
            (profile.configuration[$0] as? String ?? "").isEmpty
        })
    }

    func testFailedSecretScrubFailsClosedWithoutStartingSOCKS() async {
        let profile = LifecycleProfile()
        profile.configuration = ["keyHex": String(repeating: "b", count: 64)]
        profile.onSave = { [weak profile] in
            if profile?.saveCount == 1 { throw self.denied }
            throw VPNController.VPNControllerError("scrub failed")
        }
        let (tunnel, engine) = setup(profile: profile)
        tunnel.connect(record: record())
        await lifecycleEventually { tunnel.state == .failed("scrub failed") }
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertEqual(tunnel.activeMode, .vpn)
        // Fixture teardown retries a now-successful scrub; it never bypasses it.
        profile.onSave = nil
    }

    func testNewControllerReevaluatesAutomaticAfterSigningUpgrade() async {
        let deniedProfile = LifecycleProfile()
        deniedProfile.onSave = { throw self.denied }
        let (old, oldEngine) = setup(profile: deniedProfile)
        old.connect(record: record())
        await lifecycleEventually { oldEngine.startCount == 1 }
        old.disconnect()
        try? await old.waitForTeardown()
        let upgradedProfile = LifecycleProfile()
        let (upgraded, upgradedEngine) = setup(profile: upgradedProfile)
        XCTAssertEqual(upgraded.effectiveModeForNextConnection, .vpn)
        XCTAssertNil(upgraded.automaticModeFallbackReason)
        upgraded.connect(record: record())
        await lifecycleEventually { upgradedProfile.startCount == 1 }
        XCTAssertEqual(upgradedEngine.startCount, 0)
        XCTAssertEqual(SettingsStore.shared.connectionModePreference, .automatic)
    }

    func testExplicitVPNPermissionDenialNeverFallsBack() async {
        SettingsStore.shared.tunnelMode = .vpn
        let profile = LifecycleProfile()
        profile.onSave = { throw self.denied }
        let (tunnel, engine) = setup(profile: profile)
        tunnel.connect(record: record())
        await lifecycleEventually { if case .failed = tunnel.state { return true }; return false }
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertEqual(tunnel.effectiveModeForNextConnection, .vpn)
        XCTAssertNil(tunnel.automaticModeFallbackReason)
    }

    func testExplicitSOCKSNeverTouchesVPNPreferencesEvenWhenAvailable() async {
        SettingsStore.shared.tunnelMode = .proxy
        let profile = LifecycleProfile()
        let (tunnel, engine) = setup(profile: profile)
        tunnel.connect(record: record())
        await lifecycleEventually { engine.startCount == 1 }
        XCTAssertEqual(profile.saveCount, 0)
        XCTAssertEqual(profile.startCount, 0)
        XCTAssertEqual(tunnel.effectiveModeForNextConnection, .proxy)
    }

    func testOrdinaryLoadSaveAndStartFailuresNeverDowngrade() async {
        let errors = [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
            NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.configurationReadWriteFailed.rawValue),
            NSError(domain: "carrier", code: 10, userInfo: [NSLocalizedDescriptionKey: "permission denied"])
        ]
        for error in errors {
            for stage in ["load", "save", "start"] {
                let profile = LifecycleProfile()
                if stage == "save" { profile.onSave = { throw error } }
                if stage == "start" { profile.startError = error }
                let (tunnel, engine) = setup(profile: profile, loadError: stage == "load" ? error : nil)
                tunnel.connect(record: record())
                await lifecycleEventually { if case .failed = tunnel.state { return true }; return false }
                XCTAssertEqual(engine.startCount, 0, "\(stage): \(error)")
                XCTAssertNil(tunnel.automaticModeFallbackReason)
                tunnel.disconnect()
                try? await tunnel.waitForTeardown()
            }
        }
    }

    func testPermissionLookingStartFailureIsNotACapabilityGate() async {
        let profile = LifecycleProfile()
        profile.startError = denied
        let (tunnel, engine) = setup(profile: profile)
        tunnel.connect(record: record())
        await lifecycleEventually { if case .failed = tunnel.state { return true }; return false }
        XCTAssertEqual(tunnel.vpn.capability, .available, "successful save established capability; start failure is not its revocation")
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertNil(tunnel.automaticModeFallbackReason)
    }

    func testCapabilityClassifierRejectsGenericErrorsAndAcceptsNEPermissionEvidence() {
        XCTAssertNotNil(VPNController.capabilityFailureReason(denied))
        let generic = NSError(domain: NEVPNErrorDomain,
                              code: NEVPNError.Code.configurationReadWriteFailed.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "configuration store is temporarily unavailable"])
        XCTAssertNil(VPNController.capabilityFailureReason(generic))
        let nested = NSError(domain: NEVPNErrorDomain,
                             code: NEVPNError.Code.configurationReadWriteFailed.rawValue,
                             userInfo: [NSUnderlyingErrorKey: denied])
        XCTAssertNotNil(VPNController.capabilityFailureReason(nested))
        XCTAssertNil(VPNController.capabilityFailureReason(NSError(
            domain: "carrier", code: 10, userInfo: [NSLocalizedDescriptionKey: "permission denied"])))
    }

    func testExplicitSOCKSOverrideSurvivesActualControllerCapabilityUpgrade() async {
        let deniedProfile = LifecycleProfile()
        deniedProfile.onSave = { throw self.denied }
        let (old, oldEngine) = setup(profile: deniedProfile)
        old.connect(record: record())
        await lifecycleEventually { oldEngine.startCount == 1 }
        old.disconnect()
        try? await old.waitForTeardown()
        SettingsStore.shared.tunnelMode = .proxy
        let upgraded = LifecycleProfile()
        let (next, engine) = setup(profile: upgraded)
        next.connect(record: record())
        await lifecycleEventually { engine.startCount == 1 }
        XCTAssertEqual(next.effectiveModeForNextConnection, .proxy)
        XCTAssertNil(next.automaticModeFallbackReason)
        XCTAssertEqual(upgraded.saveCount, 0, "explicit SOCKS never invokes NE even with a newly capable signature")
    }

    func testInvalidKeyAndUnsupportedDNSNeverDowngradeOrRequestPermission() async {
        let profile = LifecycleProfile()
        let (tunnel, engine) = setup(profile: profile)
        tunnel.connect(record: record(key: "invalid"))
        if case .failed = tunnel.state {} else { XCTFail("invalid key must fail") }
        SettingsStore.shared.dnsServer = "2001:4860:4860::8888"
        tunnel.connect(record: record())
        await lifecycleEventually { tunnel.state == .failed(L10n.vpnPacketDNSUnsupported.localized()) }
        XCTAssertEqual(tunnel.state, .failed(L10n.vpnPacketDNSUnsupported.localized()))
        XCTAssertEqual(profile.saveCount, 0)
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertNil(tunnel.automaticModeFallbackReason)
    }
}
// eoc #487
