import SwiftUI
import UIKit  // UIColor trait closures back the dynamic light/dark tokens

// Design-system tokens — the single source of truth for colour, spacing, shape
// and type. App/UI/DesignSystem.swift and every screen read from here instead
// of hard-coding hex values, point sizes or per-call tints.
//
// Palette: dark-first, COLOURFUL and premium. Three families, each with a job:
//   • ACCENT — a refined blue → indigo family. Links, tints, toggles, the
//     selected chip, the active segment and the primary action all live here.
//   • SIGNAL — the app's own identity: the cyan → blue → violet gradient that
//     stands in for the signal travelling through the tunnel. Waveform, beam,
//     verdict mark. Never a button fill.
//   • STATUS — the one status vocabulary (unknown / progress / ok / warn /
//     error) in clear, readable hues; plus a calmer DESTRUCTIVE tone for the
//     stop / remove buttons so "danger" never means "glaring".
// Round 1's achromatic silver accent is gone: the user read it as "everything
// became one colour". What stays from round 1 is the graphite ground, the
// hairline-edged plates and the light-mode variant for every dynamic token.
//
// Every ground, accent and status token is a dark/light pair resolved by the
// trait, so System / Light / Dark all work from one table. Every colour used
// as TEXT clears WCAG AA (≥ 4.5:1) on both the ground and the card in each
// appearance; ratios are noted per token (sRGB relative luminance, WCAG 2.x).

enum Theme {

    /// The Signal linework and the primary action.
    /// `stroke` is the fine line colour (waveform, active tints, secondary
    /// button labels) — the blue midpoint of the signature gradient.
    /// `actionFill` / `onAction` are the primary button's plate and its label.
    enum Signal {
        /// Blue midpoint of the signature gradient. 8.4:1 on the dark ground,
        /// 5.7:1 on a white card.
        static let stroke = Theme.Palette.signalMid
        /// Solid indigo plate under WHITE text (not mint, not silver).
        /// White on #4F5BD5 = 5.5:1 (dark); white on #3B4BC8 = 6.9:1 (light).
        static let actionFill = Theme.Palette.accentFill
        static let onAction = Theme.Palette.onAccent
        /// Optional richer plate for the hero CTA: blue → indigo → violet-indigo.
        /// EVERY stop clears 4.5:1 under white, so the label is legible at any
        /// point of the sweep (dark: 5.9 / 5.5 / 5.5; light: 6.2 / 6.9 / 7.8).
        static let actionGradient = LinearGradient(
            colors: [Theme.Palette.actionGradientStart,
                     Theme.Palette.accentFill,
                     Theme.Palette.actionGradientEnd],
            startPoint: .leading, endPoint: .trailing)
        /// Horizontal cyan → blue → violet sweep for the waveform strands
        /// (leading → trailing). Same stops as `Palette.auroraGradient`.
        static let waveGradient = LinearGradient(
            colors: [Theme.Palette.signalCyan, Theme.Palette.signalMid, Theme.Palette.signalViolet],
            startPoint: .leading, endPoint: .trailing)
        static let waveHeight: CGFloat = 220
    }

    /// dark/light pair → one Color that resolves per the active trait.
    fileprivate static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    // MARK: - Colors
    enum Palette {
        // Grounds & surfaces. Dark is graphite rather than pure black so the
        // coloured accents have something to sit on; Light keeps the system
        // grouped grounds.
        static let bg        = Theme.dynamic(dark: UIColor(hex: 0x0B0C0F), light: .systemGroupedBackground)   // light = #F2F2F7
        static let card      = Theme.dynamic(dark: UIColor(hex: 0x17191D), light: .white)
        /// The layer that says "this is tappable": secondary buttons, chips,
        /// the segmented track, icon buttons. Paired with `fillBorder` so a
        /// plate reads by its edge, not by a muddy tint.
        static let fill = Theme.dynamic(dark:  UIColor.white.withAlphaComponent(0.10),
                                        light: UIColor.black.withAlphaComponent(0.05))
        /// The thin hairline that gives a `fill` plate an edge.
        static let fillBorder = Theme.dynamic(dark:  UIColor.white.withAlphaComponent(0.14),
                                              light: UIColor.black.withAlphaComponent(0.14))
        /// OlcSegmented's active segment: the indigo accent plate under `onAccent`.
        static let segActive = accentFill
        /// OlcSegmented's active-segment lift: none in Dark (the plate's own
        /// contrast is the lift), a soft 12% in Light.
        static let segActiveShadow = Theme.dynamic(dark: .clear,
                                                   light: UIColor.black.withAlphaComponent(0.12))
        /// Card hairline — an edge, not a stroke.
        static var cardBorder: Color {
            Theme.dynamic(dark: UIColor.white.withAlphaComponent(0.10),
                          light: UIColor.black.withAlphaComponent(0.08))
        }
        static let separator = Color(.separator)

