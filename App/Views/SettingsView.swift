import SwiftUI

// #491: Signal native Forms; presentation changes only. Store/secret/probe owners stay intact.
// #491 was: flat Advanced controls and unstyled native section rows.

// MARK: - SettingsView
//
// #457: the THIRD and last tab, ordered by consequence. Surfaces values that
// used to be hardcoded, plus the two sections the deleted Config tab held.
//
// #460 (screenshot findings 10, 11, 13, 20, 21): regrouped BY SUBJECT, and
// every explanation now sits with the control it explains. A `Form` footer
// belongs to its whole SECTION, so an explanation written for one control kept
// rendering under an unrelated row four positions down; the fix, applied
// everywhere, is a note row (`TunnelSettingsNote`) directly under its control,
// and a footer only where it explains the whole section.
//
// #471 (design pass D): the list had reached fourteen sections and ~35
// controls, and the ones a *user of a VPN app* changes were interleaved with
// the ones a *server admin or a developer* tunes — a start timeout above a
// language picker, a codec batch size above "Check for updates". One rule
// decides where a control lives now: if changing it is part of USING the app it
// is on this list; if it is tuning, it is behind the single "Advanced" push
// (`SettingsAdvancedView`, below). Six sections, ordered by how often they are
// touched:
//
//   Tunnel · When the app opens · Staying connected · Appearance · Updates · About
//
// Nothing was deleted from the app: every control that left this list is on
// Advanced, one tap away. What WAS deleted is dead machinery — the preset chip
// rows under the numeric fields (the defaults ARE the presets, and "Reset all
// settings" restores them) and the `ScrollViewReader` left behind by #470's
// font slider.
//
// #471 was: tunnelGroup · connectionGroup (start + stay-connected) ·
// networkGroup (SOCKS5 + DNS + vp8channel) · serversSection · checksGroup
// (IP check + speed test) · logsSection · appGroup (updates + appearance) ·
// infoSection — eight `@ViewBuilder` groups holding fourteen sections.
//
// Reads/writes go through SettingsStore.shared, which mirrors UserDefaults.
// SwiftUI rebinds on @Published changes automatically.

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    // #300: live tunnel state, needed to tell "port busy because our tunnel
    // reserved it" apart from "port busy because something else holds it".
    // #471: the port check itself moved to `SettingsAdvancedView`; what this
    // tab still needs `tunnel` for is the mode picker's lock, the VPN
    // capability probe — and handing it to the Advanced screen.
    @ObservedObject var tunnel: TunnelManager
    /// #420: bot registry (shared with Servers). Managed in `BotsSettingsView`.
    @ObservedObject var botStore: BotStore
    /// #457: the two stores the pushed `LogsView(subject: .all)` needs — the
    /// per-server container buffers and the host picker's "primary" star.
    @ObservedObject var serverStore: ServerHostStore
    @ObservedObject var connections: ConnectionStore
    /// #475: the update checker, so "Check now" and the daily check are the same
    /// object and cannot disagree about what is available. Declared LAST because
    /// the memberwise initialiser follows declaration order, and every existing
    /// call site keeps its argument order.
    @ObservedObject var updateChecker: UpdateChecker

    /// #455: confirm before "Reset all settings" — restores defaults (incl.
    /// tunnel mode → proxy), which unsticks any state that would otherwise
    /// need an app reinstall.
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            // #460: the modifier stack is split across two small wrappers,
            // the idiom ConnectionsView/ServersView adopted after this
            // repo's SwiftUI type-checker failures — no single expression
            // carries the whole chain.
            // #471 was: wrapped in `ScrollViewReader { proxy in … }`, and
            // `formWiring(_:proxy:)` took that proxy — the scroll-back hack for
            // the font slider #470 deleted. Nothing read it any more.
            formWiring(formChrome(settingsForm))
        }
    }

    /// #471: six children, in the order a user meets them. Keep it under ten:
    /// `ViewBuilder` has no eleventh-child overload.
    private var settingsForm: some View {
        Form {
            TunnelSettingsModeSection(tunnel: tunnel)
            TunnelSettingsOnOpenSection()
            stayConnectedSection
            appearanceSection
            updatesSection
            aboutSection
            resetSection // #491
        }
    }

    private func formChrome(_ content: some View) -> some View {
        content
            // (audit #299) paint the ground from the token: without this the
            // Form keeps the system grouped background, so a non-default scheme
            // never showed Theme.Palette.bg on this tab.
            .signalFormChrome() // #491: shared native ground, separators, and readable row sizing.
            // #460 (audit fix): the same defect Connections had. Hiding the
            // scroll background and painting our own leaves both system bars on
            // their transparent scroll-edge appearance, so scrolled content draws
            // THROUGH them — a title clipped under the nav bar, the last row cut
            // by the tab bar. Visibility only: each bar keeps its system material,
            // so this tab still looks like the others.
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .tabBar)
            // #460: requirement 27 — the same gesture as the other two tabs.
            .refreshable { await refreshSettings() }
            // #457 (was ConfigView's `.task`): side-effect free — only reads
            // existing VPN preferences (a past save proves the entitlement),
            // never pops the system consent alert. Drives the VPN chip's
            // enabled state in the mode section.
            .task { await tunnel.vpn.probeCapability() }
    }

    private func formWiring(_ content: some View) -> some View {
        content
            // #455: reset-to-defaults confirm (unsticks a wedged state
            // without reinstalling; connections and servers are kept).
            .confirmationDialog(L10n.resetSettingsConfirmTitle.localized(),
                                isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button(L10n.resetSettingsAction.localized(), role: .destructive) {
                    SettingsStore.shared.reset()
                    Haptics.success()
                }
                Button(L10n.cancel.localized(), role: .cancel) { }
            } message: {
                Text(L10n.resetSettingsConfirmBody.localized())
            }
            .navigationTitle(L10n.settingsTitle.localized())
            // #471 was: a keyboard `ToolbarItemGroup` with a "Done" button. No
            // row on this list opens a keyboard any more — every text field
            // moved to Advanced, which carries that toolbar now.
    }

    // MARK: Pull to refresh (#460)

    /// #460: requirement 27 — "the swipe should refresh everything on whichever
    /// screen I am on". Settings owns no server state; what DOES go stale while
    /// this screen is open is whether this install is allowed to run the system
    /// VPN at all (a re-signed sideload loses that entitlement, and the mode
    /// picker's VPN chip is gated on it), and that is re-read for real.
    /// #471 was: also `runPortCheck()`. The port field and its verdict moved to
    /// Advanced with the rest of the proxy rows — refreshing a check whose
    /// result is on another screen is a spinner that shows nothing.
    private func refreshSettings() async {
        await tunnel.vpn.probeCapability()
    }

    // MARK: Staying connected (#460)

    // #471: two rows, both about a session that is already up — keep it alive
    // while the app is in the background, and move it to another protocol when
    // the one in use stops answering.
    // #471 was: this section also held the tunnel-check interval and
    // "Auto-restart a stuck session" (both on Advanced now — an interval and an
    // opt-in experiment, not decisions), and the background row was labelled
    // "Background work (audio)": the mechanism, which is not the user's concern.
    private var stayConnectedSection: some View {
        Section {
            Toggle(L10n.settingsBackgroundLabel.localized(), isOn: $settings.backgroundAudio)
            TunnelSettingsNote(text: L10n.backgroundAudioNote.localized())
            // #471: the SAME stored value the Connect tab's card binds — one
            // setting, two honest entry points (like Wi-Fi in Control Center and
            // in Settings). That card only appears once the server has a second
            // protocol; this row is always reachable.
            Toggle(L10n.configFailoverToggle.localized(), isOn: $settings.autoFailover)
            TunnelSettingsNote(text: L10n.connectAutoSwitchHint.localized())
        } header: {
            SignalSectionHeader(L10n.settingsSectionStayConnected.localized()) // #491
        } footer: {
            // #470: both rows are in-app-proxy machinery — `TunnelManager`
            // starts the audio keeper and the failover switch only when
            // `activeMode == .proxy`; in VPN mode the core runs in the appex and
            // neither ever fires. The Connections failover card already says so
            // with this sentence; these notes promised otherwise.
            // #471 was: `.font(.caption2)` — a Form footer already is a caption.
            Text(L10n.configFailoverProxyOnlyFooter.localized())
        }
        .signalFormRows() // #491
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            Picker(L10n.languageLabel.localized(), selection: languageBinding) {
                ForEach(AppLocale.allCases) { locale in
                    Text(locale.displayName).tag(locale)
                }
            }

            // #340: appearance scheme — System / Light / Dark (applied via
            // preferredColorScheme in App.swift). #343: relabeled "Theme" —
            // the section header carries "Appearance" now.
            // #456 was: "+ Gray, a real fourth colour scheme". Gray is gone (a
            // fourth scheme diluted the palette and forced a full TabView rebuild
            // to refresh Theme's tokens); the picker iterates allCases, so it
            // dropped out of this list with the case, and Light is now tuned to
            // be genuinely good rather than a fallback.
            // #471: the DEFAULT is System now (`SettingsStore.Defaults`) — a
            // premium iOS app follows the device unless it is told otherwise.
            Picker(L10n.themeLabel.localized(), selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            // #337: screenshot-safe mode — masks IPs in the Connections
            // diagnostics rows and on VPS cards (display-only; copy + Logs
            // stay real).
            // #471: it used to be the last row of an "IP check" section, under a
            // footer about the SPEED TEST. It is a privacy switch — how the app
            // looks in a screenshot — not a diagnostic knob, so it sits with the
            // other two "how the app presents itself" rows.
            Toggle(L10n.maskIPsLabel.localized(), isOn: $settings.maskIPs)

            // #470 was: the font-size row, slider and live preview. The app now
            // follows the device's Text Size (iOS › Display & Brightness) instead
            // of duplicating that setting behind a custom slider.
        } header: {
            // #343 was: sectionFont ("Font"). #470: and the font control itself
            // is gone — the section is language + theme.
            SignalSectionHeader(L10n.appearanceLabel.localized()) // #491
        } footer: {
            // #460: wires `maskIPsFooter`, which #337 wrote and left unused.
            // #471 was: `.font(.caption2)`.
            Text(L10n.maskIPsFooter.localized())
        }
        .signalFormRows() // #491
    }

    /// #471: extracted so the language `Picker` stays one short expression — an
    /// inline `Binding(get:set:)` inside a `Picker` inside a `Section` is the
    /// shape that has broken this repo's type-checker before.
    private var languageBinding: Binding<AppLocale> {
        Binding(get: { AppLocale(rawValue: settings.language) ?? .english },
                // #486 was: direct assignment without selection feedback.
                set: { locale in
                    guard settings.language != locale.rawValue else { return }
                    Haptics.tap()
                    settings.language = locale.rawValue
                })
    }

    // MARK: Updates (#460)

    // #460 was: the update toggle sat in "Connection" with no explanation at
    // all, while `updateCheckFooter` — written for exactly this row — sat unused
    // in the L10n table. Own section, own footer, one row.
    private var updatesSection: some View {
        Section {
            // #360: opt-out of the daily, anonymous GitHub-Releases update check.
            Toggle(L10n.updateCheckLabel.localized(), isOn: $settings.updateCheckEnabled)
            // #475: the daily check waits 24 h and says nothing when there is
            // nothing to say. Asking directly is a different act and gets an
            // answer either way.
            updateCheckNowRow
        } header: {
            SignalSectionHeader(L10n.settingsSectionUpdates.localized()) // #491
        } footer: {
            // #471 was: `.font(.caption2)`.
            Text(L10n.updateCheckFooter.localized())
        }
        .signalFormRows() // #491
    }

    // boc #475
    @ViewBuilder
    private var updateCheckNowRow: some View {
        Button {
            Task { await updateChecker.checkNow() }
        } label: {
            HStack {
                Text(L10n.updateCheckNowAction.localized())
                Spacer()
                if updateChecker.manual == .checking { ProgressView() }
            }
        }
        .disabled(updateChecker.manual == .checking)
        updateCheckNowResult
    }

    /// The answer, when there is one. A newer release opens the update sheet
    /// instead, so this only ever reports "nothing new" or "could not ask".
    @ViewBuilder
    private var updateCheckNowResult: some View {
        switch updateChecker.manual {
        case .upToDate(let version):
            TunnelSettingsNote(text: L10n.updateUpToDate_fmt.formatted(version))
        case .failed:
            TunnelSettingsNote(text: L10n.updateCheckFailed.localized())
        case .idle, .checking:
            EmptyView()
        }
    }
    // eoc #475

    // MARK: About (#471 — was `infoSection`)

    // #471: the version, the unscoped way into the log reader, the one door to
    // everything a user does not tune, and the reset. Three of the four are
    // navigation; the fourth is the only destructive thing in Settings, and it
    // now looks like every other destructive row in iOS.
    private var aboutSection: some View {
        Section {
            versionRow
            // #457: Logs stopped being a tab. This is its unscoped entrance —
            // every OTHER way in is a push from the thing the log explains
            // (a connection attempt, a provisioning run, one server's container).
            // #460 (finding 21) was: `settingsOpenLogsRow` = "Diagnostics and
            // logs" — a third destination sharing the word "Diagnostics" with a
            // Connections card and a Settings section. It opens the log reader,
            // so it says that.
            // #471: it stays on the MAIN list even though the log knobs moved to
            // Advanced — reading a log is a support flow, resizing its buffer is
            // not.
            NavigationLink {
                LogsView(subject: .all, serverStore: serverStore, connections: connections)
            } label: {
                SignalSettingsLabel(L10n.settingsViewLogsRow.localized(), systemImage: "doc.text") // #491
            }
            NavigationLink {
                SettingsAdvancedView(tunnel: tunnel, botStore: botStore)
            } label: {
                SignalSettingsLabel(L10n.settingsAdvancedRow.localized(), systemImage: "slider.horizontal.3") // #491
            }

        } header: {
            SignalSectionHeader(L10n.settingsSectionAbout.localized()) // #491
        }
        .signalFormRows() // #491
    }

    // boc #491: destructive reset is visually separated from navigation.
    // #491 was: reset shared the About group with version and support links.
    private var resetSection: some View {
        Section {
            // #455: a reset that gets the app out of any wedged state (e.g. a
            // tunnel mode that can't be switched back) without reinstalling.
            // #471 was: `OlcButton(role: .danger, fillWidth: true)` — a filled
            // red button inside a grouped list, which is the one place iOS
            // already has a convention for "this row destroys something".
            Button(L10n.resetSettingsAction.localized(), role: .destructive) {
                showResetConfirm = true
            }
        } footer: {
            Text(L10n.resetSettingsFooter.localized())
        }
        .signalFormRows()
    }
    // eoc #491

    private var versionRow: some View {
        HStack {
            Text("olcOS")
                .foregroundStyle(.secondary)
            Spacer()
            Text(appVersion)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v).\(b)"
    }
}

