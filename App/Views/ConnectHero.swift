import SwiftUI

// MARK: - ConnectHero — Signal
//
// The main screen's answer, top to bottom:
//   1. the state word with one line of dated evidence;
//   2. the firewall picture — a beam meets a stone masonry wall; it breaks through
//      green when connected, is rejected red on error, and its traffic
//      particles flow with measured tunnel throughput (no printed figures:
//      the measured ↓/↑ rate is spoken to VoiceOver only);
//   3. the one labelled action;
//   4. the active connection summary — service, transport · host, and the
//      mode line that says what "Connected" means (VPN / SOCKS5 · port).
// The connection list below the hero is the switcher; it excludes this subject.
//
// Contracts kept from earlier passes:
// • State is the largest Dynamic Type text, never shrunk to one line.
// • Service/transport/host identity is shown once on the screen.
// • Health evidence is dated; the spoken readout carries only measured counters.
// • A live VPN session reads connected, never verified (proxy-only probes).
// • Explicit VPN never silently becomes SOCKS5: the fallback disclosure stays.

struct ConnectHero: View {

    // MARK: Inputs (value-only — the hero renders, it does not decide)

    let state: ConnectionState

    /// The connected record, or the last used one when idle.
    let subject: ConnectionRecord?

    let health: HealthDisplay

    /// Exit place from the last through-tunnel IP lookup (flag emoji + "City, CC").
    let exitFlag: String?
    let exitPlace: String?
    /// IPChecker's actual measurement timestamp; the only honest age source.
    let exitMeasuredAt: Date?

    /// The backend the session runs (or will run) on, and its SOCKS5 port.
    let mode: TunnelMode
    let socksPort: Int

    let secretsLocked: Bool

    /// False while a sheet covers the screen: clocks and motion pause.
    let isPresented: Bool
    /// Why an automatic VPN preference fell back to SOCKS5, when it did.
    let modeFallbackReason: String?

    /// False when no saved server links `subject` — it was imported from
    /// another device, so "fix it on the Servers tab" would point at nothing.
    var isManagedHere: Bool = true

    /// Smoothed tunnel throughput; nil = no measurement (nothing is spoken).
    /// Never printed: it only feeds the VoiceOver description of the picture.
    let throughput: ThroughputReading?
    /// 0…1 particle-flow intensity derived from `throughput`.
    let waveIntensity: Double

