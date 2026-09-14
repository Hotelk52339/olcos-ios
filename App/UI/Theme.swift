import SwiftUI
import UIKit  // #340: UIColor trait closures back the dynamic light/dark tokens

// #258: Design-system tokens — the single source of truth for color, spacing,
// shape, and type. App/UI/DesignSystem.swift and (later) every screen read from
// here instead of hardcoding `.controlSize(...)`, ad-hoc hex, or per-call tints.
//
// Values come from design_handoff_ui_redesign (pure-black ground, soft
// borderless cards). Where the handoff's hex matches an iOS system color we use
// the *semantic* color — noted per token — so Dynamic Type, contrast, and the
// dark palette keep working.
// #340 was: "The app is dark-only; this palette is authored for the dark
// appearance" — light values come from design_handoff_logs_theme §4; the
// appearance now follows SettingsStore.appearanceMode via preferredColorScheme
// in App.swift. Semantic system colors adapt for free; the handful of
// hardcoded grounds are dynamic via UIColor traits.
// #299 was: a runtime Refined/Console "design direction" (#267/#281) that only
// changed radii/borders/fonts, never colours. Dropped; the metric/type tokens
// are single (Refined) values.
// #456 was: a fourth *colour* scheme — Gray (#299) — alongside System/Light/Dark,
// whose grounds resolved to neutral mid-gray. Removed: a fourth scheme diluted
// the palette (three different "dark" grounds to design against for zero user
// benefit) and, because Dark↔Gray produced no colorScheme trait change, it
// forced a full TabView rebuild in App.swift just to refresh these tokens.
// Schemes are System / Light / Dark; the grounds are plain dark/light pairs
// resolved by the trait, and Light is now tuned to be genuinely good.
//
// #457: two inversions were fixed here.
//  (1) SCALE — the answer to the screen's one question used to render at
//      `statusTitle` (~15pt) inside a card carrying a 26pt coloured glow. The
//      glow is gone and `Typography.answer` exists so the ANSWER is the biggest
//      thing on screen. See the Typography block for the six-step scale.
//  (2) SEMANTICS — status was carried by colour alone. `OlcStatusTone` now
//      ships an SF Symbol per tone (DesignSystem.swift) so every state reads as
//      glyph + word + colour; the palette below only has to make the colour the
//      THIRD channel, not the only one.
// Also: every status hue now carries a deliberate LIGHT value. The system
// hues (`.green`/`.orange`/`.red`) are tuned for a dark ground and measure
// 2–3:1 as text on #F2F2F7 — unreadable exactly where the truth lives.

enum Theme {

    // boc #486
    /// Signal's sage linework is a connected-state expression, not the aurora
    /// health verdict. A deeper light endpoint keeps fine lines visible.
    enum Signal {
        static let stroke = Theme.dynamic(dark: UIColor(hex: 0xBDDC9E),
                                          light: UIColor(hex: 0x527B36))
        // #492: action styling is brand color, not a claim about connection
        // health. Use dark text on a solid sage fill in both appearances.
        static let actionFill = Color(UIColor(hex: 0xD1EDB9))
        static let onAction = Color(UIColor(hex: 0x23321B))
        static let waveHeight: CGFloat = 152
    }
    // eoc #486

