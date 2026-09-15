import SwiftUI

// MARK: - ServerAdvancedView
//
// "Manage server" — the pushed destination behind the low-emphasis row at the
// foot of a VPS card. Rare and destructive things live here, behind a push AND
// the confirmation dialog ServersView.hostConfirmations already owns, so no
// destructive verb is ever one tap away.
//
// Sections, top to bottom:
//   • Overview     — the dated verdict, the machine numbers as a grid, one
//                    "read N min ago" line.
//   • Host key     — only after a later key mismatch (TOFU recovery).
//   • Actions      — the card's safe menu items plus Logs / Add protocol.
//   • Connection   — recover the connection record, share full access.
//   • Maintenance  — update the server side, reboot.
//   • Danger zone  — the three removal actions, one short subtitle each.
//
// Plain values and closures only — no stores, no `@ObservedObject` — the same
// rule `ServerCardView` and `ProtocolRowView` follow, so this screen costs the
// type-checker nothing.

/// The machine readings: `df` / `free` / `uptime` and a TCP round-trip to the
/// SSH port. A diagnostic, not a verdict. Pre-formatted by ServersView, whose
/// `shortUsage` / `shortRAM` / `shortUptime` statics are pinned by
/// `VPSStatFormattingTests`.
struct ServerMachineStats {
    let ping: String
    let pingTone: Color
    let disk: String
    let ram: String
    let uptime: String
}

struct ServerAdvancedView: View {
    /// Server label, for the title.
    let hostLabel: String
    /// Key-auth hosts share the private key inside the full-access link; the
    /// row's subtitle says so before the sheet asks for confirmation.
    let isKeyAuth: Bool
    /// A container is installed but no ConnectionRecord links to it.
    let hasRecoverOption: Bool
    /// This host owns a ConnectionRecord — without one there is nothing to share.
    let hasLinkedConnection: Bool
    /// A probe found a container: Update / Remove protocols have a subject.
    let hasContainer: Bool
    /// Podman is present, so there is something a deep wipe could remove.
    let canDeepUninstall: Bool
    /// An SSH op holds the lane; every row here would collide with it.
    let actionsDisabled: Bool
    let onRecover: () -> Void
    let onShareFullAccess: () -> Void
    let onUpdate: () -> Void
    let onReboot: () -> Void
    let onUninstall: () -> Void
    let onDeepUninstall: () -> Void
    let onRemoveHost: () -> Void
    /// "user@host:port", already IP-masked by the caller.
    let addressLine: String
    let machine: ServerMachineStats
    /// "read 2 min ago", or the honest "nothing read yet".
    let readCaption: String
    /// Rebuilt from the observed parent on each render, never captured as State.
    let headline: HostHeadline
    /// Safe management actions (edit, scan, logs, add protocol). Dividers are skipped.
    let menuItems: [OlcMenuItem]
    /// Only a later key mismatch exposes recovery; first connection has no UI gate.
    let hasHostKeyMismatch: Bool
    let onResetHostKeyTrust: () -> Void

