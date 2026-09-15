import SwiftUI

// MARK: - Tunnel settings sections
//
// The two sections `SettingsView` composes FIRST in its Form: the tunnel mode
// (the most consequential setting in the app — it changes what "Connected"
// means: one SOCKS port versus the whole device) and what happens when the app
// opens. Both render as native Form sections on the shared token ground.
//
// `TunnelSettingsComparison` — three consequence rows, written for the user
// rather than the implementer — is the shape to reuse anywhere two options have
// to be compared. It answers a question asked once, so it sits behind a
// disclosure instead of being permanently open at the top of Settings.

// MARK: - Mode picker

struct TunnelSettingsModeSection: View {
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject private var settings = SettingsStore.shared

    /// A live session — the only state in which the mode switch must be locked.
    /// `.failed` is deliberately NOT live, so a refused VPN start does not trap
    /// the user on VPN mode.
    private var sessionLive: Bool {
        tunnel.state.isConnected || tunnel.state.isConnecting || tunnel.state == .waitingForNetwork
    }

    var body: some View {
        Section {
            // The mode is read once, at connect time — switching mid-session
            // would silently not apply, so the picker is dimmed while a session
            // is live, and the note says why.
            Picker(L10n.configModeSectionHeader.localized(), selection: modePreferenceBinding) {
                ForEach(ConnectionModePreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .disabled(sessionLive)
            .opacity(sessionLive ? 0.55 : 1)
            if sessionLive {
                TunnelSettingsNote(text: L10n.tunnelModeLockedNote.localized())
            }
            TunnelSettingsNote(text: settings.connectionModePreference.hint)
            if let reason = tunnel.automaticModeFallbackReason {
                TunnelSettingsNote(text: L10n.vpnAutomaticFallbackSummary.localized())
                TunnelSettingsUnavailableNote(reason: reason)
            } else if settings.connectionModePreference == .vpn,
                      case .unavailable(let reason) = tunnel.vpn.capability {
                TunnelSettingsUnavailableNote(reason: reason)
            }
            DisclosureGroup(L10n.tunnelCompareDisclosure.localized()) {
                TunnelSettingsComparison()
            }
        } header: {
            SignalSectionHeader(L10n.configModeSectionHeader.localized())
        } footer: {
            // Credentials are cleared on disconnect; the supported start path is
            // the app, not the retained iOS Settings profile.
            if tunnel.effectiveModeForNextConnection == .vpn {
                Text(L10n.vpnStartFromAppOnlyNote.localized())
            }
        }
        .signalFormRows()
    }

    /// Feedback belongs to a changed user selection, not to a publisher
    /// observation that would also buzz for automatic fallback or restoration.
    private var modePreferenceBinding: Binding<ConnectionModePreference> {
        Binding(get: { settings.connectionModePreference }, set: { preference in
            guard preference != settings.connectionModePreference else { return }
            Haptics.tap()
            settings.connectionModePreference = preference
        })
    }
}

// MARK: - When the app opens

/// Launch behaviour: connect by yourself, and check what you own by yourself.
struct TunnelSettingsOnOpenSection: View {
    @ObservedObject private var settings = SettingsStore.shared

    /// Explicit (and empty) so the initializer is unambiguously `internal` —
    /// every stored property here is `private`, and SettingsView.swift builds
    /// this from another file.
    init() {}

    var body: some View {
        Section {
            Toggle(L10n.autoConnectOnLaunchLabel.localized(), isOn: $settings.autoConnectOnLaunch)
            TunnelSettingsNote(text: L10n.autoConnectOnLaunchNote.localized())
            Toggle(L10n.settingsRefreshOnEntryToggle.localized(), isOn: $settings.refreshOnEntry)
            TunnelSettingsNote(text: L10n.settingsRefreshOnEntryExplainer.localized())
        } header: {
            SignalSectionHeader(L10n.settingsSectionOnOpen.localized())
        }
        .signalFormRows()
    }
}

// MARK: - What the two modes mean FOR THE USER

/// Three consequence rows. Each row is one question the user actually has,
/// answered for both modes side by side, so the choice is made by comparing
/// outcomes rather than by parsing prose.
struct TunnelSettingsComparison: View {
    /// One question plus its two answers. `id` is a stable literal, not a UUID —
    /// the list is rebuilt on every body pass.
    private struct Line: Identifiable {
        let id: String
        let question: String
        let proxy: String
        let vpn: String
    }

    private var lines: [Line] {
        [
            Line(id: "scope",
                 question: L10n.tunnelCompareScope.localized(),
                 proxy: L10n.tunnelCompareScopeProxy.localized(),
                 vpn: L10n.tunnelCompareScopeVPN.localized()),
            Line(id: "needs",
                 question: L10n.tunnelCompareNeeds.localized(),
                 proxy: L10n.tunnelCompareNeedsProxy.localized(),
                 vpn: L10n.tunnelCompareNeedsVPN.localized()),
            Line(id: "runs",
                 question: L10n.tunnelCompareRuns.localized(),
                 proxy: L10n.tunnelCompareRunsProxy.localized(),
                 vpn: L10n.tunnelCompareRunsVPN.localized()),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            ForEach(lines) { line in
                TunnelSettingsComparisonRow(question: line.question,
                                            proxyLabel: TunnelMode.proxy.title,
                                            proxyValue: line.proxy,
                                            vpnLabel: TunnelMode.vpn.title,
                                            vpnValue: line.vpn)
            }
        }
        .padding(.vertical, Theme.Metrics.s1)
    }
}

/// One comparison row: the question, then the two answers. Restacks vertically
/// at accessibility sizes — a fixed two-column HStack squeezes both answers to
/// nothing at AX3.
struct TunnelSettingsComparisonRow: View {
    let question: String
    let proxyLabel: String
    let proxyValue: String
    let vpnLabel: String
    let vpnValue: String

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            Text(question)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Metrics.s3) { cells }
            } else {
                HStack(alignment: .top, spacing: Theme.Metrics.s4) { cells }
            }
        }
    }

    @ViewBuilder
    private var cells: some View {
        TunnelSettingsComparisonCell(mode: proxyLabel, value: proxyValue)
        TunnelSettingsComparisonCell(mode: vpnLabel, value: vpnValue)
    }
}

/// One answer: the mode's own name over the consequence, so the column is
/// labelled in place and never read from a header two rows up.
struct TunnelSettingsComparisonCell: View {
    let mode: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text(mode)
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(value)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared notes

/// The one treatment for every per-row explanation in Settings. A `Form` footer
/// belongs to its whole section, so an explanation written for one control can
/// end up under an unrelated row; a note sits under the control it describes
/// and cannot drift.
struct TunnelSettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .listRowSeparator(.hidden)
    }
}

/// The capability gate's verdict: a red lead-in plus the reason.
struct TunnelSettingsUnavailableNote: View {
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text(L10n.configVPNUnavailableFooter.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.red)
            Text(reason)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

#if DEBUG
#Preview("Tunnel settings — Dark") {
    Form {
        TunnelSettingsModeSection(tunnel: TunnelManager())
        TunnelSettingsOnOpenSection()
    }
    .signalFormChrome()
    .preferredColorScheme(.dark)
}
#Preview("Tunnel settings — Light") {
    Form {
        TunnelSettingsModeSection(tunnel: TunnelManager())
        TunnelSettingsOnOpenSection()
    }
    .signalFormChrome()
    .preferredColorScheme(.light)
}
#endif
