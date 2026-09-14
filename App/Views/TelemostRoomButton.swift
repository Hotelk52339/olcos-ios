import SwiftUI

// MARK: - TelemostRoomButton / TelemostRoomSheet (#463)
//
// #463: the one button the owner asked for. A Yandex Telemost link stops
// working 24 hours after it is created — «ссылка на созвон работает 24 часа» —
// and a server sitting in the room does not extend it. Until now renewing meant
// opening telemost.yandex.ru by hand, creating a conference, copying the id and
// delivering it to the VPS over SSH — which is exactly the channel a whitelist
// window blocks. This is that whole errand, as one press.
//
// Everything here is a plain value or a closure: ServersView owns the state
// machine (it owns the SSH lane, the stores and the tunnel), and this file only
// renders it. That split is not stylistic — ServersView has blown the Swift
// type-checker's expression budget three times, so new UI lands in files like
// this one where every input is explicitly typed and costs nothing to resolve.

/// #463: what the renewal is doing right now. `working` carries its own
/// localized note because the operation has two distinct halves the user should
/// be able to tell apart (create the room; push it to the server), and
/// `failed` carries the human reason rather than a code.
enum TelemostRoomPhase: Equatable {
    case idle
    case working(String)
    /// The new room id.
    case done(String)
    /// A sentence the user can act on.
    case failed(String)
}

/// #463: THE hazard of this feature. Replacing the room restarts the server-side
/// process, and SSH now rides the tunnel (`App/Core/SSHTransport.swift`) — so
/// renewing the very protocol you are connected THROUGH cuts the command's own
/// transport out from under it mid-flight. A multi-protocol host has somewhere
/// safer to stand (jitsi rooms never expire, which is why that pairing exists);
/// a single-protocol host does not, and then the only honest thing to do is say
/// so before the user commits.
enum TelemostRenewHazard: Equatable {
    /// The tunnel is not running through the protocol being renewed.
    case none
    /// It is — but this host runs another protocol we can move to first.
    /// Payload: that protocol's display name.
    case liveSwitchable(String)
    /// It is, and there is nowhere else on this host to stand.
    case liveOnly
}

// MARK: - The control

/// #463: not a bare `Button` on a card — the card IS the control. It states
/// where it stands (an `OlcStatusPill`, the same status vocabulary every other
/// surface in the app uses), what that means, what it will cost, and only then
/// offers the press. Each state offers exactly one obvious next step, plus the
/// safer alternative above it when one exists.
struct TelemostRoomButton: View {
    /// A Yandex `Session_id` is stored for this device.
    let hasAccount: Bool
    let phase: TelemostRoomPhase
    let hazard: TelemostRenewHazard
    /// Another SSH operation holds the lane — the press would be a no-op.
    let busy: Bool
    let onSignIn: () -> Void
    let onCreate: () -> Void
    let onSwitchCarrier: () -> Void

