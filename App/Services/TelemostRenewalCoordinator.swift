import Foundation
import SwiftUI

// #465: the side-effecting half of automatic room renewal. `TelemostRenewalPolicy`
// decides WHETHER and WHEN; this drives the SSH and the stores.
//
// Owned by MainTabView, next to `UpdateChecker` and the subscription refresh,
// because renewal has to keep working while the user is anywhere in the app —
// including never opening Manage VPS again. It holds its OWN `Provisioner`, the
// per-owner pattern ServersView and LogsView already follow.
//
// Deliberately NOT shared with the manual button in ServersView: that path has
// to drive a sheet through create → apply → done/failed and report a hazard
// before the user commits. This one runs unattended and reports only through the
// log and a single published warning. The orchestration they share is ~15 lines;
// unifying it would mean threading UI phases through a service, and ServersView
// has already blown the SwiftUI type-checker budget three times in this repo.
@MainActor
final class TelemostRenewalCoordinator: ObservableObject {

    /// Set when the room is nearly gone and no free moment appeared, so the user
    /// has to be told. Cleared as soon as a renewal succeeds.
    @Published private(set) var warning: Warning?

    struct Warning: Identifiable, Equatable {
        let id: UUID              // the record whose room is expiring
        let minutesLeft: Int
        let recordName: String
        // boc #480: not every intervention is an expiry with a known clock.
        enum Reason: Equatable {
            case expiring, ageUnknown, setupRequired, creationFailed, applyUnconfirmed, foreignVPN, reconnectRequired
        }
        var reason: Reason = .expiring
        var candidateRoomID: String? = nil

        var title: String {
            reason == .expiring ? L10n.telemostExpiryTitle.localized()
                                : L10n.telemostRenewalAttentionTitle.localized()
        }

        var message: String {
            switch reason {
            case .expiring: return L10n.telemostExpiryBody_fmt.formatted(recordName, minutesLeft)
            case .ageUnknown: return L10n.telemostAgeUnknown_fmt.formatted(recordName)
            case .setupRequired: return L10n.telemostSetupRequired_fmt.formatted(recordName)
            case .creationFailed: return L10n.telemostCreationFailed_fmt.formatted(recordName)
            case .applyUnconfirmed:
                let explanation = L10n.telemostApplyUnconfirmed_fmt.formatted(recordName)
                guard let candidateRoomID else { return explanation }
                return explanation + "\n\n" + L10n.telemostApplyCandidate_fmt.formatted(candidateRoomID)
            case .foreignVPN: return L10n.telemostForeignVPN_fmt.formatted(recordName)
            case .reconnectRequired: return L10n.telemostReconnectRequired_fmt.formatted(recordName)
            }
        }

        var canRenew: Bool { reason == .expiring || reason == .ageUnknown }
        // eoc #480
    }

    // boc #480: inject the I/O boundary, so coordinator races and failure paths
    // can be exercised without stores, Keychain, real SSH or a live tunnel.
    // #480 was: concrete stores/tunnel and a privately constructed Provisioner.
    struct Target: Equatable {
        let host: ServerHost
        let secret: SSHSecret
        let container: String
    }

    /// Nonsecret recovery evidence, NOT a successful ConnectionRecord update.
    /// Saved before SSH so an app termination cannot erase an ambiguous write.
    struct PendingRenewal: Codable, Equatable {
        let previousRoomID: String
        let previousCreatedAt: Date?
        let candidateRoomID: String
        let candidateCreatedAt: Date
        let hostID: UUID
        let container: String

        func matches(_ record: ConnectionRecord) -> Bool {
            guard case .olcrtc(let params) = record.details else { return false }
            return params.roomID == previousRoomID && params.roomCreatedAt == previousCreatedAt
        }
    }

