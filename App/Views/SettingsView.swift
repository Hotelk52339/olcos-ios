import SwiftUI

// MARK: - SettingsView
//
// The third tab. One rule decides where a control lives: if changing it is part
// of USING the app it is on this list; if it is tuning, it is one push away on
// `SettingsAdvancedView`. Five sections, ordered by how often they are touched:
//
//   Tunnel · When the app opens · Staying connected · Appearance · About
//
// Conventions shared with every Form in the app: the token ground via
// `.signalFormChrome()`, a `TunnelSettingsNote` directly under the control it
// explains, and a section footer only where it adds information about the whole
// section. Reads/writes go through `SettingsStore.shared`, which mirrors
// UserDefaults; SwiftUI rebinds on @Published changes.

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    /// Live tunnel state: the mode picker's lock and the VPN capability probe.
    @ObservedObject var tunnel: TunnelManager
    /// Bot registry (shared with Servers). Managed in `BotsSettingsView`.
    @ObservedObject var botStore: BotStore
    /// The per-server stores the log reader and the bot screens need.
    @ObservedObject var serverStore: ServerHostStore
    @ObservedObject var connections: ConnectionStore
    /// The update checker, so "Check now" and the daily check are the same
    /// object. Declared LAST: the memberwise initialiser follows declaration
    /// order and every call site keeps its argument order.
    @ObservedObject var updateChecker: UpdateChecker

    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            // The modifier stack is split across two small wrappers so no single
            // expression carries the whole chain (type-checker budget).
            formWiring(formChrome(settingsForm))
        }
    }

    private var settingsForm: some View {
        Form {
            TunnelSettingsModeSection(tunnel: tunnel)
            TunnelSettingsOnOpenSection()
            stayConnectedSection
            appearanceSection
            aboutSection
            resetSection
        }
    }

    private func formChrome(_ content: some View) -> some View {
        content
            .signalFormChrome()
            .refreshable { await refreshSettings() }
            // Side-effect free: only reads existing VPN preferences, never pops
            // the system consent alert. Drives the VPN chip in the mode section.
            .task { await tunnel.vpn.probeCapability() }
    }

    private func formWiring(_ content: some View) -> some View {
        content
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
    }

    /// Pull to refresh: the one thing that goes stale while this screen is open
    /// is whether this install may run the system VPN at all.
    private func refreshSettings() async {
        await tunnel.vpn.probeCapability()
    }

    // MARK: Staying connected

    /// Keeping a live session alive while the app is in the background.
    /// Automatic protocol switching has no UI here: it is an opt-in stored
    /// setting (`SettingsStore.autoFailover`, default off).
    private var stayConnectedSection: some View {
        Section {
            Toggle(L10n.settingsBackgroundLabel.localized(), isOn: $settings.backgroundAudio)
            TunnelSettingsNote(text: L10n.backgroundAudioNote.localized())
        } header: {
            SignalSectionHeader(L10n.settingsSectionStayConnected.localized())
        }
        .signalFormRows()
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            Picker(L10n.languageLabel.localized(), selection: languageBinding) {
                ForEach(AppLocale.allCases) { locale in
                    Text(locale.displayName).tag(locale)
                }
            }
            Picker(L10n.themeLabel.localized(), selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            // Screenshot-safe mode: display-only masking of IP addresses.
            Toggle(L10n.maskIPsLabel.localized(), isOn: $settings.maskIPs)
        } header: {
            SignalSectionHeader(L10n.appearanceLabel.localized())
        } footer: {
            Text(L10n.maskIPsFooter.localized())
        }
        .signalFormRows()
    }

    /// Extracted so the language `Picker` stays one short expression.
    private var languageBinding: Binding<AppLocale> {
        Binding(get: { AppLocale(rawValue: settings.language) ?? .english },
                set: { locale in
                    guard settings.language != locale.rawValue else { return }
                    Haptics.tap()
                    settings.language = locale.rawValue
                })
    }

    // MARK: About

    /// The version, the app-update check (named so it cannot be confused with
    /// the server-side core update on the server screen), the unscoped way into
    /// the log reader, and the one door to everything a user does not tune.
    private var aboutSection: some View {
        Section {
            versionRow
            NavigationLink {
                AppUpdateSettingsView(updateChecker: updateChecker)
            } label: {
                SignalSettingsLabel(L10n.settingsSectionUpdates.localized(),
                                    subtitle: updateSubtitle,
                                    systemImage: "arrow.down.circle")
            }
            NavigationLink {
                LogsView(subject: .all, serverStore: serverStore, connections: connections)
            } label: {
                SignalSettingsLabel(L10n.settingsViewLogsRow.localized(), systemImage: "doc.text")
            }
            NavigationLink {
                SettingsAdvancedView(tunnel: tunnel, botStore: botStore,
                                     serverStore: serverStore, connections: connections)
            } label: {
                SignalSettingsLabel(L10n.settingsAdvancedRow.localized(), systemImage: "slider.horizontal.3")
            }
        } header: {
            SignalSectionHeader(L10n.settingsSectionAbout.localized())
        }
        .signalFormRows()
    }

    /// Whether the daily check is on — the one fact worth a glance here.
    private var updateSubtitle: String {
        settings.updateCheckEnabled ? L10n.settingsUpdateCheckOn.localized() : L10n.settingsUpdateCheckOff.localized()
    }

    /// The only destructive row in Settings, visually separated from navigation.
    private var resetSection: some View {
        Section {
            Button(L10n.resetSettingsAction.localized(), role: .destructive) {
                showResetConfirm = true
            }
        } footer: {
            Text(L10n.resetSettingsFooter.localized())
        }
        .signalFormRows()
    }

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