// MARK: - SettingsAdvancedView (#471)
//
// The one push off the main Settings list, holding everything a server admin or
// a developer tunes and a user of a VPN app never opens: the connection
// intervals, the local SOCKS listener, the resolver, the video-transport
// values, which service answers a check, and the log knobs.
//
// Nothing here is new — every row below was on the main Settings list before
// #471, scattered through fourteen sections it shared with the rows people
// actually use. The conventions are the parent's: a `Form` on the token ground,
// a `TunnelSettingsNote` under each control it explains, a footer only where it
// covers the whole section, and no chain long enough to worry the type-checker.
//
// #471 was: `socksSection`, `dnsRowSection`, `transportSection`, `startSection`,
// half of `stayConnectedSection`, `ipCheckSection`, `speedTestSection`,
// `logsSection` and `serversSection` — all within the first screenfuls of the
// Settings tab.

struct SettingsAdvancedView: View {
    @ObservedObject private var settings = SettingsStore.shared
    /// #313: the port check compares against the port the session actually
    /// bound (`tunnel.boundPort`), not the configured one.
    @ObservedObject var tunnel: TunnelManager
    /// #471: the bot registry, passed through until its row finds its real home
    /// (see `serversSection`).
    @ObservedObject var botStore: BotStore

    // boc #491: pushed destinations are real observing views, not captured View values.
    // #491 was: advancedPage(_ content: some View, title:) received a prebuilt
    // section from an off-screen directory. Bindings could still write while
    // conditional rows/verdicts depended on that ancestor rebuilding the destination.
    enum Page: Equatable {
        case directory, connection, proxy, transport, diagnostics, logs