    struct Environment {
        var records: @MainActor () -> [ConnectionRecord]
        var update: @MainActor (ConnectionRecord) -> Void
        var target: @MainActor (ConnectionRecord) -> Target?
        var engagedRecord: @MainActor () -> ConnectionRecord?
        var isConnectedProxy: @MainActor () -> Bool
        var lastActivity: @MainActor () -> Date?
        var foreignVPN: @MainActor () -> Bool
        var hasSession: @MainActor () -> Bool
        var createRoom: @MainActor () async throws -> TelemostRoom
        var applyRoom: @MainActor (Target, InstallOptions) async throws -> String?
        var disconnect: @MainActor () -> Void
        var connect: @MainActor (ConnectionRecord) -> Void
        var claimHost: @MainActor (UUID) -> Bool
        var releaseHost: @MainActor (UUID) -> Void
        var now: @MainActor () -> Date = { Date() }
        var loadPending: @MainActor () -> [UUID: PendingRenewal] = { [:] }
        var savePending: @MainActor ([UUID: PendingRenewal]) -> Void = { _ in }
    }

    private let environment: Environment

    /// Dismissals belong to a room revision, not merely a record UUID.
    private struct RoomRevision: Equatable {
        let roomID: String
        let createdAt: Date?

        init?(_ record: ConnectionRecord) {
            guard case .olcrtc(let params) = record.details else { return nil }
            roomID = params.roomID
            createdAt = params.roomCreatedAt
        }
    }

    private struct NoticeKey: Equatable {
        let revision: RoomRevision?
        let reason: Warning.Reason
    }

    private var dismissed: [UUID: NoticeKey] = [:]
    private var presented: NoticeKey?
    /// A pending entry blocks unattended retries until explicitly reconciled.
    @Published private(set) var pendingRenewals: [UUID: PendingRenewal]
    private static let pendingDefaultsKey = "olcrtc.telemost.pending-renewals.v1"
    // eoc #480

    /// Guards against two checks overlapping — `.task` fires per appearance and
    /// the loop below ticks on its own.
    private var running = false

    /// #465: how often to re-ask the policy. The decision is cheap (no I/O) and
    /// the answer changes as the tunnel goes idle, so asking often is what makes
    /// "wait for a quiet moment" actually find one.
    private static let tick: Duration = .seconds(15 * 60)

    // boc #480
    // #480 was: direct assignments to stores; network work was not injectable.
    convenience init(connections: ConnectionStore, tunnel: TunnelManager, hosts: ServerHostStore) {
        let provisioner = Provisioner()
        self.init(environment: Environment(
            records: { connections.connections },
            update: { connections.update($0) },
            target: { record in
                guard let host = hosts.hosts.first(where: {
                    $0.lastConnectionID == record.id || ($0.extraConnectionIDs ?? []).contains(record.id)
                }), let secret = hosts.secret(for: host),
                // Automatic first trust is allowed. Reject invalid/corrupt
                // identity metadata before creating a room; SSHRunner validates
                // the actual presented key before applying it.
                (try? SSHHostKeyTrustStore.shared.prepare(host: host.host, port: host.port,
                    legacyPin: host.sshHostKeyPin)) != nil,
                let container = TelemostRenewalCoordinator.containerName(for: record, host: host)
                else { return nil }
                return Target(host: host, secret: secret, container: container)
            },
            engagedRecord: { tunnel.engagedRecord },
            isConnectedProxy: { tunnel.state.isConnected && tunnel.activeMode == .proxy },
            lastActivity: { TunnelManager.lastTunnelActivityDate },
            // #479: a foreign system VPN can loop newly opened transports.
            foreignVPN: {
                SystemVPNPresence.isActive && !TunnelManager.systemTunnelIsUp(
                    activeMode: tunnel.activeMode, state: tunnel.state, vpnStatus: tunnel.vpn.status,
                    foreignTunnel: false)
            },
            hasSession: { YandexSessionStore.hasStoredSession() },
            createRoom: { try await TelemostRoomService.createRoom() },
            applyRoom: { target, options in
                try await provisioner.reconfigure(on: target.host, secret: target.secret,
                    containerName: target.container, options: options)
            },
            disconnect: { tunnel.disconnect() },
            connect: { tunnel.connect(record: $0) },
            claimHost: { Provisioner.tryEnterHost($0) },
            releaseHost: { Provisioner.leaveHost($0) },
            loadPending: {
                guard let data = UserDefaults.standard.data(forKey: TelemostRenewalCoordinator.pendingDefaultsKey),
                      let pending = try? JSONDecoder().decode([UUID: PendingRenewal].self, from: data)
                else { return [:] }
                return pending
            },
            savePending: { pending in
                if let data = try? JSONEncoder().encode(pending) {
                    UserDefaults.standard.set(data, forKey: TelemostRenewalCoordinator.pendingDefaultsKey)
                }
            }))
    }

