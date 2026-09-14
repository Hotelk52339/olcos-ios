import Foundation

// #465: WHEN to replace a Telemost room, and at what cost to the user.
//
// A Telemost link stops working 24 h after it is created — a clock, not an
// idle timer, so a server sitting in the room does not extend it. When the room
// dies the tunnel dies with it, and the tunnel is the ONLY road left to the VPS
// during a whitelist window: SSH rides inside it (App/Core/SSHTransport.swift),
// so losing the room means losing administrative access with no way back in.
// Renewing the room by hand requires noticing in time, which is exactly what
// nobody does.
//
// So the app renews on its own. The cost is that applying a new room restarts
// the container, which drops the connection for a few seconds — the whole point
// of this file is to spend that cost where the user cannot feel it:
//
//   * riding a DIFFERENT protocol → free, renew immediately;
//   * another protocol available  → move there first, then renew;
//   * riding this one, but idle   → a drop nobody is using costs nothing;
//   * riding this one, in use     → wait, and warn only once time runs short.
//
// The last rule is self-consistent: "in use" means the user is at the phone
// right now, which is exactly when a warning gets seen. An idle tunnel means
// nobody is watching — and nobody notices the blip either.
//
// Pure and synchronous on purpose: every branch here is a unit test
// (Tests/TelemostRenewalPolicyTests.swift). The side-effecting half lives in
// TelemostRenewalCoordinator.
enum TelemostRenewalPolicy {

    // MARK: - Constants

    /// Yandex: «ссылка на созвон работает 24 часа».
    static let roomLifetime: TimeInterval = 24 * 3600

    /// Start looking for a moment to renew once this little is left. Five hours
    /// is deliberately generous: it has to contain a whole night of the phone
    /// being asleep in a pocket, because iOS gives no promise that the app runs
    /// at any particular minute.
    static let renewalLead: TimeInterval = 5 * 3600

    /// Below this, stop waiting for a polite moment and tell the user.
    static let criticalLead: TimeInterval = 1 * 3600

    /// No tunnel traffic for this long counts as "nobody is using it".
    /// `SOCKSSession.noteTunnelActivity()` is what moves that marker.
    static let idleGrace: TimeInterval = 120

    // MARK: - Input

    /// Everything the decision depends on, snapshotted on MainActor by the
    /// caller. Nothing in here is read from a store — that is what makes the
    /// decision reproducible in a test.
    struct Input: Equatable {
        var now: Date
        /// nil when the app has never set this room itself.
        var roomCreatedAt: Date?
        /// True when the live tunnel is running through THIS room, i.e. renewing
        /// it cuts the connection carrying the command.
        var isRidingThisRoom: Bool
        // #480 was: nil when never — nil is no evidence, not evidence of idleness.
        /// Last observed traffic; nil when no activity measurement exists.
        var lastTunnelActivity: Date?
        // #480 was: any saved sibling was treated as an available route.
        /// A separately verified, compatible alternative on the SAME host.
        /// The coordinator passes nil: saved records alone cannot prove safety.
        var alternativeRecordID: UUID?
        /// Creating a room needs a linked Yandex account; without one the app
        /// can do nothing but say so.
        var hasYandexSession: Bool
        // boc #480: a VPN's user traffic is in the extension, not this process.
        // Connecting/recovering tunnels also cannot supply an idle interval.
        var activityIsObservable: Bool = true
        // eoc #480
    }

    // MARK: - Decision

    enum Decision: Equatable {
        /// Plenty of time left, or nothing this policy can do.
        case doNothing
        /// Renew right now — the drop is free or nobody would feel it.
        case renewNow
        /// Move the tunnel to this record first, then renew.
        case switchThenRenew(recordID: UUID)
        /// Riding this room and it is carrying traffic; try again later.
        case waitForIdle
        /// Time is nearly up and no free moment appeared — ask the user.
        case warnExpiringSoon(minutesLeft: Int)
        /// The room's age is unknown, so its expiry cannot be predicted. Renewing
        /// once through the app starts the clock.
        case ageUnknown
        /// Expired already: the tunnel is probably gone, but creating the room
        /// costs nothing and the push may still land through another protocol.
        case renewExpired
    }

    /// Seconds until the room stops working, negative once it has.
    static func timeLeft(created: Date, now: Date) -> TimeInterval {
        roomLifetime - now.timeIntervalSince(created)
    }

    static func decide(_ i: Input) -> Decision {
        // Without an account there is no room to create; the row's own sheet
        // already explains how to link one, so this stays silent rather than
        // nagging from a second place.
        guard i.hasYandexSession else { return .doNothing }

        guard let created = i.roomCreatedAt else {
            // Only worth raising for a room that is actually in play. An age we
            // never recorded could be one minute or one day old; guessing either
            // way would be the app inventing a fact, which is the habit this
            // whole feature exists to break.
            return .ageUnknown
        }

        let left = timeLeft(created: created, now: i.now)
        guard left <= renewalLead else { return .doNothing }
        // boc #480: never silently interrupt a dial/recovery or a system VPN,
        // including when the recorded expiry has passed. Ask for consent.
        if i.isRidingThisRoom && !i.activityIsObservable {
            return left <= criticalLead
                ? .warnExpiringSoon(minutesLeft: max(0, Int(left / 60)))
                : .waitForIdle
        }
        // eoc #480
        if left <= 0 { return .renewExpired }

        // Not riding it: the restart costs this user nothing at all.
        if !i.isRidingThisRoom { return .renewNow }

        // Riding it, but somewhere else to stand — the case a multi-protocol
        // host exists for. A jitsi room never expires, which is what makes it a
        // safe place to wait out the restart.
        if let alt = i.alternativeRecordID { return .switchThenRenew(recordID: alt) }

        // Riding it, nowhere else to go. An untouched tunnel can be dropped
        // without anyone noticing.
        if isIdle(i) { return .renewNow }

        // In use. Wait for a gap — unless the room is about to die, in which
        // case the user is at the phone and can decide.
        return left <= criticalLead
            ? .warnExpiringSoon(minutesLeft: max(0, Int(left / 60)))
            : .waitForIdle
    }

    // boc #480
    // #480 was: nil activity counted as idle even without traffic visibility.
    /// No observed traffic for `idleGrace`, only when observation is possible.
    static func isIdle(_ i: Input) -> Bool {
        guard i.activityIsObservable, let last = i.lastTunnelActivity else { return false }
        return i.now.timeIntervalSince(last) >= idleGrace
    }
    // eoc #480
}