    // boc #490
    // #490 was: another OlcCard nested inside the renewal scroller. The native
    // Form owns the surface now, with no idle pulse or decorative animation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            if phase != .idle {
                ServerSignalStatus(tone: tone, title: title, subtitle: subtitle,
                                   isBusy: tone == .progress)
            }
            roomLine
            hazardNote
            actions
        }
        .padding(.vertical, Theme.Metrics.s2)
        .animation(reduceMotion ? nil : .easeOut(duration:
            ServerPresentationPolicy.transitionDuration(reduceMotion: reduceMotion)), value: phase)
    }
    // eoc #490

    // MARK: State → words
    //
    // `phase` is read BEFORE `hasAccount` everywhere below: an outcome the user
    // just produced must never be swallowed by the account state, and a 401
    // ("Не авторизован") is precisely the failure that leaves the two disagreeing.
    // #463 (audit) was: "the failure that also clears the account" — nothing
    // clears it. A rejected session STAYS in the Keychain (deleting a user's
    // credential on one server answer is not this code's call), so after a 401
    // `hasAccount` is still true, Retry stays live, and the failure text plus
    // "Use another account" are what actually move the user forward.

    private var tone: OlcStatusTone {
        switch phase {
        case .failed:  return .error
        case .working: return .progress
        case .done:    return .ok
        case .idle:    return .unknown
        }
    }

    private var title: String {
        switch phase {
        case .failed:  return L10n.telemostRoomFailedTitle.localized()
        case .working: return L10n.telemostRoomWorkingTitle.localized()
        case .done:    return L10n.telemostRoomDoneTitle.localized()
        // #473: unreachable in the view (the pill is hidden at rest); kept so the
        // switch stays exhaustive and the type keeps describing every phase.
        case .idle:
            return hasAccount ? L10n.telemostRoomIdleTitle.localized()
                              : L10n.telemostRoomNoAccountTitle.localized()
        }
    }

    private var subtitle: String {
        switch phase {
        case .failed(let reason): return reason
        case .working(let note):  return note
        case .done:               return L10n.telemostRoomDoneBody.localized()
        case .idle:
            return hasAccount ? L10n.telemostRoomIdleBody.localized()
                              : L10n.telemostRoomNoAccountBody.localized()
        }
    }

    /// The new room id, monospaced and selectable — the fallback path if
    /// anything downstream went wrong is the owner pasting it somewhere by hand,
    /// so it must be readable and copyable, not buried in a sentence.
    @ViewBuilder
    private var roomLine: some View {
        if case .done(let room) = phase {
            Text(room)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    // MARK: The hazard

    /// Shown only where it can still change a decision — before the press and
    /// after a failure, never over a result.
    private var showsHazard: Bool {
        switch phase {
        case .idle, .failed:  return hazard != .none
        case .working, .done: return false
        }
    }

    /// Resolved as a String first and rendered second — a `switch` nested in an
    /// `if` inside a `@ViewBuilder` is exactly the shape that has cost this
    /// screen compile time before.
    private var hazardText: String? {
        guard showsHazard else { return nil }
        switch hazard {
        case .none:                     return nil
        case .liveSwitchable(let name): return L10n.telemostRenewLiveSwitchable_fmt.formatted(name)
        case .liveOnly:                 return L10n.telemostRenewLiveOnly.localized()
        }
    }

    @ViewBuilder
    private var hazardNote: some View {
        if let text = hazardText {
            warningBlock(text)
        }
    }

    private func warningBlock(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.orange)
            Text(text)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.caption)
        .padding(Theme.Metrics.s3)
        .background(Theme.Palette.orange.opacity(0.12), in: warningShape)
    }

    private var warningShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .idle:    idleActions
        case .working: workingAction
        case .done:    EmptyView()
        case .failed:  failedActions
        }
    }

    private var idleActions: some View {
        VStack(spacing: Theme.Metrics.s2) {
            // The safe route sits ABOVE the risky one, so the reading order and
            // the recommendation agree.
            switchAction
            if hasAccount {
                OlcButton(L10n.telemostRoomCreateAction.localized(), systemImage: "sparkles",
                          role: .primary, fillWidth: true, action: onCreate)
                    .disabled(busy)
            } else {
                OlcButton(L10n.telemostRoomSignInAction.localized(), systemImage: "person.badge.key",
                          role: .primary, fillWidth: true, action: onSignIn)
            }
        }
    }

    @ViewBuilder
    private var switchAction: some View {
        if case .liveSwitchable(let name) = hazard {
            OlcButton(L10n.telemostRenewSwitchAction_fmt.formatted(name),
                      systemImage: "arrow.left.arrow.right", role: .secondary,
                      fillWidth: true, action: onSwitchCarrier)
                .disabled(busy)
        }
    }

    /// The same button, spinning — the control never changes shape mid-operation.
    private var workingAction: some View {
        OlcButton(L10n.telemostRoomCreateAction.localized(), systemImage: "sparkles",
                  role: .primary, isBusy: true, fillWidth: true) { }
    }

    /// The likeliest failure by far is a `Session_id` that has finally expired
    /// (the API answers 401 «Не авторизован»), so signing in again is offered
    /// beside Retry rather than hidden behind a trip to Settings.
    private var failedActions: some View {
        VStack(spacing: Theme.Metrics.s2) {
            OlcButton(L10n.telemostRoomRetryAction.localized(), systemImage: "arrow.clockwise",
                      role: .primary, fillWidth: true, action: onCreate)
                .disabled(busy || !hasAccount)
            OlcButton(L10n.telemostRoomOtherAccountAction.localized(),
                      systemImage: "person.crop.circle.badge.plus",
                      role: .ghost, fillWidth: true, action: onSignIn)
        }
    }
}

// MARK: - The sheet around it

/// #463: what ServersView presents. It names the server, says why the button
/// exists at all (24 hours), holds the control, and owns the ONE thing the
/// control cannot: presenting the Yandex sign-in web view. The credential's exit
/// door lives here too — a bearer token the user cannot delete is not a feature.
struct TelemostRoomSheet: View {
    let serverLabel: String
    let hasAccount: Bool
    let phase: TelemostRoomPhase
    let hazard: TelemostRenewHazard
    let busy: Bool
    /// The raw `Session_id` from the web view; the caller stores it.
    let onSignedIn: (String) -> Void
    let onForgetAccount: () -> Void
    let onCreate: () -> Void
    let onSwitchCarrier: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false