    init(environment: Environment) {
        self.environment = environment
        self.pendingRenewals = environment.loadPending()
    }
    // eoc #480

    // MARK: - Entry points

    /// Long-lived loop started from MainTabView. Sleeps and re-checks rather than
    /// returning when there is nothing to do — an id-less `.task` never restarts,
    /// so returning would end renewal for the rest of the session.
    func run() async {
        while !Task.isCancelled {
            await checkNow()
            try? await Task.sleep(for: Self.tick)
        }
    }

    /// One pass over every telemost record. Also called when the app comes back
    /// to the foreground, where the interesting case is a phone that spent the
    /// night asleep and woke up with hours already burned.
    func checkNow() async {
        guard !running else { return }
        running = true
        defer { running = false }

        // #480: deleted/changed records must not leave a stale alert on screen.
        clearStaleWarning()
        for record in telemostRecords() {
            if Task.isCancelled { return } // #480: never start work after cancellation.
            if await act(on: record) { return }   // one renewal per pass — each restarts a container
        }
    }

    /// The user answered the expiry warning. Renews the warned record even though
    /// the tunnel is in use — they just told us the drop is acceptable.
    func renewFromWarning() async {
        // boc #480
        // #480 was: a second, unguarded route directly into renew(record).
        guard let notice = warning, notice.canRenew else { return }
        await renew(recordID: notice.id)
        // eoc #480
    }

    /// #469: the alert captures the record id while its content is built, so the
    /// renew no longer depends on `warning` surviving SwiftUI's dismissal write
    /// (which lands before a deferred Task runs).
    func renew(recordID id: UUID) async {
        // boc #480: manual and automatic entry points share the SAME flight.
        // #480 was: no running guard; foreground checks could race this task.
        guard !running, !Task.isCancelled else { return }
        running = true
        defer { running = false }
        warning = nil
        presented = nil
        guard let record = environment.records().first(where: { $0.id == id }) else { return }
        _ = await renew(record, userInitiated: true)
        // eoc #480
    }

    /// Dismiss without renewing. The policy will raise it again on a later pass
    /// only if the record changes — a warning the user has already refused should
    /// not reappear every quarter hour.
    // boc #480
    // #480 was: func dismissWarning() { warning = nil }
    func dismissWarning() {
        if let id = warning?.id, let key = presented { dismissed[id] = key }
        warning = nil
        presented = nil
    }
    // eoc #480

    // MARK: - Deciding

    private func telemostRecords() -> [ConnectionRecord] {
        environment.records().filter { // #480: use the injected store boundary.
            if case .olcrtc(let p) = $0.details { return p.carrier == "telemost" }
            return false
        }
    }

    func input(for record: ConnectionRecord, now: Date = Date()) -> TelemostRenewalPolicy.Input {
        guard case .olcrtc(let params) = record.details else {
            return .init(now: now, roomCreatedAt: nil, isRidingThisRoom: false,
                         lastTunnelActivity: nil, alternativeRecordID: nil,
                         hasYandexSession: false)
        }
        // boc #480: a connecting/recovering room is occupied, not free to restart.
        // #480 was: let riding = tunnel.connectedRecord?.id == record.id
        let riding = environment.engagedRecord()?.id == record.id
        return .init(
            now:                 now,
            roomCreatedAt:       params.roomCreatedAt,
            isRidingThisRoom:    riding,
            lastTunnelActivity:  environment.lastActivity(),
            // A saved sibling is not evidence of a working, compatible route.
            // No unattended switches until such a route can be verified safely.
            alternativeRecordID: nil,
            hasYandexSession:    environment.hasSession(),
            activityIsObservable: environment.isConnectedProxy())
        // eoc #480
    }

