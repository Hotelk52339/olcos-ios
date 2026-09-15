import SwiftUI

// MARK: - ConnectionsView — the Connect tab
//
// JOB: state the truth about the tunnel right now, and offer the ONE action that
// changes it. Nothing is drawn that cannot be dated or measured.
//
// Top to bottom:
//   1. ConnectHero          — the state as the largest text on the screen, one
//                             line of dated evidence, the waveform breathing
//                             with measured throughput and its ↓/↑ readout, one
//                             labelled button, then the active connection
//                             summary (service · transport · host · VPN/SOCKS5
//                             mode) with that connection's action menu.
//   2. Switch protocol      — one row per OTHER connection: carrier · transport,
//                             one `OlcHealthChip`, and the host label only when
//                             the list spans more than one host. TAP = connect.
//   3. Diagnostics          — "This session" (exit / latency, only while
//                             connected) + "Checks" (IP check, speed test).
//                             See HealthCard.swift.
//
// Readouts never stand between the user and the switcher; the hero's own
// readout is one quiet line. Protocol failover (`SettingsStore.autoFailover`)
// is configured in Settings only; its engine in TunnelManager is inert while
// the setting is off.
//
// THE ONE STRUCTURAL DECISION — the hero's subject is NOT in the list.
// `heroSubjectID` (the live node while a session is up, else `store.primary`) is
// skipped when the rows are drawn, so a connection's name appears exactly once
// on this screen. "Which one is selected?" is answered by POSITION and
// CONTAINER — the selected node is the card at the top with the button in it.
//
// The filtering happens at RENDER time, not in `recompute()`: keeping `groups`
// whole means `groupHeader`'s failing count and `groupFooter`'s subscription
// metadata still describe the real group, and a group whose only member is the
// hero's subject renders as an empty `Section` rather than silently dropping its
// quota footer.
//
// PULL TO REFRESH replaces any per-group "Verify all" button. See
// `refreshEverything()`.
//
// Surgery discipline: this file has hit the SwiftUI type-checker's expression
// budget twice. Every change is by EXTRACTION — the hero lives in
// ConnectHero.swift, the row in ConnectionRowView.swift, the diagnostics card in
// HealthCard.swift, throughput sampling in TunnelThroughput.swift, and the
// List's modifiers are split across small wrapper functions. Nothing here has a
// `body` over ~20 lines or a chain over ~8.
//
// The row verdicts are `HealthCoordinator`'s persisted, timestamped evidence.
// Green means an HTTP 2xx came back through that node's OWN SOCKS listener,
// minutes ago — not "we ran something once".

struct ConnectionsView: View {
    @ObservedObject var store   : ConnectionStore
    @ObservedObject var tunnel  : TunnelManager
    @ObservedObject var ipCheck : IPChecker
    @ObservedObject var speed   : SpeedTest
    /// #361: routes a subscription pasted into the AddConnection import box (an
    /// https URL or raw sub.md body) up to MainTabView's confirm-then-import flow.
    var onPasteImport: ((OlcrtcSubscription.ImportInput) -> Void)? = nil
    /// IDs of records some saved server produced; anything else was imported
    /// from another device and cannot be repaired from the Servers tab here.
    var linkedRecordIDs: Set<UUID> = []

    // #337: observe the screenshot-safe toggle so IP displays re-mask live.
    // #457: also the source of `tunnelMode` for the hero's permanent scope line.
    @ObservedObject private var settings = SettingsStore.shared
    // #456: the ONE health vocabulary — a singleton because it is written by
    // non-view code (TunnelManager) and read by two tabs.
    @ObservedObject private var health = HealthCoordinator.shared

    // #330: ONE enum-driven sheet. Multiple `.sheet` modifiers on one view is
    // unsupported in SwiftUI and, when the host re-renders under a live tunnel,
    // the editor sheet hangs on present and on dismiss.
    @State private var activeSheet: ConnectionSheet?

    // boc #486: user intent belongs to this visible screen, not a tunnel-wide
    // state observer. Tab changes, sheets and backgrounding discard it.
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var hapticPolicy = SignalHapticPolicy()
    // eoc #486

    /// Polls tunnel byte counters ~1/s for the hero — only while connected, on
    /// screen, uncovered and in the foreground (`syncThroughput`).
    @StateObject private var throughput = TunnelThroughputMonitor()

    /// #403: per-group subscription metadata, cached — `body` re-evaluates ~10×/s
    /// during a speed test and must not recompute it.
    @State private var subInfoByGroup: [String: (source: String, meta: ConnectionStore.SubscriptionMeta)] = [:]
    /// #413: the grouped connection list, cached for the same reason.
    @State private var groups: [(group: String, items: [ConnectionRecord])] = []
    /// #471: does the list span more than one host label? A row prints its host
    /// only when the answer differs between rows — otherwise it is the same word
    /// on every one. Cached for the same reason as the two above.
    @State private var showHost = false

