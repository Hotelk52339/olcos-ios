import SwiftUI

// MARK: - ConnectHero — Signal (#486)
//
// boc #486
// #486 was: a left-aligned, all-in-one OlcCard with a verified aurora border.
// Signal separates the state and dated evidence, central voice-like lines,
// selected connection plate, and one labelled action with its permanent scope.
// There is deliberately no centre icon, microphone input, or traffic meter.
//
// Retained #457/#459/#461/#470/#471 contracts:
// • State is the largest Dynamic Type text, never shrunk to one line.
// • Service/transport/host identity is shown once; the switcher excludes it.
// • The selected record retains its full shared overflow action builder.
// • Health evidence is dated, with no invented packet/audio measurements.
// • Scope qualifies the action; live VPN must never inherit proxy verification.
// • Reasons and blocked actions remain readable and actionable.
// The waveform expresses connected state only, not a health verdict.
// eoc #486

struct ConnectHero: View {

    // #486: Signal replaces the dense, left-aligned verdict card. The title
    // and evidence float above full-width linework; the actual connection and
    // its overflow menu sit in a separate plate above the one labelled action.
    // The old aurora ring is not part of Signal. Motion never means verified.

    // MARK: Inputs (value-only — the hero renders, it does not decide)

    let state: ConnectionState
    /// The connection the state applies to: the LIVE node while a session is up,
    /// else the last-used one. Never `store.primary` read directly — a row tap
    /// moves the selection without reconnecting.
    let subject: ConnectionRecord?
    /// The honesty layer's verdict for `subject`, already dated.
    let health: HealthDisplay
    /// #459: the tunnel exit's flag glyph (`CountryFlag.emoji(iso2:)`), nil when
    /// the lookup gave no usable country. Computed by `ConnectionsView`, which
    /// already owns the `IPChecker.refreshExitGeo` call.
    let exitFlag: String?
    /// #459: the tunnel exit as "Amsterdam, NL"; nil when the lookup returned
    /// nothing, in which case the evidence line falls back to the verdict.
    let exitPlace: String?
    // #486: measurement provenance comes from IPChecker, never view appearance.
    let exitMeasuredAt: Date?
    /// Which backend a session runs (or would run) through — the scope line.
    let mode: TunnelMode
    /// The port the live session bound, else the configured one.
    let socksPort: Int
    /// `ConnectionStore.secretsLocked` — the Keychain could not be read yet.
    let secretsLocked: Bool
    // #486: a presented sheet obscures this scene even while the tab is mounted.
    let isPresented: Bool
    let modeFallbackReason: String?
    /// #459: the subject's action set — the SAME builder the rows use, because
    /// the subject has no row of its own any more. Empty ⇒ no menu is drawn.
    let menuItems: [OlcMenuItem]
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    /// #457: when the current `.connecting` began, so the evidence line can age
    /// it ("starting… 6 s") instead of printing a bare, undatable "Connecting…".
    @State private var connectingSince: Date?

    // boc #486
    // #486 was: OlcCard { leading headline/identity/evidence/divider/action }
    // with an aurora border and an unconditional state spring. Signal gives
    // the lines their own central space; state changes have no implicit motion.
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

            SignalWaveform(isConnected: state.isConnected, isFailed: isFailed,
                           isPresented: isPresented)
                .padding(.vertical, Theme.Metrics.s2)

