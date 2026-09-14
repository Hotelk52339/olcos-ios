import XCTest
import SwiftUI
@testable import olcrtc_ios

// #299 was: testConsoleIsSharperAndDenserThanRefined — pinned the Refined vs
// Console "design direction" metric tokens. The direction is gone; Theme is now
// real colour schemes. These tests pin the current contract: the appearance
// modes, their colorScheme mapping, and the single (Refined) metric values.
// #456 was: the same file with Gray as a fourth scheme (testAppearanceModesIncludeGray,
// testGrayUsesDarkColorScheme, testGrayChangesGroundTokens). Gray is removed —
// System / Light / Dark only — so the first two shrank and the ground-token test
// went with the feature. In its place, testStoredGrayStillDecodesToSomethingValid
// pins the SAFE migration: a user whose UserDefaults still says "gray" must land
// on a valid mode rather than an invalid one, and that happens for free through
// SettingsStore.init's `?? .dark` (no migration code, deliberately).
// #457: the metric snapshot moved with the grid snap (controlRadius 13 → 12,
// sectionGap 22 → 24, cardBorderWidth 0 → 1), and three NEW tests pin the two
// inversions this redesign exists to fix — the scale (`Typography.answer` is
// really the largest step, and every legacy alias still resolves) and the
// semantics (every `OlcStatusTone` owns a DISTINCT SF Symbol, so no two states
// can render as the same pixels in grayscale).

@MainActor
final class ThemeDirectionTests: XCTestCase {

    /// The appearance modes are exactly System / Light / Dark, in picker order.
    func testAppearanceModes() {
        XCTAssertEqual(AppearanceMode.allCases,
                       [.system, .light, .dark])   // #456 was: + .gray
        // Each mode has a non-empty, distinct title (drives the Settings picker).
        let titles = AppearanceMode.allCases.map { $0.title }
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertFalse(titles.contains(where: \.isEmpty))
    }

