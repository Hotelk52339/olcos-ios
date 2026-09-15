import SwiftUI

// MARK: - DiagnosticsCard
//
// FILE NOTE: this file is still called HealthCard.swift because renaming it
// needs an `xcodegen generate` pass. Its contents are the Diagnostics card;
// rename the file on the next regeneration.
//
// ONE card, two blocks, last on the main screen:
//   A. "This session" — what is true about the tunnel that is up RIGHT NOW.
//      Mounted only while connected: exit IP and live latency. The hero above
//      already names the service, transport, host and mode, so none of that is
//      repeated here.
//   B. "Checks" — the two things the user can RUN: IP check and speed test.
//      Always present, because they are the only entry points to
//      `IPChecker.checkAll` and `SpeedTest.run`.
//
// NOTHING IS DRAWN THAT CANNOT BE DATED. Every value carries the age of the
// measurement behind it, in the same `HealthAge` vocabulary the row verdicts
// use, and says where it comes from, so a number from four minutes ago can
// never read as "now". `SpeedTest.quickPing` returns nil on ANY error, so the
// state machine is explicit — `probing` (a measurement is in flight now) vs
// `latencyAt` (when one last completed); "Checking…" is reachable only while
// `probing` is true AND nothing has completed yet.
//
// Throughput stays deliberately hard to claim: `SpeedResult` carries no
// timestamp, so a `lastResult` inherited from an earlier session — or from a
// DIRECT-mode test — is not evidence about the tunnel that is up now. The speed
// row dates only a run this view watched finish. (The hero's live throughput
// readout is a different thing: measured bytes/s, see `TunnelThroughputMonitor`.)
//
// Separate view structs (not inlined into ConnectionsView.body) so that file's
// body stays under the SwiftUI type-checker budget.

struct DiagnosticsCard: View {
    /// The live record (`TunnelManager.connectedRecord`) — the subject of block A.
    let record: ConnectionRecord?
    @ObservedObject var ipCheck: IPChecker
    @ObservedObject var speed: SpeedTest
    /// Route for the live probes — `.tunnel` while connected in proxy mode.
    let mode: RouteMode
    /// Screenshot-safe IP masking (mirrors the IP-check rows).
    let maskIPs: Bool
    /// Block A exists only while a session is up; block B always does.
    let isConnected: Bool
    // The carrier-endpoints tool is an action on a CONNECTION and lives in the
    // connected record's overflow menu (`ConnectionsView`).
    let onSpeedTest: () -> Void

    var body: some View {
        OlcCard(padding: 0) {
            VStack(spacing: 0) {
                sessionBlock
                DiagnosticsTools(ipCheck: ipCheck, speed: speed, mode: mode,
                                 maskIPs: maskIPs, onSpeedTest: onSpeedTest)
            }
            .padding(.horizontal, Theme.Metrics.cardPadding)
        }
    }

    /// #459: absent — not empty, not greyed — when nothing is connected. There is
    /// no session to describe, so the card is just the tools and ~140 pt shorter.
    @ViewBuilder
    private var sessionBlock: some View {
        if isConnected {
            DiagnosticsFacts(record: record, ipCheck: ipCheck, speed: speed,
                             mode: mode, maskIPs: maskIPs)
            Divider().overlay(Theme.Palette.separator)
        }
    }
}

// MARK: - DiagnosticsFacts — block A, "This session" (#454, moved here #459)
//
// The former HealthCard, minus its own title and its refresh glyph. Its dating
// machinery moves verbatim: the 8 s probe loop (#461: its reading IS the app's
// one latency again — see `responseRow`), `latencyAt` / `probing`, and
// `exitAt` (tracked here because `ExitGeo` carries no timestamp and the refresh
// is also fired from ConnectionsView on the connect transition).

private struct DiagnosticsFacts: View {
    let record: ConnectionRecord?
    @ObservedObject var ipCheck: IPChecker
    @ObservedObject var speed: SpeedTest
    let mode: RouteMode
    let maskIPs: Bool