    var body: some View {
        NavigationStack {
            scroller
                .navigationTitle(L10n.telemostNewRoomAction.localized())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.done.localized()) { dismiss() }
                    }
                }
                .sheet(isPresented: $showLogin) { login }
        }
    }

    // boc #490
    // #490 was: four ungrouped ScrollView blocks. Native form sections separate
    // the server context, account evidence and the consequential room action.
    private var scroller: some View {
        Form {
            Section { header }.signalFormRows()
            Section {
                accountStatus
                accountFooter
            }
            .signalFormRows()
            Section { control }.signalFormRows()
        }
        .signalFormChrome()
    }
    // eoc #490

    // boc #473: whether an account is linked was only ever stated by the CONTROL's
    // title — and that title belongs to `phase`, so the moment a room started
    // being created (or failed) the fact disappeared. It is the one thing this
    // sheet exists to set up, so it gets its own line that does not move: linked
    // or not, always, above the button that depends on it.
    private var accountStatus: some View {
        // boc #480
        // #480 was: a stored token produced .ok / "Yandex account linked", even
        // after rejection. Storage is not a validity check; say only what we know.
        // #490 was: OlcStatusPill; account storage remains neutral, never verified.
        ServerSignalStatus(
            tone:     Self.accountTone(hasAccount: hasAccount),
            title:    Self.accountTitle(hasAccount: hasAccount),
            subtitle: hasAccount ? L10n.telemostRoomKeychainNote.localized()
                                 : L10n.telemostRoomNoAccountBody.localized())
        // eoc #480
    }
    // eoc #473

    // boc #480: expose the exact presentation mapping for network-free tests.
    static func accountTone(hasAccount: Bool) -> OlcStatusTone { .unknown }

    static func accountTitle(hasAccount: Bool) -> String {
        hasAccount ? L10n.telemostSignInSaved.localized() : L10n.telemostRoomNoAccountTitle.localized()
    }
    // eoc #480

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            // #490 was: label-sized server context, lost among four equal blocks.
            SignalSectionHeader(L10n.telemostRoomServerLine_fmt.formatted(serverLabel),
                                systemImage: "server.rack")
            Text(L10n.telemostRoomExplainer.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var control: some View {
        TelemostRoomButton(hasAccount: hasAccount,
                           phase: phase,
                           hazard: hazard,
                           busy: busy,
                           onSignIn: { showLogin = true },
                           onCreate: onCreate,
                           onSwitchCarrier: onSwitchCarrier)
    }

    @ViewBuilder
    private var accountFooter: some View {
        if hasAccount {
            // #473 was: this also printed `telemostRoomKeychainNote`, which the
            // account row above now states — the same sentence twice on one
            // short sheet. The exit door is what belongs down here.
            OlcButton(L10n.telemostRoomForgetAccountAction.localized(),
                      systemImage: "trash", role: .ghost, action: onForgetAccount)
        }
    }

    private var login: some View {
        YandexLoginView { session in
            showLogin = false
            onSignedIn(session)
        }
    }
}

// #340: both appearance variants.
#if DEBUG
#Preview("Telemost room — states") {
    ScrollView {
        VStack(spacing: 16) {
            TelemostRoomButton(hasAccount: false, phase: .idle, hazard: .none, busy: false,
                               onSignIn: {}, onCreate: {}, onSwitchCarrier: {})
            TelemostRoomButton(hasAccount: true, phase: .idle,
                               hazard: .liveSwitchable("Jitsi"), busy: false,
                               onSignIn: {}, onCreate: {}, onSwitchCarrier: {})
            TelemostRoomButton(hasAccount: true, phase: .idle, hazard: .liveOnly, busy: false,
                               onSignIn: {}, onCreate: {}, onSwitchCarrier: {})
            TelemostRoomButton(hasAccount: true, phase: .working("Creating the room…"),
                               hazard: .none, busy: true,
                               onSignIn: {}, onCreate: {}, onSwitchCarrier: {})
            TelemostRoomButton(hasAccount: true, phase: .done("abc123def456"),
                               hazard: .none, busy: false,
                               onSignIn: {}, onCreate: {}, onSwitchCarrier: {})
            TelemostRoomButton(hasAccount: true, phase: .failed("Yandex rejected the stored sign-in."),
                               hazard: .none, busy: false,
                               onSignIn: {}, onCreate: {}, onSwitchCarrier: {})
        }
        .padding()
    }
    .background(Theme.Palette.bg)
    .preferredColorScheme(.dark)
}

#Preview("Telemost room — sheet") {
    TelemostRoomSheet(serverLabel: "MyVPS", hasAccount: true, phase: .idle,
                      hazard: .liveSwitchable("Jitsi"), busy: false,
                      onSignedIn: { _ in }, onForgetAccount: {},
                      onCreate: {}, onSwitchCarrier: {})
        .preferredColorScheme(.light)
}
#endif
