import SwiftUI

// MARK: - ServerAdvancedView (#459)
//
// #459: "Manage server" — the pushed destination behind the one low-emphasis row
// at the foot of a VPS card. It exists because the card's ⋯ menu had grown to
// THIRTEEN items, six of them destructive, and the owner had to open it for
// almost everything: "to do anything I have to go into those tiny three dots
// where SO MUCH is shown".
//
// The split is by frequency, not by danger alone:
//   • constantly       → the card's two text links (Logs, Manage ›)
//                        (#471 was: "visible buttons on the card (Check
//                        server, Container logs)" — both are gone as buttons)
//   • the next step    → the card's ONE primary button (Start / Stop / Install…)
//   • occasionally     → the card's ⋯ menu, now 5 safe items
//   • rarely / destructive → here
//
// A `Form` is the whole point of pushing rather than menu-ing. A `Menu` cannot
// render a footer, which is why "Wipe all olcrtc data from server" used to sit
// in a scrolling list with nothing but its own name to warn you. Every
// destructive row here carries a sentence saying what it destroys, and each one
// still ends in the SAME `.confirmationDialog` it always did (owned by
// ServersView.hostConfirmations) — so a destructive verb is now behind two
// deliberate steps, a push and a confirm, instead of one menu tap.
//
// Plain values and closures only — no stores, no `@ObservedObject` — the same
// rule `ServerCardView` and `ProtocolRowView` follow, so this screen costs the
// type-checker nothing. (ServersView has hit its expression budget three times.)

