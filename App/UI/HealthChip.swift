import SwiftUI

// MARK: - OlcHealthChip (#456, #457)
//
// #456: the ONE evidence chip. Renders a `HealthDisplay` (App/Models/NodeHealth.swift)
// as a compact pill: status glyph + short label. Green ONLY for `.verified` —
// every other state is neutral, amber or red, never "looks fine".
//
// It lives here (not in DesignSystem.swift) because it is the only component
// that knows the health vocabulary; the tokens it draws with — `OlcStatusTone`,
// `Theme.Palette` — already exist and are used unchanged. Both the Connections
// rows and the Manage VPS protocol rows render THIS view, so "48 ms · 2m" means
// exactly the same thing on both tabs.
//
// #457: two fixes, both about the truth being readable.
//  • GLYPH + WORD, ALWAYS. #457 was: a bare 7pt `Circle().fill(display.tone.color)`
//    and a label that was DROPPED for `.checking` — so four of the eight states
//    (`.never`, `.fading`, `.inconclusive`, `.stale`) rendered as the SAME grey
//    circle, and the in-flight state rendered as a spinner with no word at all.
//    Four different facts — "never checked", "worked a while ago", "couldn't
//    check", "too old to trust" — painted identically. Now every state draws its
//    own silhouette (see `OlcHealthGlyph`) and always carries its word.
//  • NEVER SHRINK, NEVER CLIP. #457 was: `.lineLimit(1)`. Russian runs long
//    («не проверено», «устарело · 5 мин»), so the label was tail-truncated in a
//    narrow row — and `.minimumScaleFactor` would only trade truncation for text
//    too small to read. The chip wraps to two lines and grows instead.

/// #457: `HealthDisplay` → SF Symbol. The rule this enforces: no two states may
/// ever render the same pixels. `HealthDisplay.tone` returns `.unknown` for FOUR
/// distinct states, so the tone's own glyph is not enough here — the health
/// vocabulary needs its own, finer mapping.
///
/// It is a free-standing enum rather than a `HealthDisplay` extension so the
/// honesty layer (App/Models/NodeHealth.swift) stays free to grow its own
/// `symbol` later without colliding with this file.
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

struct OlcHealthChip: View {
    let display: HealthDisplay
    /// When non-nil the chip becomes a button (re-verify on tap).
    var onTap: (() -> Void)? = nil

    var body: some View {
        // #456: tappable and static chips draw the IDENTICAL pill — only the
        // touch target and the a11y traits differ.
        if onTap != nil {
            Button { onTap?() } label: { chip }
                .buttonStyle(.plain)
                // #456: grow the TOUCH region to Apple's 44pt minimum without
                // enlarging the drawn pill (mirrors ConnectionsView.healthButton).
                .frame(minHeight: 44)
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

    /// The drawn pill: glyph + word, in every state.
    private var chip: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.s2) {
            glyph
            Text(label)
                .font(Theme.Typography.caption.monospacedDigit())
                // #456: green text is granted ONLY by `.verified` — the same
                // rule the glyph follows, so colour never outruns the evidence.
                .foregroundStyle(display.isVerified ? Theme.Palette.green
                                                    : Theme.Palette.textSecondary)
                // #457 was: .lineLimit(1). Two lines, and the pill grows to fit
                // rather than cutting the word in half.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, Theme.Metrics.s1)
        .background(Theme.Palette.fill, in: Capsule())
        // #457: the capsule is a `Palette.fill` plate — in Light that is a 6%
        // wash on a white card, so it needs its edge (see OlcButton.secondary).
        .overlay { Capsule().strokeBorder(Theme.Palette.fillBorder, lineWidth: 1) }
    }

    /// #457: the glyph channel. `.checking` keeps its spinner — an in-flight
    /// probe is the one state where motion IS the honest signal — and now says
    /// "Checking…" beside it instead of leaving the word out.
    @ViewBuilder
    private var glyph: some View {
        if display.isChecking {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: OlcHealthGlyph.symbol(for: display))
                // Dynamic-Type-backed so the glyph moves with the label.
                .font(Theme.Typography.caption.weight(.bold))
                .foregroundStyle(display.tone.color)
        }
    }

    /// #457 was: `display.chipLabel`, rendered only `if !chipLabel.isEmpty` —
    /// and `.checking`'s chipLabel is deliberately empty (the spinner used to BE
    /// the message). A spinner alone is motion plus colour with no word, which
    /// is the same failure as a bare dot. Fall back to the display's own title,
    /// which is already the right sentence ("Checking…" / «Проверяем…»).
    /// Localised at the point of use — never cached.
    private var label: String {
        let short = display.chipLabel
        return short.isEmpty ? display.title : short
    }

    /// #456: VoiceOver gets the full sentence ("Verified. 48 ms, checked 2m ago"),
    /// not the compressed pill text. Localised at the point of use.
    private var accessibilityText: String {
        "\(display.title). \(display.subtitle)"
    }
}

#if DEBUG
/// #457: the grayscale acceptance test for the health vocabulary — eight states,
/// eight silhouettes, eight words. If any two rows look alike with Color Filters
/// → Grayscale on, the mapping above is wrong.
#Preview("OlcHealthChip — the eight states") {
    VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
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
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Theme.Palette.bg)
}
#endif
