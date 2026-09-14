import SwiftUI

// MARK: - ProtocolRowView (#457)
//
// #457: the per-protocol row, cut out of `ServersView.carrierRowView` +
// `carrierRowLead`. ServersView has hit the Swift type-checker's expression
// budget twice (see `ServersView.carrierModals`), so everything this screen
// gains from here on lands in a small, value-driven struct like this one: every
// input is a plain value or a closure, and every parameter is explicitly typed,
// so the row costs the type-checker nothing to resolve.
//
// This is the densest element in the app — one row has to answer "what is this
// protocol, does it work, and how do I know". #460: "one row", not "one
// line" — the labels column is ~105pt wide once the evidence chip and the
// fixed 44pt menu have taken theirs, so each answer gets a line of its own
// rather than a share of one. The two inversions it fixes:
//
//  • SEMANTIC — nothing here is carried by colour alone. The evidence chip
//    renders glyph + word + age; the row adds the WORD "Live" for the protocol
//    the tunnel is running through (#460 was: "Connected", which was long
//    enough to be hyphenated into "Connec-ted"; #471 was: that word on a line
//    of its own with a bolt glyph — it leads the subtitle now), and a plain
//    sentence when the server-side process is not running.
//    #457 was: a cyan `checkmark.circle.fill` whose only text was an
//    `accessibilityLabel`, i.e. "live" was a colour to everyone who could see it.
//
//  • DECORATION — #455's aurora WASH, its cyan hairline and the cyan checkmark
//    are gone (`Theme.Palette.auroraSoft` is deleted). The aurora survives as
//    exactly ONE thing: a 3pt leading spine, and only where it is a VERDICT —
//    the row is live AND a probe verified it inside the freshness window.
//
// boc #471: ONE protocol row for both tabs. A protocol was drawn by two
// unrelated components — `ConnectionRowView` on Connect (its own card, a
// rounded body-step title, a caption subtitle) and this one on Servers (an
// inset plate at radius 12 inside a radius-20 card, a `.subheadline` title —
// the only non-rounded title in the app — and a caption2 subtitle). Same
// object, two dialects, so the model has to be learned twice.
// Three deletions align them, and nothing is added:
//   • the plate and its `rowShape` — the card is already a container, and a
//     container inside a container at a smaller radius is not concentric.
//     Rows separate with a hairline in `ServerCardView.protocolsSection`;
//   • the "⚡ Live" LINE — the word leads `subtitleText` instead, so a row is
//     at most two lines: `[Live] · transport · [not running]`;
//   • the `primary` tag and its `isPrimary` input — which container anchors
//     the deploy dir is an internal concept the design plan's cut list
//     retires, and it was the one token on the row with no user meaning.
// eoc #471

struct ProtocolRowView: View {
    /// #461: the SERVICE this protocol hides the traffic inside — the row's
    /// identity ("Yandex Telemost"), composed by `ServersView.rowView` from the
    /// same `CarrierTransportMatrix` labels the Connect tab reads through
    /// `ConnectionNaming.service(_:)`.
    /// #461 was: "Carrier display name ("Telemost")".
    let title: String
    /// #461: HOW it is carried, already a display LABEL ("VP8"), not the raw
    /// transport id. It leads `subtitleText`, one line under the service.
    /// #461 was: "Transport display name ("vp8channel")" — the doc named the id
    /// while the call site has always passed `transportLabel(_:)`.
    let transport: String
    // #471 was: `let isPrimary: Bool` — "the srv.sh-installed protocol, the one
    // whose container anchors the deploy dir". True, internal, and of no use to
    // anyone reading the row; it printed a `primary` tag in the subtitle.
    /// The live tunnel currently runs through this protocol.
    let isLive: Bool
    /// The server-side process for this protocol is up (a real reading, not a guess).
    let isRunningOnServer: Bool
    /// Measured evidence — the ONLY source of green (App/Models/NodeHealth.swift).
    let health: HealthDisplay
    /// True while an SSH op holds the lane.
    let menuDisabled: Bool
    /// The complete action set for this protocol — ONE menu, no rival controls.
    let menuItems: [OlcMenuItem]
    /// Re-run the end-to-end probe for THIS protocol.
    let onVerify: () -> Void
    // #490: the row can be used without opening overflow; same connectVia path.
    let onConnect: () -> Void

    /// #460: the one thing the row's shape adapts to. Private with a default,
    /// so the memberwise init ServersView calls is unchanged.
    @Environment(\.dynamicTypeSize) private var typeSize