    /// The live latency, refreshed by the loop below. nil = no measurement.
    /// #461 was documented here as "NOT a latency — one whole request including
    /// connection setup". It excludes connection setup now (`LatencyProbe`), so
    /// it is the same quantity the node chips carry; see `responseRow`.
    @State private var latencyMs: Double?
    /// #457: when the last latency measurement COMPLETED (success or failure).
    /// nil ⇒ none has completed for this record yet.
    @State private var latencyAt: Date?
    /// #457: a measurement is in flight right now. The ONLY thing that licenses
    /// the word "Checking…".
    @State private var probing = false
    /// #457: when `ipCheck.exitGeo` last changed — the exit line's age.
    @State private var exitAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // #471 was: DiagnosticsSubheader(title:) — a local uppercase label,
            // one of five hand-rolled recipes on two screens.
            OlcSectionHeader(L10n.diagSessionHeader.localized())
                .padding(.top, Theme.Metrics.s3)
            exitRow
            responseRow
        }
        // Live response time: measure now, then every ~8 s. Keyed on the live record so
        // a failover (record swap, #453) restarts the loop against the new
        // protocol; the conditional mount cancels it on disconnect. The 8 s tick
        // is also what re-renders every age in this block.
        .task(id: "\(record?.id.uuidString ?? ""):\(mode.rawValue)") { await runLatencyLoop() }
        // pull gesture and ConnectionsView's connect-transition fetch. Deliberately
        // NOT `initial: true`: a value already in the store was measured at some
        // unknown earlier moment, and stamping it on mount would date it "now".
        // refresh that returned the same geo never fired it, so a fresh reading
        // kept its old age. The checker dates each measurement (`exitGeoAt`).
        .onChange(of: ipCheck.exitGeoAt) { _, new in
            exitAt = new
        }
    }

    // MARK: The latency loop

    private func runLatencyLoop() async {
        // AND its stamp, so the previous node's number is never shown as this
        // one's after a #453 failover swap.
        latencyMs = nil
        latencyAt = nil
        // swap restarts the loop and this can never publish under the wrong node.
        let liveID = record?.id
        while !Task.isCancelled {
            // boc #461
            // .run` reserves 180 s of keep-alive suppression up front precisely
            // because extra connections mid-test add congestion; this loop was
            // the one prober that ignored that. Probing a saturated tunnel
            // measures the transfer, not the route — and now that this figure
            // and the per-node chips are the same measurement, that bad sample
            // would be published as the node's health. The previous reading
            // keeps its stamp and `DiagnosticsAge` goes on ageing it, so the
            // pause is visible and honest rather than silent.
            // `MainActor.run` rather than a bare `await speed.isTesting`: this
            // closure's isolation is whatever `.task` gives it, and an explicit
            // hop reads the same either way. `SpeedTest` is `@MainActor`, hence
            // implicitly Sendable, so nothing is captured unsafely.
            if await MainActor.run(body: { speed.isTesting }) {
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            // eoc #461
            probing = true
            // boc #470: fail-closed, the way `verifyTunnel` is (#445). URLSession
            // silently BYPASSES a loopback proxy that REFUSES the connection and
            // completes the HEAD direct, so a sample taken after the Go listener
            // died still succeeded — and was published below as `.working`
            // (green "Verified just now · N ms") while `LatencyProbe` refreshed
            // the keep-alive activity marker on what was direct traffic. The raw
            // SOCKS greeting cannot be bypassed: no answer is a failed sample,
            // never a direct one. `.direct` mode has no listener to ask.
            var listens = true
            if mode.usesSOCKS {
                listens = await TunnelManager.socksListenerAnswers(port: TunnelManager.activeSocksPort)
            }
            let ms: Double?
            if listens { ms = await speed.quickPing(via: mode) } else { ms = nil }
            // eoc #470
            if Task.isCancelled { return }
            latencyMs = ms
            latencyAt = Date()
            probing = false
            await publishLiveLatency(ms, for: liveID)
            try? await Task.sleep(for: .seconds(8))
        }
    }

    // boc #461
    /// #461: THE LIVE NODE'S CHIP PRINTS THIS CARD'S OWN SAMPLE — the half of
    /// the owner's complaint 2 that an explanation could never fix.
    ///
    /// `HealthCoordinator.noteLiveVerified` is called from two places in
    /// `TunnelManager` (the verify-tunnel success and every keep-alive tick)
    /// with `rttMs: nil`, so the live node's chip carried an rtt from some
    /// EARLIER probe — a different tunnel, a different moment — or none at all.
    /// Publishing this loop's reading means the Diagnostics row and every
    /// `OlcHealthChip` for the connected node render THE SAME INTEGER, taken by
    /// THE SAME sample, at most 8 s apart in age. Side benefit: `.verified`
    /// stops expiring mid-session, so the hero's aurora verdict ring no longer
    /// goes out while the tunnel is plainly working.
    ///
    /// `.tunnel` ONLY. #484: VPN's provenance is now `.systemVPN` (was `.direct`),
    /// and the reading is not attributable to this node's own SOCKS
    /// listener — `HealthCoordinator` refuses to probe under a live system VPN
    /// for the same reason. A failed sample publishes nothing: one missed HEAD
    /// is not evidence that a node is broken, and the keep-alive / wedge
    /// machinery owns that judgement.
    ///
    /// DESIGN NOTE: the spec asked for a non-persisting sibling
    /// (`HealthCoordinator.noteLiveLatency`) so an 8 s cadence would not write
    /// UserDefaults ~450x an hour. App/Services/HealthCoordinator.swift is
    /// outside this change's partition, so this calls the existing writer, whose
    /// stored shape (`.working`, `source: "live"`) is identical. The cost is
    /// bounded in practice — the loop only runs while a session is UP and this
    /// card is ON SCREEN — but swap the call the moment that sibling exists.
    private func publishLiveLatency(_ ms: Double?, for recordID: UUID?) async {
        guard let ms, let recordID, mode == .tunnel else { return }
        let rtt = Int(ms.rounded())
        await MainActor.run {
            HealthCoordinator.shared.noteLiveVerified(recordID: recordID, rttMs: rtt)
        }
    }
    // eoc #461

    // MARK: Rows

    // boc #471
    // DataChannel" about the same connection `ConnectHero.identityBlock` names
    // at the top of the same screen. The #461 audit comment that stood here said
    // it in as many words: "Deleting the row is the fix; it is left standing here
    // because that is a structural change." This is that change. The carrier and
    // the transport are the hero's, once.
    // eoc #471

    // boc #471
    /// #471: the row is the value and its dated source, nothing else.
    ///
    /// #471 was: a `note:` argument carrying `diagExitNote` — a permanently
    /// mounted two-line paragraph ("Your exit IP address, looked up with
    /// ipinfo.io through the tunnel — the city and country come from that same
    /// answer."). Provenance is one clause, not a paragraph: it now rides the
    /// age line below the value (`DiagnosticsAge(viaIPInfo:)`), which is where
    /// the reader already looks to ask "is this still true?".
    ///
    /// #460 was: the same sentence, only in the narrow trailing column.
    @ViewBuilder
    private var exitRow: some View {
        DiagnosticsRow(label: L10n.healthExitLabel.localized()) {
            VStack(alignment: .trailing, spacing: Theme.Metrics.s1) {
                exitValue
                // about now made from evidence about then.
                DiagnosticsAge(at: exitAt, viaIPInfo: true)
            }
        }
    }

    /// #471: THE IP, AND ONLY THE IP. #471 was: a flag + "Moscow, RU" line with
    /// the IP demoted to a caption under it — the same flag and the same place
    /// `ConnectHero.connectedEvidence` prints one card up, which the hero's own
    /// source comment already called out as "the place is on this screen twice".
    /// The hero owns the PLACE; this row owns the one exit fact that will not fit
    /// up there. `placeString` went with it.
    @ViewBuilder
    private var exitValue: some View {
        if let ip = ipCheck.exitGeo?.ip, !ip.isEmpty {
            Text(IPMask.display(ip, masked: maskIPs))
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
        } else {
            Text(L10n.healthLatencyNotMeasured.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
    // eoc #471

    // boc #461
    /// #461: THE TWO CONTRADICTORY LATENCIES, closed at the source.
    ///
    /// #460 was: on one screen, at one moment, this row read `LATENCY 1109 ms`
    /// in RED while a connection row for the same server read `133 ms`. Both
    /// were labelled "latency" and neither was wrong — they were different
    /// measurements. #460's answer was to rename this one "Response time", drop
    /// the threshold tint, and add `diagResponseNote`: a ~250-character
    /// paragraph reconciling the two numbers. The owner's answer to that: "the
    /// diagnostics ping is 947 ms again, while somewhere else it is different."
    /// An explanation is not a fix, and a paragraph explaining why two numbers
    /// disagree is the app admitting it prints two numbers.
    ///
    /// #461 makes them ONE. `SpeedTest.quickPing` now delegates to
    /// `LatencyProbe.measure(via:)`, which reproduces the Go core's own method
    /// — a warm-up request that pays the SOCKS connect and the TLS handshake,
    /// then samples over the SAME kept-alive session, best returned — so this
    /// figure and the chips' figure are comparable BY CONSTRUCTION. For the
    /// live node they are not merely comparable: `publishLiveLatency` above
    /// makes them the same integer.
    ///
    /// So the row is called what it measures again ("Latency"), and the
    /// paragraph is gone: there is nothing left to reconcile.
    ///
    /// NO THRESHOLD TINT, still. The honesty layer's chip beside this number
    /// already carries the verdict colour, and two colour systems on one number
    /// is exactly how #460 went wrong. Two tones — measured = `textPrimary`,
    /// unmeasured = `textTertiary` — and never red.
    ///
    /// `latencyMs` / `latencyAt` / `probing` keep their names: they were always
    /// accurate, and #460 renamed the LABEL away from them. This puts it back.
    @ViewBuilder
    private var responseRow: some View {
        DiagnosticsRow(label: L10n.diagResponseLabel.localized()) {
            VStack(alignment: .trailing, spacing: Theme.Metrics.s1) {
                Text(responseValue)
                    .font(Theme.Typography.metricValue)
                    .foregroundStyle(responseTone)
                    .lineLimit(1)
                DiagnosticsAge(at: latencyAt)
            }
        }
    }
    // eoc #461

    // MARK: Values

    /// #457 was: nil ⇒ "measuring…" (forever, over a dead data path) and later
    /// nil ⇒ "not measured" with no date. The word for work-in-progress is now
    /// licensed by `probing` alone, and the verdict carries its stamp below.
    private var responseValue: String {
        if let ms = latencyMs { return L10n.healthLatencyMs_fmt.formatted(Int(ms.rounded())) }
        if probing && latencyAt == nil { return L10n.healthChecking.localized() }
        // absence of measurement — "not measured · checked just now" hid a wedged
        // tunnel (in=0 out=0) under a no-measurement word while the hero above
        // still read Connected. `latencyAt` is stamped on failure too.
        if latencyAt != nil { return L10n.healthLatencyNoResponse.localized() }
        return L10n.healthLatencyNotMeasured.localized()
    }

    /// #460/#461: two tones, and neither is an alarm — see `responseRow`. A measured
    /// figure reads as data; the absence of one reads as tertiary, which is what
    /// "we have no value here" looks like everywhere else in this card.
    /// #460 was: `latencyTone` — green under 150 ms, orange under 400, red above.
    private var responseTone: Color {
        latencyMs == nil ? Theme.Palette.textTertiary : Theme.Palette.textPrimary
    }
    // place is the hero's, and this row prints the IP; nothing here needs it.
}

// MARK: - DiagnosticsTools — block B, "Checks" (#258, moved here #459)
//
// The manual probes — two of them since #461 moved the carrier-endpoints tool
// into the connected record's overflow menu. #459 was: they lived in `ConnectDiagnosticsCard`
// inside ConnectionsView.swift, under a card of their own, with a `PING ms`
// metric that measured the same thing block A measures — less often, and with no
// timestamp at all (`SpeedResult` carries none). The ping metric is deleted; DL
// and UL stay, and now say when they were taken.

private struct DiagnosticsTools: View {
    @ObservedObject var ipCheck: IPChecker
    @ObservedObject var speed: SpeedTest
    let mode: RouteMode
    let maskIPs: Bool
    let onSpeedTest: () -> Void

    // #484 was: view-local stamps on completion/spinner events, which survived
    // route changes and could date a cancelled old run as the current answer.
    private var ipCheckTime: Date? { ipCheck.resultsAt }
    private var throughputAt: Date? { speed.resultAt }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OlcSectionHeader(L10n.diagToolsHeader.localized())
                .padding(.top, Theme.Metrics.s3)
            ipRow
            Divider().overlay(Theme.Palette.separator)
            speedRow
        }
        // edge of `isTesting` is the moment a run we can attribute completed.
    }

    private var ipRow: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s3) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(L10n.ipCheckTitle.localized())
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                // two-line paragraph under a button whose label already says what
                // it does. How many services answer is a Settings fact; the
                // sentence survives where it costs no pixels, as the Run button's
                // accessibility hint (below).
                ConnectIPStatus(ipCheck: ipCheck, maskIPs: maskIPs, mode: mode)
                if let t = ipCheckTime, !ipCheck.isChecking {
                    Label(t.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Spacer(minLength: Theme.Metrics.s2)
            runIPCheckButton
        }
        .padding(.vertical, Theme.Metrics.s3)
    }

    /// #471: the IP check's one control, carrying the provenance sentence the row
    /// used to print permanently.
    private var runIPCheckButton: some View {
        OlcButton(L10n.ipCheckRun.localized(), role: .secondary, isBusy: ipCheck.isChecking) {
            Task { await ipCheck.checkAll(via: mode) }
        }
        .accessibilityHint(L10n.diagIPSourceHint_fmt.formatted(Self.ipSourceCount))
    }

    // boc #459
    // .pingMs`. Block A measures the same route every 8 s and stamps the result;
    // this one was taken once per speed test and could not be dated at all.
    private var speedRow: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s3) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                HStack(alignment: .top, spacing: Theme.Metrics.s4) {
                    // #470 was: speed.lastResult?.downloadMbps / uploadMbps (any route)
                    OlcMetric(label: L10n.speedLabelDL.localized(),
                              value: value(routeResult?.downloadMbps, L10n.speedRateValue_fmt.localized()),
                              unit: L10n.speedUnitMbps.localized(), unitInLabel: true)
                    OlcMetric(label: L10n.speedLabelUL.localized(),
                              value: value(routeResult?.uploadMbps, L10n.speedRateValue_fmt.localized()),
                              unit: L10n.speedUnitMbps.localized(), unitInLabel: true)
                }
                // run this view watched finish, on this route, or no stamp.
                if throughputAt != nil, routeResult != nil {
                    DiagnosticsAge(at: throughputAt)
                }
            }
            Spacer(minLength: Theme.Metrics.s2)
            OlcButton(L10n.speedTestRun.localized(), role: .secondary,
                      isBusy: speed.isTesting, action: onSpeedTest)
        }
        .padding(.vertical, Theme.Metrics.s3)
    }
    // eoc #459

    // boc #461
    // two-line audience-selecting hint (`carrierEndpointsRowHint` /
    // `carrierEndpointsRowConnectHint`) and a "Show" button, ~90 pt, mounted
    // permanently on the app's main screen and disabled whenever nothing was
    // connected. Every one of the four clients read for this change pushes its
    // technical tools below the fold or behind a disclosure; this one goes one
    // better and becomes an item in the connected record's overflow menu, which
    // is on screen at all times (`ConnectionsView.carrierEndpointsItem`).
    // `carrierEndpointsRowTitle` survives as that item's title; the two hints
    // and `carrierEndpointsShowAction` lose their last use.
    // eoc #461

    // boc #470
    /// The last result ONLY when it was measured on the route this card is
    /// about. #470 was: the DL/UL figures printed `speed.lastResult` whatever
    /// its `mode`, and only the AGE line was gated on it — so a direct-mode run
    /// showed as bare numbers inside the tunnel's Diagnostics, undated and
    /// unattributed, the exact claim the file header forbids. A result from the
    /// other route reads "—", like no result. #484: same-route earlier sessions
    /// are cleared at transitions; the service also owns the measurement stamp.
    private var routeResult: SpeedResult? {
        speed.lastResult.flatMap { $0.mode == mode ? $0 : nil }
    }
    // eoc #470

    private func value(_ v: Double?, _ format: String) -> String {
        if speed.isTesting { return "…" }
        guard let v else { return "—" }
        return String(format: format, v)
    }

    /// #459: how many services the IP check will actually query — the same
    /// resolution `IPChecker.sources` performs (its own copy is private), so the
    /// sentence never promises a count the check will not honour.
    private static var ipSourceCount: Int {
        let enabled = SettingsStore.shared.enabledIPSources
        let chosen = AppConstants.ipCheckServices.filter { enabled.contains($0.label) }
        if chosen.isEmpty {
            return AppConstants.ipCheckServices.filter {
                AppConstants.defaultEnabledIPCheckLabels.contains($0.label)
            }.count
        }
        return chosen.count
    }
}