        var titleKey: L10n {
            switch self {
            case .directory: return .settingsAdvancedRow
            case .connection: return .settingsSectionConnection
            case .proxy: return .settingsSectionProxy
            case .transport: return .sectionVP8
            case .diagnostics: return .diagnosticsTitle
            case .logs: return .sectionLogs
            }
        }
    }

    let page: Page

    init(tunnel: TunnelManager, botStore: BotStore, page: Page = .directory) {
        self.tunnel = tunnel
        self.botStore = botStore
        self.page = page
    }
    // eoc #491

    @State private var portCheck: PortAvailability.PortState?
    @State private var socksPassInput: String = ""
    @State private var socksPassLoaded = false
    @FocusState private var anyFieldFocused: Bool

    var body: some View {
        advancedWiring(advancedChrome(advancedForm))
    }

    /// Seven children — under the ten-child `ViewBuilder` ceiling, ordered by
    /// what a value acts on: the session, the listener, the resolver, the
    /// codec, the checks, the logs, the registry.
    // boc #491: a small native directory replaces a seven-section wall of knobs.
    // #491 was: connectionSection, proxySection, dnsRowSection, transportSection,
    // diagnosticsSection, logsSection and serversSection all expanded in one Form.
    private var advancedForm: some View {
        Form {
            if page == .directory {
                directorySections
            } else {
                editorSection
            }
        }
    }

