import XCTest
import Foundation

// MARK: - TypographyLintTests (#471 — design review, B9)
//
// A SOURCE-TREE lint, not a behaviour test. It reads every `.swift` file under
// `App/Views/` and `App/UI/` and fails on the raw type steps and fixed point
// sizes that the six-step scale in `App/UI/Theme.swift` replaced.
//
// Why a grep instead of a review note: the design critique measured 115 raw
// `.font(.headline/.subheadline/.footnote/…)` calls against 32
// `Theme.Typography.*` calls — the documented scale was bypassed 78 % of the
// time — and found 64 uses of `.caption2`, a SEVENTH size step `Theme.swift`
// explicitly abolished ("Folded into step 5"). A scale that is only written
// down drifts back inside one release; a scale with a test does not.
//
// ── THE ALLOW-LIST, and what it is for ───────────────────────────────────────
//
// The allow-list below has two sections, and BOTH are meant to shrink.
//
//   1. Permanent, narrow exemptions — the handful of places where a raw
//      monospaced font is the right answer. `Theme.swift` is one (it *defines*
//      the tokens); the others are text fields that take an address, a URI or a
//      room ID and must stay at body size, a size the scale has no mono token
//      for (step 6 is caption-sized — legible to read, too small to edit in).
//      Mono is for measured data, addresses, ports, URIs, room IDs and log
//      bodies ONLY; a prose sentence in mono is a violation even where the file
//      is exempt, and no grep can catch that one — read it.
//
//   2. `// TODO #471` entries — files that were still being migrated by other
//      agents when this test landed, listed wholesale so the test is GREEN ON
//      ARRIVAL rather than red because of somebody else's half-finished file.
//      Each of these is a promise, not a permission: delete the entry the
//      moment its file is clean. The lint PRINTS every allow-list entry that has
//      stopped being necessary, so the next person to run it is told exactly
//      which lines to delete. That print is deliberately not an assertion — the
//      section-2 files are moving targets, and failing whoever finishes first
//      would be the same "red on arrival" problem in reverse.
//
// Reading the SOURCE, not the bundle: `#filePath` resolves to this file's place
// in the developer's checkout (the app bundle carries no `.swift` files), the
// same loader `ServerScriptParityTests` / `RotateKeyScriptTests` fall back to.
// Where the checkout is not reachable the test skips rather than fails.

final class TypographyLintTests: XCTestCase {

    // MARK: The rules

    /// One banned spelling, and the token that replaces it.
    private struct Rule {
        let id: String
        let needle: String
        let fix: String
    }

    private static let rules: [Rule] = [
        Rule(id: "caption2", needle: ".font(.caption2",
             fix: "Theme.Typography.caption — `.caption2` is the seventh step Theme.swift abolished"),
        Rule(id: "headline", needle: ".font(.headline",
             fix: "Theme.Typography.title — a headline marks a card's subject, which is step 2"),
        Rule(id: "subheadline", needle: ".font(.subheadline",
             fix: "Theme.Typography.body for prose, .label for a control or a secondary row line"),
        Rule(id: "footnote", needle: ".font(.footnote",
             fix: "Theme.Typography.caption — `.footnote` is not a step on the scale"),
        Rule(id: "fixedSize", needle: ".system(size:",
             fix: "a Dynamic-Type-backed Theme.Typography step — a fixed point size ignores the text-size setting, so the glyph stays put while the words around it grow"),
        Rule(id: "mono", needle: "design: .monospaced)",
             fix: "Theme.Typography.mono / .metricValue, and only for measured data, addresses, ports, URIs, room IDs or log bodies"),
    ]

    /// Every rule id — used by the wholesale entries in section 2 of the
    /// allow-list. Pinned as a literal rather than derived from `rules` so the
    /// allow-list has no static-initialisation order to reason about;
    /// `testEveryRuleIDIsListed` keeps the two in step.
    private static let everyRule: Set<String> =
        ["caption2", "headline", "subheadline", "footnote", "fixedSize", "mono"]

    // MARK: The allow-list