// MARK: - Shared pieces

// boc #471
// design system's section-header treatment" while using a fourth (font, tint,
// tracking) recipe of its own. Both call sites draw `OlcSectionHeader` now, which
// is the treatment, and no view in the app had been using it.
// eoc #471

/// Label left, value right — the fact rows of block A. The explicit init (rather
/// than an `@ViewBuilder` stored property) matches `OlcCard` / `OlcSectionHeader`
/// in the design system.
///
/// #471 was: an optional `note` — one full-width caption under the label/value
/// line. Its two users (exit, response time) were the reason it existed; the
/// response note went with the discrepancy it explained (#461) and the exit note
/// is a clause on the age now (`DiagnosticsAge.viaIPInfo`), so the parameter had
/// no caller left. A row is a label and a value.
private struct DiagnosticsRow<Trailing: View>: View {
    private let label: String
    private let trailing: () -> Trailing
    init(label: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.label = label
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: Theme.Metrics.s3)
            trailing()
        }
        .padding(.vertical, Theme.Metrics.s3)
    }
}

/// #457/#459: the age of ONE measurement, in the same `HealthAge` vocabulary the
/// row verdicts use. No stamp means the fact was never measured — say so; never
/// print a value with a blank where its date belongs.
///
/// #459: `HealthAge.phrase` (not the old `HealthAge.label`) — the phrase carries
/// its own "ago"/«назад», which is what stops `healthCheckedAgo_fmt` reading
/// "checked just now ago".
private struct DiagnosticsAge: View {
    let at: Date?
    /// #471: fold the exit row's PROVENANCE into the age that dates it —
    /// "checked 2 min ago · via ipinfo.io". Dating a claim answers "is this still
    /// true?" and sourcing it answers "who says so?"; one line can carry both,
    /// and #460's separate paragraph could not stop being a paragraph.
    /// `var` (not `let`) so the memberwise init keeps the default.
    var viaIPInfo = false

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
            // provenance clause that truncates says nothing.
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
    }

    private var text: String {
        guard let at else { return L10n.healthNeverMeasured.localized() }
        let aged = L10n.healthCheckedAgo_fmt.formatted(HealthAge.phrase(Date().timeIntervalSince(at)))
        return viaIPInfo ? L10n.diagAgeVia_fmt.formatted(aged) : aged
    }
}