    @ViewBuilder
    private var directorySections: some View {
        Section {
            NavigationLink {
                SettingsAdvancedView(tunnel: tunnel, botStore: botStore, page: .connection)
            } label: {
                SignalSettingsLabel(L10n.settingsSectionConnection.localized(), systemImage: "timer")
            }
            NavigationLink {
                SettingsAdvancedView(tunnel: tunnel, botStore: botStore, page: .proxy)
            } label: {
                SignalSettingsLabel(L10n.settingsSectionProxy.localized(), systemImage: "network")
            }
            dnsLink
            NavigationLink {
                SettingsAdvancedView(tunnel: tunnel, botStore: botStore, page: .transport)
            } label: {
                SignalSettingsLabel(L10n.sectionVP8.localized(), systemImage: "video")
            }
        } header: {
            SignalSectionHeader(L10n.settingsSectionConnection.localized())
        }
        .signalFormRows()
        Section {
            NavigationLink {
                SettingsAdvancedView(tunnel: tunnel, botStore: botStore, page: .diagnostics)
            } label: {
                SignalSettingsLabel(L10n.diagnosticsTitle.localized(), systemImage: "waveform.path.ecg")
            }
            NavigationLink {
                SettingsAdvancedView(tunnel: tunnel, botStore: botStore, page: .logs)
            } label: {
                SignalSettingsLabel(L10n.sectionLogs.localized(), systemImage: "doc.text")
            }
        } header: {
            SignalSectionHeader(L10n.diagnosticsTitle.localized())
        }
        .signalFormRows()
        serversSection
    }

    /// Each editor evaluates these sections in its own body, which observes
    /// settings/tunnel and owns portCheck, password draft, and keyboard focus.
    /// No new service is constructed; the same injected stores cross each push.
    @ViewBuilder
    private var editorSection: some View {
        switch page {
        case .directory: EmptyView()
        case .connection: connectionSection
        case .proxy: proxySection
        case .transport: transportSection
        case .diagnostics: diagnosticsSection
        case .logs: logsSection
        }
    }
    // eoc #491

    private func advancedChrome(_ content: some View) -> some View {
        content
            // (audit #299) token ground, like the parent Settings Form.
            .signalFormChrome() // #491: shared native ground, separators, and readable row sizing.
            .onDisappear { socksPassLoaded = false }
    }

