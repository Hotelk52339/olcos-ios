import SwiftUI

// MARK: - CarrierEndpointsView
//
// Opened from Connections → Diagnostics → "Using another proxy app?" while a
// tunnel is up, and from Settings › Advanced › Servers. Shows the carrier base
// host (derived from the connection params) plus its freshly-resolved IP(s) —
// the endpoints an external proxy app (Shadowrocket etc.) must route DIRECT so
// the tunnel's own carrier traffic does not loop back through the SOCKS port.
// Copy the host, an IP, or host + all IPs. Owns its own resolve state (IPs
// rotate, so it re-resolves on demand).
//
// Accuracy: the Go core exposes no live ICE / STUN / TURN endpoints, so this is
// the carrier base host + a resolver pass — a best-effort hint, not the
// addresses the running session actually negotiated.

struct CarrierEndpointsView: View {
    let params: OlcrtcConnection
    @Environment(\.dismiss) private var dismiss

    @State private var ips: [String] = []
    @State private var resolving = false

    /// nil when the carrier's roomID is an opaque ID, not a host (telemost /
    /// wbstream) — there's then nothing to exclude.
    private var host: String? { CarrierEndpoints.baseHost(for: params) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    leadIn
                }
                .signalFormRows()
                if let host {
                    Section {
                        endpointRow(label: L10n.carrierEndpointHost.localized(), value: host)
                    }
                    .signalFormRows()
                    Section {
                        resolvedIPsRow(host: host)
                    } header: {
                        SignalSectionHeader(L10n.carrierEndpointResolvedIPs.localized())
                    } footer: {
                        Text(L10n.carrierEndpointsFootnote.localized())
                    }
                    .signalFormRows()
                    Section {
                        Button {
                            copyAll(host: host)
                        } label: {
                            Label(L10n.carrierEndpointCopyAll.localized(), systemImage: "doc.on.doc")
                        }
                        .disabled(resolving)
                    }
                    .signalFormRows()
                } else {
                    Section {
                        Text(L10n.carrierEndpointNoHost.localized())
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    } footer: {
                        Text(L10n.carrierEndpointsFootnote.localized())
                    }
                    .signalFormRows()
                }
            }
            .signalFormChrome()
            .navigationTitle(L10n.carrierEndpointsScreenTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.closeAction.localized())
                }
            }
        }
        // IPs rotate, so resolve on appear; the row offers a re-resolve too.
        .task { if let host, ips.isEmpty { await resolve(host) } }
    }

    /// The "is this screen for me?" paragraph. Plain prose, read once.
    private var leadIn: some View {
        Text(L10n.carrierEndpointsLead.localized())
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One copyable endpoint: label + monospaced value + a copy button.
    private func endpointRow(label: String, value: String) -> some View {
        HStack(spacing: Theme.Metrics.s2) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(label)
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(value)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Theme.Metrics.s2)
            copyButton { copy(value) }
                .accessibilityValue(value)
        }
    }

    /// The resolved-IPs rows: a re-resolve action, then each IP copyable.
    @ViewBuilder
    private func resolvedIPsRow(host: String) -> some View {
        Button {
            Task { await resolve(host) }
        } label: {
            Label(L10n.carrierEndpointRefresh.localized(), systemImage: "arrow.clockwise")
        }
        .disabled(resolving)
        if resolving {
            HStack(spacing: Theme.Metrics.s2) {
                ProgressView()
                Text(L10n.carrierEndpointResolving.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        } else if ips.isEmpty {
            Text(L10n.carrierEndpointUnresolved.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else {
            ForEach(ips, id: \.self) { ip in
                HStack(spacing: Theme.Metrics.s2) {
                    Text(ip)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .textSelection(.enabled)
                    Spacer(minLength: Theme.Metrics.s2)
                    copyButton { copy(ip) }
                        .accessibilityValue(ip)
                }
            }
        }
    }

    private func copyButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Palette.accent)
                .frame(minWidth: Theme.Metrics.rowMinHeight, minHeight: Theme.Metrics.rowMinHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L10n.copyURIAction.localized())
    }

    /// Copies one value (host or IP) and logs it.
    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        LogStore.shared.log(.connection, L10n.carrierEndpointCopied_fmt.formatted(value))
    }

    /// Copies the host plus every resolved IP, newline-separated, in one action.
    private func copyAll(host: String) {
        let all = ([host] + ips).joined(separator: "\n")
        UIPasteboard.general.string = all
        Haptics.success()
        LogStore.shared.log(.connection, L10n.carrierEndpointCopied_fmt.formatted(host))
    }

    /// Resolves the carrier base host's current IPs (DNS pass). Re-runnable.
    private func resolve(_ host: String) async {
        guard !resolving else { return }
        resolving = true
        ips = await CarrierEndpoints.resolve(host: host)
        resolving = false
    }
}
