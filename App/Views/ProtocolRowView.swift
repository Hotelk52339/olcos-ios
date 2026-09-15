import SwiftUI

// MARK: - ProtocolRowView
//
// One compact row per protocol on a server card. Every input is a plain value
// or a closure and every parameter is explicitly typed, so the row costs the
// ServersView type-checker nothing to resolve.
//
// The row answers "what is this protocol, does it work, and how do I connect":
//  • identity — "carrier · transport", one line, never duplicated in the chip;
//  • state — one short word under the identity (live / not running on the
//    server), omitted when nothing is exceptional;
//  • evidence — the ONE `OlcHealthChip` (App/UI/HealthChip.swift), the same
//    glow-dot status the Connections rows draw, and the only source of colour;
//  • the row itself is the connect control; the overflow menu holds the rest.
// Nothing here is carried by colour alone: the live protocol is NAMED, and the
// leading spine is a verdict mark (live and verified), not decoration.

struct ProtocolRowView: View {
    /// Service display name ("Yandex Telemost"), from `CarrierTransportMatrix.carrierLabel`.
    let title: String
    /// Transport display label ("VP8"), from `CarrierTransportMatrix.transportLabel`.
    let transport: String
    /// The live tunnel currently runs through this protocol.
    let isLive: Bool
    /// The server-side process for this protocol is up (a real reading, not a guess).
    let isRunningOnServer: Bool
    /// Measured evidence — the ONLY source of colour (App/Models/NodeHealth.swift).
    let health: HealthDisplay
    /// True while an SSH op holds the lane.
    let menuDisabled: Bool
    /// The complete action set for this protocol — ONE menu, no rival controls.
    let menuItems: [OlcMenuItem]
    /// Verified one-line descriptions of the carrier and transport
    /// (`ProtocolDescriptions.lines`); shown on demand from the menu.
    var detailLines: [String] = []
    /// Re-run the end-to-end probe for THIS protocol.
    let onVerify: () -> Void
    /// Connect through this protocol (the whole row is the control).
    let onConnect: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            connectRow
            if showsDetail, !detailLines.isEmpty { detail }
        }
        .padding(.vertical, Theme.Metrics.s2)
    }

    /// The tappable body: identity + state on the left, evidence chip on the
    /// right, overflow at the trailing edge. A live row is not re-connectable.
    private var connectRow: some View {
        HStack(alignment: .center, spacing: Theme.Metrics.s2) {
            Button {
                guard !menuDisabled, !isLive else { return }
                Haptics.impact()
                onConnect()
            } label: {
                layout
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: Theme.Metrics.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(menuDisabled || isLive)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityHint(isLive ? "" : L10n.actionConnect.localized())
            OlcOverflowMenu(items: allMenuItems)
                .disabled(menuDisabled)
        }
        .overlay(alignment: .leading) { spine }
    }

    @ViewBuilder
    private var layout: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                labels
                OlcHealthChip(display: health, onTap: onVerify)
            }
        } else {
            // The title owns the width: it takes what it needs first and the
            // chip yields (scales to 85 %, then truncates) rather than the
            // row wrapping onto a third line.
            HStack(alignment: .center, spacing: Theme.Metrics.s3) {
                labels
                    .layoutPriority(1)
                Spacer(minLength: Theme.Metrics.s2)
                OlcHealthChip(display: health, onTap: onVerify)
            }
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text("\(title) · \(transport)")
                .font(isLive ? Theme.Typography.bodyStrong : Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(OlcHealthDotMetrics.minimumScale)
                .fixedSize(horizontal: false, vertical: true)
            if let state = stateText {
                Text(state)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// The one exceptional fact about this row, or nil when there is none.
    private var stateText: String? {
        if isLive { return L10n.protocolLiveBadge.localized() }
        if !isRunningOnServer { return L10n.protocolStoppedNote.localized() }
        return nil
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            ForEach(detailLines, id: \.self) { line in
                Text(line)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, Theme.Metrics.s1)
    }

    /// Menu = the caller's actions plus "About this protocol" when there is a
    /// description to show.
    private var allMenuItems: [OlcMenuItem] {
        guard !detailLines.isEmpty else { return menuItems }
        let about = OlcMenuItem.action(
            showsDetail ? L10n.protocolAboutHide.localized() : L10n.protocolAboutAction.localized(),
            systemImage: "info.circle") { showsDetail.toggle() }
        return menuItems + [.divider, about]
    }

    /// Verdict mark: live + verified → stroke; live but unproven → neutral;
    /// anything else → nothing, because an unproven row must draw nothing.
    private var spine: some View {
        Capsule(style: .continuous)
            .fill(spineStyle)
            .frame(width: 3)
            .frame(height: Theme.Metrics.s6)
            .offset(x: -Theme.Metrics.s2)
            .accessibilityHidden(true)
    }

    private var spineStyle: AnyShapeStyle {
        if isLive && health.isVerified { return AnyShapeStyle(Theme.Signal.stroke) }
        if isLive { return AnyShapeStyle(Theme.Palette.textTertiary) }
        return AnyShapeStyle(Color.clear)
    }

    private var accessibilityTitle: String {
        var parts = ["\(title) · \(transport)"]
        if let state = stateText { parts.append(state) }
        return parts.joined(separator: ". ")
    }
}

#if DEBUG
#Preview("Protocol row — Dark") {
    VStack(spacing: Theme.Metrics.s3) {
        ProtocolRowView(title: "Yandex Telemost", transport: "VP8",
                        isLive: true, isRunningOnServer: true,
                        health: .verified(ms: 48, age: 120),
                        menuDisabled: false, menuItems: [],
                        detailLines: ProtocolDescriptions.lines(carrier: "telemost", transport: "vp8channel"),
                        onVerify: {}, onConnect: {})
        Divider().overlay(Theme.Palette.separator)
        ProtocolRowView(title: "Jitsi", transport: "DataChannel",
                        isLive: false, isRunningOnServer: false,
                        health: .never,
                        menuDisabled: false, menuItems: [], onVerify: {}, onConnect: {})
        Divider().overlay(Theme.Palette.separator)
        ProtocolRowView(title: "WB Stream", transport: "SEI",
                        isLive: false, isRunningOnServer: true,
                        health: .broken(.keyMismatch, age: 300),
                        menuDisabled: false, menuItems: [], onVerify: {}, onConnect: {})
    }
    .padding()
    .background(Theme.Palette.bg)
    .preferredColorScheme(.dark)
}
#endif