    // #491: the visible editor owns both the title and its keyboard focus.
    private func advancedWiring(_ content: some View) -> some View {
        content
            .navigationTitle(page.titleKey.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if page != .directory {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(L10n.done.localized()) { anyFieldFocused = false }
                    }
                }
            }
    }

    // MARK: Connection (#471)

    // #471: the three values that TIME a session — how long to wait for it to
    // come up, how often to prove it still passes traffic, and whether to
    // restart it the moment it stops. Two intervals and an opt-in experiment
    // (`earlyRestartOnWedge` is off by default and brittle by its own
    // description), which is exactly why none of them is on the main list.
    // #471 was: `startSection` (header "Starting a connection") plus two rows of
    // `stayConnectedSection`, three sections apart.
    private var connectionSection: some View {
        Section {
            numericField(L10n.startTimeoutLabel.localized(), value: $settings.startTimeoutSeconds,
                         unit: L10n.unitSeconds.localized(),   // #455: was hardcoded "s"
                         note: L10n.startTimeoutNote.localized())
            numericField(L10n.tunnelCheckLabel.localized(), value: $settings.keepAliveSeconds,
                         unit: L10n.unitSeconds.localized(),
                         note: L10n.footerKeepAlive.localized())
            // #440: opt-in early restart of a stuck session (off by default).
            Toggle(L10n.earlyRestartWedgeLabel.localized(), isOn: $settings.earlyRestartOnWedge)
            TunnelSettingsNote(text: L10n.earlyRestartWedgeNote.localized())
        } header: {
            SignalSectionHeader(L10n.settingsSectionConnection.localized()) // #491
        }
        .signalFormRows() // #491
    }

    // MARK: Proxy (#471 — was the "SOCKS5" section on the main list)

    // #343 was: two sections (port+check / auth) with three stacked footers —
    // one section now.
    // #460: the section footer said "Port change takes effect on the next
    // connection" and rendered under the PASSWORD field whenever auth was on —
    // the same fault as findings 10/11/20, one screen down. Both sentences are
    // notes on their own rows now, and `socksAuthFooter` explains the auth
    // toggle again instead of nothing explaining it.
    // #471: the header names the thing, not the wire protocol.
    // #474: and the address someone types into another app lives here, beside
    // the port it is built from, instead of as a bare number on the first
    // screen of Settings.
    @ViewBuilder
    private var proxySection: some View {
        Section {
            portRow
            proxyAddressRow   // #474
            TunnelSettingsNote(text: L10n.socksPortChangeNote.localized())
            // #460 was: the whole check ran inline in this button's action — it
            // is a method now, so one code path answers the question.
            Button { runPortCheck() } label: { portCheckLabel }
            Toggle(L10n.localSocksAuthLabel.localized(), isOn: $settings.localSocksAuthEnabled)
            TunnelSettingsNote(text: L10n.socksAuthFooter.localized())
            if settings.localSocksAuthEnabled {
                authFields
            }
        } header: {
            SignalSectionHeader(L10n.settingsSectionProxy.localized()) // #491
        }
        // #470: the verdict describes the port that was CHECKED. Typing a new
        // one or tapping "Random port" left "free" / "in use" beside a port
        // nobody had checked — the next connect could then fail with OLC-1026.
        .signalFormRows() // #491
        .onChange(of: settings.socksPort) { _, _ in portCheck = nil }
    }

    // #474: the number alone answers nothing — what goes into another app's
    // proxy settings is host AND port. Printed as one selectable line so it can
    // be copied rather than transcribed, and stated for what it is: a local
    // address that only answers while the tunnel is up in proxy mode.
    private var proxyAddressRow: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text(L10n.settingsProxyAddressLabel.localized())
            // #482 was: settings.socksPort — edits apply only at the next connect.
            Text(Self.proxyAddress(boundPort: tunnel.boundPort, configuredPort: settings.socksPort)) // #482
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
                .textSelection(.enabled)
        }
    }

    // #482: the live listener is authoritative; configuration is only a fallback.
    nonisolated static func proxyAddress(boundPort: Int?, configuredPort: Int) -> String {
        "127.0.0.1:\(boundPort ?? configuredPort)"
    }

    // boc #491: label and port controls no longer compete with long localized text.
    // #491 was: label, 90pt field, and custom Random button on a single line.
    private var portRow: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            Text(L10n.settingsPortLabel.localized())
            HStack {
                TextField("8808", value: $settings.socksPort, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .focused($anyFieldFocused)
                    .monospacedDigit()
                    .accessibilityLabel(L10n.settingsPortLabel.localized())
                Button(L10n.randomPortAction.localized()) {
                    settings.socksPort = Int.random(in: 1024...65535)
                }
                .buttonStyle(.borderless)
            }
        }
    }
    // eoc #491

    /// #471: extracted from the section body — the `SecureField`'s two lifecycle
    /// modifiers on top of the section's other five children was one expression
    /// more than this repo's type-checker budget likes.
    @ViewBuilder
    private var authFields: some View {
        TextField(L10n.socksUserLabel.localized(), text: $settings.localSocksUser)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        SecureField(L10n.socksPassLabel.localized(), text: $socksPassInput)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onAppear {
                if !socksPassLoaded {
                    socksPassInput = settings.localSocksPass
                    socksPassLoaded = true
                }
            }
            .onChange(of: socksPassInput) { _, v in
                settings.localSocksPass = v
            }
    }

    private var portCheckLabel: some View {
        HStack {
            Image(systemName: "checkmark.circle")
            Text(L10n.checkPortAction.localized())
            Spacer()
            if let r = portCheck {
                switch r {
                // #317: ad-hoc .green/.red → Theme.Palette status tokens (#258 invariant)
                // #317 was: .foregroundStyle(.green) / .foregroundStyle(.red)
                case .free:      Text(L10n.portFree.localized()).foregroundStyle(Theme.Palette.green)
                case .busyOurs:  Text(L10n.portInUseByOlcrtc.localized()).foregroundStyle(Theme.Palette.green)
                case .busyOther: Text(L10n.portBusy.localized()).foregroundStyle(Theme.Palette.red)
                }
            }
        }
    }

    private func runPortCheck() {
        let port = UInt16(settings.socksPort)
        // #313: compare against the port the tunnel actually bound
        // (`tunnel.boundPort`, snapshotted at connect; nil unless a
        // session is live). The #300 gate compared two reads of the
        // *configured* port — always equal — so while connected, any
        // value typed into the field was labeled "in use by olcrtc
        // tunnel" even though the tunnel still holds the old port.
        // #313 was: let tunnelHoldsPort = tunnel.state.isConnected
        //     && TunnelManager.socksPort == settings.socksPort
        let tunnelHoldsPort = tunnel.boundPort == settings.socksPort
        let result = PortAvailability.state(port, tunnelHoldsPort: tunnelHoldsPort)
        portCheck = result
        // #287: one L10n key per concept instead of assembling the line
        // from fragments (which drifted between code paths / languages).
        // #300: three states → three log lines.
        let logLine: String
        switch result {
        case .free:      logLine = L10n.logPortFree_fmt.formatted(settings.socksPort)
        case .busyOther: logLine = L10n.logPortBusyOther_fmt.formatted(settings.socksPort)
        case .busyOurs:  logLine = L10n.logPortBusyOlcrtc_fmt.formatted(settings.socksPort)
        }
        LogStore.shared.log(.connection, logLine)
    }

    // MARK: DNS (#343 — submenu)

    // #343 was: dnsSection — a top-level OlcChipPicker "chip wall" over all
    // presets + the free-form field (the MegaFon/Yota shared value also made
    // duplicate ForEach IDs there). Now a summary NavigationLink row; the
    // presets/footer live in DNSSettingsView, same pattern as the IP sources.
    // boc #491: DNS summary gets a full second line instead of a clipped trailing value.
    // #491 was: dnsRowSection with one-line trailing dnsSummary.
    private var dnsLink: some View {
        NavigationLink {
            DNSSettingsView()
        } label: {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                SignalSettingsLabel(L10n.sectionDNS.localized(), systemImage: "globe")
                Text(dnsSummary)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    // eoc #491

    /// "Yandex · 77.88.8.8:53" when the value matches a preset, else the raw value.
    private var dnsSummary: String {
        let v = settings.dnsServer
        let presets: [(String, String)] = AppConstants.dnsPresets.map { ($0.label, $0.value) }
            + AppConstants.ruCarrierDnsPresets.map { ($0.label.localized(), $0.value) }
        if let hit = presets.first(where: { $0.1 == v }) { return "\(hit.0) · \(v)" }
        return v
    }

    // MARK: Numeric field helper
    //
    // Replaces Stepper: a TextField for direct entry. Out-of-range entries are
    // auto-clamped by SettingsStore.didSet.
    //
    // #471 was: the field, then an `OlcChipPicker` row of "preset" values, then
    // the note — a custom control mounted inside a native Form row, six times
    // over. The field and its unit are enough, and those presets were the
    // defaults, which "Reset all settings" already restores.

    @ViewBuilder
    private func numericField(_ title: String,
                              value: Binding<Int>,
                              unit: String? = nil,
                              note: String? = nil) -> some View {
        // #491 was: a fixed 80pt input squeezed the title and unit on one line.
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("", value: value, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .monospacedDigit()
                    .focused($anyFieldFocused)
                    .accessibilityLabel(title)
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
        }
        // #460 (findings 10/11): an explanation that belongs to ONE control
        // renders under that control, not in a section footer four rows down.
        if let note {
            TunnelSettingsNote(text: note)
        }
    }

    // MARK: Video transport

    private var transportSection: some View {
        Section {
            numericField(L10n.vp8FpsLabel.localized(), value: $settings.vp8FPS)
            numericField(L10n.vp8BatchLabel.localized(), value: $settings.vp8BatchSize)
        } header: {
            SignalSectionHeader(L10n.sectionVP8.localized()) // #491
        } footer: {
            // #460 (finding 12) was: `vp8Footer`, which opened with the gomobile
            // symbol "MobileSetVP8Options" and the literal "transport=vp8channel".
            // Both rows here are that one subject, so a section footer is still
            // the right place — only the words changed.
            // #471 was: `.font(.caption2)`.
            Text(L10n.vp8Note.localized())
        }
        .signalFormRows() // #491
    }

    // MARK: Diagnostics (#471)

    // #460 (findings 20/21) was: one "Diagnostics" section holding IP sources,
    // the speed-test provider AND "Hide IP addresses", with a footer about the
    // SPEED TEST rendering under the IP toggle — so #460 split it into two
    // sections on the main list.
    // #471: "Hide IP addresses" is a privacy switch and went to Appearance; what
    // is left is two source pickers — WHICH service answers a check — a fallback
    // for a blocked network, not a preference. One section again, both rows
    // genuinely one subject, and the footer covers the row above it.
    private var diagnosticsSection: some View {
        Section {
            ipSourcesRow
            Picker(L10n.sectionSpeedProvider.localized(), selection: $settings.speedTestProviderID) {
                ForEach(AppConstants.SpeedTest.providers) { p in
                    Text(Self.providerName(p)).tag(p.id)
                }
            }
            // #460 (finding 19): the picker used to show the provider's `label`,
            // which is a HOSTNAME — a menu picker prints its value on one line,
            // so it arrived clipped ("speed.cl…are.com"). The name identifies the
            // provider; the host is data and gets a full line of its own.
            Text(speedProviderHost)
                // #471 was: `.font(.system(.caption, design: .monospaced))`.
                .font(Theme.Typography.mono)
                .foregroundStyle(.secondary)
        } header: {
            SignalSectionHeader(L10n.diagnosticsTitle.localized()) // #491
        } footer: {
            // #471 was: `.font(.caption2)`.
            Text(L10n.speedProviderFooter.localized())
        }
        .signalFormRows() // #491
    }

    private var ipSourcesRow: some View {
        NavigationLink {
            IPSourcesSettingsView()
        } label: {
            HStack {
                SignalSettingsLabel(L10n.sectionIPSources.localized(), systemImage: "network") // #491
                Spacer()
                Text("\(settings.enabledIPSources.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var speedProviderHost: String {
        AppConstants.SpeedTest.provider(id: settings.speedTestProviderID).host
    }

    /// #460: display name for a speed-test provider. Two of the three labels
    /// already carry the brand in parentheses ("proof.ovh.net (OVH)"); otherwise
    /// take the host's registrable label ("speed.cloudflare.com" → "Cloudflare").
    /// Derived, not a hardcoded brand table — a new provider needs no change
    /// here, and a brand name is the same word in every language.
    private static func providerName(_ p: SpeedTestProvider) -> String {
        if let open = p.label.firstIndex(of: "("),
           let close = p.label.lastIndex(of: ")"), open < close {
            let inside = p.label[p.label.index(after: open)..<close]
            let trimmed = inside.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        let parts = p.host.split(separator: ".")
        guard parts.count >= 2 else { return p.host }
        let name = String(parts[parts.count - 2])
        return name.prefix(1).uppercased() + String(name.dropFirst())
    }

    // MARK: Logs

    // #343 was: three sections (buffer / container tail / clear-all) with two
    // footers. #460 (finding 11) was: one "Logs" section whose single footer
    // ("Maximum number of lines kept in memory per log category") rendered under
    // the "Clear all logs" BUTTON. Everything here is one subject — logs — so
    // the section stays whole and each explanation sits on its own row.
    // #471: "View all logs" stayed behind on the main list (reading a log is a
    // support flow); what moved here are the four knobs that shape it.
    private var logsSection: some View {
        Section {
            Picker(L10n.logLevelLabel.localized(), selection: $settings.logLevel) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            TunnelSettingsNote(text: L10n.logLevelNote.localized())
            numericField(L10n.logBufferLabel.localized(), value: $settings.logBufferSize,
                         note: L10n.footerLogBuffer.localized())
            numericField(L10n.containerLogsTailLabel.localized(), value: $settings.containerLogsTailLines,
                         note: L10n.containerLogsTailNote.localized())
            // #471 was: `OlcButton(role: .danger, fillWidth: true)` — a filled
            // red button inside a grouped list. A native destructive row is the
            // convention iOS already has for this.
            Button(L10n.clearAllLogsAction.localized(), role: .destructive) {
                LogStore.shared.clearAll()
                // #455: the clear is instant and its effect is off-screen (the
                // log reader is a pushed destination since #457), so confirm it fired.
                Haptics.success()
            }
        } header: {
            SignalSectionHeader(L10n.sectionLogs.localized()) // #491
        }
        .signalFormRows() // #491
    }

    // MARK: Servers (#471)

    // #471: the bot registry, waiting for its real home. It is read by exactly
    // one screen — the per-server bot sheet on the Servers tab — so the row
    // belongs there rather than in Settings; that move is a ServersView change
    // and not this pass's to make. Until then the row lives here: off the main
    // list, still one push from it, and nothing becomes unreachable.
    // #471 was: a "Servers" section on the MAIN list holding this row and the
    // "Remove linked connection when VPS is uninstalled" toggle. That toggle is
    // gone — removing a server now always removes the connections it created
    // (`SettingsStore.autoRemoveConnectionOnUninstall` is pinned on), which is a
    // sentence in the confirm dialog rather than a choice made months earlier.
    private var serversSection: some View {
        Section {
            NavigationLink {
                BotsSettingsView(botStore: botStore)
            } label: {
                HStack {
                    SignalSettingsLabel(L10n.sectionBots.localized(), systemImage: "terminal") // #491
                    Spacer()
                    Text("\(botStore.bots.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            SignalSectionHeader(L10n.serversTitle.localized()) // #491
        }
        .signalFormRows() // #491
    }
}

// MARK: - IPSourcesSettingsView (#293)
//
// Dedicated sub-screen for the IP-check source checkboxes (moved out of the main
// Settings list, which #286 had crowded). Pushed from the "IP check sources" row;
// the model + default subset + empty-set fallback live in SettingsStore.

struct IPSourcesSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(AppConstants.ipCheckServices, id: \.label) { svc in
                    Toggle(isOn: Binding(
                        get: { settings.enabledIPSources.contains(svc.label) },
                        set: { on in
                            if on { settings.enabledIPSources.insert(svc.label) }
                            else  { settings.enabledIPSources.remove(svc.label) }
                        }
                    )) {
                        Text(svc.label)
                    }
                }
            } header: {
                SignalSectionHeader(L10n.sectionIPSources.localized()) // #491
            } footer: {
                Text(L10n.ipSourcesFooter.localized())
            }
            .signalFormRows() // #491
        }
        // (audit #299) token ground, like the parent Settings Form.
        .signalFormChrome() // #491
        .navigationTitle(L10n.sectionIPSources.localized())
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - DNSSettingsView (#343)
//
// DNS presets as rows (name + monospaced address + checkmark) + the free-form
// field, moved off the main Settings list into a subscreen — same pattern as
// IPSourcesSettingsView (#293). The top-level row shows the current summary.

struct DNSSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var fieldFocused: Bool

    // boc #470
    /// The free-form field edits a DRAFT; only a valid `host:port` reaches the
    /// store. Master's `SetDNS` rejects anything else (`validateHostPort`:
    /// net.SplitHostPort, non-empty host, port 1…65535), so a bare "8.8.8.8" or
    /// a trailing space failed EVERY connect with the raw Go error, and
    /// `installEnv` baked the same string into the server's `dns:` line.
    @State private var dnsDraft: String = SettingsStore.shared.dnsServer

    private var dnsDraftBinding: Binding<String> {
        Binding(get: { dnsDraft }, set: { value in
            dnsDraft = value
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isValidResolver(trimmed) { settings.dnsServer = trimmed }
        })
    }

    private var draftIsValid: Bool {
        Self.isValidResolver(dnsDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// PURE: the Go runtime's rule, so the field refuses exactly what the core
    /// would refuse. Tested in Tests/Review470Chunk5Tests.swift.
    static func isValidResolver(_ value: String) -> Bool {
        guard let colon = value.lastIndex(of: ":") else { return false }
        var host = String(value[..<colon])
        let portText = String(value[value.index(after: colon)...])
        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return false }
            host = String(host.dropFirst().dropLast())
        } else if host.contains(":") {
            return false   // an unbracketed IPv6 literal — "too many colons" to SplitHostPort
        }
        guard !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let port = Int(portText), (1...65535).contains(port) else { return false }
        return true
    }
    // eoc #470

    /// Global presets + RU-carrier presets (labels localized). Keyed by label
    /// — values are NOT unique (Yota shares MegaFon's resolver).
    private var presets: [(label: String, value: String)] {
        AppConstants.dnsPresets.map { ($0.label, $0.value) }
            + AppConstants.ruCarrierDnsPresets.map { ($0.label.localized(), $0.value) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(presets, id: \.label) { preset in
                    Button {
                        settings.dnsServer = preset.value
                        dnsDraft = preset.value   // #470: the field mirrors the pick
                    } label: {
                        HStack {
                            // #491 was: provider and resolver fought for horizontal space.
                            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                                Text(preset.label)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Text(preset.value)
                                    .font(Theme.Typography.mono)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            Spacer()
                            if settings.dnsServer == preset.value {
                                Image(systemName: "checkmark")
                                    // #471 was: `.font(.footnote.weight(.semibold))`.
                                    .font(Theme.Typography.captionStrong)
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                    }
                    .accessibilityAddTraits(settings.dnsServer == preset.value ? .isSelected : []) // #491
                }
            } header: {
                SignalSectionHeader(L10n.sectionDNS.localized()) // #491
            } footer: {
                // The long explanation lives here now, off the main list (#343).
                // #471 was: `.font(.caption2)`.
                Text(L10n.dnsFooter.localized())
            }
            .signalFormRows() // #491

            Section {
                // #470 was: `text: $settings.dnsServer` — every keystroke reached the store.
                TextField(L10n.dnsFreeFormPlaceholder.localized(), text: dnsDraftBinding)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    .focused($fieldFocused)
                    .accessibilityLabel(L10n.sectionDNS.localized()) // #491
                // #470: the row says WHY the value is not taking effect.
                if !draftIsValid {
                    Text(L10n.dnsInvalidNote.localized())
                        // #471 was: `.font(.footnote)`.
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.red)
                }
            } header: {
                SignalSectionHeader(L10n.dnsFreeFormPlaceholder.localized()) // #491
            }
            .signalFormRows() // #491
        }
        // (audit #299) token ground, like the parent Settings Form.
        .signalFormChrome() // #491
        .navigationTitle(L10n.sectionDNS.localized())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.done.localized()) { fieldFocused = false }
            }
        }
    }
}

// MARK: - BotsSettingsView (#420)
//
// Manages the bot registry: list bots (name + platform), add / edit / delete.

struct BotsSettingsView: View {
    @ObservedObject var botStore: BotStore
    @State private var editorBot: BotIdentity?
    @State private var addingNew = false

    var body: some View {
        Form {
            Section {
                if botStore.bots.isEmpty {
                    Text(L10n.botsEmptyHint.localized()).foregroundStyle(.secondary)
                } else {
                    ForEach(botStore.bots) { bot in
                        Button { editorBot = bot } label: {
                            HStack {
                                Text(bot.name).foregroundStyle(Theme.Palette.textPrimary)
                                Spacer()
                                Text(bot.platform.title).font(Theme.Typography.caption).foregroundStyle(.secondary) // #491
                            }
                        }
                    }
                    .onDelete { botStore.remove(at: $0) }
                }
            } footer: {
                // #471 was: `.font(.caption2)`.
                Text(L10n.botsFooter.localized())
            }
            .signalFormRows() // #491
        }
        // (audit #299) token ground, like the parent Settings Form.
        .signalFormChrome() // #491
        .navigationTitle(L10n.sectionBots.localized())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingNew = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L10n.botAddTitle.localized())
            }
        }
        .sheet(item: $editorBot) { bot in
            BotEditorView(botStore: botStore, existing: bot)
        }
        .sheet(isPresented: $addingNew) {
            BotEditorView(botStore: botStore, existing: nil)
        }
    }
}

