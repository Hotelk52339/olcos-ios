import SwiftUI

// #491: Signal log-reader chrome and native pickers only. Subject routing, exports,
// fetch scheduling and selected-container scope remain with the audited owners.

// #316: single-stack Logs screen. #294's per-source rework made LogsView a
// `TabView` nested inside MainTabView's `TabView`, which rendered a second
// tab strip at the bottom, and every tab stacked its own NavigationStack +
// title + description header + file caption before the first log line.
// Now: ONE `.searchable`, ONE trailing overflow menu; a single header row
// (file name + line count) sits directly on top of the log body. Per-line
// rendering (#276 severity tints, #277 newest-first dated stamps) and the
// per-server container buffers/fetch (#295/#296/#297) are unchanged.
//
// #457: Logs is no longer a TAB — it is a pushed destination that always knows
// what it is about (`LogSubject`), so its own NavigationStack is gone (it would
// nest inside the pusher's) and the 4-way category switch renders only for the
// one unscoped entrance. Everything the old tab needed to be TOLD after the
// fact — which category, which host, whether to auto-fetch — now arrives with
// the push. See `LogSubject` for what that deleted.
//
// #316 was: `isActive` (passed from App.swift, unused since #294) — dropped
// together with the per-tab `LogCategoryTabView` / `ContainerLogsTabView`
// wrappers and the `LogTabHeader` (its description now feeds the empty-state
// hint).

// MARK: - LogSubject (#457)

/// What a pushed Logs screen is ABOUT. Every entrance carries its own context,
/// so the screen is never opened and then steered.
///
/// #457 was: `LogsRouter` + `LogsRouter.Request` + `LogsRouter.fetchingHostID`
/// (App.swift), `MainTabView.onChange { selectedTab = 3 }`,
/// `LogsView.consumeLogsRequest` and `ServersView.containerLogBusyStrip` — the
/// app's only cross-tab back-channel, which existed purely to teleport the user
/// to a tab and re-establish context the caller already held, then draw a busy
/// indicator on a card that had just scrolled off-screen. A push carries all of
/// it for free, and the busy state is now on THIS screen.
enum LogSubject: Equatable {
    /// One connect / reconnect attempt's `.connection` log.
    case connection
    /// A provisioning (SSH) run's `.provisioning` log.
    case provisioning
    /// One server's `podman logs` buffer — the host is pinned, no picker.
    case container(ServerHost)
    /// The unscoped entrance (Settings → "Diagnostics and logs"): every
    /// category, with the switch.
    case all

    /// The category the screen opens on.
    var category: LogCategory {
        switch self {
        case .connection:   return .connection
        case .provisioning: return .provisioning
        case .container:    return .containerLogs
        case .all:          return .connection
        }
    }

    /// The server a `.container` subject is pinned to; nil for every other case.
    var host: ServerHost? {
        if case .container(let host) = self { return host }
        return nil
    }

    /// Only the unscoped entrance offers the 4-way category switch — for every
    /// other subject the control has nothing left to decide.
    var showsCategoryPicker: Bool { self == .all }

    /// The subject sentence, used as the screen title: whose log this is and
    /// what produced it.
    var title: String {
        switch self {
        case .connection:       return L10n.logsSubjectConnection.localized()
        case .provisioning:     return L10n.logsSubjectProvisioning.localized()
        case .container(let h): return L10n.logsSubjectContainer_fmt.formatted(h.label)
        case .all:              return L10n.logsTitle.localized()
        }
    }
}

// MARK: - LogsView

struct LogsView: View {
    /// #457: what this screen is about — fixed by whoever pushed it.
    private let subject: LogSubject
    @ObservedObject private var serverStore: ServerHostStore
    /// #338: needed to spot the primary connection's host (ordered first,
    /// starred) in the container source card's picker.
    @ObservedObject private var connections: ConnectionStore
    // #332 was: @ObservedObject private var store = LogStore.shared — every
    // store publish re-evaluated this whole body (toolbar export string +
    // filtered/attributed log text) even while another tab was selected.
    // The store is now read directly; the body refreshes off the coalesced
    // `revision` via `logRefreshTick`, gated on visibility below.
    private let store = LogStore.shared
    /// #332: bumped from `store.$revision` (≤4/s) while the screen is on
    /// screen — the only log-driven invalidation this view has left.
    @State private var logRefreshTick = 0
    /// #332: skip the tick while the screen is not visible; catch up once in
    /// `onAppear`.
    // #457 was: `isTabVisible` — Logs is a pushed destination now, not a tab.
    @State private var isOnScreen = false
    @StateObject private var provisioner = Provisioner()