    // #480 was: alternative(to:) selected the first saved non-Telemost sibling;
    // host(of:) read the stores directly. Target resolution is now injected.

    // MARK: - Acting

    /// Returns true when it did something that restarts a container, so the
    /// caller stops for this pass.
    private func act(on record: ConnectionRecord) async -> Bool {
        // boc #480: unknown age and missing setup are actionable facts, not silence.
        if let pending = pendingRenewals[record.id], pending.matches(record) {
            present(record, reason: .applyUnconfirmed)
            return false
        }
        if pendingRenewals[record.id] != nil {
            // A changed saved room is an explicit reconciliation, not a timer.
            pendingRenewals[record.id] = nil
            environment.savePending(pendingRenewals)
        }
        // #480 was: .ageUnknown was grouped with .doNothing.
        if case .olcrtc(let params) = record.details, params.roomCreatedAt == nil {
            let ready = environment.target(record) != nil && environment.hasSession()
            present(record, reason: ready ? .ageUnknown : .setupRequired)
            return false
        }
        switch TelemostRenewalPolicy.decide(input(for: record, now: environment.now())) {
        case .doNothing, .waitForIdle:
            return false
        case .ageUnknown:
            present(record, reason: .ageUnknown)
            return false
        case .warnExpiringSoon(let minutes):
            present(record, reason: .expiring, minutes: minutes)
            return false
        // #480 was: connect to the first saved sibling, destroying the live
        // session without evidence the sibling works. No automatic switch.
        case .switchThenRenew:
            return false
        case .renewNow, .renewExpired:
            return await renew(record)
        }
        // eoc #480
    }

    // boc #480
    private func present(_ record: ConnectionRecord, reason: Warning.Reason, minutes: Int = 0) {
        let key = NoticeKey(revision: RoomRevision(record), reason: reason)
        guard dismissed[record.id] != key, warning == nil else { return }
        let notice = Warning(id: record.id, minutesLeft: minutes, recordName: record.name,
            reason: reason, candidateRoomID: pendingRenewals[record.id]?.candidateRoomID)
        warning = notice
        presented = key
        LogStore.shared.log(.provisioning, "Telemost renewal needs attention for \(record.name): \(reason)")
    }

    private func clearStaleWarning() {
        guard let notice = warning else { return }
        guard let record = environment.records().first(where: { $0.id == notice.id }),
              RoomRevision(record) == presented?.revision else {
            warning = nil
            presented = nil
            return
        }
    }
    // eoc #480