    /// System follows the OS (nil); Light/Dark force their own scheme. With Gray
    /// gone, every switch between modes flips `colorScheme` — which is what lets
    /// App.swift drop the `.id(settings.appearanceMode)` full-TabView rebuild
    /// (#456): SwiftUI re-resolves the dynamic Theme tokens on the trait change.
    func testColorSchemeMapping() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme,  .dark)   // #456 was: + .gray → .dark
    }

    /// #456: an existing user's persisted `"gray"` must not strand the app on an
    /// invalid appearance. The raw value no longer matches a case, so
    /// `AppearanceMode(rawValue:)` returns nil and SettingsStore.init's `?? .dark`
    /// resolves it to Dark — the scheme Gray was closest to. This is the whole
    /// migration; if this test ever fails, the removal stopped being safe.
    func testStoredGrayStillDecodesToSomethingValid() {
        XCTAssertNil(AppearanceMode(rawValue: "gray"))
        XCTAssertEqual(AppearanceMode(rawValue: "gray") ?? .dark, .dark)
    }

    /// The "design direction" tokens collapsed to single Refined values.
    /// #457 was: controlRadius 13 / sectionGap 22 / cardBorderWidth 0. The first
    /// two are now on the 4pt grid; the third is 1 because `Palette.cardBorder`
    /// existed but, at width 0, was never actually drawn — a white card on the
    /// #F2F2F7 light ground has a ~2% edge and needs it.
    func testMetricsAreSingleRefinedValues() {
        XCTAssertEqual(Theme.Metrics.cardBorderWidth, 1)
        XCTAssertEqual(Theme.Metrics.cardRadius, 20)
        XCTAssertEqual(Theme.Metrics.controlRadius, 12)
        XCTAssertEqual(Theme.Metrics.cardPadding, 16)
        XCTAssertEqual(Theme.Metrics.sectionGap, 24)
    }

    /// #457: ONE spacing grid. Every step is a multiple of 4 and strictly larger
    /// than the one before it — the property that makes a token scale usable as
    /// a scale rather than as eight arbitrary numbers.
    func testSpacingGridIsMonotonicMultiplesOfFour() {
        let grid: [CGFloat] = [Theme.Metrics.s1, Theme.Metrics.s2, Theme.Metrics.s3,
                               Theme.Metrics.s4, Theme.Metrics.s5, Theme.Metrics.s6,
                               Theme.Metrics.s7, Theme.Metrics.s8]
        for step in grid {
            XCTAssertEqual(step.truncatingRemainder(dividingBy: 4), 0,
                           "spacing step \(step) is off the 4pt grid")
        }
        XCTAssertEqual(grid, grid.sorted())
        XCTAssertEqual(Set(grid).count, grid.count, "two spacing steps are the same value")
        // The inner radius of a shape nested in an OlcCard is derived, not guessed,
        // so nested corners stay concentric.
        XCTAssertEqual(Theme.Metrics.innerRadius,
                       Theme.Metrics.cardRadius - Theme.Metrics.cardPadding)
    }

    // MARK: - #457: the scale inversion

    /// #457: `Typography.answer` is the token the Connect screen renders the
    /// tunnel state with — the ANSWER to the screen's one question, and the
    /// largest thing on it. Before this change the answer rendered at
    /// `statusTitle` (~15pt) inside a card carrying a 26pt coloured glow.
    ///
    /// Fonts are opaque, so what is pinned here is the CONTRACT the other
    /// partitions build against: the token exists, the legacy names still
    /// resolve to a real font, and `answer` is not accidentally the same token
    /// as the supporting line beneath it.
    func testAnswerIsItsOwnStepAboveItsSupportingLine() {
        XCTAssertNotEqual(Theme.Typography.answer, Theme.Typography.answerSupport)
        XCTAssertNotEqual(Theme.Typography.answer, Theme.Typography.title)
        XCTAssertNotEqual(Theme.Typography.answer, Theme.Typography.body)
        XCTAssertNotEqual(Theme.Typography.answer, Theme.Typography.label)
        XCTAssertNotEqual(Theme.Typography.answer, Theme.Typography.caption)
    }

    /// #457: the scale is SIX steps. `display` and `largeTitle` were byte-identical
    /// duplicates of each other; both are now aliases of `answer`, and the other
    /// legacy names each collapse onto the step they always were. This test is
    /// what makes the aliases safe to keep: if someone re-points one at a
    /// different size, the collapse is no longer silent.
    func testLegacyTypographyAliasesResolveOntoTheSixSteps() {
        XCTAssertEqual(Theme.Typography.display,        Theme.Typography.answer)
        XCTAssertEqual(Theme.Typography.largeTitle,     Theme.Typography.answer)
        XCTAssertEqual(Theme.Typography.button,         Theme.Typography.label)
        XCTAssertEqual(Theme.Typography.statusTitle,    Theme.Typography.label)
        XCTAssertEqual(Theme.Typography.chip,           Theme.Typography.label)
        XCTAssertEqual(Theme.Typography.segment,        Theme.Typography.label)
        XCTAssertEqual(Theme.Typography.statusSubtitle, Theme.Typography.caption)
        XCTAssertEqual(Theme.Typography.sectionHeader,  Theme.Typography.captionStrong)
        XCTAssertEqual(Theme.Typography.metricLabel,    Theme.Typography.captionStrong)
    }

    // MARK: - #457: the semantic inversion

    /// #457: status may never be carried by colour alone. Every `OlcStatusTone`
    /// owns a DISTINCT SF Symbol, so the five states stay distinguishable with
    /// iOS Settings → Accessibility → Display → Color Filters → Grayscale on
    /// (WCAG 2.2 SC 1.4.1, and Apple's "Differentiate Without Color Alone").
    /// #457 was: `OlcStatusDot` drew a bare `Circle().fill(tone.color)` — one
    /// shape, five states.
    func testEveryStatusToneHasItsOwnGlyph() {
        let tones: [OlcStatusTone] = [.unknown, .progress, .ok, .warn, .error]
        let symbols = tones.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, tones.count,
                       "two status tones render the same glyph: \(symbols)")
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
        // The failure state must not be another circle — a different silhouette
        // is what survives a squint, not a different hue of the same disc.
        XCTAssertEqual(OlcStatusTone.error.symbol, "xmark.octagon.fill")
        XCTAssertEqual(OlcStatusTone.ok.symbol,    "checkmark.circle.fill")
    }

    /// #457: `HealthDisplay.tone` returns `.unknown` for FOUR different facts
    /// (`.never`, `.fading`, `.inconclusive`, `.stale`), so the tone's glyph is
    /// not fine-grained enough for the health vocabulary. `OlcHealthGlyph` gives
    /// all eight states their own silhouette — "never checked", "worked a while
    /// ago", "couldn't check" and "too old to trust" are four different
    /// sentences and must not be four identical grey dots.
    func testEveryHealthStateHasItsOwnGlyph() {
        let states: [HealthDisplay] = [
            .never,
            .checking,
            .verified(ms: 128, age: 20),
            .fading(ms: 128, age: 600),
            .handshakeOnly(age: 45),
            .broken(.keyMismatch, age: 300),
            .inconclusive(.hostUnreachable, age: 120),
            .stale(age: 7200),
        ]
        let symbols = states.map(OlcHealthGlyph.symbol(for:))
        XCTAssertEqual(Set(symbols).count, states.count,
                       "two health states render the same glyph: \(symbols)")
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
        // The `.verified` → `.fading` demotion changes three channels at once:
        // the word, the colour and — pinned here — the glyph's FILL.
        XCTAssertEqual(OlcHealthGlyph.symbol(for: .verified(ms: 1, age: 1)), "checkmark.circle.fill")
        XCTAssertEqual(OlcHealthGlyph.symbol(for: .fading(ms: 1, age: 1)),   "checkmark.circle")
    }
}