    @State private var confirmHostKeyReset = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Form {
            overviewSection
            hostKeyRecoverySection
            actionsSection
            connectionSection
            maintenanceSection
            dangerSection
        }
        .signalFormChrome()
        .navigationTitle(L10n.vpsAdvancedTitle_fmt.formatted(hostLabel))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(actionsDisabled)
        .confirmationDialog(L10n.sshHostKeyChangedTitle.localized(),
                            isPresented: $confirmHostKeyReset,
                            titleVisibility: .visible) {
            Button(L10n.sshHostKeyResetAction.localized(), role: .destructive) {
                guard hasHostKeyMismatch, !actionsDisabled else { return }
                onResetHostKeyTrust()
            }
            Button(L10n.cancel.localized(), role: .cancel) { }
        } message: {
            Text(L10n.sshHostKeyResetWarning.localized())
        }
    }

    // MARK: Overview

    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                ServerSignalStatus(tone: headline.tone, title: headline.title,
                                   subtitle: headline.subtitle, isBusy: headlineIsBusy)
                Text(addressLine)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, Theme.Metrics.s1)
            metricsGrid
                .padding(.vertical, Theme.Metrics.s2)
            Text(readCaption)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        } header: {
            SignalSectionHeader(L10n.vpsAdvancedOverviewHeader.localized(), systemImage: "server.rack")
        }
        .signalFormRows()
    }

    private var headlineIsBusy: Bool {
        if case .busy = headline { return true }
        return false
    }

    /// Ping · Disk · RAM · Uptime — two columns, four at accessibility sizes
    /// collapse to one so long values never fight for width.
    private var metricsGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), alignment: .leading),
                            count: typeSize.isAccessibilitySize ? 1 : 2)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Metrics.s4) {
            OlcMetric(label: L10n.vpsStatPing.localized(), value: metricValue(machine.ping),
                      tone: machine.pingTone)
            OlcMetric(label: L10n.vpsStatDisk.localized(), value: metricValue(machine.disk))
            OlcMetric(label: L10n.vpsStatRAM.localized(),  value: metricValue(machine.ram))
            OlcMetric(label: L10n.vpsStatUp.localized(),   value: metricValue(machine.uptime))
        }
    }

    private func metricValue(_ raw: String) -> String { raw.isEmpty ? "—" : raw }

    // MARK: Host key recovery

    @ViewBuilder private var hostKeyRecoverySection: some View {
        if hasHostKeyMismatch {
            Section {
                row(L10n.sshHostKeyResetAction.localized(),
                    subtitle: L10n.sshHostKeyMismatch.localized(),
                    systemImage: "key.slash",
                    destructive: true) { confirmHostKeyReset = true }
            } header: {
                SignalSectionHeader(L10n.sshHostKeyChangedTitle.localized())
            }
            .signalFormRows()
        }
    }

    // MARK: Actions

    @ViewBuilder private var actionsSection: some View {
        if menuItems.contains(where: { if case .button = $0.kind { return true } else { return false } }) {
            Section {
                ServerManagementMenuRows(items: menuItems)
            } header: {
                SignalSectionHeader(L10n.vpsAdvancedActionsHeader.localized())
            }
            .signalFormRows()
        }
    }

    // MARK: Connection

    @ViewBuilder private var connectionSection: some View {
        if hasRecoverOption || hasLinkedConnection {
            Section {
                if hasRecoverOption {
                    row(L10n.actionRecoverConnection.localized(),
                        subtitle: L10n.vpsAdvancedRecoverSub.localized(),
                        systemImage: "arrow.counterclockwise.circle",
                        action: onRecover)
                }
                if hasLinkedConnection {
                    row(L10n.shareFullAccessTitle.localized(),
                        subtitle: (isKeyAuth ? L10n.shareFullAccessKeySub : L10n.shareFullAccessPasswordSub).localized(),
                        systemImage: "key.horizontal",
                        action: onShareFullAccess)
                }
            } header: {
                SignalSectionHeader(L10n.vpsAdvancedConnectionHeader.localized())
            }
            .signalFormRows()
        }
    }

    // MARK: Maintenance

    private var maintenanceSection: some View {
        Section {
            if hasContainer {
                row(L10n.actionUpdate.localized(),
                    subtitle: L10n.actionUpdateSub.localized(),
                    systemImage: "arrow.triangle.2.circlepath",
                    action: onUpdate)
            }
            row(L10n.actionReboot.localized(),
                subtitle: L10n.vpsAdvancedRebootFooter.localized(),
                systemImage: "arrow.clockwise",
                action: onReboot)
        } header: {
            SignalSectionHeader(L10n.vpsAdvancedMaintenanceHeader.localized())
        }
        .signalFormRows()
    }

    // MARK: Danger zone

    private var dangerSection: some View {
        Section {
            if hasContainer {
                row(L10n.actionUninstall.localized(),
                    subtitle: L10n.vpsAdvancedUninstallFooter.localized(),
                    systemImage: "trash",
                    destructive: true, action: onUninstall)
            }
            if canDeepUninstall {
                row(L10n.actionDeepUninstall.localized(),
                    subtitle: L10n.vpsAdvancedDeepUninstallFooter.localized(),
                    systemImage: "flame",
                    destructive: true, action: onDeepUninstall)
            }
            row(L10n.actionRemoveFromList.localized(),
                subtitle: L10n.vpsAdvancedRemoveHostFooter.localized(),
                systemImage: "minus.circle",
                destructive: true, action: onRemoveHost)
        } header: {
            SignalSectionHeader(L10n.vpsAdvancedRemoveHeader.localized())
        }
        .signalFormRows()
    }

    // MARK: Row

    /// One row style for the whole screen: icon, title, one-line subtitle.
    /// Destructive rows colour the title only — icon and subtitle stay quiet.
    private func row(_ title: String, subtitle: String, systemImage: String,
                     destructive: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    Text(title)
                        .font(Theme.Typography.body)
                        .foregroundStyle(destructive ? Theme.Palette.red : Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: Theme.Metrics.rowMinHeight)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}
