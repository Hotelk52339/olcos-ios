import SwiftUI

// #491: native Signal endpoint Form; copy/resolve methods and automatic probe scope stay unchanged.

// MARK: - CarrierEndpointsView (#406 — was #328's inline Connections card)
//
// Opened from Connections → Diagnostics → "Using another proxy app?" while a
// tunnel is up (#460 was: a row titled "Carrier endpoints", which named the
// mechanism rather than the situation, so nobody could tell whether it applied
// to them). Shows the carrier base host (derived from the connection params) plus its
// freshly-resolved IP(s) — the endpoints an external proxy app (Shadowrocket
// etc.) must route DIRECT so the olcrtc tunnel's own carrier traffic doesn't
// loop back through the SOCKS port. Copy the host, an IP, or host + all IPs.
//
// #406 was: an always-on Section in ConnectionsView that appeared the instant
// the tunnel connected and shifted the whole screen. The exclusions are debug
// info, not a permanent fixture, so they now live behind this on-demand sheet,
// which owns its own resolve state (IPs rotate, so it re-resolves on demand).
//
// Accuracy honesty (unchanged from #328): Mobile.objc.h exposes no live ICE /
// STUN / TURN endpoints, so this is the carrier base host + a resolver pass, a
// best-effort hint — not the addresses the running session actually negotiated.

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
            // boc #491: clear native sections instead of nested cards in a ScrollView.
            // #491 was: lead-in, host/IP/copy card, then a loose footnote.
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
            // eoc #491
            // #460 was: `carrierEndpointsTitle` ("Carrier endpoints") — the
            // vocabulary of the person who built it, not of the person who needs
            // it. The title now names the action the screen exists to support.
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

    /// #460: the "is this screen for me?" paragraph. Plain prose, no card — it is
    /// read once and then ignored by everyone whose phone has only olcrtc on it.
    private var leadIn: some View {
        Text(L10n.carrierEndpointsLead.localized())
            // #471: B9 — prose is step 3, never a raw `.subheadline`.
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    /// One copyable endpoint: label + monospaced value + a copy button.
    private func endpointRow(label: String, value: String) -> some View {
        HStack(spacing: Theme.Metrics.s2) {   // #471: B9 — 8 → s2
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {   // #471: 2 → s1
                Text(label)
                    // #471: B9 — this is a field label above a value (the
                    // `OlcMetric` shape), not a section header, so it takes step
                    // 5 semibold rather than `OlcSectionHeader`.
                    // #471 was: .font(.caption2.weight(.semibold))
                    .font(Theme.Typography.captionStrong)
                    // #491 was: uppercase tertiary label.
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(value)
                    // #471: B9 — an address is step 6, via its token.
                    // #471 was: .font(.system(.caption, design: .monospaced))
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            copyButton { copy(value) }
                .accessibilityValue(value) // #491: distinguish copy targets in VoiceOver.
        }
    }

    /// The resolved-IPs row: a re-resolve action + each IP copyable.
    // boc #491: each resolver result is an independent native Form row.
    // #491 was: header, refresh, status and every address shared one VStack/card row.
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
    // eoc #491

    private func copyButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                // #471: B9 — one of the two fixed point sizes left in the app
                // after #457; a fixed size ignores Dynamic Type, so the glyph
                // stayed put while the row around it grew.
                // #471 was: .font(.system(size: 15, weight: .semibold))
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Palette.accent)
                .frame(minWidth: Theme.Metrics.rowMinHeight, minHeight: Theme.Metrics.rowMinHeight) // #491
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless) // #491: independent copy buttons within native rows.
        .accessibilityLabel(L10n.copyURIAction.localized())
    }

    /// Copies one value (host or IP) and logs it.
    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        Haptics.success()   // #455: copy confirmation
        LogStore.shared.log(.connection, L10n.carrierEndpointCopied_fmt.formatted(value))
    }

    /// Copies the host plus every resolved IP, newline-separated, in one action.
    private func copyAll(host: String) {
        let all = ([host] + ips).joined(separator: "\n")
        UIPasteboard.general.string = all
        Haptics.success()   // #455: copy confirmation
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
