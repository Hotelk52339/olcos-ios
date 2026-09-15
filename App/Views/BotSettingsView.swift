import SwiftUI

// MARK: - BotSettingsView
//
// Per-server bot sheet — one bot per server. The user picks a bot from the
// Settings registry (`BotStore`), sets the start/stop commands + replies, then
// Checks / Deploys / Removes it on this VPS. Detection probes every registry
// name (`BotStore.markers`); the token comes from the registry (not entered here).

struct BotSettingsView: View {
    let host: ServerHost
    @ObservedObject var botStore: BotStore
    @ObservedObject var provisioner: Provisioner
    /// The host's SSH secret (password or private key), supplied by the caller.
    let secret: SSHSecret?

    @Environment(\.dismiss) private var dismiss

    // Per-server fields (commands are language-neutral config seeds, like
    // InstallOptions defaults; the replies seed from L10n on a fresh deploy).
    @State private var selectedBotID: UUID?
    @State private var startCmd = "start"
    @State private var stopCmd  = "stop"
    @State private var startReply = ""
    @State private var stopReply  = ""
    @State private var unknownReply = ""
    @State private var isEditing = false

    @State private var deployed: DeployedBot?     // what's currently on this server (nil = none)
    @State private var didInitialCheck = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var confirmRemove = false

    private var selectedBot: BotIdentity? { botStore.bots.first { $0.id == selectedBotID } }
    private var canOperate: Bool { secret != nil && !busy }

    var body: some View {
        NavigationStack {
            Form {
                if botStore.bots.isEmpty {
                    emptyRegistrySection
                } else {
                    statusSection
                    botSection
                    commandsSection
                    repliesSection
                    actionsSection
                }
            }
            .signalFormChrome()
            .navigationTitle(L10n.botSheetTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.close.localized())
                }
            }
            // Auto-detect on open so the fields reflect what's actually on the server.
            .task {
                guard !didInitialCheck else { return }
                didInitialCheck = true

                // stored credentials and at least one configured bot. Otherwise just
                // show the state (no SSH round-trip, no credentials alert on open).
                guard secret != nil, !botStore.bots.isEmpty else { return }
                await check()
            }
            .alert(L10n.botRemoveConfirmTitle.localized(), isPresented: $confirmRemove) {
                Button(L10n.botRemoveAction.localized(), role: .destructive) { Task { await remove() } }
                Button(L10n.cancel.localized(), role: .cancel) {}
            } message: {
                Text(L10n.botRemoveConfirmBody.localized())
            }
            .alert(L10n.error.localized(), isPresented: Binding(
                get: { errorText != nil }, set: { if !$0 { errorText = nil } }
            )) {
                Button(L10n.ok.localized()) { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }

    // MARK: Sections

    private var emptyRegistrySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                Text(L10n.botNoBotsTitle.localized()).font(Theme.Typography.title)
                Text(L10n.botNoBotsHint.localized())
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .signalFormRows()
    }