    /// #457: seeded from the subject; only the `.all` subject can change it.
    @State private var selection: LogCategory
    @State private var searchText = ""
    /// #457: seeded from a `.container` subject; only the `.all` subject shows
    /// the picker that changes it.
    @State private var selectedHostID: UUID?
    // #338 was: fetching: Bool — now the monotonic fetch phase (nil = idle),
    // mirroring the HostDisplay forward-only pattern; drives text + k/n + bar.
    // #468: which container's `podman logs` to fetch. nil = the host's primary.
    // A multi-protocol host runs one container per protocol, and this screen
    // only ever fetched the primary — so on a host with a jitsi primary and a
    // telemost sibling, the telemost log (where the traffic actually is) could
    // not be read at all.
    @State private var selectedContainerName: String?
    /// #470: the container the running fetch targets — what the phase line
    /// prints. #470 was: `phaseText(1)` printed `selectedHost?.lastContainerName`
    /// (always the primary) while `primaryAction` fetched the picked sibling.
    @State private var fetchingContainerName: String?
    @State private var fetchPhase: Int?
    @State private var alertText: String?  // #297

    /// #338: the three fetch phases (README §2): Connecting… (includes the
    /// scan-first fallback) → the podman command → Receiving output….
    private static let fetchPhaseCount = 3