    /// #340: dark/light pair → one Color that resolves per the active trait.
    fileprivate static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    // MARK: - Colors
    enum Palette {
        // Grounds & surfaces. #340: light values per the handoff §4 token table.
        // boc #456
        // #456 was: bg / card / segActive each branched on `Theme.isGray` (#299)
        // and were therefore `static var` — recomputed from a SettingsStore read
        // on every body evaluation. With Gray gone they are plain dark/light
        // pairs the trait resolves, so they can be `let` again.
        // #340 was: bg = .black (dark-only)
        static let bg        = Theme.dynamic(dark: .black, light: .systemGroupedBackground)   // light = #F2F2F7
        static let card      = Color(.secondarySystemGroupedBackground)
        // boc #457
        // #457 was: fill = Color(.tertiarySystemFill) — rgba(118,118,128,0.12) in
        // Light. That is the layer that says "this is tappable" (secondary
        // buttons, chips, the segmented track, icon buttons), and on a WHITE card
        // it is a ~3% wash: the controls effectively vanished. Now an explicit
        // pair, deliberately LIGHTER in light mode but paired with `fillBorder`
        // so a plate reads by its EDGE rather than by a muddy tint.
        static let fill = Theme.dynamic(dark:  UIColor.white.withAlphaComponent(0.14),
                                        light: UIColor.black.withAlphaComponent(0.06))
        /// #457: the hairline that gives a `fill` plate an edge. Without it a 6%
        /// wash on a white card is invisible; with it the control has a boundary
        /// in both appearances.
        static let fillBorder = Theme.dynamic(dark:  UIColor.white.withAlphaComponent(0.10),
                                              light: UIColor.black.withAlphaComponent(0.16))
        // eoc #457
        // #340 was: segActive = 0x48484A (dark-only); light = white (+ OlcSegmented's soft shadow)
        static let segActive = Theme.dynamic(dark: UIColor(hex: 0x48484A), light: .white)
        /// #457: OlcSegmented's active-segment lift. #457 was: a hardcoded
        /// `.black.opacity(0.3)` authored for the dark #48484A fill — on a white
        /// light-mode segment that is a heavy smudge, and on the dark ground it
        /// is invisible anyway. Dark gets none (the fill contrast IS the lift);
        /// light gets a soft, deliberate 12%.
        static let segActiveShadow = Theme.dynamic(dark: .clear,
                                                   light: UIColor.black.withAlphaComponent(0.12))
        // eoc #456
        /// #340: Console card hairline — was hardcoded `Color.white.opacity(0.16)`
        /// in OlcCard (#281 bumped dark from the handoff's 8% for visibility);
        /// light uses the handoff's black 8%.
        /// #457 was: dark 16% / light 8%, and `Metrics.cardBorderWidth` was 0 so
        /// NEITHER was ever drawn. The width is now 1: a white card on #F2F2F7
        /// has a ~2% edge and needs the hairline more than the dark card does,
        /// so both values were softened to read as an edge, not a stroke.
        static var cardBorder: Color {
            Theme.dynamic(dark: UIColor.white.withAlphaComponent(0.08),
                          light: UIColor.black.withAlphaComponent(0.07))
        }
        static let separator = Color(.separator)                         // rgba(84,84,88,0.5)

        // Text
        static let textPrimary   = Color.primary           // #FFFFFF
        static let textSecondary = Color.secondary         // rgba(235,235,245,0.62)
        static let textTertiary  = Color(.tertiaryLabel)   // rgba(235,235,245,0.32)