    private var statusSection: some View {
        Section {
            // The button's own spinner covers the busy state.
            Text(statusLabel).foregroundStyle(statusTone)
            Button {
                Task { await check() }
            } label: {
                HStack {
                    Label(L10n.botCheckAction.localized(), systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(!canOperate)
            if let d = deployed, !botStore.bots.contains(where: { $0.name == d.marker }) {
                Text(L10n.botUnknownFound_fmt.formatted(d.marker))
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.orange)
            }
        } header: {
            SignalSectionHeader(L10n.botSheetTitle.localized())
        } footer: {
            Text(L10n.botSheetFooter.localized())
        }
        .signalFormRows()
    }

    private var botSection: some View {
        Section {
            Picker(L10n.botSelectLabel.localized(), selection: Binding(
                get: { selectedBotID ?? botStore.bots.first?.id },
                set: { selectedBotID = $0 }
            )) {
                ForEach(botStore.bots) { bot in
                    Text(bot.name).tag(Optional(bot.id))
                }
            }
            .disabled(!isEditing)
            if let bot = selectedBot {
                HStack {
                    Text(L10n.botPlatformLabel.localized())
                    Spacer()
                    Text(bot.platform.title).foregroundStyle(Theme.Palette.textSecondary)
                }

                // itself is entered in Settings → Bots). was: a token hint line.
                HStack {
                    Text(L10n.botTokenLabel.localized())
                    Spacer()
                    Text(botStore.hasToken(bot) ? L10n.botTokenStatusSaved.localized()
                                                : L10n.botTokenStatusMissing.localized())
                        .foregroundStyle(botStore.hasToken(bot) ? Theme.Palette.textSecondary
                                                                : Theme.Palette.orange)
                }
            }
        } footer: {
            Text(L10n.botTokenManageHint.localized())
        }
        .signalFormRows()
    }

    private var commandsSection: some View {
        Section {
            labeledField(L10n.botStartCmdLabel.localized(), text: $startCmd)
            labeledField(L10n.botStopCmdLabel.localized(),  text: $stopCmd)
        } header: {
            SignalSectionHeader(L10n.botCommandsHeader.localized())
        }
        .signalFormRows()
    }

    private var repliesSection: some View {
        Section {
            labeledField(L10n.botStartReplyLabel.localized(),   text: $startReply)
            labeledField(L10n.botStopReplyLabel.localized(),    text: $stopReply)
            labeledField(L10n.botUnknownReplyLabel.localized(), text: $unknownReply)
        } header: {
            SignalSectionHeader(L10n.botRepliesHeader.localized())
        }
        .signalFormRows()
    }

    private var actionsSection: some View {
        Section {
            if isEditing {
                Button {
                    Task { await deploy() }
                } label: {
                    HStack {
                        Label(deployed == nil ? L10n.botDeployAction.localized() : L10n.save.localized(),
                              systemImage: "arrow.up.circle")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(!canOperate || selectedBot == nil)
            } else {
                Button {
                    isEditing = true
                } label: {
                    Label(L10n.edit.localized(), systemImage: "pencil")
                }
                .disabled(busy)
            }
            if deployed != nil {
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label(L10n.botRemoveAction.localized(), systemImage: "trash")
                }
                .disabled(!canOperate)
            }
        }
        .signalFormRows()
    }

    @ViewBuilder
    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text(label).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
            TextField("", text: text)
                .accessibilityLabel(label)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!isEditing)
                .foregroundStyle(isEditing ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
        }
    }

    private var statusLabel: String {
        guard let d = deployed else { return L10n.botStatusNone.localized() }
        return d.active ? L10n.botStatusRunning.localized() : L10n.botStatusInstalledIdle.localized()
    }

    private var statusTone: Color {
        guard let d = deployed else { return Theme.Palette.textSecondary }
        return d.active ? Theme.Palette.green : Theme.Palette.orange
    }

    // MARK: Operations

    private func check() async {
        guard let secret else { errorText = missingCredentialText; return }
        busy = true; defer { busy = false }
        do {
            let found = try await provisioner.checkBots(on: host, secret: secret, markers: botStore.markers)
            applyFound(found.first)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Method-appropriate "credential missing" message.
    private var missingCredentialText: String {
        host.authMethod == .privateKey
            ? L10n.alertKeyMissingShort.localized()
            : L10n.alertPasswordMissingShort.localized()
    }

    /// Folds a detection result into the editable fields: a found bot → display
    /// mode with its values; nothing found → edit mode seeded for a fresh deploy.
    private func applyFound(_ bot: DeployedBot?) {
        deployed = bot
        if let b = bot {
            if !b.startCmd.isEmpty { startCmd = b.startCmd }
            if !b.stopCmd.isEmpty  { stopCmd  = b.stopCmd }
            startReply   = b.startReply
            stopReply    = b.stopReply
            unknownReply = b.unknownReply
            if let match = botStore.bots.first(where: { $0.name == b.marker }) {
                selectedBotID = match.id
            }
            isEditing = false
        } else {
            if startReply.isEmpty   { startReply   = L10n.botDefaultStartReply.localized() }
            if stopReply.isEmpty    { stopReply    = L10n.botDefaultStopReply.localized() }
            if unknownReply.isEmpty { unknownReply = L10n.botDefaultUnknownReply.localized() }
            if selectedBotID == nil { selectedBotID = botStore.bots.first?.id }
            isEditing = true
        }
    }

    private func deploy() async {
        guard let secret else { errorText = missingCredentialText; return }
        guard let bot = selectedBot else { return }
        let token = botStore.token(for: bot)
        guard !token.isEmpty else { errorText = L10n.botMissingTokenError.localized(); return }
        let config = BotDeployConfig(
            marker: bot.name, platform: bot.platform, token: token,
            startCmd: startCmd.trimmingCharacters(in: .whitespaces),
            stopCmd:  stopCmd.trimmingCharacters(in: .whitespaces),
            startReply: startReply, stopReply: stopReply, unknownReply: unknownReply)
        busy = true; defer { busy = false }
        do {
            try await provisioner.deployBot(on: host, secret: secret, config: config)
            let found = try await provisioner.checkBots(on: host, secret: secret, markers: botStore.markers)
            applyFound(found.first { $0.marker == bot.name } ?? found.first)
            Haptics.success()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func remove() async {
        guard let secret, let d = deployed else { return }
        busy = true; defer { busy = false }
        do {
            try await provisioner.removeBot(on: host, secret: secret, marker: d.marker)
            applyFound(nil)
            Haptics.warning()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