// MARK: - BotEditorView (#420)
//
// Add / edit one registry bot: name, platform (Telegram first, Max second), and
// token. The token field is masked and paste-only with a Copy button (no reveal).

struct BotEditorView: View {
    @ObservedObject var botStore: BotStore
    var existing: BotIdentity?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var platform: BotPlatform = .telegram
    @State private var token = ""
    @State private var copied = false

    private var isDuplicateName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return botStore.bots.contains {
            $0.id != existing?.id && $0.name.lowercased() == trimmed.lowercased()
        }
    }
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isDuplicateName
    }
    private var hasAnyToken: Bool {
        !token.isEmpty || (existing.map { botStore.hasToken($0) } ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormField(label: L10n.botNameLabel.localized(),
                              placeholder: L10n.botNamePlaceholder.localized(), text: $name)
                    if isDuplicateName {
                        Text(L10n.botNameTakenError.localized())
                            .font(.caption).foregroundStyle(Theme.Palette.red)
                    }
                    Picker(L10n.botPlatformLabel.localized(), selection: $platform) {
                        ForEach(BotPlatform.allCases) { p in Text(p.title).tag(p) }
                    }
                }
                .signalFormRows() // #491
                Section {
                    // Masked, paste-only token field — no reveal (a screenshot
                    // shows only dots). Copy retrieves it without displaying it.
                    SecureField(L10n.botTokenPlaceholder.localized(), text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if token.isEmpty {
                        Text((existing.map { botStore.hasToken($0) } ?? false)
                             ? L10n.botTokenSavedHint.localized()
                             : L10n.botTokenNoneHint.localized())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { copyToken() } label: {
                        Label(copied ? L10n.botTokenCopied.localized()
                                     : L10n.botCopyTokenAction.localized(),
                              systemImage: "doc.on.doc")
                    }
                    .disabled(!hasAnyToken)
                } header: {
                    SignalSectionHeader(L10n.botTokenLabel.localized()) // #491
                } footer: {
                    // #428: tell the user the token comes from the platform first.
                    // #471 was: `.font(.caption2)`.
                    Text(L10n.botTokenCreateHint.localized())
                }
                .signalFormRows() // #491
            }
            .signalFormChrome() // #491
            .navigationTitle(existing == nil ? L10n.botAddTitle.localized()
                                             : L10n.botEditTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .olcSheet(confirm: L10n.save.localized(), disabled: !isValid) { save() }
            .onAppear { prefill() }
        }
    }

    private func copyToken() {
        let value = token.isEmpty ? (existing.map { botStore.token(for: $0) } ?? "") : token
        guard !value.isEmpty else { return }
        UIPasteboard.general.string = value
        copied = true
    }

    private func save() {
        var bot = existing ?? BotIdentity(name: "", platform: .telegram)
        bot.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        bot.platform = platform
        if existing == nil {
            botStore.add(bot, token: token)
        } else {
            botStore.update(bot, token: token.isEmpty ? nil : token)
        }
        dismiss()
    }

    private func prefill() {
        guard let e = existing else { return }
        name = e.name
        platform = e.platform
        // Token left blank: paste to replace, blank keeps the stored one.
    }
}

// #340: both appearance variants.
#if DEBUG
#Preview("Settings — Dark") {
    SettingsView(tunnel: TunnelManager(), botStore: BotStore(),
                 serverStore: ServerHostStore(), connections: ConnectionStore(),
                 updateChecker: UpdateChecker())
        .preferredColorScheme(.dark)
}
#Preview("Settings — Light") {
    SettingsView(tunnel: TunnelManager(), botStore: BotStore(),
                 serverStore: ServerHostStore(), connections: ConnectionStore(),
                 updateChecker: UpdateChecker())
        .preferredColorScheme(.light)
}
// #471: the Advanced screen is seven sections deep behind a push — previewing
// it through the parent means four taps per rebuild.
#Preview("Settings — Advanced") {
    NavigationStack {
        SettingsAdvancedView(tunnel: TunnelManager(), botStore: BotStore())
    }
    .preferredColorScheme(.dark)
}
#endif