        // Accent + the ONE status vocabulary (unknown = gray, progress = amber,
        // ok = green, warn = orange, error = red), used identically everywhere.
        // #457: each status hue is a glyph/text colour now that `OlcStatusTone`
        // renders a SYMBOL, so each needs to clear 4.5:1 on BOTH grounds. The
        // dark endpoints are the unchanged Apple values; the light ones are
        // deliberately deep (measured against #FFFFFF card and #F2F2F7 ground).
        static let accent = Color.accentColor   // #0A84FF — existing AccentColor asset
        /// #457: solid fill for `OlcButton(.primary)` under WHITE text.
        /// #457 was: `auroraGradient` — white on its cyan end measures ~1.7:1, so
        /// the app's most important button was its least legible, AND the aurora
        /// stopped meaning "verified live" by appearing on every CTA. These two
        /// blues are the same family as `accent` (no second hue is introduced)
        /// and land 5.6:1 (dark) / 7.2:1 (light) against `onAccent`.
        static let accentFill = Theme.dynamic(dark: UIColor(hex: 0x1C5FE0),
                                              light: UIColor(hex: 0x0A4FC4))
        /// #457: the only foreground ever drawn on `accentFill`.
        static let onAccent = Color.white
        // boc #457
        // #457 was: green/orange/red = Color.green/.orange/.red. Those resolve to
        // systemGreen #34C759 (~2.2:1 on white), systemOrange #FF9500 (~2.1:1)
        // and systemRed #FF3B30 (~3.1:1) in Light — i.e. the three colours that
        // carry "working", "degraded" and "broken" were the least readable text
        // in the app on a light ground. Dark endpoints unchanged.
        static let green  = Theme.dynamic(dark: UIColor(hex: 0x30D158), light: UIColor(hex: 0x1B7A34))  // 5.4:1 on white
        static let orange = Theme.dynamic(dark: UIColor(hex: 0xFF9F0A), light: UIColor(hex: 0x9A5B00))  // 5.4:1 on white
        static let red    = Theme.dynamic(dark: UIColor(hex: 0xFF453A), light: UIColor(hex: 0xC8241A))  // 5.6:1 on white
        // #350 (audit U4) was: amber = Color.yellow (#FFD60A) — ~1.3:1 on light/gray
        // grounds, so the .progress dot and OlcProgressBar fill were near-invisible
        // in Light. Now dynamic: bright yellow on dark, a darker amber on light.
        // #457 was: light = 0xB8860B (3.3:1) — fine for a 4pt progress capsule,
        // not for the `.progress` STATUS GLYPH it now also has to draw.
        static let amber  = Theme.dynamic(dark: UIColor(hex: 0xFFD60A), light: UIColor(hex: 0x9A6A00))  // 4.7:1 on white
        // eoc #457

        // Tinted (weak) fills
        /// #457: derived from `red`, so the danger button's wash follows the
        /// same deep light-mode red its label uses.
        static let redWeak  = red.opacity(0.16)      // danger-button background
        // #350 (audit U4) was: star = Color.yellow (#FFD60A) — same low-contrast
        // problem on the "Main" badge in Light. Dynamic, matching `amber`.
        // #457: star/starWeak are a THIRD accent system and the cut list retires
        // them with the "Main" badge itself. The badge lives in the Connect
        // screen, so the tokens outlive this change by one partition — delete
        // them once `ConnectionsView`'s star is gone and this comment is the
        // only reference left.
        static let star     = Theme.dynamic(dark: UIColor(hex: 0xFFD60A), light: UIColor(hex: 0x8A6100))
        // (audit) was: Color.yellow.opacity(0.16) — static bright-yellow wash
        // clashed with the dark-amber `star` text on light cards. Dynamic like
        // `star`: bright yellow wash in dark, muted amber wash in light.
        static let starWeak = Theme.dynamic(dark: UIColor(hex: 0xFFD60A).withAlphaComponent(0.16),
                                            light: UIColor(hex: 0x8A6100).withAlphaComponent(0.12))

        // MARK: Aurora signature (#455 premium redesign)
        //
        // The app's own identity: a cyan→violet "aurora" that stands in for the
        // signal travelling through the tunnel.
        // #457: the aurora is now a VERDICT, not a style. It is allowed ONLY
        // where traffic has been verified end-to-end inside the freshness window
        // (`HealthDisplay.verified`) — the mark around the status block and the
        // spine on the one live protocol row. It is no longer the primary
        // button's fill (see `accentFill`), no longer a card hairline, and no
        // longer a row wash. Rare, therefore meaningful.
        // boc #456
        // #456 was: three STATIC, dark-tuned hexes (Color(hex: 0x36D8F5) …). They
        // were authored on pure black and failed in Light: white text on
        // OlcButton(.primary)'s cyan end measured ~1.7:1, and the hairline/glow
        // built from them washed out on #F2F2F7. Now dynamic pairs exactly as
        // #350 did for amber/star — the DARK endpoints are unchanged (dark mode
        // looks identical), the LIGHT ones are deeper so the mark reads on a
        // #F2F2F7 ground.
        static let signalCyan   = Theme.dynamic(dark: UIColor(hex: 0x36D8F5), light: UIColor(hex: 0x0E86A8))   // near-cyan, high-energy end
        static let signalViolet = Theme.dynamic(dark: UIColor(hex: 0x8B7BFF), light: UIColor(hex: 0x5B4BD6))   // soft violet, calm end
        static let signalMid    = Theme.dynamic(dark: UIColor(hex: 0x5EAEFF), light: UIColor(hex: 0x2C6BD4))   // blue midpoint (blends toward the system accent)
        // eoc #456