    // boc #480: claim the host for the entire create/apply transaction. Persist
    // only a confirmed application; a lost SSH reply proves neither success nor
    // failure of the remote mutation. Revalidate after every suspension.
    // #480 was: save the room/stamp BEFORE SSH; catch every error as an expected
    // mid-restart drop, report success, and reconnect a connect-time snapshot.
    private func renew(_ record: ConnectionRecord, userInitiated: Bool = false) async -> Bool {
        guard case .olcrtc(let params) = record.details,
              params.carrier == "telemost" else { return false }
        guard let target = environment.target(record) else {
            present(record, reason: .setupRequired)
            return false
        }
        guard !environment.foreignVPN() else {
            present(record, reason: .foreignVPN)
            return false
        }
        guard !Task.isCancelled, environment.claimHost(target.host.id) else {
            LogStore.shared.log(.provisioning,
                "Telemost renewal deferred — cancelled or another operation owns the server")
            return false
        }
        defer { environment.releaseHost(target.host.id) }

        let room: TelemostRoom
        let createdAt: Date
        do {
            // Stamp the start of creation, not the end of a potentially slow SSH
            // command; conservatively never overstate the new room's lifetime.
            createdAt = environment.now()
            room = try await environment.createRoom()
            try Task.checkCancellation()
        } catch {
            if !Task.isCancelled { present(record, reason: .creationFailed) }
            return false
        }

        guard let current = environment.records().first(where: { $0.id == record.id }),
              current.details == record.details, environment.target(current) == target else { return false }
        guard !environment.foreignVPN() else {
            present(current, reason: .foreignVPN)
            return false
        }
        // The user may have started a dial or begun using the room while Yandex
        // was responding. Automatic work must re-earn permission to restart.
        if !userInitiated {
            let decision = TelemostRenewalPolicy.decide(input(for: current, now: environment.now()))
            guard decision == .renewNow || decision == .renewExpired else { return false }
        }

        pendingRenewals[record.id] = PendingRenewal(previousRoomID: params.roomID,
            previousCreatedAt: params.roomCreatedAt, candidateRoomID: room.id,
            candidateCreatedAt: createdAt, hostID: target.host.id, container: target.container)
        environment.savePending(pendingRenewals)
        do {
            let uri = try await environment.applyRoom(target,
                InstallOptions(carrier:   params.carrier,
                                        transport: params.transport,
                                        roomID:    room.id))
            // The URI is emitted AFTER restart. Nil/malformed/mismatching
            // output cannot confirm this operation, even if SSH returned.
            guard Self.confirms(uri: uri, roomID: room.id, params: params) else {
                throw ConfirmationError.unconfirmed
            }
        } catch {
            present(record, reason: .applyUnconfirmed)
            return false
        }

        // Do not resurrect a deleted record or overwrite edits made during SSH.
        guard var updated = environment.records().first(where: { $0.id == record.id }),
              updated.details == record.details, environment.target(updated) == target else {
            present(record, reason: .applyUnconfirmed)
            return false
        }
        var moved = params
        moved.roomID = room.id
        moved.roomCreatedAt = createdAt
        updated.details = .olcrtc(moved)
        environment.update(updated)
        pendingRenewals[record.id] = nil
        environment.savePending(pendingRenewals)
        dismissed[record.id] = nil
        if warning?.id == record.id { warning = nil; presented = nil }
        LogStore.shared.log(.provisioning, "Telemost renewal confirmed by the server")

        // Only replace the tunnel if it STILL belongs to this record. Never
        // undo a user's disconnect or switch during the awaited operation.
        if environment.engagedRecord()?.id == record.id {
            // A foreign VPN appearing mid-command permits saving the confirmed
            // room, but not tearing down a session we cannot safely replace.
            if environment.foreignVPN() {
                present(updated, reason: .foreignVPN)
            } else {
                environment.disconnect()
                if !Task.isCancelled { environment.connect(updated) }
                else { present(updated, reason: .reconnectRequired) }
            }
        }
        return true
    }

    private enum ConfirmationError: Error { case unconfirmed }

    static func confirms(uri: String?, roomID: String, params: OlcrtcConnection) -> Bool {
        guard let uri, let parsed = try? OlcrtcURI.parse(uri) else { return false }
        return parsed.roomID == roomID && parsed.carrier == params.carrier
            && parsed.transport == params.transport
            // #485: a concurrently rotated server key requires recovery too;
            // moving only the room would knowingly retain unusable credentials.
            && parsed.key.lowercased() == params.key.lowercased()
    }
    // eoc #480

    /// The container this record's protocol runs in. The primary keeps the name
    /// the install gave it; a sibling carrier is `<base>-<carrier>` (#452).
    // #480 was: an instance helper; now shared by the production target resolver.
    private static func containerName(for record: ConnectionRecord, host: ServerHost) -> String? {
        guard let base = host.lastContainerName else { return nil }
        guard host.lastConnectionID == record.id else {
            guard case .olcrtc(let p) = record.details else { return nil }
            return SSHRunner.siblingContainerName(base: base, carrier: p.carrier)
        }
        return base
    }
}
