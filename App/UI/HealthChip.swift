import SwiftUI

// MARK: - OlcHealthChip
//
// The ONE evidence chip. Renders a `HealthDisplay` (App/Models/NodeHealth.swift)
// as a calm, right-aligned status: a small glowing dot in the status colour,
// one primary line in the regular caption face (`146 ms`, `Server didn't
// answer`, `Not checked`) and, when there is an age to date it with, a smaller
// tertiary age (`now`, `5m`). Green is granted ONLY by `.verified`; every other
// state is neutral, amber or red, so colour never outruns the evidence. Both the
// Connections rows and the Servers tab's protocol rows render this view, so
// "146 ms · now" means the same on both tabs.
//
// Rules the chip enforces:
//  • Never wraps, never grows the row. Each line is ONE line; long verdicts
//    scale down to 85 % and then truncate. The row's title carries the layout
//    priority, so the chip yields first.
//  • No capsule, no border, no mono face. The old pill drew a hairline
//    capsule around a monospaced sentence; the user called it crooked.
//  • Still readable without colour. With "Differentiate Without Colour" on,
//    the dot becomes the state's own SF Symbol (`OlcHealthGlyph`); the primary
//    line differs by WORD in every state regardless.
//  • `.checking` swaps the dot for a mini spinner — an in-flight probe is the
//    one state where motion IS the honest signal.

/// `HealthDisplay` → SF Symbol, one silhouette per state. `HealthDisplay.tone`
/// returns `.unknown` for four distinct states, so the health vocabulary needs
/// its own, finer mapping. Drawn instead of the dot under "Differentiate
/// Without Colour", and used by VoiceOver-free grayscale checks.
enum OlcHealthGlyph {
    static func symbol(for display: HealthDisplay) -> String {
        switch display {
        case .never:          return "questionmark.circle"                        // no test has run
        case .checking:       return "arrow.triangle.2.circlepath"                // in flight
        case .verified:       return "checkmark.circle.fill"                      // filled = present tense
        case .fading:         return "checkmark.circle"                           // hollow = past tense
        case .handshakeOnly:  return "exclamationmark.triangle.fill"              // came up, unproven
        case .broken:         return "xmark.octagon.fill"                         // octagon ≠ every circle
        case .inconclusive:   return "antenna.radiowaves.left.and.right.slash"    // we could NOT check
        case .stale:          return "clock.arrow.circlepath"                     // too old to rely on
        }
    }
}

/// Geometry of the glow dot — one place, so the two tabs draw the same dot.
enum OlcHealthDotMetrics {
    /// The solid core.
    static let core: CGFloat = 8
    /// The soft ring behind it (drawn at low alpha, then blurred).
    static let halo: CGFloat = 16
    /// Alpha of the halo for a state that carries a real colour.
    static let haloAlpha: Double = 0.28
    /// Alpha of the halo for a neutral (grey) state — present, but quieter.
    static let neutralHaloAlpha: Double = 0.12
    /// Long verdicts may shrink this far before they truncate.
    static let minimumScale: CGFloat = 0.85
}

struct OlcHealthChip: View {
    let display: HealthDisplay
    /// When non-nil the chip becomes a button (re-verify on tap).
    var onTap: (() -> Void)? = nil

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        // Tappable and static chips draw the identical status — only the touch
        // target and the accessibility traits differ.
        if onTap != nil {
            Button { onTap?() } label: { chip }
                .buttonStyle(.plain)
                // Grow the touch region to the control minimum without
                // enlarging what is drawn.
                .frame(minHeight: Theme.Metrics.controlHeight)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(.isButton)
        } else {
            chip
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
        }
    }

    /// Dot on the left, the two text lines stacked and right-aligned beside it.
    /// `fixedSize(horizontal: false, vertical: true)` lets the stack take its
    /// natural height while the parent HStack still decides its width.
    private var chip: some View {
        HStack(alignment: .center, spacing: Theme.Metrics.s2) {
            indicator
            VStack(alignment: .trailing, spacing: 0) {
                Text(text.primary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(OlcHealthDotMetrics.minimumScale)
                    .truncationMode(.tail)
                if let age = text.secondary {
                    Text(age)
                        .font(Theme.Typography.caption)
                        .textScale(.secondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(OlcHealthDotMetrics.minimumScale)
                }
            }
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Metrics.s1)
    }

    /// The tone channel: a glowing dot, or the state's glyph when the user has
    /// asked not to rely on colour, or a spinner while a probe is in flight.
    @ViewBuilder
    private var indicator: some View {
        if display.isChecking {
            ProgressView()
                .controlSize(.mini)
                .frame(width: OlcHealthDotMetrics.halo, height: OlcHealthDotMetrics.halo)
        } else if differentiateWithoutColor {
            Image(systemName: OlcHealthGlyph.symbol(for: display))
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(dotColor)
                .frame(width: OlcHealthDotMetrics.halo, height: OlcHealthDotMetrics.halo)
        } else {
            glowDot
        }
    }

    /// 8pt core over a soft 16pt halo. The halo is the core's own colour at low
    /// alpha with a small blur, so it reads as light spilling from the dot, not
    /// as a second ring.
    private var glowDot: some View {
        ZStack {
            Circle()
                .fill(dotColor.opacity(haloAlpha))
                .frame(width: OlcHealthDotMetrics.halo, height: OlcHealthDotMetrics.halo)
                .blur(radius: 2)
            Circle()
                .fill(dotColor)
                .frame(width: OlcHealthDotMetrics.core, height: OlcHealthDotMetrics.core)
        }
        .frame(width: OlcHealthDotMetrics.halo, height: OlcHealthDotMetrics.halo)
        .accessibilityHidden(true)
    }

    private var isNeutral: Bool { display.tone == .unknown }

    private var haloAlpha: Double {
        isNeutral ? OlcHealthDotMetrics.neutralHaloAlpha : OlcHealthDotMetrics.haloAlpha
    }

    /// `OlcStatusTone.color` already maps `.unknown` to the tertiary text colour.
    private var dotColor: Color { display.tone.color }

    /// The verdict line: primary text for an earned present-tense value, the
    /// secondary text colour for everything else. Never the tone colour — the
    /// dot carries the tone, the words carry the fact.
    private var primaryColor: Color {
        display.isVerified ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
    }

    private var text: HealthChipText { display.chipText }

    /// VoiceOver gets the full sentence ("Verified. 48 ms, checked 2m ago"),
    /// not the compressed chip text.
    private var accessibilityText: String {
        "\(display.title). \(display.subtitle)"
    }
}

#if DEBUG
/// Acceptance preview — eight states, eight words, one dot. If any two rows
/// read alike with Color Filters → Grayscale on, `chipText` is wrong.
#Preview("OlcHealthChip — the eight states") {
    VStack(alignment: .trailing, spacing: Theme.Metrics.s3) {
        OlcHealthChip(display: .never)
        OlcHealthChip(display: .checking)
        OlcHealthChip(display: .verified(ms: 128, age: 20))
        OlcHealthChip(display: .fading(ms: 128, age: 600))
        OlcHealthChip(display: .handshakeOnly(age: 45))
        OlcHealthChip(display: .broken(.keyMismatch, age: 300))
        OlcHealthChip(display: .inconclusive(.hostUnreachable, age: 120))
        OlcHealthChip(display: .stale(age: 7200))
    }
    .padding(Theme.Metrics.s5)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    .background(Theme.Palette.bg)
}
#endif