    // boc #460: finding 16 — the live row hyphenated its own status word
    // ("Connec-ted"). The row is three channels wide — labels, evidence chip
    // and the overflow menu — and the menu costs a FIXED 44pt at every text size, so
    // on a 393pt phone the labels column is left with roughly 105pt. A carrier
    // name and a status word never fitted in that together, and SwiftUI resolves
    // an impossible line by breaking the last word in it.
    //
    // Three changes, each removing one cause:
    //   1. the badge has its OWN line (see `labels`), so it never competes with
    //      the carrier name for width;
    //   2. it is `lineLimit(1)` + `fixedSize`, which makes a break impossible at
    //      any width it is ever offered — the chip beside it is the flexible one
    //      and is documented to wrap instead (App/UI/HealthChip.swift);
    //   3. the word itself is shorter (`protocolLiveBadge`), because the old one
    //      was the longest string in the row in both languages.
    // #471 was: "The `primary` tag left the title line for the same reason and
    // now joins the technical subtitle" — the tag is deleted outright. What is
    // left in the subtitle still wraps freely and still breaks only at a " · "
    // between words, never inside one.
    var body: some View {
        layout
            // #471 was: `.padding(.vertical, 10)` + `.padding(.trailing, 8)` +
            // `.background(Theme.Palette.fill.opacity(0.5), in: rowShape)`.
            // With no plate there is nothing for a trailing inset to sit inside
            // — the overflow menu keeps its own 44pt — and the vertical padding
            // goes on the grid.
            .padding(.vertical, Theme.Metrics.s2)
    }

    /// #460: at the accessibility text sizes the evidence chip alone is wider
    /// than the whole labels column, so the row stops sharing one line. Two
    /// whole layouts rather than one with `if`s inside it, so each stays a tiny
    /// expression.
    /// #471 was: "…the same rule `ServerMetricsGrid` follows for the machine
    /// numbers" — that grid is deleted; this row is the last place on the card
    /// where a fold at accessibility sizes is still load-bearing.
    @ViewBuilder
    private var layout: some View {
        if typeSize.isAccessibilitySize { stacked } else { inline }
    }