    // #457 was: init(serverStore:connections:router:) — the router carried the
    // category + host + autofetch AFTER the tab switch. `subject` carries them
    // before the screen exists.
    init(subject: LogSubject,
         serverStore: ServerHostStore,
         connections: ConnectionStore) {
        self.subject = subject
        _serverStore = ObservedObject(wrappedValue: serverStore)
        _connections = ObservedObject(wrappedValue: connections)
        _selection      = State(initialValue: subject.category)
        _selectedHostID = State(initialValue: subject.host?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // #332: reading the tick ties this body to the coalesced refresh
            // (the store itself is no longer observed).
            let _ = logRefreshTick
            if subject.showsCategoryPicker {
                categoryPicker
            }
            // #338 was: serverPicker (nav-area menu) + downloadBar (bare
            // right-aligned text button) — replaced by the source card.
            if selection == .containerLogs {
                containerSourceCard
            }
            fileHeaderRow
            logBody
        }
        // (audit #299) paint the ground from the token: without this the screen
        // keeps the system background and the Palette ground never shows.
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.bg)
        .tint(Theme.Signal.stroke) // #491: match the Settings hierarchy.
        .toolbarBackground(.visible, for: .navigationBar) // #491: no scrolling through bars.
        .toolbarBackground(.visible, for: .tabBar)
        // #457 was: .navigationTitle(L10n.logsTitle) inside this view's own
        // NavigationStack. The title is the SUBJECT now, and it is inline —
        // large-title space belongs to answers, not to a screen name.
        .navigationTitle(subject.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: L10n.logsSearchPlaceholder.localized())
        .toolbar {
            ToolbarItem(placement: .primaryAction) { exportMenu }
        }
        // #332: visibility-gated refresh. `$revision` is already coalesced in
        // LogStore (≤4 bumps/s), so a teardown log storm costs the UI at most
        // four body re-evaluations per second, and zero while off screen.
        .onReceive(store.$revision) { _ in
            if isOnScreen { logRefreshTick &+= 1 }
        }
        .onDisappear { isOnScreen = false }  // #332
        .onAppear {
            isOnScreen = true       // #332
            logRefreshTick &+= 1    // #332: render lines logged while hidden
        }
        // #338: advance the fetch phase forward-only from the provisioner's
        // real progress signals — the podman command starting (SSHRunner
        // step) and the output-received marker; the scan-first fallback's
        // own steps deliberately stay in phase 1 ("Connecting…").
        .onChange(of: provisioner.status) { _, status in
            guard fetchPhase != nil, case .running(let msg) = status else { return }
            if msg.hasPrefix("podman logs") {
                fetchPhase = max(fetchPhase ?? 0, 1)
            } else if msg == L10n.logsPhaseReceiving.localized() {
                fetchPhase = max(fetchPhase ?? 0, 2)
            }
        }
        // #297: surface scan/download failures instead of a silent no-op
        // that looked like the button had frozen.
        .alert(L10n.okPrompt.localized(), isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button(L10n.ok.localized()) { alertText = nil }
        } message: {
            Text(alertText ?? "")
        }
    }

    // MARK: Chrome (#457 — extracted so `body` stays small)

    /// #316: category switch — short labels so four segments never wrap; the
    /// full category names go to VoiceOver. #457: `.all` only.
    // boc #491: native menu uses full localized titles rather than four squeezed segments.
    // #491 was: OlcSegmented with abbreviated labels and fixed horizontal competition.
    private var categoryPicker: some View {
        Picker(L10n.logsTitle.localized(), selection: $selection) {
            ForEach(LogCategory.allCases, id: \.self) { category in
                Text(category.title).tag(category)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Theme.Metrics.rowMinHeight)
        .padding(.horizontal, Theme.Metrics.s4)
        .background(Theme.Palette.card)
    }
    // eoc #491

    private var logBody: some View {
        LogBodyView(
            entries: currentEntries,
            searchText: searchText,
            emptySystemImage: selection.systemImage,
            emptyTitle: L10n.emptyLogsGeneric.localized(),
            emptyHint: emptyHint,
            // #338: container empty state gets a primary "Fetch from {host}" CTA.
            ctaTitle: containerCTAHost.map { L10n.logsFetchFromHost_fmt.formatted($0.label) },
            ctaSystemImage: "arrow.down.doc",
            ctaAction: containerCTAHost.map { host in
                { Task { await primaryAction(host) } }
            }
        )
    }

    // #353 was: `let plain = LogRendering.plain(currentEntries.reversed())`
    // built the entire export string on every toolbar refresh, even though
    // it's only needed when the user opens Share or taps Copy. Both now
    // build it on demand.
    // #432: Share hands iOS a real FILE (named + self-describing header)
    // instead of a bare String, plus "Export all logs" bundles every category
    // + per-server container buffer into one file. Copy prepends the same
    // header so pasted text is just as identifiable. The menu stays enabled
    // whenever ANY log has content, so "Export all" works from an empty view.
    private var exportMenu: some View {
        OlcOverflowMenu(items: [
            .shareFileLazy(L10n.logsShareThisAction.localized(), systemImage: "square.and.arrow.up") {
                LogExport.exportCurrent(title: currentLogTitle, label: currentLogLabel,
                                        displayFileName: currentFileName, entries: currentEntries)
            },
            .shareFileLazy(L10n.logsExportAllAction.localized(), systemImage: "square.and.arrow.up.on.square") {
                LogExport.exportAll(sections: allLogSections)
            },
            .action(L10n.copyAllAction.localized(), systemImage: "doc.on.doc") {
                UIPasteboard.general.string = LogExport.rendered(
                    title: currentLogTitle, displayFileName: currentFileName, entries: currentEntries)
            },
            .divider,
            .action(L10n.clearCategoryAction.localized(), systemImage: "trash", role: .destructive) {
                clearCurrent()
            },
        ])
        .disabled(!hasAnyLogs)
    }

    // MARK: Current category plumbing (#316)

    /// The buffer behind the selected segment — the category buffer, or the
    /// selected host's per-server container buffer (#295).
    private var currentEntries: [LogEntry] {
        if selection == .containerLogs {
            guard let host = selectedHost else { return [] }
            // #476 was: `store.containerEntries[host.logFilePrefix]` — the host's
            // single buffer, shown whichever protocol the picker named.
            return store.containerEntries[selectedContainerKey(host)] ?? []
        }
        return store.entries[selection] ?? []
    }

    /// #476: the buffer key for the container the picker currently names,
    /// falling back to the host's primary — the same resolution the fetch uses,
    /// so what is displayed and what is fetched can never disagree.
    private func selectedContainerKey(_ host: ServerHost) -> String {
        let items = containers(of: host)
        let name = items.first(where: { $0.name == selectedContainerName })?.name
            ?? items.first?.name
            ?? host.lastContainerName
            ?? ""
        return LogStore.containerKey(prefix: host.logFilePrefix, container: name)
    }

    private var currentFileName: String {
        if selection == .containerLogs {
            guard let host = selectedHost else { return "—_container.log" }
            return "\(selectedContainerKey(host))_container.log"
        }
        return selection.logFileName
    }

    /// #432: human name of the selected log for the export header ("Log:" row) —
    /// the category title, or the host's container log.
    private var currentLogTitle: String {
        if selection == .containerLogs {
            guard let host = selectedHost else { return selection.title }
            return "\(host.label) — \(selection.title)"
        }
        return selection.title
    }

    /// #432: filename-safe label for the selected log's export file.
    private var currentLogLabel: String {
        if selection == .containerLogs {
            return "container-\(selectedHost?.logFilePrefix ?? "server")"
        }
        return selection.rawValue
    }

    /// #432: every non-empty log — fixed categories plus each per-server container
    /// buffer — assembled for the combined "Export all" file.
    private var allLogSections: [LogExport.Section] {
        var out: [LogExport.Section] = []
        for cat in LogCategory.allCases where cat != .containerLogs {
            let entries = store.entries[cat] ?? []
            if !entries.isEmpty {
                out.append(.init(title: cat.title, file: cat.logFileName, entries: entries))
            }
        }
        // #476 was: the map was keyed by `logFilePrefix` alone, which no longer
        // matches a buffer key (`<prefix>__<container>`), so every exported
        // container section would have fallen back to the raw key. Match on the
        // prefix the key starts with, and name the protocol the log came from.
        let labels = serverStore.hosts.reduce(into: [String: String]()) { $0[$1.logFilePrefix] = $1.label }
        for (key, entries) in store.containerEntries where !entries.isEmpty {
            let host = labels.first { key == $0.key || key.hasPrefix($0.key + "__") }
            // Split on the FIRST separator: a host label or a container name may
            // itself contain an underscore, and taking the last piece would then
            // print a fragment.
            let container = key.range(of: "__").map { String(key[$0.upperBound...]) } ?? ""
            let name = [host?.value ?? key, container.isEmpty ? nil : container]
                .compactMap { $0 }.joined(separator: " · ")
            out.append(.init(title: "\(name) — \(LogCategory.containerLogs.title)",
                             file: "\(key)_container.log", entries: entries))
        }
        return out
    }

    /// #432: any log with content — gates the whole export menu (so "Export all"
    /// stays reachable from an empty view).
    private var hasAnyLogs: Bool {
        store.entries.values.contains { !$0.isEmpty }
            || store.containerEntries.values.contains { !$0.isEmpty }
    }

    /// #316: LogTabHeader's per-category description moved into the empty state.
    // #457 was: `+ L10n.emptyLogsGenericHint` — "Run an operation in the
    // Connections or Manage VPS tab", which named two tabs (one of which the
    // Russian table left untranslated, and one of which no longer exists) to a
    // reader who is already looking at the one thing this screen is about.
    private var emptyHint: String {
        if selection == .containerLogs {
            return L10n.logsContainerEmptyHint.localized()
        }
        return "\(selection.tabDescription). \(L10n.logsEmptySubjectHint.localized())"
    }

    private func clearCurrent() {
        if selection == .containerLogs {
            if let host = selectedHost {
                // #482 was: host.logFilePrefix — no longer a container buffer key.
                LogStore.shared.clearContainer(serverPrefix: selectedContainerKey(host))
            }
        } else {
            LogStore.shared.clear(category: selection)
        }
    }

    /// #316: the ONE header row, attached to the top of the log body —
    /// `doc.text` + monospaced file name + right-aligned line count.
    // boc #491: filename gets a full line; counts never crush host/container identifiers.
    // #491 was: filename, peers and line count in one horizontal row.
    private var fileHeaderRow: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            Label {
                Text(currentFileName)
                    .font(Theme.Typography.mono)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "doc.text").accessibilityHidden(true)
            }
            HStack {
                peerCountLabel
                Text(L10n.logsLineCount_fmt.formatted(currentEntries.count))
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Theme.Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metrics.s4)
        .background(Theme.Palette.card)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.Palette.separator) }
    }
    // eoc #491

    /// #367: live peer count for the selected container server, parsed from the
    /// server's "Current peers count:" log lines (PR #96).
    @ViewBuilder
    private var peerCountLabel: some View {
        if selection == .containerLogs,
           let host = selectedHost,
           let peers = store.peerCounts[selectedContainerKey(host)] {   // #476
            Text(L10n.logsPeerCount_fmt.formatted(peers))
                .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("·")
                .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption2)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    // MARK: Container source (#295/#296 — unchanged behaviour, new home)

    /// The host whose container log is shown. #457: a `.container` subject pins
    /// it (resolved through the store so a scan's `lastContainerName` update is
    /// picked up); otherwise the explicit selection, falling back to the
    /// last-fetched target (#278), falling back to the first configured host.
    private var selectedHost: ServerHost? {
        if let pinned = subject.host {
            return serverStore.hosts.first(where: { $0.id == pinned.id }) ?? pinned
        }
        if let id = selectedHostID, let h = serverStore.hosts.first(where: { $0.id == id }) {
            return h
        }
        if let target = store.lastContainerTarget,
           let h = serverStore.hosts.first(where: { $0.id == target.hostID }) {
            return h
        }
        return serverStore.hosts.first
    }

    /// #338: hosts for the picker — the primary connection's host first
    /// (starred), the rest in store order.
    private var orderedHosts: [ServerHost] {
        guard let pid = connections.primary?.id,
              let i = serverStore.hosts.firstIndex(where: { $0.lastConnectionID == pid })
        else { return serverStore.hosts }
        var hosts = serverStore.hosts
        let primary = hosts.remove(at: i)
        return [primary] + hosts
    }

    private func hostLabel(_ host: ServerHost) -> String {
        host.lastConnectionID != nil && host.lastConnectionID == connections.primary?.id
            ? "★ \(host.label)" : host.label
    }

    /// #338: the host the empty-state "Fetch from {host}" CTA targets —
    /// container category only, with a host, while idle.
    private var containerCTAHost: ServerHost? {
        guard selection == .containerLogs, fetchPhase == nil else { return nil }
        return selectedHost
    }

    /// #338: source card (README §2) — host chips (≤3; Menu picker beyond) +
    /// one secondary Fetch button, with the monotonic phase progress while a
    /// fetch runs. #457: a subject-pinned host drops the picker entirely.
    private var containerSourceCard: some View {
        OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {   // #471: B9 — 10 → s3
                if serverStore.hosts.isEmpty && subject.host == nil {
                    Text(L10n.logsContainerNoServers.localized())
                        // #471: B9 — prose is step 3. was: .font(.subheadline)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    containerSourceControls
                    if let phase = fetchPhase {
                        fetchProgress(phase)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.2), value: fetchPhase != nil)
    }

    // boc #491: each native selector gets its own line for long hosts and French labels.
    // #491 was: both chip walls and Fetch competed in one HStack.
    private var containerSourceControls: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
            if subject.host == nil {
                hostPicker
            }
            if let pinned = subject.host ?? selectedHost {
                protocolPicker(pinned)
            }
            fetchButton
        }
    }
    // eoc #491

    private func fetchProgress(_ phase: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {   // #471: B9 — 6 → s2
            HStack {
                Text(phaseText(phase))
                    // #471 was: .font(.system(.caption, design: .monospaced))
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(min(phase + 1, Self.fetchPhaseCount))/\(Self.fetchPhaseCount)")
                    .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            OlcProgressBar(fraction: Double(min(phase + 1, Self.fetchPhaseCount))
                                   / Double(Self.fetchPhaseCount))
        }
    }

    /// #468: every container this host runs, primary first. Derived from local
    /// records (`extraConnectionIDs` → carrier → `<base>-<carrier>`), never from
    /// an SSH scan — the picker has to be there before any connection is made.
    /// #470: the derivation itself is `ContainerLogTargets.targets` (pure,
    /// unit-tested); this only attaches the labels. The primary reads its own
    /// protocol name when the app knows it, so the picker says "Jitsi / Yandex
    /// Telemost" rather than "Primary / Yandex Telemost".
    // #470 was: the `guard let base` / `for id in extraConnectionIDs` loop inline
    // here plus `primaryLabel(_ host:)` — both private to the view, untestable.
    private func containers(of host: ServerHost) -> [(name: String, label: String)] {
        ContainerLogTargets.targets(host: host, records: connections.connections).map { t in
            (name: t.name,
             label: t.carrier.map { CarrierTransportMatrix.carrierLabel($0) }
                        ?? L10n.logsContainerPrimary.localized())
        }
    }

    // boc #491: only the controls change. Resolved selections and host-reset semantics stay exact.
    // #491 was: protocols used chips; host count switched chips/menu at three hosts.
    @ViewBuilder
    private func protocolPicker(_ host: ServerHost) -> some View {
        let items = containers(of: host)
        if items.count > 1 {
            Picker(L10n.protocolsSectionHeader.localized(), selection: Binding<String?>(
                get: { items.first(where: { $0.name == selectedContainerName })?.name ?? items[0].name },
                set: { selectedContainerName = $0 }
            )) {
                ForEach(items, id: \.name) { item in
                    Text(item.label).tag(Optional(item.name))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var hostPicker: some View {
        Picker(L10n.logsContainerSelectServer.localized(), selection: Binding(
            get: { selectedHost?.id },
            set: { selectedHostID = $0; selectedContainerName = nil }
        )) {
            ForEach(orderedHosts) { host in
                Text(hostLabel(host)).tag(Optional(host.id))
            }
        }
        .pickerStyle(.menu)
    }
    // eoc #491

    /// #296: always-present action — "Fetch" once the host has a known
    /// container, otherwise "Check server" (scan-first fallback, run inside
    /// `primaryAction`).
    @ViewBuilder
    private var fetchButton: some View {
        if let host = selectedHost {
            let unprobed = host.lastContainerName == nil
            OlcButton(unprobed ? L10n.logsCheckServer.localized() : L10n.logsFetchAction.localized(),
                      systemImage: unprobed ? "antenna.radiowaves.left.and.right" : "arrow.down.doc",
                      role: .secondary,
                      isBusy: fetchPhase != nil) {
                Task { await primaryAction(host) }
            }
        }
    }

    private func phaseText(_ phase: Int) -> String {
        switch phase {
        case 0:  return L10n.logsPhaseConnecting.localized()
        case 1:  return L10n.logsPhaseCommand_fmt.formatted(
                     SettingsStore.shared.containerLogsTailLines,
                     // #470: the container the fetch is actually running against.
                     // #470 was: selectedHost?.lastContainerName ?? "olcrtc"
                     fetchingContainerName ?? selectedHost?.lastContainerName ?? "olcrtc")
        default: return L10n.logsPhaseReceiving.localized()
        }
    }

    /// #296: the button never blocks the UI — it kicks off a `Task` and
    /// returns immediately; `fetchPhase` drives the spinner. #297: every dead
    /// end now sets `alertText` instead of returning silently, so a tap
    /// always ends in either new log lines or a visible reason it didn't.
    private func primaryAction(_ host: ServerHost) async {
        guard let pw = serverStore.password(for: host) else {
            alertText = L10n.alertPasswordMissingShort.localized(); return
        }
        // #338 was: fetching = true … defer { fetching = false }
        // #457 was: also published `router.fetchingHostID` so a card on ANOTHER
        // tab could draw a busy indicator. The fetch is on screen now.
        fetchPhase = 0
        defer { fetchPhase = nil; fetchingContainerName = nil }   // #470 was: defer { fetchPhase = nil }

        var target = host
        if target.lastContainerName == nil {
            // "Check server": probeReadiness(containerName: nil) can never
            // report a container name (#297 was: relied on it to do so, so
            // this branch was a no-op dead end). Scan for an existing olcrtc
            // container instead, mirroring #302's ServersView fold-in.
            do {
                // boc #470: adopt only an UNAMBIGUOUS answer. `.first` of a scan
                // that listed several olcrtc containers (an old install beside a
                // new one, a sibling beside its primary) became the card's
                // primary silently — Stop / Start and every row then targeted
                // it. ServersView puts the same situation to the user as a
                // choice; here the honest move is to say so and send them there.
                // #470 was: guard let found = try await provisioner.scanContainers(on: target, password: pw).first else { … }
                let found = try await provisioner.scanContainers(on: target, password: pw)
                guard let only = found.first else {
                    alertText = L10n.scanNoContainers.localized(); return
                }
                guard found.count == 1 else {
                    alertText = L10n.logsScanAmbiguous_fmt.formatted(found.count); return
                }
                target.lastContainerName = only.name
                serverStore.update(target, password: nil)
                LogStore.shared.log(.provisioning,
                    "→ Logs: \(target.label) had no known container — adopted \(only.name) from the scan")
                // eoc #470
            } catch {
                alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription); return
            }
        }

        // #468 was: `target.lastContainerName` unconditionally — the primary, and
        // only ever the primary. Honour the picker; fall back to the primary when
        // the chosen name does not belong to this host (the host was switched).
        // #470: resolved through the pure helper (tested), and remembered so the
        // phase line prints the command that is actually running.
        // #470 was: let available = containers(of: target).map { $0.name }
        //           let chosen = selectedContainerName.flatMap { available.contains($0) ? $0 : nil }
        //           guard let cname = chosen ?? target.lastContainerName else { return }
        let targets = ContainerLogTargets.targets(host: target, records: connections.connections)
        guard let cname = ContainerLogTargets.resolve(selected: selectedContainerName, in: targets)
        else { return }
        fetchingContainerName = cname
        do {
            _ = try await provisioner.containerLogs(
                on: target, password: pw, containerName: cname,
                tail: SettingsStore.shared.containerLogsTailLines)
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }
}

// MARK: - ContainerLogTargets (#470)

/// #470: the pure derivation behind the #468 protocol picker, lifted out of
/// `LogsView` so it can be unit-tested (Tests/Review470Chunk4Tests.swift): which
/// containers a host runs, and which of them a Fetch targets when the picked
/// name may belong to another host.
enum ContainerLogTargets {
    struct Target: Equatable {
        let name: String
        /// The carrier the container serves when a local record says so; nil for
        /// a primary whose connection the app does not know.
        let carrier: String?
    }

    /// Every container `host` runs, primary first: the primary is
    /// `lastContainerName`; each sibling is `<base>-<carrier>`
    /// (`SSHRunner.siblingContainerName`) for the carrier of the record behind
    /// `extraConnectionIDs`. Local records only, never an SSH scan. No known
    /// primary ⇒ nothing — a sibling name cannot be formed without the base.
    static func targets(host: ServerHost, records: [ConnectionRecord]) -> [Target] {
        guard let base = host.lastContainerName else { return [] }
        var out = [Target(name: base, carrier: carrier(of: host.lastConnectionID, in: records))]
        for id in host.extraConnectionIDs ?? [] {
            guard let c = carrier(of: id, in: records) else { continue }
            out.append(Target(name: SSHRunner.siblingContainerName(base: base, carrier: c), carrier: c))
        }
        return out
    }

    /// The container a Fetch runs against: `selected` when it is one of
    /// `targets`, else the primary — a name picked on another host (or for a
    /// sibling since removed) never leaks into this host's command.
    static func resolve(selected: String?, in targets: [Target]) -> String? {
        if let selected, targets.contains(where: { $0.name == selected }) { return selected }
        return targets.first?.name
    }

    private static func carrier(of id: UUID?, in records: [ConnectionRecord]) -> String? {
        guard let id, let rec = records.first(where: { $0.id == id }),
              case .olcrtc(let p) = rec.details else { return nil }
        return p.carrier
    }
}

// MARK: - Shared rendering helpers

/// Newest-first (#277), colour-coded (#276) rendering of a list of `LogEntry`
/// plus the matching plain-text export, filtered by `searchText`.
@MainActor
enum LogRendering {
    static func filtered(_ entries: [LogEntry], search: String) -> [LogEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = entries.reversed()
        guard !q.isEmpty else { return Array(ordered) }
        return ordered.filter { e in
            e.text.localizedStandardContains(q)
                || LogStore.format(date: e.date).localizedStandardContains(q)
        }
    }

    // boc #332
    /// Rendering cap, independent of the in-memory buffer cap
    /// (`SettingsStore.logBufferSize`): the monolithic `attributed` rebuild is
    /// O(rendered lines) per refresh, so capping what's rendered keeps each
    /// refresh flat no matter how large the buffer grows. Share / Copy / the
    /// on-disk files keep the full history.
    static let renderCap = 500

    /// Newest `renderCap` of an already newest-first list (`filtered` output).
    static func capped(_ entries: [LogEntry]) -> [LogEntry] {
        entries.count > renderCap ? Array(entries.prefix(renderCap)) : entries
    }
    // eoc #332

    static func attributed(_ entries: [LogEntry]) -> AttributedString {
        var attr = AttributedString()
        for e in entries {
            let ts = LogStore.format(date: e.date)
            var stamp = AttributedString("\(ts)  ")
            stamp.foregroundColor = Theme.Palette.textTertiary
            var msg = AttributedString("\(e.text)\n")
            msg.foregroundColor = tint(e.level)
            attr.append(stamp)
            attr.append(msg)
        }
        return attr
    }

    static func plain(_ entries: [LogEntry]) -> String {
        entries.map { "\(LogStore.format(date: $0.date)) \($0.text)" }.joined(separator: "\n")
    }

    static func tint(_ level: LogLineLevel) -> Color {
        switch level {
        case .error: return Theme.Palette.red
        case .warn:  return Theme.Palette.orange
        case .info:  return Theme.Palette.textSecondary
        case .debug: return Theme.Palette.textTertiary
        }
    }
}

/// The scrollable log body: empty state, search-results empty state, or the
/// colour-coded newest-first text.
struct LogBodyView: View {
    let entries: [LogEntry]
    let searchText: String
    let emptySystemImage: String
    let emptyTitle: String
    let emptyHint: String
    // #338: optional CTA on the (non-search) empty state — Container's
    // "Fetch from {host}" primary button.
    var ctaTitle: String? = nil
    var ctaSystemImage: String? = nil
    var ctaAction: (() -> Void)? = nil

    var body: some View {
        let items = LogRendering.filtered(entries, search: searchText)
        if items.isEmpty {
            let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            OlcEmptyState(
                systemImage: isSearching ? "magnifyingglass" : emptySystemImage,
                title: isSearching ? L10n.noSearchResults.localized() : emptyTitle,
                hint: isSearching
                      ? L10n.noSearchResultsHint_fmt.formatted(searchText)
                      : emptyHint,
                ctaTitle: isSearching ? nil : ctaTitle,        // #338
                ctaSystemImage: ctaSystemImage,
                action: ctaAction
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // boc #332: render only the newest `renderCap` lines, with a
            // truncation notice on top (the list is newest-first) pointing at
            // Share/Copy for the full history.
            let visible = LogRendering.capped(items)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.s2) {   // #471: B9 — 8 → s2
                    if visible.count < items.count {
                        Text(L10n.logsRenderTruncated_fmt.formatted(visible.count))
                            .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption2)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Text(LogRendering.attributed(visible))
                        // #471: B9 — the log body is the canonical step-6 case, but
                        // it was drawn at `.caption2`, the seventh step Theme
                        // abolished. Same mono face, now on the scale.
                        // #471 was: .font(.system(.caption2, design: .monospaced))
                        .font(Theme.Typography.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            // eoc #332
        }
    }
}

// #316 was: `LogTabHeader` (description + "File: x.log" caption above every
// tab), `LogCategoryTabView` (per-category NavigationStack + searchable +
// toolbar) and `ContainerLogsTabView` (the same plus host picker, download
// bar and the #296/#297 fetch logic) — all folded into the single-stack
// `LogsView` above; the fetch logic moved verbatim.

// #340: both appearance variants. #457: Logs is pushed now, so the previews
// wrap it in the NavigationStack its pusher supplies.
#if DEBUG
#Preview("Logs — Dark") {
    NavigationStack {
        LogsView(subject: .all, serverStore: ServerHostStore(), connections: ConnectionStore())
    }
    .preferredColorScheme(.dark)
}
#Preview("Logs — Light") {
    NavigationStack {
        LogsView(subject: .connection, serverStore: ServerHostStore(), connections: ConnectionStore())
    }
    .preferredColorScheme(.light)
}
#endif