    /// File name → the rule ids tolerated in that file. See the header: both
    /// sections are meant to shrink, and section 2 to disappear entirely.
    private static let allowList: [String: Set<String>] = [

        // ── 1. Permanent, narrow exemptions ─────────────────────────────────

        // The scale's own definitions live here — `Typography.mono` and
        // `.metricValue` ARE `Font.system(…, design: .monospaced)`.
        "Theme.swift": ["mono"],

        // Room ID / Jitsi URL / WB-token entry fields. These are exactly the
        // documented mono cases (addresses, URIs, room IDs) and they are
        // EDITABLE fields, so they stay at body size; step 6's token is
        // caption-sized. Every other raw font in both sheets was migrated.
        "InstallOptionsView.swift": ["mono"],
        "ReconfigureOptionsView.swift": ["mono"],

        // ── 2. Identifiers that stay monospaced ─────────────────────────────
        //
        // #471: these were wholesale `everyRule` entries while the design wave
        // was in flight. Every file is migrated now, so each entry is narrowed
        // to the ONE rule it still needs — and four files dropped out entirely
        // (ConnectionsView, ServerCardView, ProtocolRowView, ConfigView).

        // The app version — a value you read back to support, not prose.
        "SettingsView.swift": ["mono"],
        // Scanned container names in the adopt sheet: identifiers, at body size
        // because they sit in a List row. A body-mono token would retire this.
        "ServersView.swift": ["mono"],
    ]

    // MARK: Scanning

    /// The repository root, from this file's compile-time path.
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Tests/
            .deletingLastPathComponent()          // olcrtc-ios/
    }

    /// Every `.swift` file under the two UI trees, sorted by name.
    /// Skips (rather than fails) when the checkout is not reachable.
    private func sourceFiles() throws -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for dir in ["App/Views", "App/UI"] {
            let root = Self.sourceRoot.appendingPathComponent(dir)
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                found.append(url)
            }
        }
        if found.isEmpty {
            throw XCTSkip("""
                No sources under \(Self.sourceRoot.path)/App — this lint reads the \
                SOURCE TREE through #filePath and cannot run without the checkout.
                """)
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The code half of a line: everything from the first `//` is dropped, so
    /// the `// #471 was: .font(.caption2)` tombstones this pass leaves behind
    /// are not read as violations. A `//` inside a string literal truncates the
    /// line early, which can only ever HIDE a hit — it can never invent one.
    private static func code(of line: Substring) -> Substring {
        guard let comment = line.range(of: "//") else { return line }
        return line[line.startIndex..<comment.lowerBound]
    }

    // MARK: Tests

    func testNoRawTypeStepsOutsideTheAllowList() throws {
        var failures: [String] = []
        var tripped: [String: Set<String>] = [:]   // file → rule ids actually hit

        for url in try sourceFiles() {
            let name = url.lastPathComponent
            let allowed = Self.allowList[name] ?? []
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let source = Self.code(of: line)
                for rule in Self.rules where source.contains(rule.needle) {
                    tripped[name, default: []].insert(rule.id)
                    if allowed.contains(rule.id) { continue }
                    failures.append("\(name):\(index + 1)  \(rule.needle)  →  use \(rule.fix)")
                }
            }
        }

        // Non-fatal housekeeping: name the allow-list entries that have stopped
        // earning their place, so the list shrinks instead of ossifying.
        for (name, ids) in Self.allowList.sorted(by: { $0.key < $1.key }) {
            let stale = ids.subtracting(tripped[name] ?? []).sorted()
            if !stale.isEmpty {
                print("""
                    TypographyLint: \(name) no longer needs the allow-list for \
                    \(stale.joined(separator: ", ")) — delete that much of the entry (#471).
                    """)
            }
        }

        XCTAssertTrue(failures.isEmpty, """
            Raw type steps outside the six-step scale (App/UI/Theme.swift → Theme.Typography).
            Each line below bypasses the scale; migrate it, or add a documented \
            allow-list entry in TypographyLintTests and say why:

            \(failures.joined(separator: "\n"))
            """)
    }

    /// A renamed or deleted file must not leave a silent hole in the allow-list
    /// — an entry that matches nothing would quietly exempt nothing while
    /// looking like it still covers something.
    func testAllowListEntriesNameRealFiles() throws {
        let present = Set(try sourceFiles().map(\.lastPathComponent))
        for name in Self.allowList.keys.sorted() {
            XCTAssertTrue(present.contains(name), """
                TypographyLintTests.allowList names \(name), which no longer exists under \
                App/Views or App/UI. Delete the entry, or update it to the new name (#471).
                """)
        }
    }

    /// `everyRule` is written out by hand (see its doc comment); this keeps it
    /// honest when a rule is added or removed.
    func testEveryRuleIDIsListed() {
        XCTAssertEqual(Self.everyRule, Set(Self.rules.map(\.id)),
                       "TypographyLintTests.everyRule must list exactly the ids in `rules`.")
    }
}