// MARK: - AppUpdateSettingsView
//
// The APP's own update check (GitHub Releases, anonymous). Deliberately its own
// screen under its own name — the server-side olcOS core update is a different
// action on the server screen.

struct AppUpdateSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject var updateChecker: UpdateChecker

    var body: some View {
        Form {
            Section {
                Toggle(L10n.updateCheckLabel.localized(), isOn: $settings.updateCheckEnabled)
                checkNowRow
                checkNowResult
            } footer: {
                Text(L10n.updateCheckFooter.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
        .navigationTitle(L10n.settingsSectionUpdates.localized())
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The daily check waits 24 h and says nothing when there is nothing to
    /// say. Asking directly gets an answer either way.
    private var checkNowRow: some View {
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
    }

    /// A newer release opens the update sheet instead, so this only ever
    /// reports "nothing new" or "could not ask".
    @ViewBuilder
    private var checkNowResult: some View {
        switch updateChecker.manual {
        case .upToDate(let version):
            TunnelSettingsNote(text: L10n.updateUpToDate_fmt.formatted(version))
        case .failed:
            TunnelSettingsNote(text: L10n.updateCheckFailed.localized())
        case .idle, .checking:
            EmptyView()
        }
    }
}

// MARK: - SettingsAdvancedView
//
// The one push off the main Settings list: everything a server admin or a
// developer tunes and a user of a VPN app never opens. The directory groups the
// editors by what they act on — Connection (session timing, the local proxy,
// the resolver, the video transport), Servers (the bot registry, the bypass
// list for another proxy app) and Diagnostics (check sources, log knobs). Every
// directory row shows its current value as one caption line in the same style.
//
// Each editor is a real observing view pushed with the same injected stores, so
// bindings write to the store that the visible rows read.

struct SettingsAdvancedView: View {
    @ObservedObject private var settings = SettingsStore.shared
    /// The port check compares against the port the session actually bound.
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject var botStore: BotStore
    @ObservedObject var serverStore: ServerHostStore
    @ObservedObject var connections: ConnectionStore

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

    init(tunnel: TunnelManager, botStore: BotStore, serverStore: ServerHostStore,
         connections: ConnectionStore, page: Page = .directory) {
        self.tunnel = tunnel
        self.botStore = botStore
        self.serverStore = serverStore
        self.connections = connections
        self.page = page
    }

    @State private var portCheck: PortAvailability.PortState?
    /// This install's room name (DeviceIdentity); re-rolled by the button.
    @State private var deviceName: String = DeviceIdentity.current()
    @State private var socksPassInput: String = ""
    @State private var socksPassLoaded = false
    @FocusState private var anyFieldFocused: Bool

    var body: some View {
        advancedWiring(advancedChrome(advancedForm))
    }

    private var advancedForm: some View {
        Form {
            if page == .directory {
                directorySections
            } else {
                editorSection
            }
        }
    }

    // MARK: Directory

    @ViewBuilder
    private var directorySections: some View {
        Section {
            pageLink(.connection, systemImage: "timer", subtitle: connectionSummary)
            pageLink(.proxy, systemImage: "network", subtitle: proxySummary)
            dnsLink
            pageLink(.transport, systemImage: "video", subtitle: transportSummary)
        } header: {
            SignalSectionHeader(L10n.settingsSectionConnection.localized())
        }
        .signalFormRows()

        Section {
            NavigationLink {
                BotsSettingsView(botStore: botStore, serverStore: serverStore)
            } label: {
                SignalSettingsLabel(L10n.sectionBots.localized(),
                                    subtitle: botsSummary, systemImage: "terminal")
            }
            NavigationLink {
                CarrierEndpointsPickerView(connections: connections)
            } label: {
                SignalSettingsLabel(L10n.settingsCarrierEndpointsRow.localized(),
                                    subtitle: L10n.settingsConnectionsCount_fmt.formatted(connections.connections.count),
                                    systemImage: "arrow.triangle.branch")
            }
        } header: {
            SignalSectionHeader(L10n.serversTitle.localized())
        }
        .signalFormRows()

        Section {
            HStack(spacing: Theme.Metrics.s2) {
                SignalSettingsLabel(L10n.deviceNameLabel.localized(),
                                    subtitle: deviceName, systemImage: "person.crop.circle.dashed")
                Spacer(minLength: 0)
                Button(L10n.deviceNameRegenerate.localized()) {
                    deviceName = DeviceIdentity.regenerate()
                }
                .buttonStyle(.borderless)
                .font(Theme.Typography.caption)
            }
        } header: {
            SignalSectionHeader(L10n.deviceNameSectionHeader.localized())
        } footer: {
            Text(L10n.deviceNameFooter.localized())
        }
        .signalFormRows()

        Section {
            pageLink(.diagnostics, systemImage: "waveform.path.ecg", subtitle: diagnosticsSummary)
            pageLink(.logs, systemImage: "doc.text", subtitle: settings.logLevel.label)
        } header: {
            SignalSectionHeader(L10n.diagnosticsTitle.localized())
        }
        .signalFormRows()
    }

    private func pageLink(_ target: Page, systemImage: String, subtitle: String) -> some View {
        NavigationLink {
            SettingsAdvancedView(tunnel: tunnel, botStore: botStore, serverStore: serverStore,
                                 connections: connections, page: target)
        } label: {
            SignalSettingsLabel(target.titleKey.localized(), subtitle: subtitle, systemImage: systemImage)
        }
    }

    private var dnsLink: some View {
        NavigationLink {
            DNSSettingsView()
        } label: {
            SignalSettingsLabel(L10n.sectionDNS.localized(), subtitle: dnsSummary, systemImage: "globe")
        }
    }

    // Current values, one caption each.

    private var connectionSummary: String {
        L10n.settingsConnectionSummary_fmt.formatted(settings.startTimeoutSeconds, settings.keepAliveSeconds)
    }

    private var proxySummary: String {
        Self.proxyAddress(boundPort: tunnel.boundPort, configuredPort: settings.socksPort)
    }

    private var transportSummary: String {
        L10n.settingsTransportSummary_fmt.formatted(settings.vp8FPS, settings.vp8BatchSize)
    }

    private var diagnosticsSummary: String {
        let provider = Self.providerName(AppConstants.SpeedTest.provider(id: settings.speedTestProviderID))
        return L10n.settingsDiagnosticsSummary_fmt.formatted(provider, settings.enabledIPSources.count)
    }

    private var botsSummary: String {
        botStore.bots.isEmpty ? L10n.botsEmptyHint.localized()
                              : L10n.settingsBotsCount_fmt.formatted(botStore.bots.count)
    }

    /// "Yandex · 77.88.8.8:53" when the value matches a preset, else the raw value.
    private var dnsSummary: String {
        let v = settings.dnsServer
        let presets: [(String, String)] = AppConstants.dnsPresets.map { ($0.label, $0.value) }
            + AppConstants.ruCarrierDnsPresets.map { ($0.label.localized(), $0.value) }
        if let hit = presets.first(where: { $0.1 == v }) { return "\(hit.0) · \(v)" }
        return v
    }

    // MARK: Editors

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

    private func advancedChrome(_ content: some View) -> some View {
        content
            .signalFormChrome()
            .onDisappear { socksPassLoaded = false }
    }

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

    // MARK: Connection

    /// The values that TIME a session: how long to wait for it to come up, how
    /// often to prove it still passes traffic, and the opt-in early restart.
    private var connectionSection: some View {
        Section {
            numericField(L10n.startTimeoutLabel.localized(), value: $settings.startTimeoutSeconds,
                         unit: L10n.unitSeconds.localized(),
                         note: L10n.startTimeoutNote.localized())
            numericField(L10n.tunnelCheckLabel.localized(), value: $settings.keepAliveSeconds,
                         unit: L10n.unitSeconds.localized(),
                         note: L10n.footerKeepAlive.localized())
            Toggle(L10n.earlyRestartWedgeLabel.localized(), isOn: $settings.earlyRestartOnWedge)
            TunnelSettingsNote(text: L10n.earlyRestartWedgeNote.localized())
        } header: {
            SignalSectionHeader(L10n.settingsSectionConnection.localized())
        }
        .signalFormRows()
    }

    // MARK: Proxy

    @ViewBuilder
    private var proxySection: some View {
        Section {
            portRow
            proxyAddressRow
            TunnelSettingsNote(text: L10n.socksPortChangeNote.localized())
            Button { runPortCheck() } label: { portCheckLabel }
            Toggle(L10n.localSocksAuthLabel.localized(), isOn: $settings.localSocksAuthEnabled)
            TunnelSettingsNote(text: L10n.socksAuthFooter.localized())
            if settings.localSocksAuthEnabled {
                authFields
            }
        } header: {
            SignalSectionHeader(L10n.settingsSectionProxy.localized())
        }
        .signalFormRows()
        // The verdict describes the port that was CHECKED; a new value is unchecked.
        .onChange(of: settings.socksPort) { _, _ in portCheck = nil }
    }

    /// Host AND port, as one selectable line — what goes into another app's
    /// proxy settings. A local address that only answers in proxy mode.
    private var proxyAddressRow: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text(L10n.settingsProxyAddressLabel.localized())
            Text(Self.proxyAddress(boundPort: tunnel.boundPort, configuredPort: settings.socksPort))
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
                .textSelection(.enabled)
        }
    }

    /// The live listener is authoritative; configuration is only a fallback.
    nonisolated static func proxyAddress(boundPort: Int?, configuredPort: Int) -> String {
        "127.0.0.1:\(boundPort ?? configuredPort)"
    }

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
                case .free:      Text(L10n.portFree.localized()).foregroundStyle(Theme.Palette.green)
                case .busyOurs:  Text(L10n.portInUseByOlcrtc.localized()).foregroundStyle(Theme.Palette.green)
                case .busyOther: Text(L10n.portBusy.localized()).foregroundStyle(Theme.Palette.red)
                }
            }
        }
    }

    private func runPortCheck() {
        let port = UInt16(settings.socksPort)
        // Compare against the port the tunnel actually bound (`tunnel.boundPort`,
        // snapshotted at connect; nil unless a session is live).
        let tunnelHoldsPort = tunnel.boundPort == settings.socksPort
        let result = PortAvailability.state(port, tunnelHoldsPort: tunnelHoldsPort)
        portCheck = result
        let logLine: String
        switch result {
        case .free:      logLine = L10n.logPortFree_fmt.formatted(settings.socksPort)
        case .busyOther: logLine = L10n.logPortBusyOther_fmt.formatted(settings.socksPort)
        case .busyOurs:  logLine = L10n.logPortBusyOlcrtc_fmt.formatted(settings.socksPort)
        }
        LogStore.shared.log(.connection, logLine)
    }

    // MARK: Numeric field helper

    /// A TextField for direct entry; out-of-range values are clamped by
    /// `SettingsStore.didSet`. The note, when given, renders directly under it.
    @ViewBuilder
    private func numericField(_ title: String,
                              value: Binding<Int>,
                              unit: String? = nil,
                              note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("", value: value, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .monospacedDigit()
                    .focused($anyFieldFocused)
                    .accessibilityLabel(title)
                if let unit {
                    Text(unit).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
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
            SignalSectionHeader(L10n.sectionVP8.localized())
        } footer: {
            Text(L10n.vp8Note.localized())
        }
        .signalFormRows()
    }

    // MARK: Diagnostics

    /// WHICH service answers a check — a fallback for a blocked network.
    private var diagnosticsSection: some View {
        Section {
            ipSourcesRow
            Picker(L10n.sectionSpeedProvider.localized(), selection: $settings.speedTestProviderID) {
                ForEach(AppConstants.SpeedTest.providers) { p in
                    Text(Self.providerName(p)).tag(p.id)
                }
            }
            // The name identifies the provider; the host is data on its own line.
            Text(speedProviderHost)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
        } header: {
            SignalSectionHeader(L10n.diagnosticsTitle.localized())
        } footer: {
            Text(L10n.speedProviderFooter.localized())
        }
        .signalFormRows()
    }

    private var ipSourcesRow: some View {
        NavigationLink {
            IPSourcesSettingsView()
        } label: {
            HStack {
                SignalSettingsLabel(L10n.sectionIPSources.localized(), systemImage: "network")
                Spacer()
                Text("\(settings.enabledIPSources.count)")
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    private var speedProviderHost: String {
        AppConstants.SpeedTest.provider(id: settings.speedTestProviderID).host
    }

    /// Display name for a speed-test provider: the brand in parentheses when
    /// the label carries one ("proof.ovh.net (OVH)"), else the host's
    /// registrable label ("speed.cloudflare.com" → "Cloudflare").
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

    /// The knobs that shape the log; reading it is on the main list.
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
            Button(L10n.clearAllLogsAction.localized(), role: .destructive) {
                LogStore.shared.clearAll()
                // The clear is instant and its effect is off-screen — confirm it fired.
                Haptics.success()
            }
        } header: {
            SignalSectionHeader(L10n.sectionLogs.localized())
        }
        .signalFormRows()
    }
}

// MARK: - CarrierEndpointsPickerView
//
// The Settings entrance to the bypass list for another proxy app. The addresses
// derive from a connection's room, so this screen lists the connections and
// opens `CarrierEndpointsView` for the chosen one.

struct CarrierEndpointsPickerView: View {
    @ObservedObject var connections: ConnectionStore
    @State private var chosen: ConnectionRecord?

    var body: some View {
        Form {
            Section {
                if connections.connections.isEmpty {
                    Text(L10n.settingsCarrierEndpointsEmpty.localized())
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    ForEach(connections.connections) { conn in
                        Button { chosen = conn } label: {
                            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                                Text(conn.displayName)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Text(conn.details.subtitle)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                    }
                }
            } footer: {
                Text(L10n.carrierEndpointsLead.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
        .navigationTitle(L10n.settingsCarrierEndpointsRow.localized())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $chosen) { conn in
            switch conn.details {
            case .olcrtc(let params):
                CarrierEndpointsView(params: params)
            }
        }
    }
}

// MARK: - IPSourcesSettingsView
//
// The IP-check source checkboxes. The model, default subset and empty-set
// fallback live in SettingsStore.

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
                SignalSectionHeader(L10n.sectionIPSources.localized())
            } footer: {
                Text(L10n.ipSourcesFooter.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
        .navigationTitle(L10n.sectionIPSources.localized())
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - DNSSettingsView
//
// DNS presets as rows (name + address + checkmark) plus the free-form field.

struct DNSSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var fieldFocused: Bool

    /// The free-form field edits a DRAFT; only a valid `host:port` reaches the
    /// store. The Go core's `SetDNS` rejects anything else, and the same string
    /// is baked into a new server's `dns:` line.
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

    /// PURE: the Go runtime's rule (net.SplitHostPort, non-empty host, port
    /// 1…65535), so the field refuses exactly what the core would refuse.
    /// Tested in Tests/Review470Chunk5Tests.swift.
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
                        dnsDraft = preset.value
                    } label: {
                        HStack {
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
                                    .font(Theme.Typography.captionStrong)
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                    }
                    .accessibilityAddTraits(settings.dnsServer == preset.value ? .isSelected : [])
                }
            } header: {
                SignalSectionHeader(L10n.sectionDNS.localized())
            } footer: {
                Text(L10n.dnsFooter.localized())
            }
            .signalFormRows()

            Section {
                TextField(L10n.dnsFreeFormPlaceholder.localized(), text: dnsDraftBinding)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(Theme.Typography.body.monospaced())
                    .focused($fieldFocused)
                    .accessibilityLabel(L10n.sectionDNS.localized())
                if !draftIsValid {
                    Text(L10n.dnsInvalidNote.localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.red)
                }
            } header: {
                SignalSectionHeader(L10n.dnsFreeFormPlaceholder.localized())
            }
            .signalFormRows()
        }
        .signalFormChrome()
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

// MARK: - BotsSettingsView
//
// The bot registry (name + platform + token), and the per-server bot screen for
// every saved server — so bots are managed from Settings only.

struct BotsSettingsView: View {
    @ObservedObject var botStore: BotStore
    @ObservedObject var serverStore: ServerHostStore
    @StateObject private var provisioner = Provisioner()
    @State private var editorBot: BotIdentity?
    @State private var addingNew = false
    @State private var botConfigFor: ServerHost?

    var body: some View {
        Form {
            registrySection
            if !serverStore.hosts.isEmpty {
                serversSection
            }
        }
        .signalFormChrome()
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
        .sheet(item: $botConfigFor) { host in
            BotSettingsView(host: host, botStore: botStore,
                            provisioner: provisioner,
                            secret: serverStore.secret(for: host))
        }
    }

    private var registrySection: some View {
        Section {
            if botStore.bots.isEmpty {
                Text(L10n.botsEmptyHint.localized())
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                ForEach(botStore.bots) { bot in
                    Button { editorBot = bot } label: {
                        HStack {
                            Text(bot.name).foregroundStyle(Theme.Palette.textPrimary)
                            Spacer()
                            Text(bot.platform.title)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
                .onDelete { botStore.remove(at: $0) }
            }
        } footer: {
            Text(L10n.botsFooter.localized())
        }
        .signalFormRows()
    }

    private var serversSection: some View {
        Section {
            ForEach(serverStore.hosts) { host in
                Button { botConfigFor = host } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                            Text(host.label)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(host.host)
                                .font(Theme.Typography.mono)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(Theme.Typography.captionStrong)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
        } header: {
            SignalSectionHeader(L10n.settingsBotsServersHeader.localized())
        } footer: {
            Text(L10n.settingsBotsServersFooter.localized())
        }
        .signalFormRows()
    }
}

// MARK: - BotEditorView
//
// Add / edit one registry bot: name, platform and token. The token field is
// masked and paste-only with a Copy button (no reveal).

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
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.red)
                    }
                    Picker(L10n.botPlatformLabel.localized(), selection: $platform) {
                        ForEach(BotPlatform.allCases) { p in Text(p.title).tag(p) }
                    }
                }
                .signalFormRows()
                Section {
                    // Masked, paste-only token field — no reveal. Copy retrieves
                    // it without displaying it.
                    SecureField(L10n.botTokenPlaceholder.localized(), text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if token.isEmpty {
                        Text((existing.map { botStore.hasToken($0) } ?? false)
                             ? L10n.botTokenSavedHint.localized()
                             : L10n.botTokenNoneHint.localized())
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Button { copyToken() } label: {
                        Label(copied ? L10n.botTokenCopied.localized()
                                     : L10n.botCopyTokenAction.localized(),
                              systemImage: "doc.on.doc")
                    }
                    .disabled(!hasAnyToken)
                } header: {
                    SignalSectionHeader(L10n.botTokenLabel.localized())
                } footer: {
                    Text(L10n.botTokenCreateHint.localized())
                }
                .signalFormRows()
            }
            .signalFormChrome()
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
#Preview("Settings — Advanced") {
    NavigationStack {
        SettingsAdvancedView(tunnel: TunnelManager(), botStore: BotStore(),
                             serverStore: ServerHostStore(), connections: ConnectionStore())
    }
    .preferredColorScheme(.dark)
}
#endif