        /// The signature gradient (top-leading cyan → bottom-trailing violet).
        /// #457: its ONE remaining job is the verdict mark on a freshly-verified
        /// state. Never a button fill, never a card edge, never a background.
        static let auroraGradient = LinearGradient(
            colors: [signalCyan, signalMid, signalViolet],
            startPoint: .topLeading, endPoint: .bottomTrailing)

        // #457 was: `auroraSoft` — a low-opacity wash of the same gradient whose
        // own doc comment read "decoration only". It backed the live carrier-row
        // wash on Manage VPS, which is the third rival "this is live" mark on a
        // screen that only needs one. Deleted with the wash.
        // #457 was: `connectedGlow` — the tint for `Elevation.glow`, a 26pt /
        // 45%-opacity coloured shadow applied for as long as the tunnel was up.
        // Continuous emphasis on a state that lasts for hours stops carrying
        // information and only costs legibility. Deleted with the elevation.
    }

    // MARK: - Elevation (#455)
    //
    // Depth is what separates a flat, templated look from a premium one: content
    // sits at the base, cards lift a little off it, and the hero/floating layer
    // lifts more. Applied via `.olcShadow(_:)`.
    // boc #457
    // #457 was: `case glow` (a 26pt Palette.connectedGlow shadow at 45%) plus
    // four PURE BLACK shadow values. Two problems, one fix each:
    //  • `.glow` made DEPTH encode STATUS — the colour-alone failure and the
    //    hierarchy-from-decoration failure at the same time. Deleted; the aurora
    //    verdict mark replaces it, and the hero uses `.floating` in every state.
    //  • A black shadow on a black ground is mathematically invisible, so in
    //    dark the app paid for an offscreen pass and got nothing; in light the
    //    same opacities read as mud. The shadows are now dynamic: dark has NO
    //    shadow at all (depth comes from `Palette.cardBorder`'s hairline over
    //    the lighter card fill), light gets soft, wide, low-opacity lifts.
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
    // eoc #457

    // MARK: - Metrics (spacing / shape)
    // #299 was: a few tokens branched on the Refined/Console "design direction"
    // (#267/#281). The direction is gone — these are the single Refined values.
    enum Metrics {
        static let controlHeight:   CGFloat = 44   // every button, always
        // #457 was: controlRadius = 13 — an odd value that made nested shapes
        // non-concentric against the 20pt card. 12 divides the grid.
        static let controlRadius:   CGFloat = 12
        static let cardRadius:      CGFloat = 20
        static let cardPadding:     CGFloat = 16
        /// #457: the radius a shape nested INSIDE an OlcCard should use so the
        /// two curves stay concentric: outer radius − the padding between them.
        static var innerRadius:     CGFloat { cardRadius - cardPadding }   // 4
        // #457 was: 0 — so `Palette.cardBorder` existed but was never drawn.
        // A white card on the #F2F2F7 light ground has a ~2% edge; 1pt of the
        // (softened) hairline is what gives it a boundary in both appearances.
        static let cardBorderWidth: CGFloat = 1
        static let rowMinHeight:    CGFloat = 52
        // #457 was: 22 — off the 4pt grid by 2.
        static let sectionGap:      CGFloat = 24
        static let segmentedRadius: CGFloat = 10
        static let chipHeight:      CGFloat = 34   // handoff range 32–38