    // boc #457 was: @State alertText — a one-OK alert titled `healthWhyTitle`,
    // reached from a "What's wrong?" overflow item. The reason and its fix are
    // now ON the failing row, which is where the user is already looking.
    // eoc #457

    /// #330: the single sheet this view can present.
    private enum ConnectionSheet: Identifiable {
        case add
        case edit(ConnectionRecord)
        case qr(ConnectionRecord)
        case carrierEndpoints(OlcrtcConnection)   // #406
        case share(ConnectionRecord)              // #456

        var id: String {
            switch self {
            case .add:              return "add"
            case .edit(let c):      return "edit-\(c.id.uuidString)"
            case .qr(let c):        return "qr-\(c.id.uuidString)"
            case .carrierEndpoints: return "carrier"
            case .share(let c):     return "share-\(c.id.uuidString)"
            }
        }
    }

    // #484 was: connected proxy ? .tunnel : .direct. VPN uses ordinary sockets
    // but is NOT direct provenance; the distinction also invalidates old ISP IPs.
    private var currentMode: RouteMode {
        RouteMode.current(isConnected: tunnel.state.isConnected, activeMode: tunnel.activeMode)
    }

    // MARK: Body

    var body: some View {
        // #459: the List's modifiers are split across two wrappers. This file has
        // blown the SwiftUI type-checker's budget twice; one chain of eleven
        // modifiers on a `List` whose content is four dynamic sections is exactly
        // how it happened.
        NavigationStack {
            // #460: a third wrapper (`listBars`) rather than a longer chain —
            // this file has blown the SwiftUI type-checker's budget twice and
            // the bar fixes are four modifiers on their own.
            listWiring(listBars(listChrome(connectionList)))
        }
        // #459: the manual equivalent of the pull, on entry — governed by the
        // "Check on opening" switch. The contract, stated once: THE TOGGLE
        // DECIDES WHETHER THE APP CHECKS BY ITSELF; A PULL ALWAYS CHECKS.
        // boc #486
        // #486 was: .onAppear { entrySweep() }
        .onAppear {
            isVisible = true
            Haptics.prepare()
            entrySweep()
            syncThroughput()
        }
        .onDisappear {
            isVisible = false
            hapticPolicy.cancel()
            throughput.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { hapticPolicy.cancel() }
            else if isVisible { Haptics.prepare() }
            syncThroughput()
        }
        .onChange(of: activeSheet?.id) { _, id in
            if id != nil { hapticPolicy.cancel() }
            else if isVisible { Haptics.prepare() }
            syncThroughput()
        }
        // eoc #486
        // #484: same-state record/mode replacement also invalidates diagnostics.
        .onChange(of: tunnel.connectedRecord?.id) { _, _ in invalidateDiagnostics() }
        .onChange(of: tunnel.activeMode) { _, _ in invalidateDiagnostics(); syncThroughput() }
        // #469 was: `.onDisappear { health.cancelAll() }` — see ServersView: the
        // two tabs verify the SAME records through ONE coordinator, and a tab
        // switch fires the new tab's onAppear and the old one's onDisappear in
        // the same turn, so the sweep just scheduled was cancelled before its
        // first probe. "Check on opening" silently did nothing on a switch.
    }

    /// ONE PAGE. The first screenful holds only things you can act on: the
    /// answer, the control, and the switcher. Diagnostics — the readouts — sit
    /// one deliberate scroll down, where IVPN's `.full` drag and Mullvad's
    /// chevron put theirs.
    private var connectionList: some View {
        List {
            Section { heroBlock }   // 1. the answer, the action, the active connection
            connectionsSection      // 2. the switcher
            diagnosticsSection      // 3. the readouts
        }
    }

