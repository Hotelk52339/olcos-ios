import Foundation
import NetworkExtension

// MARK: - VPNController (#vpn)
//
// Main-app control plane for the system-VPN (packet-tunnel) mode. In VPN mode
// the app never runs the Go core itself — the olcrtc-tunnel extension does —
// so this controller only drives NETunnelProviderManager: save the
// configuration, start/stop the tunnel, observe status, and exchange
// stats/log messages with the provider.
//
// Deliberately self-contained: it does not touch TunnelManager or OlcrtcEngine —
// TunnelManager's `.vpn` mode branch delegates here (#vpn), and the user-facing
// strings go through L10n (`vpnSettingsEntryName`, `vpnCapabilityUnavailable_fmt`).
//
// The manager flow below follows vpn-impl-decisions.md Q4 exactly:
//   1. loadAllFromPreferences, reuse managers.first (NEVER create duplicates —
//      each extra save adds another entry under Settings > VPN).
//   2. Fresh NETunnelProviderProtocol: providerBundleIdentifier of the appex,
//      a non-nil serverAddress (save fails on nil), providerConfiguration from
//      VPNConfig (String/Int values only).
//   3. isEnabled = true, then saveToPreferences. THE FIRST SAVE on a device
//      shows the system consent alert ("OlcRTC" Would Like to Add VPN
//      Configurations). User denial — or a build whose Network Extension
//      entitlement was stripped by free-Apple-ID re-signing — surfaces HERE as
//      an error; that is the runtime capability gate (iOS offers no way to
//      introspect your own entitlements), captured into `capability`.
//   4. loadFromPreferences AGAIN — MANDATORY. Skipping it makes
//      startVPNTunnel throw NEVPNErrorDomain .configurationInvalid
//      ("Missing protocol or protocol has invalid type").
//   5. Subscribe .NEVPNStatusDidChange on manager.connection BEFORE starting.
//   6. startVPNTunnel(options: nil).

@MainActor
final class VPNController: ObservableObject {

    // MARK: Types

    // #487 was: capability implied device-wide support and recommended fallback
    // for every denial. It now records this controller/session's public NE gate.
    /// Unknown until the installed app configures VPN or adopts an active tunnel.
    /// Unavailable can mean denied user consent OR unavailable signing capability;
    /// it is not a statement about the device or the user's Developer subscription.
    enum VPNCapability: Equatable {
        case unknown
        case available
        case unavailable(String)
    }

    /// NEVPNStatus mirrored into an Equatable value type the UI (and later
    /// TunnelManager's mode branch) can switch over without importing
    /// NetworkExtension semantics.
    enum Status: String, Equatable {
        case invalid, disconnected, connecting, connected, reasserting, disconnecting

        init(_ status: NEVPNStatus) {
            switch status {
            case .invalid:       self = .invalid
            case .disconnected:  self = .disconnected
            case .connecting:    self = .connecting
            case .connected:     self = .connected
            case .reasserting:   self = .reasserting
            case .disconnecting: self = .disconnecting
            @unknown default:    self = .invalid
            }
        }
    }

    struct VPNControllerError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // boc #487: only a failed permission gate authorizes automatic fallback.
    // A previously unavailable capability must NOT classify a later network error.
    struct CapabilityUnavailableError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    private var storedSecretsMayExist = false
    // eoc #487

    // MARK: Constants

    /// Bundle id of the packet-tunnel appex (project.yml target olcrtc-tunnel).
    /// Derived from the app's own bundle id — the appex is always
    /// `<app id>.tunnel`. A hard-coded literal breaks VPN mode in any rebuild
    /// under a different bundle id (a fork signed with its own team): the
    /// system finds no such provider and the tunnel silently stays disconnected.
    static let providerBundleIdentifier =
        (Bundle.main.bundleIdentifier ?? "io.github.hotelk52339.olcrtc-ios") + ".tunnel"

    /// Shown under Settings > VPN next to the toggle.
    private static var localizedDescription: String { L10n.vpnSettingsEntryName.localized() }

    // MARK: Published state

    @Published private(set) var status: Status = .invalid
    @Published private(set) var capability: VPNCapability = .unknown
    /// Last provider-reported disconnect reason (iOS fetchLastDisconnectError),
    /// filled when the tunnel drops without a local stop() call.
    @Published private(set) var lastDisconnectReason: String?

    // MARK: Private state