        // Text
        static let textPrimary   = Color.primary
        static let textSecondary = Color.secondary
        static let textTertiary  = Color(.tertiaryLabel)

        // MARK: Accent — blue → indigo family
        //
        // `accent` reads the `AccentColor` asset so system controls (toggles,
        // pickers, links) and our own tokens agree. The asset carries the SAME
        // pair as `accentTint` below: #6E9BFF in Dark, #3B4BC8 in Light.
        static let accent = Color.accentColor
        /// Explicit twin of the asset, for call sites that need a `UIColor`
        /// pair rather than the asset lookup. As text: 7.3:1 on the dark
        /// ground / 6.5:1 on the dark card; 6.9:1 on white / 6.2:1 on #F2F2F7.
        static let accentTint = Theme.dynamic(dark: UIColor(hex: 0x6E9BFF),
                                              light: UIColor(hex: 0x3B4BC8))
        /// Solid plate for `OlcButton(.primary)`, the selected chip and the
        /// active segment. Indigo in both appearances — one step deeper in
        /// Light so the white label keeps its margin.
        /// White on #4F5BD5 = 5.54:1; white on #3B4BC8 = 6.94:1.
        static let accentFill = Theme.dynamic(dark: UIColor(hex: 0x4F5BD5),
                                              light: UIColor(hex: 0x3B4BC8))
        /// The only foreground ever drawn on `accentFill`.
        static let onAccent = Color(UIColor(hex: 0xFFFFFF))   // explicit sRGB so contrast tests can read components
        /// Ends of `Signal.actionGradient`. White on each: dark 5.92 / 5.50,
        /// light 6.23 / 7.77.
        static let actionGradientStart = Theme.dynamic(dark: UIColor(hex: 0x3A57D9),
                                                       light: UIColor(hex: 0x2F55D4))
        static let actionGradientEnd   = Theme.dynamic(dark: UIColor(hex: 0x5F55DC),
                                                       light: UIColor(hex: 0x4B3FB8))
        /// Neutral convenience names kept from round 1 (no longer the accent):
        /// a cool silver and a deep graphite for the rare monochrome detail.
        static let silver   = Theme.dynamic(dark: UIColor(hex: 0xE3E7EC), light: UIColor(hex: 0x5F6774))
        static let graphite = Theme.dynamic(dark: UIColor(hex: 0x2B2F36), light: UIColor(hex: 0x2B2F36))

        // MARK: Status — the ONE vocabulary
        //
        // unknown = grey, progress = amber, ok = green, warn = orange,
        // error = red — used identically everywhere. Dark endpoints are the
        // clear Apple-family hues (the round-1 desaturation is gone); light
        // endpoints are deliberately deep so the words stay readable on white.
        // Ratios: dark on #0B0C0F ground / light on #FFFFFF card.
        static let green  = Theme.dynamic(dark: UIColor(hex: 0x30D158), light: UIColor(hex: 0x1B7A34))  // 9.7:1 / 5.4:1
        static let orange = Theme.dynamic(dark: UIColor(hex: 0xFF9F0A), light: UIColor(hex: 0x9A5B00))  // 9.5:1 / 5.4:1
        /// Status red for dots, chips and error text — stays close to system
        /// red for instant recognition (a touch lighter than #FF453A so it
        /// clears 6.5:1 on graphite). NOT the stop-button fill: see
        /// `destructive*` below.
        static let red    = Theme.dynamic(dark: UIColor(hex: 0xFF5F57), light: UIColor(hex: 0xC0302A))  // 6.5:1 / 5.7:1
        static let amber  = Theme.dynamic(dark: UIColor(hex: 0xFFD60A), light: UIColor(hex: 0x9A6A00))  // 13.9:1 / 4.7:1