    private func listChrome(_ content: some View) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.bg)
            // #459 was: `refreshSubscriptions()` only, with a per-group "Verify
            // all" button in every section header.
            .refreshable { await refreshEverything() }
    }

    // boc #460
    /// #460 (findings 1 and 4): BOTH SYSTEM BARS WERE DRAWING OVER THE CONTENT.
    ///
    /// `.scrollContentBackground(.hidden)` + a custom `Theme.Palette.bg` leaves
    /// the navigation bar and the tab bar on their transparent scroll-edge
    /// appearance, so a scrolled `List` does not disappear behind them — it
    /// shows THROUGH them. On the owner's phone that clipped the top of the
    /// hero's state word (the largest, most important text in the app) under the
    /// navigation bar, and cut the last row's badge in half under the tab bar.
    ///
    /// Forcing both bars to draw their background is the fix: content that
    /// scrolls under a bar is now covered by it, cleanly. Visibility only — no
    /// style argument — so each bar keeps the SYSTEM material it would have
    /// shown anyway; a flat `Palette.bg` fill here would make this tab's bars
    /// look unlike every other tab's.
    ///
    /// The bottom content margin braces that belt: the last card gets the same
    /// breathing room above the tab bar that a section gets from its neighbour,
    /// instead of ending flush against it.
    ///
    /// NOTE for the other tabs: ServersView and SettingsView draw the same
    /// `scrollContentBackground(.hidden)` + custom-background List, so they have
    /// the same defect and want the same two lines.
    private func listBars(_ content: some View) -> some View {
        content
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .tabBar)
            .contentMargins(.bottom, Theme.Metrics.s6, for: .scrollContent)
            // #471: the token grid used to stop at the card edge. `List`'s default
            // section spacing is ~35 pt, so with `olcCardRow`'s 8 + 8 the gap
            // BETWEEN cards was ~51 pt against 20 pt INSIDE one — a 2.5× ratio,
            // which is why the screen read half empty while each card read as a
            // dense slab. 16 pt puts the gap on the grid.
            .listSectionSpacing(Theme.Metrics.s4)
    }
    // eoc #460

    private func listWiring(_ content: some View) -> some View {
        content
            .onChange(of: store.connections, initial: true) { _, _ in recompute() }
            .onChange(of: store.subscriptionMeta) { _, _ in recompute() }
            .onChange(of: tunnel.state) { old, new in stateChanged(from: old, to: new) }
            // #457 was: `.navigationTitle("OlcRTC")` — 34 pt of the most valuable
            // space spent on a word carrying no information.
            .navigationTitle(L10n.tabConnections.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) { addButton } }
            .sheet(item: $activeSheet) { sheetContent($0) }
    }

    private var addButton: some View {
        Button { activeSheet = .add } label: { Image(systemName: "plus") }
            .accessibilityLabel(L10n.newConnectionTitle.localized())
    }

    // MARK: 1. Hero

    private var heroBlock: some View {
        ConnectHero(state: tunnel.state,
                    subject: heroSubject,
                    health: heroSubject.map { health.display(for: $0.id) } ?? HealthDisplay.never,
                    exitFlag: exitFlag,
                    exitPlace: exitPlace,
                    exitMeasuredAt: ipCheck.exitGeoAt, // the measurement date, not the view's
                    // Setup/recovery keep their captured backend; idle scope
                    // previews the same effective mode that connect() will use.
                    mode: heroMode,
                    socksPort: tunnel.boundPort ?? settings.socksPort,
                    secretsLocked: store.secretsLocked,
                    isPresented: isVisible && activeSheet == nil,
                    modeFallbackReason: heroMode == .proxy ? tunnel.automaticModeFallbackReason : nil,
                    isManagedHere: heroSubject.map { linkedRecordIDs.contains($0.id) } ?? true,
                    throughput: throughput.reading,
                    waveIntensity: throughput.intensity,
                    // The subject has no row, so it carries the row's own action
                    // set — the SAME builder, not a copy.
                    menuItems: heroSubject.map { rowMenuItems($0) } ?? [],
                    onConnect: { heroConnect() },
                    onDisconnect: { heroDisconnect() })
            // Signal sits on the page ground; only the connection summary is a plate.
            .listRowInsets(EdgeInsets(top: 0, leading: Theme.Metrics.s4,
                                     bottom: Theme.Metrics.s2, trailing: Theme.Metrics.s4))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var heroMode: TunnelMode {
        switch tunnel.state {
        case .connected, .connecting, .waitingForNetwork: return tunnel.activeMode
        case .failed where tunnel.hasPendingRecovery: return tunnel.activeMode
        case .disconnected, .failed: return tunnel.effectiveModeForNextConnection
        }
    }

    /// The throughput monitor runs only while there is something to measure and
    /// someone to see it. Every input change funnels through here; anything
    /// else stops the loop and clears the reading.
    private func syncThroughput() {
        throughput.update(isConnected: tunnel.state.isConnected,
                          isOnScreen: isVisible && activeSheet == nil,
                          sceneIsActive: scenePhase == .active,
                          mode: tunnel.activeMode,
                          vpn: tunnel.vpn)
    }

    /// #456: the record the hero describes — the LIVE node while a session is up
    /// (never `store.primary`, which a row tap used to move without reconnecting),
    /// else the last-used one, which is also the node a Connect tap will dial.
    private var heroSubject: ConnectionRecord? {
        // #486 was: connected ? connectedRecord : store.primary. In-flight
        // scope/identity must stay with the engaged attempt, not a saved choice.
        if tunnel.state.isConnected { return tunnel.connectedRecord }
        return tunnel.engagedRecord ?? store.primary
    }

    /// #459: the hero's subject is drawn in the hero, never again in the list.
    private var heroSubjectID: UUID? { heroSubject?.id }

    /// #459: the exit as the hero prints it — "Amsterdam, NL". nil whenever the
    /// lookup gave nothing usable, in which case the hero falls back to the
    /// honesty layer's own dated sentence.
    private var exitPlace: String? {
        guard let geo = ipCheck.exitGeo, geo != IPChecker.ExitGeo() else { return nil }
        let place = [geo.city, geo.country].compactMap { $0 }.joined(separator: ", ")
        return place.isEmpty ? nil : place
    }

    private var exitFlag: String? {
        guard let cc = ipCheck.exitGeo?.country else { return nil }
        return CountryFlag.emoji(iso2: cc)
    }

    private func heroConnect() {
        // boc #486
        // #486 was: impact then connect, with no user-outcome ownership.
        guard let p = store.primary, !store.secretsLocked else { return }
        beginUserConnection(p)
        // eoc #486
    }

    private func heroDisconnect() {
        // #486: cancellation has one press impact, never a later success buzz.
        hapticPolicy.cancel()
        Haptics.impact()
        tunnel.disconnect()
    }

    /// #455: physical feedback on the OUTCOME — success only after `verifyTunnel`
    /// returned 200, an error buzz when the attempt gives up. #454: the exit geo is
    /// fetched on the connect transition and cleared on the way down.
    private func stateChanged(from old: ConnectionState, to new: ConnectionState) {
        invalidateDiagnostics() // #484: includes connecting/waiting, not only disconnect.
        // #486 was: every connected/failed transition fired success/error,
        // including automatic recovery, launch adoption and off-screen changes.
        resolveUserOutcome()
        syncThroughput()
        if new.isConnected {
            Task { await ipCheck.refreshExitGeo(via: currentMode) }
        } else {
            ipCheck.clearExitGeo()
        }
    }

    // boc #486
    private func beginUserConnection(_ record: ConnectionRecord) {
        guard isVisible, scenePhase == .active, activeSheet == nil,
              !store.secretsLocked else { return }
        // #486: the manager deliberately ignores an already-engaged identical
        // choice. A no-op must not masquerade as a new successful connection.
        if tunnel.engagedRecord?.id == record.id,
           tunnel.activeMode == tunnel.effectiveModeForNextConnection {
            switch tunnel.state {
            case .connected, .connecting, .waitingForNetwork: return
            case .disconnected, .failed: break
            }
        }
        hapticPolicy.beginConnection(id: record.id)
        Haptics.impact()
        tunnel.connect(record: record)
        // Preflight can fail synchronously, even with the same error text as a
        // previous retry (no onChange). Consume now as well; the policy is once-only.
        resolveUserOutcome()
    }

    private func resolveUserOutcome() {
        let phase: SignalConnectionPhase
        switch tunnel.state {
        case .disconnected: phase = .idle
        case .connecting: phase = .connecting
        case .connected: phase = .connected
        case .waitingForNetwork: phase = .waiting
        case .failed: phase = .failed
        }
        let outcome = hapticPolicy.outcome(
            phase: phase, connectedRecordID: tunnel.connectedRecord?.id,
            isVisible: isVisible && activeSheet == nil,
            sceneIsActive: scenePhase == .active,
            isAutomaticRecovery: tunnel.hasPendingRecovery)
        switch outcome {
        case .success: Haptics.success()
        case .error: Haptics.error()
        case nil: break
        }
    }
    // eoc #486

    // boc #484: App.swift also invokes these on lifecycle transitions while this
    // view is absent. Generation guards make late network completions harmless.
    private func invalidateDiagnostics() {
        ipCheck.invalidateRoute()
        speed.invalidateRoute()
    }
    // eoc #484

    // MARK: 2. The connection list — the switcher

    @ViewBuilder
    private var connectionsSection: some View {
        if store.connections.isEmpty {
            Section {
                OlcEmptyState(systemImage: "network",
                              title: L10n.emptyNoConnections.localized(),
                              hint: L10n.emptyNoConnectionsHint.localized(),
                              ctaTitle: L10n.newConnectionTitle.localized()) {
                    activeSheet = .add
                }
                .olcCardRow()
            }
        } else {
            // #471 was: `onlyOneProtocolNote` — see below the `ForEach`.
            // #459 was: a `pullToRefreshHint` row — a caption instructing the
            // user to perform a standard system gesture. The gesture now does
            // considerably more, and still needs no caption.
            ForEach(groups, id: \.group) { group in
                Section {
                    connectionRows(group.items)
                } header: {
                    groupHeader(group.group, items: group.items)
                } footer: {
                    groupFooter(group.group)
                }
            }
        }
    }

    /// #459: the hero's subject is skipped. `excluded` is read once per SECTION,
    /// never per row (AGENTS.md: don't derive in `body` on a view that
    /// re-evaluates ~10×/s during a speed test), and the filtering is a per-row
    /// `if` rather than a `filter` so no new array is built either.
    private func connectionRows(_ items: [ConnectionRecord]) -> some View {
        let excluded = heroSubjectID
        return ForEach(items) { conn in
            rowUnlessHeroSubject(conn, excluded: excluded)
        }
    }

    @ViewBuilder
    private func rowUnlessHeroSubject(_ conn: ConnectionRecord, excluded: UUID?) -> some View {
        if conn.id != excluded { row(conn) }
    }

    /// #459: a group whose ONLY member is the hero's subject keeps its Section —
    /// so `groupFooter`'s subscription quota still renders — but drops its header,
    /// because a "Switch to" heading over nothing is a promise the list can't keep.
    private func hasVisibleRows(_ items: [ConnectionRecord]) -> Bool {
        let excluded = heroSubjectID
        return items.contains { $0.id != excluded }
    }

    // boc #471
    // #471 was: `onlyOneProtocolNote` (+ its `hasAnyVisibleRow` helper) — two
    // caption lines mounted on the main screen of every one-protocol install:
    // "Only one protocol on this server" and "Install a second one on the Servers
    // tab, so you can switch when one stops working."
    //
    // THE MAIN SCREEN DOES NOT TELL THE USER WHAT IT CANNOT DO. An empty switcher
    // section is not a gap that needs explaining — a user with one connection has
    // one connection, sees the hero and Diagnostics, and nothing is missing. The
    // note was #461's answer to "a silent gap between the hero and the
    // auto-switch card"; #471 closes that gap at the other end instead, by not
    // drawing the auto-switch card when there is nothing to switch between.
    // (`connectSwitcherOnlyOne` / `connectSwitcherAddHint` lose their last use.)
    // The zero-connection empty state above is untouched: THAT one offers an
    // action.
    // eoc #471

    private func row(_ conn: ConnectionRecord) -> some View {
        // #459 was: also `isLive:` — the live node is the hero's subject and is
        // therefore never in this list, so the "Live" badge could never render.
        ConnectionRowView(record: conn,
                          display: health.display(for: conn.id),
                          maskIPs: settings.maskIPs,
                          menuItems: rowMenuItems(conn),
                          onConnect: { connect(conn) },
                          onVerify: { verify(conn) },
                          showHost: showHost)   // #471: cached in `recompute()`
            .olcCardRow()
            .swipeActions(edge: .trailing) { rowSwipeActions(conn) }
    }

    @ViewBuilder
    private func rowSwipeActions(_ conn: ConnectionRecord) -> some View {
        Button(role: .destructive) { remove(conn) } label: {
            // #457 was: `actionRemoveFromList` ("Remove host from list") — a
            // connection is not a host, and `trash` is reserved for irreversible
            // server-side destruction.
            Label(L10n.connectRowRemove.localized(), systemImage: "minus.circle")
        }
        Button { activeSheet = .edit(conn) } label: {
            Label(L10n.edit.localized(), systemImage: "pencil")
        }
        // #457 was: `.tint(Theme.Palette.orange)` — amber now means in-flight only.
        .tint(Theme.Palette.accent)
    }

    /// #457: a tap on a row CONNECTS through it. `connect(record:)` already
    /// disconnects-then-dials, so this is safe from any state. `store.primary` is
    /// kept in step as a SIDE EFFECT — it is no longer a user-facing concept, but
    /// auto-connect-on-launch and the hero's idle subject still read it.
    /// #457 was: `Haptics.tap()` + `store.setPrimary(conn.id)` and no connection.
    private func connect(_ conn: ConnectionRecord) {
        // boc #486
        // #486 was: setPrimary + impact + connect; bypassed the locked UI guard.
        guard !store.secretsLocked, isVisible, scenePhase == .active else { return }
        store.setPrimary(conn.id)
        // A row both selects and connects. One soft connect impact, not stacked
        // selection + impact feedback for the same gesture.
        beginUserConnection(conn)
        // eoc #486
    }

    private func verify(_ conn: ConnectionRecord) {
        Task { await health.verify(conn, using: tunnel, force: true) }
    }

    private func remove(_ conn: ConnectionRecord) {
        // #470: the hero carries this menu for the LIVE record too. Removing it
        // used to leave the session up and the hero showing the deleted record
        // as "Connected" with Edit/Share/QR on a ghost (`connectedRecord` kept
        // the snapshot; `store.update` on a gone id was a silent no-op). A
        // record that no longer exists cannot stay connected honestly.
        if tunnel.connectedRecord?.id == conn.id { tunnel.disconnect() }
        if let i = store.connections.firstIndex(where: { $0.id == conn.id }) {
            store.remove(at: IndexSet([i]))
        }
    }

    // MARK: Section chrome

    /// #459: the default group's header says what the list below it IS — a
    /// switcher for everything that is not the hero's subject. #457 had left it
    /// blank because its own name ("Connections") repeated the tab it sits in.
    /// #461: the header names the SUBJECT of the choice ("Switch protocol"), not
    /// a bare preposition — "Switch to" ran straight into the row under it and
    /// read as "Switch to — ams-1". #461 was: `connectListOtherHeader` = "Switch to".
    ///
    /// #459 was: `groupHealthControl` — a per-group "Verify all" button plus its
    /// spinner, sitting in a section header. Pull-to-refresh replaces it, checks
    /// EVERYTHING rather than one group, and reports progress per row instead of
    /// through one header spinner.
    @ViewBuilder
    private func groupHeader(_ group: String, items: [ConnectionRecord]) -> some View {
        if hasVisibleRows(items) {
            HStack(spacing: Theme.Metrics.s2) {   // #471 was: 8
                Text(group == ConnectionRecord.defaultGroupName
                     ? L10n.connectListOtherHeader.localized()
                     : ConnectionRecord.displayGroupName(group))
                failingBadge(items)
                Spacer()
            }
        }
    }

    /// #456: `HealthCoordinator.summary` reports the BEST evidence, which on its
    /// own lets one working node hide a dead sibling. The count is the pairing that
    /// keeps a known failure from being silent.
    @ViewBuilder
    private func failingBadge(_ items: [ConnectionRecord]) -> some View {
        if let label = failingLabel(items) {
            Text(label)
                .foregroundStyle(Theme.Palette.red)
                .textCase(nil)
        }
    }

    private func failingLabel(_ items: [ConnectionRecord]) -> String? {
        let counts = health.failingCount(for: items.map(\.id))
        guard counts.failing > 0 else { return nil }
        return L10n.connectGroupFailing_fmt.formatted(counts.failing, counts.total)
    }

    // boc #459
    // #459 was: `groupHealthControl(_:)` — an `if items.contains(where: health
    // .isChecking) { ProgressView() } else { Button(healthVerifyAllAction) { … } }`
    // in every section header. The owner asked for "something like the Verify all
    // button — but not a button, a SWIPE DOWN". `refreshEverything()` below is it.
    // eoc #459

    @ViewBuilder
    private func groupFooter(_ group: String) -> some View {
        if let info = subInfoByGroup[group] {
            SubscriptionMetaFooter(source: info.source, meta: info.meta)
        }
    }

    // MARK: 3. Diagnostics — the ONE card (defined in HealthCard.swift)

    /// LAST, below the switcher: readouts may not stand between the user and
    /// the list of protocols they came to change (`connectionList`). The
    /// carrier-endpoints tool is an action ON A CONNECTION and lives in
    /// `rowMenuItems`.
    private var diagnosticsSection: some View {
        Section {
            DiagnosticsCard(record: tunnel.connectedRecord,
                            ipCheck: ipCheck, speed: speed,
                            mode: currentMode, maskIPs: settings.maskIPs,
                            isConnected: tunnel.state.isConnected,
                            onSpeedTest: { runSpeedTest() })
                // #484: checks during route installation cannot be attributed.
                .disabled(tunnel.state.isConnecting || tunnel.state == .waitingForNetwork)
                .olcCardRow()
        } header: {
            Text(L10n.diagnosticsTitle.localized())
        }
    }

    /// #285: pass the LIVE carrier/transport into the speed test so the header logs
    /// the connection type and the datachannel hint can fire.
    private func runSpeedTest() {
        var carrier: String?
        var transport: String?
        if currentMode.isTunnelled, case .olcrtc(let p)? = tunnel.connectedRecord?.details { // #484
            carrier = p.carrier
            transport = p.transport
        }
        Task { await speed.run(via: currentMode, carrier: carrier, transport: transport) }
    }

    // MARK: Row actions

    /// #457 was: this menu also held "Connect" (offered only on rows that were NOT
    /// primary — i.e. missing on exactly the row you most wanted) and "What's
    /// wrong?" (an alert). Tapping the row connects; the reason and its fix are on
    /// the row itself.
    ///
    /// #459 was: this menu also opened with "Verify". The row's `OlcHealthChip`
    /// IS the verify affordance now — a 44 pt target that re-probes on tap — and
    /// the hero, which shows this same menu for its own subject, is covered by
    /// the pull gesture.
    private func rowMenuItems(_ conn: ConnectionRecord) -> [OlcMenuItem] {
        var items: [OlcMenuItem] = []
        // #456: connection-ONLY share — the `olcrtc://` URI and nothing else, so it
        // grants NO VPS/SSH access.
        items.append(.action(L10n.shareConnectionTitle.localized(), systemImage: "square.and.arrow.up") {
            activeSheet = .share(conn)
        })
        items.append(.divider)
        items.append(.action(L10n.copyURIAction.localized(), systemImage: "doc.on.doc") {
            UIPasteboard.general.string = Self.uriOf(conn)
            LogStore.shared.log(.connection, L10n.copiedURI_fmt.formatted(conn.displayName))
        })
        items.append(.action(L10n.actionQR.localized(), systemImage: "qrcode") {
            activeSheet = .qr(conn)
        })
        carrierEndpointsItem(conn, into: &items)
        items.append(.divider)
        items.append(.action(L10n.edit.localized(), systemImage: "pencil") { activeSheet = .edit(conn) })
        // #457 was: `actionRemoveFromList` + systemImage "trash" — the string says
        // "host" on a connection row, and `trash` is reserved for irreversible
        // server-side destruction; this only tidies the local list.
        items.append(.action(L10n.connectRowRemove.localized(),
                             systemImage: "minus.circle", role: .destructive) {
            remove(conn)
        })
        return items
    }

    // boc #461
    /// #461: the carrier-endpoints tool, MOVED here from a ~90 pt Diagnostics
    /// row (`DiagnosticsTools.carrierRow`: a title, a two-line
    /// audience-selecting hint and a "Show" button, permanently mounted on the
    /// app's main screen and disabled whenever nothing is connected).
    ///
    /// It is an ACTION ON A CONNECTION — "which addresses does THIS carrier
    /// need let out directly?" — and it only has an answer for the live one, so
    /// it belongs in that connection's menu. The live node is the hero's
    /// subject, the hero carries `rowMenuItems` for its subject, and that menu
    /// is on screen at all times: the tool is no further away than it was, and
    /// the first screenful is 90 pt lighter.
    ///
    /// Gated on the LIVE record (not `store.primary`, which a row tap desyncs) —
    /// the endpoints depend on the host the tunnel actually holds. Rows in the
    /// switcher are never the live record, so in practice this item appears
    /// only in the hero's menu.
    private func carrierEndpointsItem(_ conn: ConnectionRecord, into items: inout [OlcMenuItem]) {
        guard case .olcrtc(let params) = conn.details,
              conn.id == tunnel.connectedRecord?.id else { return }
        items.append(.divider)
        items.append(.action(L10n.carrierEndpointsRowTitle.localized(),
                             systemImage: "arrow.triangle.branch") {
            activeSheet = .carrierEndpoints(params)
        })
    }
    // eoc #461

    /// Reassembles the original `olcrtc://` URI for sharing / copy / QR.
    private static func uriOf(_ conn: ConnectionRecord) -> String {
        switch conn.details {
        case .olcrtc(let p): return OlcrtcURI.encode(p)
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: ConnectionSheet) -> some View {
        switch sheet {
        case .add:
            AddConnectionView(onImport: { input in
                activeSheet = nil   // hand off to the subscription confirm flow
                onPasteImport?(input)
            }) {
                store.add($0)
            }
        case .edit(let conn):
            AddConnectionView(existing: conn) { updated in
                store.update(updated)
                // #470: the stored verdict was measured against the OLD
                // room/key/carrier and kept the same id — the row stayed green
                // "48 ms · 1m" for a configuration nobody had measured, and the
                // debounced sweep refused to re-check it for two minutes. A
                // changed `details` is unmeasured until proven otherwise.
                if updated.details != conn.details { verify(updated) }
            }
        case .qr(let conn):
            qrSheet(conn)
        case .carrierEndpoints(let params):
            CarrierEndpointsView(params: params)
        case .share(let conn):
            ShareConnectionView(conn: conn)
        }
    }

    private func qrSheet(_ conn: ConnectionRecord) -> some View {
        // #470: service first, host last — the #461 identity rule the hero, the
        // rows and the Servers card already follow ("Yandex Telemost · ams-1").
        // #470 was: `.navigationTitle(conn.displayName)` ("ams-1 · Telemost")
        let title = "\(ConnectionNaming.service(conn.details)) · \(ConnectionNaming.host(conn))"
        return NavigationStack {
            QRCodeView(uri: Self.uriOf(conn))
                .padding(32)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.actionDone.localized()) { activeSheet = nil }
                    }
                }
        }
        .presentationDetents([.medium])
    }

    // MARK: Caches

    /// #403/#413: rebuild the cached grouped list + per-group subscription meta.
    /// Runs only when the inputs change, never inside `body`.
    private func recompute() {
        let grouped = store.grouped()
        groups = grouped
        // #471: decided ONCE per change of the store, never inside `body`.
        showHost = ConnectionNaming.spansMultipleHosts(store.connections)
        var map: [String: (source: String, meta: ConnectionStore.SubscriptionMeta)] = [:]
        for group in grouped {
            if let info = store.subscriptionInfo(for: group.items) {
                map[group.group] = info
            }
        }
        subInfoByGroup = map
    }

    /// #411: manual pull-to-refresh — force-refresh every subscription source.
    private func refreshSubscriptions() async {
        guard store.hasSubscriptions else { return }
        _ = await store.refreshAllSources()
    }

    // MARK: Refresh — the gesture that replaced the button (#459)

    /// #459: how long the pull spinner may be held for the health sweep. The
    /// sweep is sequential and each probe owns a 20 s budget
    /// (`HealthPolicy.probeTimeoutMs`), so without a cap one dead carrier would
    /// pin the spinner for minutes. Past the cap the sweep keeps running and the
    /// rows keep saying "Checking…", which is the honest report either way.
    private static let pullSweepMaxSeconds: TimeInterval = 20

    /// #459 was: `refreshSubscriptions()` alone, with a per-group "Verify all"
    /// button beside it. A pull now refreshes the STATE OF EVERYTHING, which is
    /// what the owner asked the gesture to mean:
    ///   • every connection's end-to-end health probe (`verifyDue`, the same pass
    ///     the on-entry sweep runs — uncapped, no staleness filter, and left to
    ///     the coordinator so `sweepTask` bookkeeping and `cancelAll()` still
    ///     apply to it);
    ///   • the tunnel's exit geo, while a session is up (the hero's evidence line
    ///     and Diagnostics → Exit both read it);
    ///   • every subscription source.
    ///
    /// It ignores `SettingsStore.refreshOnEntry`: that switch governs only what
    /// the app does BY ITSELF.
    private func refreshEverything() async {
        // #460 (audit fix) was: `verifyDue`, which passes `force: false`, so
        // `shouldProbe` refused every node checked in the last two minutes and
        // the gesture did nothing while still showing a spinner. A pull is an
        // EXPLICIT request — the debounce exists to keep AUTOMATIC passes cheap,
        // not to ignore the user. `verifyAll` forces.
        health.verifyAll(store.connections, using: tunnel)
        if tunnel.state.isConnected {
            await ipCheck.refreshExitGeo(via: currentMode)
        }
        await refreshSubscriptions()
        await awaitSweep()
    }

    /// #459: hold the spinner while the coordinator is actually probing, so the
    /// gesture reports real work instead of snapping back on a fire-and-forget.
    /// Gives up on the cap, and the moment the refresh task itself is cancelled.
    private func awaitSweep() async {
        // The sweep is a `Task` the coordinator has only just scheduled; give it
        // the actor before deciding it never started.
        try? await Task.sleep(for: .milliseconds(120))
        let deadline = Date().addingTimeInterval(Self.pullSweepMaxSeconds)
        while !Task.isCancelled, Date() < deadline, sweepInFlight {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private var sweepInFlight: Bool {
        store.connections.contains { health.isChecking($0.id) }
    }

    /// #459: the automatic twin of the pull, on tab entry — the same uncapped
    /// `verifyDue` pass, but debounced by `HealthPolicy.minRecheckSeconds` and
    /// gated on the user's "Check on opening" switch. Connections had no on-entry
    /// sweep at all before this, so that switch governed only the Servers tab and
    /// the foreground transition.
    private func entrySweep() {
        guard settings.refreshOnEntry else { return }
        // #474 was: a sweep on every appearance of this tab. Switching back and
        // forth re-checked everything each time; automatic is once per
        // foreground session now. Pull-to-refresh is unaffected and always runs.
        guard health.claimAutomaticSweep() else { return }
        health.verifyDue(store.connections, using: tunnel)
    }
}

// MARK: - SubscriptionMetaFooter (#363, extracted #457)
//
// Per-group subscription metadata. Every value is server-provided free text, so
// it renders as plain captions with no styling derived from the input.

private struct SubscriptionMetaFooter: View {
    let source: String
    let meta: ConnectionStore.SubscriptionMeta

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {   // #471 was: 3
            line(L10n.subMetaSource.localized(), Self.displaySource(source))
            if let count = meta.serverCount {
                line(L10n.subMetaServers.localized(), String(count))
            }
            line(L10n.subMetaRefresh.localized(), Self.refreshDisplay(meta.refreshInterval))
            // #469 (issue #17): the pull DOES re-fetch every source, but nothing on
            // screen said so after #459 dropped the button and the caption — so the
            // line says WHEN it last happened.
            // #471 was: `subMetaUpdatedPull_fmt` — "Updated %@ · pull down to
            // refresh". A caption instructing the user to perform a standard
            // system gesture, which this codebase's own rule forbids
            // (ServersView: "a line telling the user to perform a standard
            // gesture is exactly the kind of word this pass removes"). The date
            // is the fact; the gesture is not news.
            Text(L10n.subMetaUpdated_fmt.formatted(HealthAge.phrase(Date().timeIntervalSince(meta.lastRefresh))))
                .foregroundStyle(Theme.Palette.textTertiary)
            if let used = meta.used, !used.isEmpty {
                line(L10n.subMetaUsed.localized(), used)
            }
            if let available = meta.available, !available.isEmpty {
                line(L10n.subMetaAvailable.localized(), available)
            }
        }
        .padding(.top, Theme.Metrics.s1)   // #471 was: 4
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(spacing: Theme.Metrics.s2) {   // #471 was: 6
            Text(label).foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(Theme.Typography.caption)   // #471 was: .caption2
    }

    /// #363: a readable host for the source link. Falls back to the raw string.
    private static func displaySource(_ source: String) -> String {
        URL(string: source)?.host ?? source
    }

    /// #363: the stored `#refresh` interval, as the largest whole unit.
    private static func refreshDisplay(_ interval: TimeInterval?) -> String {
        guard let i = interval, i > 0 else { return L10n.subMetaRefreshNever.localized() }
        let s = Int(i)
        let text: String
        switch s {
        case let n where n % 86400 == 0: text = "\(n / 86400)d"
        case let n where n % 3600  == 0: text = "\(n / 3600)h"
        case let n where n % 60    == 0: text = "\(n / 60)m"
        default:                         text = "\(s)s"
        }
        return L10n.subMetaRefreshInterval_fmt.formatted(text)
    }
}

// Both appearance variants.
#if DEBUG
#Preview("Connect — Dark") {
    ConnectionsView(store: ConnectionStore(), tunnel: TunnelManager(),
                    ipCheck: IPChecker(), speed: SpeedTest())
        .preferredColorScheme(.dark)
}
#Preview("Connect — Light") {
    ConnectionsView(store: ConnectionStore(), tunnel: TunnelManager(),
                    ipCheck: IPChecker(), speed: SpeedTest())
        .preferredColorScheme(.light)
}
#endif