    // boc #483
    // #483 was: direct NETunnelProviderManager ownership with overlapping,
    // unversioned load/save/start tasks. VPNProfile keeps the native boundary
    // injectable; the serial operation tail owns all preference writes.
    private var manager: (any VPNProfile)?
    private let loadProfiles: @MainActor () async throws -> [any VPNProfile]
    private let makeProfile: @MainActor () -> any VPNProfile
    private var adoptionTask: Task<Void, Never>?
    private var operationTask: Task<Void, Error>?
    private var teardownTask: Task<Void, Error>? // #483: stop work has ownership too.
    private var operationEpoch = 0
    private var sessionEpoch = 0
    private var awaitingStartStatus = false // #483: accepted start is not a terminal idle snapshot.
    private var handshakeInProgress = false
    var isPreparingStart: Bool { handshakeInProgress } // #483: only the real preference handshake suppresses idle.
    private(set) var stopRequested = false
    private var localStopComplete = false // #483: only a joined stop can authorize later external adoption.
    private(set) var externallyStarted = false // #483: a later external session has no known app record.

    init(loadProfiles: (@MainActor () async throws -> [any VPNProfile])? = nil,
         makeProfile: (@MainActor () -> any VPNProfile)? = nil) {
        self.loadProfiles = loadProfiles ?? {
            try await NETunnelProviderManager.loadAllFromPreferences().map { SystemVPNProfile($0) }
        }
        self.makeProfile = makeProfile ?? { SystemVPNProfile() }
    }

    private func checkOperation(_ epoch: Int) throws {
        guard operationEpoch == epoch, !Task.isCancelled else { throw CancellationError() }
    }

    private func selectProfile(_ profiles: [any VPNProfile]) -> (any VPNProfile)? {
        let own = profiles.filter { $0.providerIdentifier == Self.providerBundleIdentifier }
        return own.first(where: { Self.mayHoldRoutes($0.status) }) ?? own.first
    }

    nonisolated static func mayHoldRoutes(_ status: Status) -> Bool {
        switch status {
        case .connecting, .connected, .reasserting, .disconnecting: return true
        case .invalid, .disconnected: return false
        }
    }
    // eoc #483
    /// Set while stop() is in flight so an expected .disconnected does not
    /// trigger a disconnect-error fetch.
    // #483: stopRequested remains set through the terminal observation, so a
    // queued connected signal cannot resurrect a locally stopped session.

    // MARK: Capability probe (lazy, side-effect free)

    // #487 was: an existing idle profile proved the entitlement still worked.
    /// Loads without saving or presenting consent. An active provider proves
    /// current support; an idle profile can survive re-signing and stays unknown.
    /// The definitive gate is the load/save handshake on the user's next connect.
    func probeCapability() async {
        // #477 was: `guard capability == .unknown else { return }` guarded the
        // WHOLE body, adoption included — see `adoptRunningTunnel`.
        await adoptRunningTunnel()
    }

    // boc #477: adoption has to be its own entry point, callable at any time.
    // #469 folded it into `probeCapability`, which (a) returned early once
    // `capability` was known and (b) is only ever called from the Settings
    // screen. A tunnel switched on from iOS Settings — or from Control Centre —
    // while the app sat on any other tab was therefore never observed: no
    // manager, no status notification, and `TunnelManager` went on running the
    // in-app proxy underneath it. Both clients then carried the SAME clientID
    // into the carrier room, which is the one thing the room cannot survive.
    //
    // Safe to call repeatedly: it adopts at most once and otherwise just
    // re-reads the live status, which is exactly what is needed after a
    // foreground return (notifications posted while suspended are not queued).
    /// Observes an already-running tunnel and publishes its real status.
    func adoptRunningTunnel() async {
        // boc #483
        // #483 was: publish status directly (including unchanged disconnected)
        // and load preferences independently on every concurrent cold call.
        if let adoptionTask {
            await adoptionTask.value
            return
        }
        if manager != nil {
            statusDidChange()
            return
        }
        let epoch = operationEpoch
        let task = Task { @MainActor [weak self] in
            guard let self,
                  let profiles = try? await self.loadProfiles(),
                  self.operationEpoch == epoch, self.manager == nil,
                  let existing = self.selectProfile(profiles) else { return }
            // #487 was: an idle profile proved current signing capability.
            // A profile can survive re-signing; only an active provider is evidence.
            if Self.mayHoldRoutes(existing.status) { self.capability = .available }
            self.storedSecretsMayExist = Self.containsSecrets(existing.configuration)
            self.manager = existing
            self.observeStatus(of: existing)
            self.statusDidChange()
        }
        adoptionTask = task
        await task.value
        adoptionTask = nil
        // eoc #483
    }
    // eoc #477