        // #457: ONE spacing grid. Views wrote 15 distinct `spacing:` values and
        // 10 ad-hoc paddings; these are the only steps anything should use.
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
    // #457: SIX steps, and nothing else. The old scale had ten tokens resolving
    // to about five real sizes, jumping largeTitle (34) straight to callout (16)
    // with no body size — so the eye read "two sizes plus a lot of weight", and
    // importance had to be signalled by colour and by drawing more boxes. Real
    // size contrast is what frees colour from carrying importance.
    //
    // The six steps, largest first, and what each is FOR:
    //   1. answer   (.largeTitle)  THE answer to the screen's one question — the
    //                              tunnel state word. At most one per screen.
    //   2. title    (.title3)      Subjects: server name, protocol name, card
    //                              titles. `answerSupport` is the same step in a
    //                              lighter weight: the line directly under the
    //                              answer that says WHAT it applies to.
    //   3. body     (.body)        Prose, notes, a row's primary line
    //                              (`bodyStrong` = same step, semibold).
    //   4. label    (.subheadline) Secondary row line, chips, buttons, segments.
    //   5. caption  (.caption)     Units, ages, provenance, section headers
    //                              (`captionStrong` = same step, semibold).
    //   6. mono     (.caption mono) Addresses, ports, room IDs, URIs, log lines.
    //                              `metricValue` is the body-sized mono used for
    //                              measured numbers so columns align.
    // A different WEIGHT or DESIGN of a step is not a new step. Anything that
    // needs a seventh size is a layout problem, not a type problem.
    //
    // Everything maps to a Dynamic Type text style (never a fixed point size),
    // so the app's font-size slider — `.dynamicTypeSize(...)` in App.swift —
    // keeps scaling all of it.
    // #455: the scale is SF Rounded; data stays monospaced so numbers align.
    enum Typography {
        // ── Step 1 — the answer ─────────────────────────────────────────────
        /// #457: the state word on Connect. THE largest thing on the screen —
        /// this token exists because the app's one answer used to render two
        /// size steps SMALLER than the ornament around it.
        static let answer        = Font.system(.largeTitle, design: .rounded).weight(.bold)

        // ── Step 2 — subjects ───────────────────────────────────────────────
        static let title         = Font.system(.title3, design: .rounded).weight(.semibold)
        /// #457: the line directly beneath `answer` — "Prague-1 · Telemost".
        /// Same size step, lighter weight, so it supports rather than competes.
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
        // #457: the old names, each mapped onto the step it always WAS, so no
        // call site had to change in the same pass that changed the scale.
        // Prefer the six names above in new code.
        // #457 was: `display` and `largeTitle` were byte-identical duplicates of
        // each other with zero call sites between them; both now point at
        // `answer`, which is the one name that says what the step is for.
        static let display        = answer
        static let largeTitle     = answer
        // #457 was: `button` = .callout semibold — half a step above `label` for
        // no reason; buttons and segments now share one control size.
        static let button         = label
        static let statusTitle    = label
        static let statusSubtitle = caption
        static let sectionHeader  = captionStrong
        static let chip           = label
        static let segment        = label
        // #457 was: `metricLabel` = .caption2 semibold — a seventh size step
        // that existed only for metric labels. Folded into step 5.
        static let metricLabel    = captionStrong
    }
}

extension Color {
    /// `0xRRGGBB` literal → opaque sRGB Color. Used only for the handful of tokens
    /// with no iOS system-color equivalent (e.g. the segmented control's active
    /// fill). Prefer a semantic `Color(.xxx)` whenever one matches.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: 1)
    }
}

extension UIColor {
    /// #340: UIColor twin of `Color(hex:)` — the dynamic light/dark tokens are
    /// built from UIColor trait closures, which need UIColor end points.
    convenience init(hex: UInt32) {
        self.init(red:   CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8)  & 0xFF) / 255,
                  blue:  CGFloat( hex        & 0xFF) / 255,
                  alpha: 1)
    }
}
