import SwiftUI

/// Guided add-server flow: Access → Check → Protocols → Room → Install.
///
/// Presenter contract (one sheet, two outcomes in one callback):
///
///     AddServerFlowView(otherLabels: serverStore.hosts.map(\.label),
///                       serverStore: serverStore, connections: connections,
///                       provisioner: provisioner) { host, secret, primary, extras in
///         serverStore.add(host, secret: secret)
///         Task { await install(host, primary: primary, extras: extras) }
///     }
///
/// The callback fires once, when the user taps Install on the last step. The
/// wizard then mirrors `provisioner.status` for live progress and shows the
/// connections that landed in `connections` for the saved host.
struct AddServerFlowView: View {
    typealias Completion = (ServerHost, SSHSecret, InstallOptions, [InstallOptions]) -> Void

    @ObservedObject var serverStore: ServerHostStore
    @ObservedObject var connections: ConnectionStore
    @ObservedObject var provisioner: Provisioner
    @StateObject private var flow: AddServerFlowController
    @Environment(\.dismiss) private var dismiss

    private let onComplete: Completion

    init(otherLabels: [String],
         serverStore: ServerHostStore,
         connections: ConnectionStore,
         provisioner: Provisioner,
         onComplete: @escaping Completion) {
        self.serverStore = serverStore
        self.connections = connections
        self.provisioner = provisioner
        self.onComplete = onComplete
        _flow = StateObject(wrappedValue: AddServerFlowController(otherLabels: otherLabels))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AddServerStepIndicator(current: flow.step)
                    .padding(.horizontal, Theme.Metrics.cardPadding)
                    .padding(.vertical, Theme.Metrics.s3)
                ScrollView {
                    stepContent
                        .padding(.horizontal, Theme.Metrics.cardPadding)
                        .padding(.bottom, Theme.Metrics.s8)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Theme.Palette.bg)
            .navigationTitle(flow.step.title.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if flow.installPhase == .review {
                        Button(L10n.cancel.localized()) { close() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .interactiveDismissDisabled(flow.installPhase.isRunning)
        }
        .onChange(of: provisioner.status) { _, status in flow.observe(status) }
        .onDisappear { flow.cancelWork() }
    }

    // MARK: Steps

    @ViewBuilder private var stepContent: some View {
        switch flow.step {
        case .access:    AddServerAccessStep(flow: flow)
        case .check:     AddServerCheckStep(flow: flow)
        case .protocols: AddServerProtocolsStep(flow: flow)
        case .room:      AddServerRoomStep(flow: flow, yandexStore: flow.yandexStore)
        case .install:   AddServerInstallStep(flow: flow, serverStore: serverStore,
                                              connections: connections)
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: Theme.Metrics.s3) {
            if flow.canGoBack {
                OlcButton(L10n.addFlowBack.localized(), systemImage: "chevron.left",
                          role: .secondary) { flow.goBack() }
            }
            switch flow.step {
            case .install:
                installButton
            default:
                OlcButton(L10n.addFlowNext.localized(), systemImage: "chevron.right",
                          role: .primary, fillWidth: true) { flow.advance() }
                    .disabled(!flow.canAdvance(from: flow.step) && flow.step != .access && flow.step != .room)
            }
        }
        .padding(Theme.Metrics.cardPadding)
        .background(.bar)
    }

    @ViewBuilder private var installButton: some View {
        switch flow.installPhase {
        case .review:
            OlcButton(L10n.actionInstall.localized(), systemImage: "arrow.down.circle",
                      role: .primary, fillWidth: true) { startInstall() }
                .disabled(provisioner.status.isRunning)
        case .running:
            OlcButton(L10n.addFlowInstallRunning.localized(), role: .primary,
                      isBusy: true, fillWidth: true) { }
                .disabled(true)
        case .success, .failure:
            OlcButton(L10n.done.localized(), systemImage: "checkmark",
                      role: .primary, fillWidth: true) { close() }
        }
    }

    private func startInstall() {
        guard let outcome = flow.makeOutcome() else { return }
        flow.markInstallStarted(host: outcome.host)
        onComplete(outcome.host, outcome.secret, outcome.primary, outcome.extras)
    }

    private func close() {
        flow.cancelWork()
        dismiss()
    }
}

// MARK: - Step indicator

struct AddServerStepIndicator: View {
    let current: AddServerStep

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            HStack(spacing: Theme.Metrics.s1) {
                ForEach(AddServerStep.allCases) { step in
                    Capsule()
                        .fill(step.rawValue <= current.rawValue
                              ? Theme.Palette.accent : Theme.Palette.fill)
                        .frame(height: Theme.Metrics.s1)
                        .animation(.snappy, value: current)
                }
            }
            HStack(spacing: Theme.Metrics.s2) {
                Image(systemName: current.systemImage)
                    .foregroundStyle(Theme.Palette.accent)
                Text(L10n.addFlowStepCounter_fmt.formatted(current.rawValue + 1,
                                                          AddServerStep.allCases.count))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(current.title.localized()). " +
                            L10n.addFlowStepCounter_fmt.formatted(current.rawValue + 1,
                                                                  AddServerStep.allCases.count))
    }
}

// MARK: - Shared bits

/// Lead paragraph at the top of a step.
struct AddServerLead: View {
    let text: L10n
    var body: some View {
        Text(text.localized())
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, Theme.Metrics.s2)
    }
}

/// Inline validation line under a field.
struct AddServerInlineError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(message)
    }
}

/// A label + value line in a summary card.
struct AddServerFactRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.s3) {
            Text(label)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: Theme.Metrics.s2)
            Text(value)
                .font(mono ? Theme.Typography.metricValue : Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .frame(minHeight: Theme.Metrics.controlHeight)
        .accessibilityElement(children: .combine)
    }
}

/// Small rounded badge (Recommended / Alternative / Primary / Needs Yandex).
struct AddServerBadge: View {
    let text: String
    var tone: OlcStatusTone = .ok

    var body: some View {
        Text(text)
            .font(Theme.Typography.captionStrong)
            .foregroundStyle(tone.color)
            .padding(.horizontal, Theme.Metrics.s2)
            .padding(.vertical, Theme.Metrics.s1)
            .background(tone.color.opacity(0.14), in: Capsule())
    }
}