    // boc #490
    // #490 was: carrier identity, evidence and overflow competed on one line.
    // Both regular and accessibility layouts give identity the full row width;
    // evidence and the explicit Connect action occupy their own lower line.
    private var inline: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            identityRow
            HStack(alignment: .center, spacing: Theme.Metrics.s2) {
                OlcHealthChip(display: health, onTap: onVerify)
                Spacer(minLength: 0)
                connectButton
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            identityRow
            OlcHealthChip(display: health, onTap: onVerify)
            connectButton
        }
    }

    private var identityRow: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s3) {
            labels
            Spacer(minLength: 0)
            overflow
        }
        .overlay(alignment: .leading) { spine }
    }

    private var connectButton: some View {
        // #490 was: Button(action: onConnect). Feedback belongs to the explicit
        // tap, not connection observation; a live/current row is a no-op.
        Button {
            guard !menuDisabled, !isLive else { return }
            Haptics.impact()
            onConnect()
        } label: {
            Label(isLive ? L10n.protocolLiveBadge.localized() : L10n.protocolConnectAction.localized(),
                  systemImage: "personalhotspot")
                .font(Theme.Typography.label)
                .foregroundStyle(isLive ? Theme.Palette.textSecondary : Theme.Signal.stroke)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: Theme.Metrics.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(menuDisabled || isLive)
    }
    // eoc #490

    private var overflow: some View {
        OlcOverflowMenu(items: menuItems)
            .disabled(menuDisabled)
    }
    // eoc #460

    // #471 was: `rowShape` — the plate's RoundedRectangle(cornerRadius: 12)
    // inside a card whose own radius is 20 and whose padding is 16, i.e. a
    // corner that could not be concentric with the one around it at any inset.

    /// #457: the only aurora left on this screen, and it is a verdict mark.
    /// Live + verified → aurora. Live but unproven → a neutral spine (the row is
    /// still the one carrying traffic, we just have no proof yet). Anything else
    /// → nothing at all, because an unproven row must draw nothing.
    private var spine: some View {
        Capsule(style: .continuous)
            .fill(spineStyle)
            .frame(width: 3)
            .frame(height: Theme.Metrics.s6) // #490 was: unbounded height.
            .offset(x: -Theme.Metrics.s2)
            // #471 was: `.padding(.leading, 5)` — the inset the deleted plate
            // needed. The spine sits at the row's leading edge now, so it reads
            // as a list accent rather than a mark floating inside a box.
            .accessibilityHidden(true)
    }

    private var spineStyle: AnyShapeStyle {
        if isLive && health.isVerified { return AnyShapeStyle(Theme.Signal.stroke) } // #490 was: aurora; live remains named.
        if isLive { return AnyShapeStyle(Theme.Palette.textTertiary) }
        return AnyShapeStyle(Color.clear)
    }

    // #460 was: `titleLine` — an HStack packing the carrier name, the live
    // badge and the `primary` tag onto one ~105pt line.
    // #471: TWO lines that each fit, not three — the title, and one subtitle
    // holding everything else. The `primary` tag is not moved any more, it is
    // deleted.
    private var labels: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {   // #471 was: 3
            Text(title)
                // #471 was: `.subheadline.weight(isLive ? .semibold : .regular)`
                // — the only non-rounded title in the app, for the same object
                // ConnectionRowView titles at `Theme.Typography.bodyStrong`.
                // Same two weights, one step up, in the scale's own face.
                .font(isLive ? Theme.Typography.bodyStrong : Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                // boc #461: TWO lines, not one.
                // #460 was: `.lineLimit(1)`, on the stated premise that "carrier
                // names are 5-8 characters, so this is a backstop rather than
                // something anyone will see". That premise expired the moment
                // the carrier became its full service name ("Yandex Telemost",
                // «Яндекс Телемост») — at one line it is the very word the owner
                // asked to see, ellipsised, in a labels column that is ~105pt
                // once the evidence chip and the fixed 44pt menu have taken
                // theirs.
                // What #460 actually guaranteed was never "one line", it was
                // "never break a WORD" (finding 16, "Connec-ted"). Two lines
                // keep that guarantee intact: the break falls on the space
                // between the two words, and each of them is far narrower than
                // the column at every non-accessibility text size — and at
                // accessibility sizes `stacked` gives the labels the whole row.
                // #490 was: .lineLimit(2); keep the complete carrier at every text size.
                .fixedSize(horizontal: false, vertical: true)
                // eoc #461
            // #471 was: `if isLive { liveBadge }` — a THIRD line carrying one
            // word. The word leads `subtitleText` now, so the row is two lines
            // at most and the live protocol is still named, not painted.
            Text(subtitleText)
                // #471 was: `.font(.caption2)` — the seventh size step
                // `Theme.swift` abolished, and one step below the caption
                // ConnectionRowView uses for the same line.
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // #471 was: `liveBadge` — a `Label("Live", systemImage: "bolt.horizontal.fill")`
    // on a line of its own, `lineLimit(1)` + `fixedSize` so the word could never
    // be hyphenated ("Connec-ted", #460 finding 16). Deleting the LINE keeps
    // that guarantee for free: the word now sits inside a subtitle that is
    // allowed to wrap, and it wraps at the " · " boundaries between its parts,
    // never inside a word. The glyph goes with the line — the row already draws
    // an aurora spine for live-and-verified, and the word itself is the
    // semantic marker the #457 note demands.

    /// #457 was: `"\(transport) · \(row.status.shortLabel)"` — raw `podman ps`
    /// text ("Up 3 hours", "Exited (137) 5 minutes ago") sitting in a top-level
    /// row. Process liveness answers a question the user did not ask; a stopped
    /// process is one plain sentence and a running one adds nothing.
    /// #471: `[Live] · transport · [not running]`, the row's ONE secondary line.
    /// The live word leads because it is the most important thing true of this
    /// row; the transport is what it is carried by; the stopped note is the
    /// exception. `protocolPrimaryBadge` is gone from it (see `isPrimary`).
    /// #471 was: `[transport] · [primary] · [not running]`, with "⚡ Live" on a
    /// third line above it.
    private var subtitleText: String {
        var parts: [String] = []
        if isLive { parts.append(L10n.protocolLiveBadge.localized()) }
        parts.append(transport)
        if !isRunningOnServer { parts.append(L10n.protocolStoppedNote.localized()) }
        return parts.joined(separator: " · ")
    }
}

// #340: both appearance variants.
#if DEBUG
#Preview("Protocol row — Dark") {
    // #471: separated the way `ServerCardView.protocolsSection` separates them
    // — one grid step and a hairline — since the rows no longer draw a plate of
    // their own. A preview that keeps the old container previews a row the app
    // does not draw.
    VStack(spacing: Theme.Metrics.s3) {
        // #461: the real strings the call site passes — service labels (the
        // longest of them is the one this row has to survive) over transport
        // LABELS, not raw ids. A preview that lies about its inputs cannot show
        // the width pressure the row is built for.
        ProtocolRowView(title: "Yandex Telemost", transport: "VP8",
                        isLive: true, isRunningOnServer: true,
                        health: .verified(ms: 48, age: 120),
                        menuDisabled: false, menuItems: [], onVerify: {}, onConnect: {})
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