        // MARK: Destructive — calm, premium
        //
        // Stop / disconnect / remove / uninstall. A desaturated coral rather
        // than full-saturation red: the action is serious, not an alarm.
        /// Label / glyph / outline colour of a destructive control.
        /// 6.8:1 on the dark ground, 6.1:1 on the dark card; 5.4:1 on white,
        /// 4.8:1 on #F2F2F7.
        static let destructive = Theme.dynamic(dark: UIColor(hex: 0xE8776F),
                                               light: UIColor(hex: 0xB8433D))
        /// Solid plate for a FILLED stop button under `onDestructive` (white).
        /// White on #B8433D = 5.37:1 (dark); white on #A83C36 = 6.24:1 (light).
        static let destructiveFill = Theme.dynamic(dark: UIColor(hex: 0xB8433D),
                                                   light: UIColor(hex: 0xA83C36))
        static let onDestructive = Color(UIColor(hex: 0xFFFFFF))
        /// Low-opacity wash behind an outlined / ghost destructive button.
        static let destructiveWeak = destructive.opacity(0.16)

        // Tinted (weak) fills
        /// `OlcButton(.danger)`'s wash. Follows the calm `destructive` tone,
        /// not the status red, so the button plate never glares.
        static let redWeak  = destructiveWeak
        /// The "Main" badge on the Connect screen: star yellow, deep amber in Light.
        static let star     = Theme.dynamic(dark: UIColor(hex: 0xFFD60A), light: UIColor(hex: 0x8A6100))
        static let starWeak = Theme.dynamic(dark: UIColor(hex: 0xFFD60A).withAlphaComponent(0.16),
                                            light: UIColor(hex: 0x8A6100).withAlphaComponent(0.12))

        // MARK: Signal signature — cyan → blue → violet
        //
        // The app's own identity: the aurora that stands in for the signal
        // travelling through the tunnel. Hero waveform, beam, verdict mark.
        // Never a button fill (white on the cyan end is ~1.7:1), never a card
        // edge, never a background. Dark endpoints are the original values;
        // light endpoints are deeper so the linework reads on #F2F2F7.
        static let signalCyan   = Theme.dynamic(dark: UIColor(hex: 0x36D8F5), light: UIColor(hex: 0x0B7A99))   // high-energy end — 11.5:1 / 4.9:1 on white
        static let signalMid    = Theme.dynamic(dark: UIColor(hex: 0x5EAEFF), light: UIColor(hex: 0x2A62C9))   // blue midpoint (Signal.stroke) — 8.4:1 / 5.7:1
        static let signalViolet = Theme.dynamic(dark: UIColor(hex: 0x8B7BFF), light: UIColor(hex: 0x5B4BD6))   // calm end — 5.9:1 / 6.1:1