    let menuItems: [OlcMenuItem]
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    /// When the current `.connecting` began, so the evidence line can age it.
    @State private var connectingSince: Date?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Theme.Metrics.s2) {
                stateWord
                reasonLine
                evidenceLine
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Metrics.s2)
            .padding(.top, Theme.Metrics.s4)

            // The picture is one accessibility element whose label is the
            // measured throughput (or nothing while there is no reading).
            SignalWaveform(state: beamState, isPresented: isPresented, intensity: waveIntensity,
                           inboundShare: throughput?.inboundShare ?? 0.5)
                .padding(.vertical, Theme.Metrics.s2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(throughputReadout ?? "")
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityHidden(throughputReadout == nil)

            primaryControl
                .padding(.top, Theme.Metrics.s3)

            subjectPlate
                .padding(.top, Theme.Metrics.s4)

            VStack(spacing: Theme.Metrics.s2) {
                if let modeFallbackReason {
                    // Reveals information only; backend preference lives in Settings.
                    DisclosureGroup {
                        evidenceText(modeFallbackReason, tone: Theme.Palette.textSecondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Theme.Metrics.s2)
                    } label: {
                        Text(L10n.vpnAutomaticFallbackSummary.localized())
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .tint(Theme.Palette.textSecondary)
                }
                elsewhereNote
            }
            .multilineTextAlignment(.center)
            .padding(.top, Theme.Metrics.s3)
        }
        .padding(.bottom, Theme.Metrics.s2)
        .transaction { $0.animation = nil }
        .onChange(of: state, initial: true) { _, new in
            connectingSince = new.isConnecting ? (connectingSince ?? Date()) : nil
        }
    }

    // MARK: 1. The answer

    private var stateWord: some View {
        Text(stateTitle)
            .font(Theme.Typography.answer)
            .foregroundStyle(Theme.Palette.textPrimary)
            // The one line here that may never be shrunk or clipped: it wraps.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var stateTitle: String {
        switch state {
        case .connected:         return L10n.stateConnected.localized()
        case .connecting:        return L10n.stateConnecting.localized()
        case .waitingForNetwork: return L10n.stateWaitingForNetwork.localized()
        case .failed:            return L10n.stateConnectFailed.localized()
        case .disconnected:      return L10n.stateDisconnected.localized()
        }
    }

    /// What the firewall picture shows for this state. Waiting for the network
    /// reads as connecting: the session is down, so the wall closes and the
    /// beam pushes at it again until the route returns.
    private var beamState: FirewallBeamState {
        switch state {
        case .connected:                    return .connected
        case .connecting, .waitingForNetwork: return .connecting
        case .failed:                       return .error
        case .disconnected:                 return .idle
        }
    }

    // MARK: 2. Dated evidence

    @ViewBuilder
    private var evidenceLine: some View {
        switch state {
        case .connecting:
            ConnectHeroElapsed(since: connectingSince ?? Date(), isPresented: isPresented)
        case .connected:
            connectedEvidence
        case .waitingForNetwork:
            evidenceText(L10n.heroEvidenceNoNetwork.localized(), tone: Theme.Palette.textSecondary)
        case .failed(let raw):
            // With a mapped reason the sentence is the WHY; without one the raw
            // message is all we have, so it stands alone and stays red.
            evidenceText(failureReason?.message ?? raw,
                         tone: failureReason == nil ? Theme.Palette.red
                                                    : Theme.Palette.textSecondary)
        case .disconnected:
            evidenceText(subject == nil ? " " : health.subtitle, tone: Theme.Palette.textSecondary)
        }
    }

    /// While a session is up, WHERE traffic exits outranks the verdict sentence.
    /// Green still needs `.verified`: the place is where traffic came out, not
    /// proof that it did. Only IPChecker's measurement timestamp dates it.
    @ViewBuilder
    private var connectedEvidence: some View {
        if let place = exitPlace, let measuredAt = exitMeasuredAt {
            ConnectHeroExitLine(text: exitFlag.map { "\($0) \(place)" } ?? place,
                                since: measuredAt,
                                tone: sessionVerified ? Theme.Palette.green
                                                      : Theme.Palette.textSecondary,
                                isPresented: isPresented)
        } else {
            evidenceText(heroEvidenceHasReading ? health.subtitle
                                                : L10n.heroEvidenceUnverified.localized(),
                         tone: sessionVerified ? Theme.Palette.green
                                               : Theme.Palette.textSecondary)
        }
    }

    /// Nothing verifies a system-VPN session — `verifyTunnel`, keep-alive and
    /// the Diagnostics latency loop are proxy-only — so a live VPN session
    /// reads connected, never verified.
    private var sessionVerified: Bool {
        state.isConnected && health.isVerified && mode == .proxy
    }

    /// Does this verdict carry an actual end-to-end reading? `.never` never
    /// measured anything; `.handshakeOnly` reached the room but no data passed.
    private var heroEvidenceHasReading: Bool {
        switch health {
        case .never, .handshakeOnly: return false
        default:                     return true
        }
    }

    /// `mono` is for ADDRESSES AND PORTS, never sentences.
    private func evidenceText(_ text: String, tone: Color, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? Theme.Typography.mono
                       : Theme.Typography.caption.monospacedDigit())
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 18, alignment: .leading)
    }

    /// The failure's HUMAN headline from the honesty layer's mapper.
    @ViewBuilder
    private var reasonLine: some View {
        if case .failed = state, let reason = failureReason {
            Text(reason.headline)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var failureReason: HealthReason? {
        // In `.failed(raw)` the sentence must explain THIS failure: classify the
        // raw message first, fall back to the stored verdict only when the
        // mapper recognises nothing in it.
        if case .failed(let raw) = state {
            let now = HealthFailureMapper.reason(forRaw: raw)
            if now != .unknown { return now }
        }
        switch health {
        case .broken(let r, _), .inconclusive(let r, _): return r
        default: return nil
        }
    }

    // MARK: 3. Spoken throughput

    /// The picture's VoiceOver label — nothing is printed on screen. Only
    /// while connected and only from a real sample: VPN mode speaks ↓ and ↑
    /// from the packet path; SOCKS5 in-app mode speaks one "about" figure from
    /// loopback deltas (see TunnelThroughput.swift). Nil hides the element.
    private var throughputReadout: String? {
        guard state.isConnected, let throughput else { return nil }
        switch throughput {
        case .exact(let down, let up):
            return L10n.throughputA11y_fmt.formatted(ThroughputFormat.rate(down),
                                                     ThroughputFormat.rate(up))
        case .estimate(let total):
            return L10n.throughputEstimateA11y_fmt.formatted(ThroughputFormat.rate(total))
        }
    }

    // MARK: 4. The one action

    @ViewBuilder
    private var primaryControl: some View {
        switch state {
        case .connecting:
            // Never lock the control mid-connect: a dead carrier combo must not
            // cost the whole start timeout with no way out.
            OlcButton(L10n.cancel.localized(), systemImage: "xmark",
                      role: .secondary, fillWidth: true, action: onDisconnect)
        case .connected, .waitingForNetwork:
            OlcButton(L10n.actionDisconnect.localized(), systemImage: "power",
                      role: .secondary, fillWidth: true, action: onDisconnect)
        case .disconnected, .failed:
            connectControl
        }
    }

    @ViewBuilder
    private var connectControl: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            OlcButton(connectTitle, systemImage: "power",
                      role: .primary, fillWidth: true, action: onConnect)
                .disabled(!canConnect)
            if let blocked = blockedReason {
                Text(blocked)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectTitle: String {
        if case .failed = state { return L10n.actionRetry.localized() }
        return L10n.actionConnect.localized()
    }

    private var canConnect: Bool { subject != nil && !secretsLocked }

    private var blockedReason: String? {
        if secretsLocked { return L10n.errorSecretsLocked.localized() }
        if subject == nil { return L10n.heroPickAConnection.localized() }
        return nil
    }

    /// The fix for a failure whose action lives on another screen: naming the
    /// screen is honest; drawing a button that cannot run here is not.
    @ViewBuilder
    private var elsewhereNote: some View {
        if case .failed = state, let action = failureReason?.action,
           let note = ConnectActionSite.elsewhereNote(for: action, managedHere: isManagedHere) {
            Text(note)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 5. The active connection summary

    /// Service · transport · host · mode, with the record's overflow menu.
    /// The mode line is permanent: the backend changes what "Connected" MEANS.
    private var subjectPlate: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s2) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                identityBlock
                scopeLine
            }
            Spacer(minLength: Theme.Metrics.s2)
            heroMenu
        }
        .padding(Theme.Metrics.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.card,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.Palette.cardBorder, lineWidth: Theme.Metrics.cardBorderWidth)
        }
    }

    /// Drawn only when there is a subject to act on — an empty menu is a
    /// control that does nothing.
    @ViewBuilder
    private var heroMenu: some View {
        if subject != nil, !menuItems.isEmpty {
            OlcOverflowMenu(items: menuItems)
        }
    }

    /// The SERVICE first ("Yandex Telemost"), then how and where it goes
    /// ("VP8 · ams-1"). Neither line is clamped: they stay readable at the
    /// largest accessibility text size.
    @ViewBuilder
    private var identityBlock: some View {
        if let subject = subject {
            Text(ConnectionNaming.service(subject.details))
                .font(Theme.Typography.answerSupport)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            carriedByLine(subject)
        } else {
            Text(L10n.heroSubjectNone.localized())
                .font(Theme.Typography.answerSupport)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// "VP8 · ams-1" — transport carries the weight, the host is the quiet half.
    /// Bound to locals so the concatenation stays trivial for the type-checker.
    private func carriedByLine(_ subject: ConnectionRecord) -> some View {
        let transport = Text(ConnectionNaming.transport(subject.details))
            .font(Theme.Typography.bodyStrong)
            .foregroundStyle(Theme.Palette.textSecondary)
        let separator = Text(verbatim: " · ")
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textTertiary)
        let host = Text(ConnectionNaming.host(subject))
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
        return (transport + separator + host).fixedSize(horizontal: false, vertical: true)
    }

    /// "VPN · whole device" / "SOCKS5 · port 8808". Digits stay aligned
    /// without dragging the words into mono; the line wraps, never clips.
    private var scopeLine: some View {
        Text(mode == .vpn
             ? L10n.heroScopeVPN.localized()
             : L10n.heroScopeProxy_fmt.formatted(String(socksPort)))
            .font(Theme.Typography.caption.monospacedDigit())
            .foregroundStyle(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.Metrics.s1)
    }
}