            subjectPlate
            primaryControl
                .padding(.top, Theme.Metrics.s5)
            VStack(spacing: Theme.Metrics.s2) {
                scopeLine
                if let modeFallbackReason {
                    // #486: keep the main scope concise without hiding the
                    // capability explanation. This reveals information only;
                    // backend preferences still belong in Settings.
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
    // eoc #486

    // MARK: 1. The answer

    // boc #486
    // #486 was: headlineRow put the overflow beside the state. It acts on the
    // connection, not the state, so it now lives with the connection identity.
    private var subjectPlate: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s2) {
            identityBlock
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

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
    // eoc #486

    /// #459: drawn only when there is a subject to act on — an empty menu is a
    /// control that does nothing.
    @ViewBuilder
    private var heroMenu: some View {
        if subject != nil, !menuItems.isEmpty {
            OlcOverflowMenu(items: menuItems)
        }
    }

    private var stateWord: some View {
        Text(stateTitle)
            .font(Theme.Typography.answer)
            .foregroundStyle(Theme.Palette.textPrimary)
            // #459 (audit) was: .lineLimit(1) + .minimumScaleFactor(0.55). The
            // answer is the one line here that may never be shrunk or clipped,
            // and both happened: "Waiting for network…" is 20 characters at the
            // largeTitle step with the overflow menu beside it, so it already
            // rendered smaller than `Typography.answer` on a phone, and past the
            // 0.55 floor (reached a couple of Dynamic Type steps up) it clipped.
            // #486: it wraps in the centred Signal header without competing with a menu.
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

    // MARK: 2. The subject

    // boc #461
    // #461: THE IDENTITY INVERSION — the owner's complaint 1, verbatim: "why
    // the hell should I look at the fact that ZAZA is connected? Let it say
    // Yandex Telemost, and under it which protocol it goes through."
    //
    // #461 was: `subjectLine` — an `HStack` printing `subject.displayName`,
    // i.e. "zaza · Telemost", the label they typed for their VPS with the
    // carrier suffix `ServersView.recordName` appends. One VPS here runs
    // SEVERAL protocol containers, so the machine is the same on every
    // connection and the SERVICE is what differs. Mullvad renders
    // "Netherlands, Amsterdam" over "nl-ams-wg-001" in exactly this shape —
    // `.title3` semibold identity over `.body` machine detail, `spacing: 2`.
    //
    // Two lines (#471 was: three), in descending order of what the user came for:
    //   1. THE SERVICE — "Yandex Telemost".
    //   2. HOW · WHOSE — "VP8 · zaza". One `Text` built by CONCATENATION, not
    //      interpolation, so the two halves carry different weights and tones
    //      without a second view (and so the pair truncates as one line).
    //
    // #471 was: a "LAST USED" eyebrow above the service, drawn whenever the state
    // was not connected. The hero STATES, it does not narrate: the state word
    // directly above already says the session is not live, and the card's
    // position says which connection it is about. One label per fact.
    @ViewBuilder
    private var identityBlock: some View {
        if let subject = subject {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {   // #471 was: 2
                Text(ConnectionNaming.service(subject.details))
                    .font(Theme.Typography.answerSupport)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    // #461 (audit) was: `.lineLimit(1)`. This is the string the
                    // owner asked to see, at the title3 step; «Яндекс Телемост»
                    // clears the card width at the default text size and stops
                    // clearing it a couple of Dynamic Type steps up, where a
                    // one-line clamp would ellipsise the service name itself.
                    // Two lines, breaking on the space between the two words —
                    // the same rule `ProtocolRowView.labels` adopted for the
                    // same string.
                    // #486 was: .lineLimit(2). The named connection must remain
                    // readable even with the largest accessibility text size.
                    .fixedSize(horizontal: false, vertical: true)
                carriedByLine(subject)
            }
        } else {
            Text(L10n.heroSubjectNone.localized())
                .font(Theme.Typography.answerSupport)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// #461: "VP8 · zaza" — the transport carries the weight, the host label is
    /// the quiet half, exactly as Windscribe's `LocationNameView` gives city and
    /// datacenter nickname the same size and lets weight do the ranking.
    /// The three pieces are bound to locals so this stays three trivial
    /// expressions rather than one nine-term concatenation — the SwiftUI
    /// type-checker has failed this repo's CI three times on exactly that shape.
    private func carriedByLine(_ subject: ConnectionRecord) -> some View {
        let transport = Text(ConnectionNaming.transport(subject.details))
            .font(Theme.Typography.bodyStrong)
            .foregroundStyle(Theme.Palette.textSecondary)
        let separator = Text(verbatim: " · ")
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textTertiary)
        let host = Text(ConnectionNaming.host(subject))
            .font(Theme.Typography.body)
            // #486 was: tertiary; server identity is useful, not placeholder text.
            .foregroundStyle(Theme.Palette.textSecondary)
        // #486 was: .lineLimit(1) — preserve the selected host at Dynamic Type.
        return (transport + separator + host).fixedSize(horizontal: false, vertical: true)
    }
    // eoc #461

    // MARK: 3. One line of dated evidence

    @ViewBuilder
    private var evidenceLine: some View {
        switch state {
        case .connecting:
            ConnectHeroElapsed(since: connectingSince ?? Date(), isPresented: isPresented) // #486
        case .connected:
            connectedEvidence
        case .waitingForNetwork:
            evidenceText(L10n.heroEvidenceNoNetwork.localized(), tone: Theme.Palette.textSecondary)
        case .failed(let raw):
            // #457: with a mapped reason the sentence is the WHY; without one the
            // raw message is all we have, so it stands alone and stays red.
            // #471 was: an explicit `mono: false` — the default now.
            evidenceText(failureReason?.message ?? raw,
                         tone: failureReason == nil ? Theme.Palette.red
                                                    : Theme.Palette.textSecondary)
        case .disconnected:
            evidenceText(subject == nil ? " " : health.subtitle, tone: Theme.Palette.textSecondary)
        }
    }

    /// #459: while a session is up, the WHERE outranks the verdict sentence.
    /// Green still needs `.verified`: the place is where traffic came out, not
    /// proof that it did.
    ///
    /// #461 (audit) was: "…the one connected-state fact the numbers in
    /// Diagnostics cannot state, and printing it here means no figure appears on
    /// this screen twice." Both halves are false — `DiagnosticsFacts.exitRow`
    /// prints the SAME flag + "Moscow, RU" (with the IP and an age beside it),
    /// so the place is on this screen twice. It is below the fold since #461, which is
    /// why it is tolerable, not why it is fine.
    ///
    /// #457 (audit fix) was, and still is, the fallback: anything that is not
    /// `.verified` used to print "no data checked through it yet" — which called
    /// a REAL measurement taken four minutes ago "never measured". `.fading` and
    /// `.stale` say what they actually know (in the past tense, which their own
    /// subtitle already does); only the two states that genuinely have no
    /// end-to-end reading fall back to that line.
    ///
    /// boc #461
    /// #461 was: a `VStack` holding the place line AND `heroExitSourceNote` —
    /// two caption lines of #460 provenance ("where your traffic comes out —
    /// from a location lookup of the exit IP, made through the tunnel") on the
    /// app's most valuable card. `diagExitNote` states the same fact one card
    /// down, attached to the exit value it describes. ONE FACT, ONE PLACE: the
    /// note stays where the value is, and the hero gets ~34 pt of its first
    /// screenful back for the identity block above.
    /// eoc #461
    @ViewBuilder
    private var connectedEvidence: some View {
        // boc #486
        // #486 was: exitSince = Date() on appearance/place changes. That made a
        // cached lookup fresh again and did not date a repeat lookup of the same
        // place. Only IPChecker's actual measurement timestamp is evidence.
        if let place = exitPlace, let measuredAt = exitMeasuredAt {
            ConnectHeroExitLine(text: exitFlag.map { "\($0) \(place)" } ?? place,
                                since: measuredAt,
                                tone: sessionVerified ? Theme.Palette.green
                                                      : Theme.Palette.textSecondary,
                                isPresented: isPresented)
        // eoc #486
        } else {
            evidenceText(heroEvidenceHasReading ? health.subtitle
                                                : L10n.heroEvidenceUnverified.localized(),
                         tone: sessionVerified ? Theme.Palette.green   // #470 was: health.isVerified
                                               : Theme.Palette.textSecondary)
        }
    }

    /// #470: green evidence needs proof about THIS session; #486 removed the ring. Nothing
    /// verifies a system-VPN session — `verifyTunnel`, keep-alive and the
    /// Diagnostics latency loop are all proxy-only — so in VPN mode a `.verified`
    /// verdict can only be a probe or proxy-era reading ≤ 5 min old, which then
    /// faded mid-session. A live VPN session reads connected, never verified.
    private var sessionVerified: Bool {
        state.isConnected && health.isVerified && mode == .proxy
    }

    /// #457 (audit fix): does this verdict carry an actual end-to-end reading to
    /// report? `.never` never measured anything; `.handshakeOnly` reached the room
    /// but no data passed. Everything else — verified, ageing, stale, broken,
    /// couldn't-check — has something true to say and says it in its own subtitle.
    private var heroEvidenceHasReading: Bool {
        switch health {
        case .never, .handshakeOnly: return false
        default:                     return true
        }
    }

    /// `mono` is for ADDRESSES AND PORTS, never sentences.
    ///
    /// #471 was: `mono: Bool = true`, so every caller that did not opt out — the
    /// verdict subtitle, the no-network line, the unverified line — rendered a
    /// SENTENCE in the monospaced face. `.monospacedDigit()` keeps the figures
    /// inside those sentences from jittering as an age ticks, which is the only
    /// thing mono was buying here.
    private func evidenceText(_ text: String, tone: Color, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? Theme.Typography.mono
                       : Theme.Typography.caption.monospacedDigit())
            .foregroundStyle(tone)
            // #457: a reason is never truncated (HIG Typography) — it wraps.
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 18, alignment: .leading)
    }

    /// #457: the failure's HUMAN headline, from the honesty layer's mapper —
    /// never the raw core line, which the evidence line above already carries in
    /// its engineering voice.
    @ViewBuilder
    private var reasonLine: some View {
        if case .failed = state, let reason = failureReason {
            Text(reason.headline)
                // #471: the same step, through the token. #471 was: a local
                // `.system(.subheadline, design: .rounded).weight(.semibold)` —
                // exactly `Typography.label`, re-declared here, which is the
                // drift the TYPE NOTE at the top of this file warns about.
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var failureReason: HealthReason? {
        // #469: in `.failed(raw)` the sentence must explain THIS failure. It used
        // to read only `health` — the subject's stored verdict from an earlier
        // probe — so a port-busy failure five minutes after a key-mismatch probe
        // was headlined "Key no longer matches" with the real reason discarded.
        // Classify the raw message first; fall back to the stored verdict only
        // when it carries nothing the mapper recognises.
        if case .failed(let raw) = state {
            let now = HealthFailureMapper.reason(forRaw: raw)
            if now != .unknown { return now }
        }
        switch health {
        case .broken(let r, _), .inconclusive(let r, _): return r
        default: return nil
        }
    }

    // MARK: 4. The scope — a footnote to the action (#471 was: "always on screen")

    /// #471: the scope stays PERMANENTLY VISIBLE (the truth rule: `tunnelMode`
    /// changes what the word "Connected" MEANS), but it is a footnote to the
    /// button, not a readout above it — so it moved below `primaryControl` and
    /// lost the loopback address that made it a sentence.
    ///
    /// #471 was: `.system(.caption2, design: .monospaced)` on "Proxy · apps
    /// pointed at 127.0.0.1:8808" — a whole prose line in the face reserved for
    /// measured data, at the seventh size step the type scale abolished. The copy
    /// is now "Proxy · port 8808" / "VPN · whole device"; the port keeps its
    /// digits aligned without dragging the words into mono.
    private var scopeLine: some View {
        Text(mode == .vpn
             ? L10n.heroScopeVPN.localized()
             : L10n.heroScopeProxy_fmt.formatted(String(socksPort)))
            .font(Theme.Typography.caption.monospacedDigit())
            .foregroundStyle(Theme.Palette.textSecondary) // #486: scope must remain legible.
            // #459 (audit) was: .lineLimit(1) + .minimumScaleFactor(0.8). The
            // line that says what "Connected" MEANS may not be cut, so it wraps.
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 5. The one action

    @ViewBuilder
    private var primaryControl: some View {
        switch state {
        case .connecting:
            // Never lock the control mid-connect: a dead carrier combo must not
            // cost the whole start timeout with no way out (#269).
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
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {   // #471 was: 6
            OlcButton(connectTitle, systemImage: "power",
                      role: .primary, fillWidth: true, action: onConnect)
                .disabled(!canConnect)
            if let blocked = blockedReason {
                Text(blocked)
                    .font(Theme.Typography.caption)   // #471 was: .caption
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

    /// #457: the fix for a failure whose action lives on another screen. Naming
    /// the screen is honest; drawing a button that cannot run here is not.
    @ViewBuilder
    private var elsewhereNote: some View {
        if case .failed = state, let action = failureReason?.action,
           let note = ConnectActionSite.elsewhereNote(for: action) {
            Text(note)
                .font(Theme.Typography.caption)   // #471 was: .caption
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // #486 was: auroraVerdictRing, a gradient card border for verified sessions.
    // Dated evidence still carries the verdict; Signal's lines carry no proof.
}

// MARK: - ConnectHeroElapsed (#457)
//
// #457: `.connecting` is the one state with no step count the core can report,
// so the honest signal is elapsed time — a number that visibly moves, not a
// bare word. One ticking view, isolated so the hero's own body never re-runs
// the whole card's type-check for it.

private struct ConnectHeroElapsed: View {
    let since: Date
    // boc #486: text ages are not waveform motion; still stop their clocks when
    // the screen cannot be seen. Returning resumes from the real start date.
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
    // eoc #486
}

// MARK: - ConnectHeroExitLine (#470)
//
// #470: the connected evidence line WITH its age — "🇳🇱 Amsterdam, NL · 2 h ago",
// re-rendered once a minute like `ConnectHeroElapsed`, so the exit place is dated
// evidence rather than a present-tense claim from a lookup made at connect time.

private struct ConnectHeroExitLine: View {
    let text: String
    let since: Date
    let tone: Color
    // boc #486
    let isPresented: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        // #486 was: an always-mounted periodic clock, including in background.
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
    // eoc #486
}

// MARK: - ConnectActionSite (#457)
//
// #457: `HealthDisplay.suggestedAction` names an offer; this decides WHERE that
// offer can actually be honoured. Only re-checking runs on the Connect screen —
// recovering a key, changing a room and starting a container all need SSH, and
// the port lives in Settings. Rather than draw a dead button (or, worse, hide
// the fix in an overflow menu), the row and the hero name the screen.

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
    static func elsewhereNote(for action: HealthAction) -> String? {
        switch site(for: action) {
        case .here:     return nil
        case .servers:  return L10n.healthActionOnServersTab_fmt.formatted(action.title)
        case .settings: return L10n.healthActionInSettings_fmt.formatted(action.title)
        }
    }
}