/// #471: the machine readings, moved off the VPS card. They are a diagnostic,
/// not a verdict — `df` / `free` / `uptime` and a TCP-22 round-trip — so they
/// belong on the screen you open when you want to LOOK at a server, not on the
/// one that answers "does it work". Pre-formatted by ServersView, whose
/// `shortUsage` / `shortRAM` / `shortUptime` statics stay there because
/// `VPSStatFormattingTests` pins them by name.
/// #471 was: `ServerCardMetrics` + `ServerMetricsGrid`
/// (App/Views/ServerCardView.swift) — a 2×2 grid of uppercase tracked labels
/// over body-size monospaced semibold values, on the card.
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
    /// #451: key-auth hosts cannot produce a full-access link (it would have to
    /// embed the private key). The row stays visible and explains on tap.
    let isKeyAuth: Bool
    /// A container is installed but no ConnectionRecord links to it (#303).
    let hasRecoverOption: Bool
    /// This host owns a ConnectionRecord — without one there is nothing to share.
    let hasLinkedConnection: Bool
    /// A probe found a container: Update / Remove container have a subject.
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
    // boc #471: what this screen is FOR, besides deleting things.
    /// "user@host:port", already IP-masked by the caller — the Machine
    /// section's identity line.
    let addressLine: String
    /// The four readings the VPS card used to draw as a grid.
    let machine: ServerMachineStats
    /// How old all of it is ("read 2 min ago"), or the honest "nothing has been
    /// read yet". This is where the card's deleted `readStamp` ends up: the one
    /// place where an age dates NUMBERS rather than a claim.
    let readCaption: String
    // eoc #471

    // boc #490
    // #490: values are rebuilt from the observed parent, not captured as State.
    let headline: HostHeadline
    let menuItems: [OlcMenuItem]
    // eoc #490

    /// Only a later key mismatch exposes recovery; first connection has no UI gate.
    let hasHostKeyMismatch: Bool
    let onResetHostKeyTrust: () -> Void
    @State private var confirmHostKeyReset = false

    var body: some View {
        Form {
            summarySection // #490: the same real dated verdict as the listing.
            hostKeyRecoverySection
            actionsSection // #490: edit, bot, share, scan, logs and add protocol.
            machineSection   // #471
            connectionSection
            maintenanceSection
            removeSection
        }
        .signalFormChrome() // #490 was: unstyled Form.
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

    @ViewBuilder private var hostKeyRecoverySection: some View {
        if hasHostKeyMismatch {
            Section {
                Text(L10n.sshHostKeyMismatch.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.sshHostKeyResetAction.localized(), role: .destructive) {
                    confirmHostKeyReset = true
                }
            } header: {
                SignalSectionHeader(L10n.sshHostKeyChangedTitle.localized())
            }
            .signalFormRows()
        }
    }

    // boc #490
    // #490 was: management opened straight into read-only machine stats.
    private var summarySection: some View {
        Section {
            ServerSignalStatus(tone: headline.tone, title: headline.title,
                               subtitle: headline.subtitle, isBusy: headlineIsBusy)
        } header: {
            SignalSectionHeader(hostLabel, systemImage: "server.rack")
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }

    private var headlineIsBusy: Bool {
        if case .busy = headline { return true }
        return false
    }

    private var actionsSection: some View {
        Section {
            ServerManagementMenuRows(items: menuItems)
        } header: {
            SignalSectionHeader(L10n.vpsManageServer.localized())
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }
    // eoc #490

    // MARK: Machine (#471)
    //
    // #471: the reason this screen is no longer only destructive rows. The
    // owner opened "Manage server" to find four ways to delete something; the
    // first thing it shows now is what the server IS — where it lives, how full
    // its disk is, how much memory it has, how long it has been up — dated once,
    // in the footer, by the reading all four came from.
    //
    // Read-only by construction: plain `Text`, no `Button`, no destination. The
    // card can afford to drop these because they are still HERE.

    private var machineSection: some View {
        Section {
            Text(addressLine)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
            statRow(L10n.vpsStatPing.localized(), machine.ping, tone: machine.pingTone)
            statRow(L10n.vpsStatDisk.localized(), machine.disk)
            statRow(L10n.vpsStatRAM.localized(),  machine.ram)
            statRow(L10n.vpsStatUp.localized(),   machine.uptime)
        } header: {
            SignalSectionHeader(L10n.vpsAdvancedMachineHeader.localized())
        } footer: {
            Text(readCaption)
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }

    /// #471: label left, value right — a `Form`'s own idiom, and the reason the
    /// deleted grid's label-above-value trick is not needed here: a Form row is
    /// the width of the phone, so nothing has to survive a ~150pt column. The
    /// two rules that DID matter travel with the numbers: no
    /// `minimumScaleFactor` anywhere (a value that shrinks to fit is a value the
    /// owner cannot read), and `lineLimit(1)` on the VALUE only, because a
    /// wrapped number is a lie while a wrapped label is merely a wrapped label.
    /// "—" is the same honesty placeholder the data side already returns.
    @Environment(\.dynamicTypeSize) private var typeSize // #490

    private func statRow(_ label: String, _ value: String, tone: Color? = nil) -> some View {
        // #490 was: always a horizontal label/value pair; AX labels need room.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Metrics.s1))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Metrics.s3))
        return layout {
            Text(label)
                .foregroundStyle(Theme.Palette.textSecondary)
            if !typeSize.isAccessibilitySize { Spacer(minLength: Theme.Metrics.s2) }
            Text(value.isEmpty ? "—" : value)
                .font(Theme.Typography.metricValue)
                .foregroundStyle(tone ?? Theme.Palette.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: Connection

    @ViewBuilder
    private var connectionSection: some View {
        if hasRecoverOption || hasLinkedConnection {
            Section {
                if hasRecoverOption {
                    plainRow(L10n.actionRecoverConnection.localized(),
                             systemImage: "arrow.counterclockwise.circle",
                             action: onRecover)
                }
                if hasLinkedConnection { shareFullAccessRow }
            } header: {
                SignalSectionHeader(L10n.vpsAdvancedConnectionHeader.localized())
            }
            .signalFormRows() // #490: retain native rows on Signal surfaces.
        }
    }

    /// #135/#451: destructive for password hosts (the link carries the SSH
    /// credentials); for key hosts the tap is the explanation instead, so the
    /// row must not wear the destructive role it will never perform.
    private var shareFullAccessRow: some View {
        Button(role: shareRole, action: onShareFullAccess) {
            Label(L10n.shareFullAccessTitle.localized(), systemImage: "key.horizontal")
        }
    }

    private var shareRole: ButtonRole? { isKeyAuth ? nil : .destructive }

    // MARK: Maintenance

    @ViewBuilder
    private var maintenanceSection: some View {
        Section {
            if hasContainer {
                // #459: the full label finally fits — in a menu row it competed
                // with twelve siblings for one line.
                plainRow(L10n.actionUpdate.localized(),
                         systemImage: "arrow.triangle.2.circlepath",
                         action: onUpdate)
            }
            destructiveRow(L10n.actionReboot.localized(),
                           systemImage: "arrow.clockwise",
                           note: L10n.vpsAdvancedRebootFooter.localized(),
                           action: onReboot)
        } header: {
            SignalSectionHeader(L10n.vpsAdvancedMaintenanceHeader.localized())
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }

    // MARK: Remove

    @ViewBuilder
    private var removeSection: some View {
        Section {
            if hasContainer {
                destructiveRow(L10n.actionUninstall.localized(),
                               systemImage: "trash",
                               note: L10n.vpsAdvancedUninstallFooter.localized(),
                               action: onUninstall)
            }
            if canDeepUninstall {
                destructiveRow(L10n.actionDeepUninstall.localized(),
                               systemImage: "flame",
                               note: L10n.vpsAdvancedDeepUninstallFooter.localized(),
                               action: onDeepUninstall)
            }
            destructiveRow(L10n.actionRemoveFromList.localized(),
                           systemImage: "minus.circle",
                           note: L10n.vpsAdvancedRemoveHostFooter.localized(),
                           action: onRemoveHost)
        } header: {
            SignalSectionHeader(L10n.vpsAdvancedRemoveHeader.localized())
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }

    // MARK: Rows

    private func plainRow(_ title: String, systemImage: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SignalSettingsLabel(title, systemImage: systemImage) // #490: same native action.
        }
    }

    /// #459: the sentence under the verb is the reason this screen exists.
    /// The note keeps its own secondary colour so the destructive tint stays on
    /// the NAME of the action and never washes out its explanation.
    private func destructiveRow(_ title: String, systemImage: String,
                                note: String,
                                action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {   // #471 was: 3
                Label(title, systemImage: systemImage)
                Text(note)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