// MARK: - ConnectHeroElapsed
//
// `.connecting` is the one state with no step count the core can report, so
// the honest signal is elapsed time. One ticking view, isolated so the hero's
// body never re-runs for it; the clock stops while the screen cannot be seen.

private struct ConnectHeroElapsed: View {
    let since: Date
    let isPresented: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible && isPresented && scenePhase == .active {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    label(at: context.date)
                }
            } else {
                label(at: Date())
            }
        }
        .font(Theme.Typography.caption.monospacedDigit())
        .foregroundStyle(Theme.Palette.textSecondary)
        .frame(minHeight: 18)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .transaction { $0.animation = nil }
    }

    private func label(at date: Date) -> some View {
        Text(L10n.heroEvidenceStarting_fmt.formatted(Int(max(0, date.timeIntervalSince(since)))))
    }
}

// MARK: - ConnectHeroExitLine
//
// The connected evidence line WITH its age — "🇳🇱 Amsterdam, NL · 2 h ago",
// re-rendered once a minute, so the exit place is dated evidence rather than a
// present-tense claim from a lookup made at connect time.

private struct ConnectHeroExitLine: View {
    let text: String
    let since: Date
    let tone: Color
    let isPresented: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible && isPresented && scenePhase == .active {
                TimelineView(.periodic(from: since, by: 60)) { context in
                    label(at: context.date)
                }
            } else {
                label(at: Date())
            }
        }
        .font(Theme.Typography.caption.monospacedDigit())
        .foregroundStyle(tone)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 18)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .transaction { $0.animation = nil }
    }

    private func label(at date: Date) -> some View {
        Text("\(text) · \(HealthAge.phrase(max(0, date.timeIntervalSince(since))))")
    }
}

// MARK: - ConnectActionSite
//
// `HealthDisplay.suggestedAction` names an offer; this decides WHERE that
// offer can actually be honoured. Only re-checking runs on the Connect screen —
// recovering a key, changing a room and starting a container all need SSH, and
// the port lives in Settings. Rather than draw a dead button, name the screen.

enum ConnectActionSite {
    case here, servers, settings

    static func site(for action: HealthAction) -> ConnectActionSite {
        switch action {
        case .verify, .retry:                                    return .here
        case .recoverConnection, .checkRoom, .startContainer:    return .servers
        case .openPortSettings:                                  return .settings
        }
    }

    /// The sentence to print when the fix is not on this screen; nil when it is.
    /// A Servers-tab fix on a record no saved server links to (imported from
    /// another device) is replaced by the only honest advice: ask the owner.
    static func elsewhereNote(for action: HealthAction, managedHere: Bool = true) -> String? {
        switch site(for: action) {
        case .here:     return nil
        case .servers:
            return managedHere
                ? L10n.healthActionOnServersTab_fmt.formatted(action.title)
                : L10n.healthActionSharedRecordNote.localized()
        case .settings: return L10n.healthActionInSettings_fmt.formatted(action.title)
        }
    }
}