    // MARK: Start

    /// Saves (or updates) the tunnel configuration and starts the VPN.
    /// Throws on save/start failure; save failures caused by a missing NE
    /// entitlement or denied consent also flip `capability` to `.unavailable`.
    func start(_ config: VPNConfig) async throws {
        // boc #483
        // #483 was: unowned preference handshake followed by unconditional start.
        try Task.checkCancellation()
        operationEpoch &+= 1
        let epoch = operationEpoch
        let previous = operationTask
        let task = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self else { throw CancellationError() }
            try self.checkOperation(epoch)
            self.handshakeInProgress = true
            defer { self.handshakeInProgress = false }
            // boc #487: missing permission may fail at load before save is reached.
            let profiles: [any VPNProfile]
            do { profiles = try await self.loadProfiles() }
            catch {
                try self.checkOperation(epoch)
                if let reason = Self.capabilityFailureReason(error) {
                    self.capability = .unavailable(reason)
                    throw CapabilityUnavailableError(reason: reason)
                }
                throw error
            }
            // eoc #487
            try self.checkOperation(epoch)
            let profile = self.selectProfile(profiles) ?? self.makeProfile()
            // #487: retain dirty-on-disk evidence if a previous scrub failed
            // after it blanked this same profile's in-memory configuration.
            self.storedSecretsMayExist = (self.manager === profile && self.storedSecretsMayExist)
                || Self.containsSecrets(profile.configuration)
            self.manager = profile
            self.observeStatus(of: profile)
            // Even a controller-only caller must not reconfigure a live session.
            if Self.mayHoldRoutes(profile.status) {
                self.stopRequested = true // #483: this is our stop, not a provider failure.
                self.localStopComplete = false
                profile.stop()
                try await self.waitUntilDown(profile)
                try self.checkOperation(epoch)
            }
            self.awaitingStartStatus = true // #483: do not scrub the pre-start idle profile.
            self.externallyStarted = false
            profile.configure(config)
            do {
                try await profile.save()
                self.storedSecretsMayExist = true // #487: stop must join a successful scrub even if start was cancelled.
            } catch {
                try self.checkOperation(epoch)
                if let reason = Self.capabilityFailureReason(error) {
                    self.capability = .unavailable(reason)
                    throw CapabilityUnavailableError(reason: reason) // #487 was: untyped VPNControllerError
                }
                throw error
            }
            try self.checkOperation(epoch)
            self.capability = .available
            try await profile.reload() // Mandatory after EVERY save.
            try self.checkOperation(epoch)
            self.sessionEpoch &+= 1
            self.lastDisconnectReason = nil
            self.statusDidChange()
            self.stopRequested = false // #483: suppress only the pre-start snapshot.
            try profile.start()
            self.statusDidChange()
        }
        operationTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                // Cancellation can arrive after startVPNTunnel returned. Scope
                // cleanup to this epoch so it never stops the next attempt.
                Task { @MainActor [weak self] in
                    guard let self, self.operationEpoch == epoch else { return }
                    self.stop()
                }
            }
        } catch {
            // #483: a failed/cancelled save/start must not leave freshly written
            // secrets behind just because NE never changed its idle status.
            if operationEpoch == epoch {
                awaitingStartStatus = false
                scrubStoredSecrets()
            }
            throw error
        }
        // eoc #483
    }

    // MARK: Stop

    /// Asks the provider to stop (provider receives stopTunnel(.userInitiated)).
    /// Status flows back through the .NEVPNStatusDidChange observer.
    func stop() {
        // #483: invalidate a handshake BEFORE any suspended save/load resumes.
        operationEpoch &+= 1
        sessionEpoch &+= 1
        stopRequested = true
        localStopComplete = false
        awaitingStartStatus = false // #483: a local stop cancels pending start acceptance too.
        manager?.stop()
        // #483: capture the stop generation synchronously. A queued waiter must
        // never look up and stop whichever new profile is current when it resumes.
        let epoch = operationEpoch
        let previous = operationTask
        let profile = manager
        teardownTask = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, self.operationEpoch == epoch else { return }
            guard let profile else {
                self.localStopComplete = true
                return
            }
            if Self.mayHoldRoutes(profile.status) { profile.stop() }
            try await self.waitUntilDown(profile)
            guard self.operationEpoch == epoch, self.manager === profile else { return }
            self.localStopComplete = true
            self.statusDidChange()
            // #487 was: scrub errors were discarded, authorizing another backend
            // even if a saved profile still retained the previous session's secrets.
            let scrub = self.scrubStoredSecrets()
            try await scrub?.value
            // #487: an externally resumed profile cannot release another client
            // merely because its earlier terminal snapshot preceded the scrub.
            guard self.operationEpoch == epoch, self.manager === profile,
                  !Self.mayHoldRoutes(profile.status) else { throw CancellationError() }
        }
    }

    // boc #483: terminal NE status, not the return from stopVPNTunnel, releases
    // the room identity. Timeout fails closed; never dial the other backend.
    func stopAndWait() async throws {
        // #483 was: unversioned post-await stop of self.manager.
        try await teardownTask?.value
    }

    private func waitUntilDown(_ profile: any VPNProfile) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while Self.mayHoldRoutes(profile.status) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw VPNControllerError(L10n.vpnDisconnected.localized())
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    // eoc #483

    // boc #470: `providerConfiguration` keeps the room key and the WB token in
    // the system's VPN profile for as long as the profile exists — a secret at
    // rest outside the Keychain, long after the session ended. Blank the two
    // once the tunnel is down. `start()` writes the full configuration before
    // every launch, so nothing depends on them surviving; and this re-saves an
    // EXISTING profile (never `removeFromPreferences`, which would re-prompt
    // for consent).
    // boc #487: the joined task is the stop/scrub barrier. Never scrub a live profile.
    private static func containsSecrets(_ config: [String: Any]) -> Bool {
        VPNConfig.secretConfigKeys.contains { !((config[$0] as? String) ?? "").isEmpty }
    }
    @discardableResult
    private func scrubStoredSecrets() -> Task<Void, Error>? {
        // #483: retain the secret-at-rest policy. External restart after scrub
        // requires shared Keychain entitlements, NOT leaving plaintext in NE.
        guard let manager, !Self.mayHoldRoutes(manager.status) else { return nil } // #487: invalid is terminal too.
        var config = manager.configuration
        let names = VPNConfig.secretConfigKeys
        // Nothing to do when they are already blank — a save per status change
        // would be pointless churn against the system's preferences store.
        guard storedSecretsMayExist || Self.containsSecrets(config) else { return nil } // #487: retry a failed persisted scrub even if memory is blank.
        // #487: a denied first save wrote no profile. Clear in-memory secrets,
        // but don't demand a second (also forbidden) save of a nonexistent profile.
        if !storedSecretsMayExist {
            for name in names { config[name] = "" }
            manager.configuration = config
            return nil
        }
        for name in names { config[name] = "" }
        // boc #483: serialize the scrub with starts; a late scrub must never
        // save an old/blank config over a newer start's hydrated configuration.
        let epoch = operationEpoch
        let previous = operationTask
        operationTask = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, self.operationEpoch == epoch,
                  self.manager === manager, !Self.mayHoldRoutes(manager.status) else { return } // #487
            manager.configuration = config
            try await manager.save()
            if self.operationEpoch == epoch, self.manager === manager {
                self.storedSecretsMayExist = false // #487: only a successful persisted scrub releases secrets.
            }
        }
        return operationTask // #487
        // eoc #483
    }
    // eoc #487
    // eoc #470

    // MARK: Provider messages

    /// Provider stats via NETunnelProviderSession.sendProviderMessage
    /// (answered by PacketTunnelProvider.handleAppMessage "stats" with the
    /// JSON blob described by `ProviderStats`). nil when no session exists or
    /// the provider is not running.
    func stats() async -> Data? {
        await sendProviderMessage("stats")
    }

    /// The "stats" provider message, version 1. Encoder: `PacketTunnelProvider
    /// .statsJSON()`; consumer: `TunnelThroughputMonitor`. Bump `version` and
    /// `v` together on any incompatible change — a payload whose `v` is not
    /// recognised decodes to nil so the app never shows numbers it cannot read.
    struct ProviderStats: Decodable, Equatable {
        static let version = 1

        let v: Int
        let state: String?
        let running: Bool?
        let tunnelActive: Bool?
        /// Cumulative bytes toward the device (tunstack rx) — only while a tunnel is up.
        let rxBytes: Int64?
        /// Cumulative bytes from the device (tunstack tx) — only while a tunnel is up.
        let txBytes: Int64?
        let uptimeSeconds: Int?
        /// Provider monotonic clock (ms) at sampling time, for rate maths.
        let monotonicMs: Int64?

        static func decode(_ data: Data) -> ProviderStats? {
            guard let stats = try? JSONDecoder().decode(ProviderStats.self, from: data),
                  stats.v == version else { return nil }
            return stats
        }
    }

    /// Tail of the extension's in-process log ring buffer (UTF-8 text,
    /// newline-separated) via handleAppMessage "logs".
    func logsTail() async -> String? {
        guard let data = await sendProviderMessage("logs") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func sendProviderMessage(_ message: String) async -> Data? {
        // #483 was: native sendProviderMessage continuation here; native IO is
        // now behind the injected profile boundary.
        await manager?.message(Data(message.utf8))
    }

    // MARK: Status observation

    // #483 was: observer callback read whichever manager was current, including
    // callbacks queued by a profile that had since been superseded.
    private func observeStatus(of manager: any VPNProfile) {
        manager.observe { [weak self, weak manager] in
            guard let self, let manager, self.manager === manager else { return }
            self.statusDidChange(isNotification: true) // #483: distinguish real terminal event from reread.
        }
    }

    private func statusDidChange(isNotification: Bool = false) { // #483: rereads are not fresh terminal events.
        guard let manager else { return }
        let previous = status
        // boc #483: one reducer serves notifications AND foreground rereads.
        let current = manager.status
        let pendingFailure = isNotification && awaitingStartStatus
            && !handshakeInProgress && current == .disconnected
        guard current != previous || pendingFailure else { return }
        let wasUp = previous == .connected || previous == .connecting || previous == .reasserting
        let isUp = current == .connected || current == .connecting || current == .reasserting
        if isUp, !wasUp, !handshakeInProgress, !awaitingStartStatus,
           !stopRequested || localStopComplete {
            externallyStarted = true // #483: classify before clearing the pending-start marker.
        }
        if isUp || pendingFailure { awaitingStartStatus = false }
        if isUp, !wasUp, !stopRequested {
            sessionEpoch &+= 1
            lastDisconnectReason = nil
        }
        // A genuine external start after a confirmed terminal state is allowed;
        // a late connected signal while stopping is not a new session.
        if isUp, !wasUp, stopRequested, localStopComplete,
           previous == .disconnected || previous == .invalid {
            stopRequested = false
            sessionEpoch &+= 1
            lastDisconnectReason = nil
        }
        status = current
        if current == .disconnected, awaitingStartStatus { return }
        // eoc #483

        // Post-mortem for unexpected drops: the provider's startTunnel/
        // stopTunnel error (if any) is retained by the system and readable
        // after the fact (iOS 16+; deployment target is 17).
        if current == .disconnected,
           (wasUp || previous == .disconnecting || pendingFailure), !stopRequested {
            fetchLastDisconnectError()
        }
        if current == .disconnected {
            // #483: keep local-stop suppression until the next genuinely new
            // up transition; unchanged terminal rereads must not erase errors.
            scrubStoredSecrets()   // #470
        }
    }

    private func fetchLastDisconnectError() {
        // boc #483
        // #483 was: asynchronous errors wrote into whichever session was current.
        guard let manager else { return }
        let epoch = sessionEpoch
        Task { @MainActor [weak self] in
            let reason = await manager.disconnectError()
            guard let self, self.manager === manager, self.sessionEpoch == epoch,
                  self.status == .disconnected, !self.stopRequested,
                  let reason else { return }
            self.lastDisconnectReason = reason
            self.status = .disconnected // Intentional reason update, not a reread.
        }
        // eoc #483
    }

    // MARK: Capability error classification

    // boc #487
    // #487 was: NEVPN configurationReadWriteFailed alone OR any error text
    // containing "permission denied" was classified as missing capability.
    // Read/write failure is also storage/transient failure. Only recognized NE
    // permission evidence, from the public load/save operations, permits downgrade.
    static func capabilityFailureReason(_ error: Error) -> String? {
        let ns = error as NSError
        let isNE = ns.domain == "NEConfigurationErrorDomain" || ns.domain == NEVPNErrorDomain
        let denied = ns.domain == "NEConfigurationErrorDomain" && ns.code == 10
        let permissionText = isNE && ns.localizedDescription.lowercased().contains("permission denied")
        if denied || permissionText {
            return L10n.vpnPermissionUnavailable_fmt.formatted(ns.localizedDescription)
        }
        if isNE, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== ns {
            // Only the direct underlying error is considered; no arbitrary text
            // from a carrier, DNS lookup, or key-validation failure is evidence.
            if underlying.domain == "NEConfigurationErrorDomain", underlying.code == 10 {
                return L10n.vpnPermissionUnavailable_fmt.formatted(underlying.localizedDescription)
            }
        }
        return nil
    }
    // eoc #487
}
