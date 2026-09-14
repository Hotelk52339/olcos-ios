import XCTest
@testable import olcrtc_ios

// Verifies completeness of every per-language dictionary in L10nTable.
// Adding a new L10n case without translations fails one of these tests with
// a list of the missing keys — no silent fallbacks.

final class L10nTests: XCTestCase {

    func testEveryKeyHasAllLanguages() {
        var problems: [String] = []
        for key in L10n.allCases {
            for locale in AppLocale.allCases {
                let value: String?
                switch locale {
                case .english: value = L10nTable.english[key]
                case .russian: value = L10nTable.russian[key]
                case .french: value = L10nTable.french[key] // #488: No French fallback may hide a missing entry.
                }
                if value == nil {
                    problems.append("[\(locale.rawValue)] missing: \(key.rawValue)")
                } else if value!.isEmpty {
                    problems.append("[\(locale.rawValue)] empty: \(key.rawValue)")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.sorted().joined(separator: "\n"))
    }

    // boc #488
    // #488 was: Counts and orphan keys were checked only for English and Russian.
    // Dictionary literals trap on duplicate keys; the offline validator also
    // checks source duplicates before a Swift runtime can construct the tables.
    func testNoExtraKeysInDictionaries() {
        let expected = Set(L10n.allCases)
        for locale in AppLocale.allCases {
            let table = Self.dictionary(for: locale)
            XCTAssertEqual(table.count, expected.count, "[\(locale.rawValue)] wrong dictionary size")
            XCTAssertEqual(Set(table.keys), expected, "[\(locale.rawValue)] missing or orphan keys")
        }
    }

    private static func dictionary(for locale: AppLocale) -> [L10n: String] {
        switch locale {
        case .english: return L10nTable.english
        case .russian: return L10nTable.russian
        case .french: return L10nTable.french
        }
    }
    // eoc #488

    // Format-string consistency: cases whose names end with `_fmt` must contain
    // at least one placeholder in EVERY language. Catches translators who drop
    // the %@/%d/%lld marker accidentally.
    // #470: and the SAME specifiers in the SAME order in every language.
    // `L10n.formatted` is `String(format:arguments:)`, so a Russian string that
    // swaps "%@ … %d" to "%d … %@", or adds a third "%@", passed the old
    // "contains at least one" check and would read an Int as an object pointer
    // (or off the end of the argument list) at runtime — e.g. the expiry alert
    // crashing at the moment the room is about to die. Positional forms
    // (`%1$@`) are not used in the tables; if one is ever introduced, this
    // order comparison has to sort by position instead.
    // boc #488
    // #488 was: Only EN/RU *_fmt values were compared for ordered placeholders.
    func testFormatCasesContainPlaceholders() {
        let formatKeys = L10n.allCases.filter { $0.rawValue.hasSuffix("_fmt") }
        XCTAssertFalse(formatKeys.isEmpty, "The format-case check must not be vacuous")
        for key in formatKeys {
            let expected = Self.specifiers(in: L10nTable.english[key] ?? "")
            XCTAssertFalse(expected.isEmpty, "[en] \(key.rawValue) has no placeholders")
            for locale in AppLocale.allCases {
                let actual = Self.specifiers(in: Self.dictionary(for: locale)[key] ?? "")
                XCTAssertEqual(actual, expected,
                    "[\(locale.rawValue)] \(key.rawValue): String(format:) needs identical ordered specifiers")
            }
        }
    }

    // Compare every value, not only named format cases, so translated prose
    // cannot accidentally introduce an unchecked conversion specifier.
    func testAllPlaceholderSequencesMatchEnglish() {
        for key in L10n.allCases {
            let expected = Self.specifiers(in: L10nTable.english[key] ?? "")
            for locale in AppLocale.allCases {
                XCTAssertEqual(Self.specifiers(in: Self.dictionary(for: locale)[key] ?? ""), expected,
                    "[\(locale.rawValue)] mismatched placeholders for \(key.rawValue)")
            }
        }
    }
    // eoc #488
    // #470 was: assertHasPlaceholder(_:key:lang:) — "contains at least one of
    // %@ %d %lld %f %.0f %.1f %.2f", per language, with no cross-language check.

    // boc #470
    /// The inverse rule: a value carrying a `%` specifier that is NOT a `_fmt`
    /// case escapes the check above entirely — `removeHostConfirmTitle`
    /// ("Remove %@?", consumed with `.formatted(…)` in ServersView) is exactly
    /// that today. It is listed here rather than renamed, because the rename
    /// touches L10n.swift, both tables and ServersView. The set is compared for
    /// EQUALITY: the rename, or a new offender, fails this test and updates it.
    func testEveryPlaceholderBelongsToAFormatCase() {
        let knownExceptions: Set<String> = []   // #470: removeHostConfirmTitle is _fmt now
        var offenders: Set<String> = []
        for key in L10n.allCases where !key.rawValue.hasSuffix("_fmt") {
            // #488 was: [L10nTable.english[key], L10nTable.russian[key]]
            for value in AppLocale.allCases.compactMap({ Self.dictionary(for: $0)[key] })
            where !Self.specifiers(in: value).isEmpty {
                offenders.insert(key.rawValue)
            }
        }
        XCTAssertEqual(offenders, knownExceptions,
            "a value with a % specifier must live in a *_fmt case (or be listed above, with its reason)")
    }

    /// The `%` conversion specifiers of a `String(format:)` string, in order:
    /// %[positional$][flags][width][.precision][length]conversion. The space
    /// flag is deliberately not accepted, so prose like "50% done" never reads
    /// as `% d`; an escaped `%%` is not in the tables either.
    private static func specifiers(in value: String) -> [String] {
        let pattern = #"%(\d+\$)?[-+0#]*\d*(\.\d+)?(ll|l|h)?[@dfsxXuioceEgGp]"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let whole = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: whole).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }
    // eoc #470

    // MARK: AppLocale

    func testAppLocaleCurrentRespectsSettings() {
        let original = SettingsStore.shared.language
        // boc #488: Restore asynchronous settings writes even if a test exits early.
        defer {
            SettingsStore.shared.language = original
            SettingsStore.flushPendingWrites()
        }
        // eoc #488
        SettingsStore.shared.language = "en"
        XCTAssertEqual(AppLocale.current, .english)
        SettingsStore.shared.language = "ru"
        XCTAssertEqual(AppLocale.current, .russian)
        // boc #488
        SettingsStore.shared.language = "fr"
        XCTAssertEqual(AppLocale.current, .french)
        // eoc #488
        SettingsStore.shared.language = "xx-unknown"
        XCTAssertEqual(AppLocale.current, .english, "Unknown codes must fall back to English")
        // #488 was: SettingsStore.shared.language = original — now restored by defer.
    }

    func testEveryAppLocaleHasDisplayName() {
        for locale in AppLocale.allCases {
            XCTAssertFalse(locale.displayName.isEmpty,
                "AppLocale.\(locale.rawValue) has empty displayName")
        }
    }

    // MARK: Smoke test for L10n.localized / .formatted

    func testLocalizedReturnsCurrentLanguageValue() {
        let original = SettingsStore.shared.language
        // boc #488: Restore asynchronous settings writes even if a test exits early.
        defer {
            SettingsStore.shared.language = original
            SettingsStore.flushPendingWrites()
        }
        // eoc #488
        SettingsStore.shared.language = "en"
        XCTAssertEqual(L10n.actionConnect.localized(), "Connect")
        SettingsStore.shared.language = "ru"
        XCTAssertEqual(L10n.actionConnect.localized(), "Подключить")
        // boc #488
        SettingsStore.shared.language = "fr"
        XCTAssertEqual(L10n.actionConnect.localized(), "Connecter")
        // eoc #488
        // #488 was: SettingsStore.shared.language = original — now restored by defer.
    }

    func testFormattedSubstitutesArgs() {
        let original = SettingsStore.shared.language
        // boc #488: Restore asynchronous settings writes even if a test exits early.
        defer {
            SettingsStore.shared.language = original
            SettingsStore.flushPendingWrites()
        }
        // eoc #488
        SettingsStore.shared.language = "en"
        let result = L10n.installResultSuccess_fmt.formatted("telemost", "vp8channel")
        XCTAssertEqual(result, "olcOS server installed (telemost/vp8channel)")
        // #488 was: SettingsStore.shared.language = original — now restored by defer.
    }
}