        /// The signature gradient (top-leading cyan → bottom-trailing violet).
        static let auroraGradient = LinearGradient(
            colors: [signalCyan, signalMid, signalViolet],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Elevation
    //
    // Content sits at the base, cards lift a little off it, and the
    // hero/floating layer lifts more. Applied via `.olcShadow(_:)`. Dark has no
    // shadow at all (a black shadow on graphite is invisible; depth comes from
    // the card hairline over the lighter card fill); Light gets soft, wide,
    // low-opacity lifts.
    enum Elevation {
        case none, card, floating

        var color: Color {
            switch self {
            case .none:     return .clear
            case .card:     return Theme.dynamic(dark: .clear,
                                                 light: UIColor.black.withAlphaComponent(0.06))
            case .floating: return Theme.dynamic(dark: .clear,
                                                 light: UIColor.black.withAlphaComponent(0.10))
            }
        }
        var radius: CGFloat {
            switch self {
            case .none: return 0
            case .card: return 12
            case .floating: return 24
            }
        }
        var y: CGFloat {
            switch self {
            case .none: return 0
            case .card: return 3
            case .floating: return 10
            }
        }
    }

    // MARK: - Metrics (spacing / shape)
    enum Metrics {
        static let controlHeight:   CGFloat = 44   // every button, always
        static let controlRadius:   CGFloat = 12
        static let cardRadius:      CGFloat = 20
        static let cardPadding:     CGFloat = 16
        /// The radius a shape nested INSIDE an OlcCard should use so the two
        /// curves stay concentric: outer radius − the padding between them.
        static var innerRadius:     CGFloat { cardRadius - cardPadding }   // 4
        static let cardBorderWidth: CGFloat = 1
        static let rowMinHeight:    CGFloat = 52
        static let sectionGap:      CGFloat = 24
        static let segmentedRadius: CGFloat = 10
        static let chipHeight:      CGFloat = 34

        // ONE spacing grid. These are the only steps anything should use.
        static let s1: CGFloat = 4     // hairline gaps inside one label
        static let s2: CGFloat = 8     // label ↔ value, glyph ↔ word
        static let s3: CGFloat = 12    // rows inside a card
        static let s4: CGFloat = 16    // card padding, sibling controls
        static let s5: CGFloat = 20    // block ↔ block inside a card
        static let s6: CGFloat = 24    // section ↔ section
        static let s7: CGFloat = 32    // screen-level separation
        static let s8: CGFloat = 40    // the answer ↔ everything below it
    }

    // MARK: - Type
    //
    // SIX steps, and nothing else:
    //   1. answer   (.largeTitle)  THE answer to the screen's one question.
    //   2. title    (.title3)      Subjects: server name, protocol name, card
    //                              titles. `answerSupport` is the same step in a
    //                              lighter weight.
    //   3. body     (.body)        Prose, notes, a row's primary line
    //                              (`bodyStrong` = same step, semibold).
    //   4. label    (.subheadline) Secondary row line, chips, buttons, segments.
    //   5. caption  (.caption)     Units, ages, provenance, section headers
    //                              (`captionStrong` = same step, semibold).
    //                              Nothing informative may be smaller.
    //   6. mono     (.caption mono) Addresses, ports, room IDs, URIs, log lines.
    //                              `metricValue` is the body-sized mono used for
    //                              measured numbers so columns align.
    // A different WEIGHT or DESIGN of a step is not a new step. Everything maps
    // to a Dynamic Type text style, never a fixed point size.
    enum Typography {
        // ── Step 1 — the answer ─────────────────────────────────────────────
        static let answer        = Font.system(.largeTitle, design: .rounded).weight(.bold)

        // ── Step 2 — subjects ───────────────────────────────────────────────
        static let title         = Font.system(.title3, design: .rounded).weight(.semibold)
        static let answerSupport = Font.system(.title3, design: .rounded).weight(.medium)

        // ── Step 3 — content ────────────────────────────────────────────────
        static let body          = Font.system(.body, design: .rounded)
        static let bodyStrong    = Font.system(.body, design: .rounded).weight(.semibold)

        // ── Step 4 — controls and secondary lines ───────────────────────────
        static let label         = Font.system(.subheadline, design: .rounded).weight(.semibold)

        // ── Step 5 — units, ages, provenance ────────────────────────────────
        static let caption       = Font.system(.caption, design: .rounded)
        static let captionStrong = Font.system(.caption, design: .rounded).weight(.semibold)

        // ── Step 6 — measured data ──────────────────────────────────────────
        static let mono          = Font.system(.caption, design: .monospaced)
        static let metricValue   = Font.system(.body, design: .monospaced).weight(.semibold)

        // ── Compatibility aliases ───────────────────────────────────────────
        // Older names, each mapped onto the step it always was. Prefer the six
        // names above in new code.
        static let display        = answer
        static let largeTitle     = answer
        static let button         = label
        static let statusTitle    = label
        static let statusSubtitle = caption
        static let sectionHeader  = captionStrong
        static let chip           = label
        static let segment        = label
        static let metricLabel    = captionStrong
    }
}

extension Color {
    /// `0xRRGGBB` literal → opaque sRGB Color. Used only for the handful of tokens
    /// with no iOS system-color equivalent. Prefer a semantic `Color(.xxx)`
    /// whenever one matches.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: 1)
    }
}

extension UIColor {
    /// UIColor twin of `Color(hex:)` — the dynamic light/dark tokens are built
    /// from UIColor trait closures, which need UIColor end points.
    convenience init(hex: UInt32) {
        self.init(red:   CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8)  & 0xFF) / 255,
                  blue:  CGFloat( hex        & 0xFF) / 255,
                  alpha: 1)
    }
}