// MARK: - ConnectIPStatus (extracted #457, moved here #459)
//
// The IP-check result block: collapsed agreement line, the DNS-leak warning, or
// the per-source list. Its own struct so the tools block's body stays small.

private struct ConnectIPStatus: View {
    @ObservedObject var ipCheck: IPChecker
    let maskIPs: Bool
    /// #470: the route the card is about NOW — a result from the other route is
    /// attributed, and never green.
    let mode: RouteMode

    var body: some View {
        if ipCheck.isChecking {
            Text(L10n.ipChecking.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else if !hasResults {
            Text(L10n.ipNotChecked.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else if collapsed, let ip = summaryIP {
            // #470: say WHICH ROUTE answered, and be green only while that is the
            // route this card is about. `IPResult.mode` was stored and never
            // rendered, and nothing clears results across connect / disconnect,
            // so a real-IP check made before connecting sat green under a
            // Connected hero (and a tunnel IP stayed green after disconnecting),
            // reading as the current answer.
            let agree = L10n.ipSourcesAgree_fmt.formatted(IPMask.display(ip, masked: maskIPs),
                                                          ipCheck.results.filter { $0.ip != nil }.count)
            Text("\(agree) · \(resultRoute.label)")
                .font(Theme.Typography.mono)
                .foregroundStyle(resultIsCurrentRoute ? Theme.Palette.green : Theme.Palette.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                if allDone, Set(ipCheck.results.compactMap { $0.ip }).count > 1 {
                    leakWarning
                }
                ForEach(ipCheck.results) { r in sourceRow(r) }
                routeCaption
            }
        }
    }

    // boc #470
    /// The route the listed answers came from (every row of one check shares it).
    private var resultRoute: RouteMode { ipCheck.results.first?.mode ?? mode }
    private var resultIsCurrentRoute: Bool { resultRoute == mode }

    private var routeCaption: some View {
        Text(resultRoute.label)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
    }
    // eoc #470

    private var leakWarning: some View {
        HStack(spacing: Theme.Metrics.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.red)
            Text(L10n.ipDnsLeak.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.red)
        }
    }

    @ViewBuilder
    private func sourceRow(_ r: IPResult) -> some View {
        HStack {
            Text(r.label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            if let ip = r.ip {
                Text(IPMask.display(ip, masked: maskIPs))
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textPrimary)
            } else if let err = r.error {
                Text(err)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("—").foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private var collapsed: Bool {
        let ips = ipCheck.results.compactMap { $0.ip }
        guard ips.count >= 2 else { return false }
        return Set(ips).count == 1
    }
    private var summaryIP: String? { ipCheck.results.compactMap { $0.ip }.first }
    private var hasResults: Bool { ipCheck.results.contains { $0.ip != nil || $0.error != nil } }
    private var allDone: Bool {
        !ipCheck.results.isEmpty && ipCheck.results.allSatisfy { $0.ip != nil || $0.error != nil }
    }
}
