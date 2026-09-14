import XCTest
@testable import olcrtc_ios

// boc #488
// Pure preference matching and representative French copy. Native permission
// resource selection and layout still require an iOS host/device integration run.
final class AppLocaleFrenchTests: XCTestCase {
    func testSupportedLocalesAndNativeNames() {
        XCTAssertEqual(Set(AppLocale.allCases.map(\.rawValue)), Set(["en", "ru", "fr"]))
        XCTAssertEqual(AppLocale.french.displayName, "Français")
        XCTAssertEqual(AppLocale.french.id, "fr")
    }

    func testPreferredLanguageUsesFirstSupportedSystemPreference() {
        let examples: [([String], String)] = [
            (["fr"], "fr"), (["fr-FR"], "fr"), (["fr-CA"], "fr"),
            (["FR-ch"], "fr"), (["fr_BE"], "fr"),
            (["ru"], "ru"), (["ru-RU"], "ru"), (["RU-kz"], "ru"),
            (["en-GB", "fr-FR"], "en"), (["fr-CA", "ru-RU"], "fr"),
            (["ru-RU", "fr-FR"], "ru"), (["de-DE", "fr-FR", "en"], "fr"),
            (["ja", "ru-RU"], "ru"), (["de-DE", "en-US", "fr"], "en"),
            ([], "en"), ([""], "en"), (["de-DE", "ja"], "en")
        ]
        for (preferences, expected) in examples {
            XCTAssertEqual(AppLocale.preferredLanguage(from: preferences), expected,
                "Unexpected seed for \(preferences)")
        }
    }

    func testFrenchLookupIsAnIndependentTranslation() {
        XCTAssertEqual(L10n.tabSettings.localized(.french), "Réglages")
        XCTAssertEqual(L10n.actionDisconnect.localized(.french), "Déconnecter")
        XCTAssertEqual(L10n.languageLabel.localized(.french), "Langue")
        XCTAssertEqual(L10n.vpnAutomaticFallbackSummary.localized(.french), "Mode de secours SOCKS5 actif")
        XCTAssertEqual(L10n.transportDatachannel.localized(.french), "DataChannel")
        for key in L10n.allCases {
            XCTAssertEqual(L10nTable.value(for: key, in: .french), L10nTable.french[key],
                "\(key.rawValue) must resolve directly from French, not fallback")
        }
    }

    func testFrenchFormattingPreservesArgumentOrder() {
        let original = SettingsStore.shared.language
        defer {
            SettingsStore.shared.language = original
            SettingsStore.flushPendingWrites()
        }
        SettingsStore.shared.language = "fr"
        XCTAssertEqual(L10n.installResultSuccess_fmt.formatted("telemost", "vp8channel"),
            "Serveur olcOS installé (telemost/vp8channel)")
        XCTAssertEqual(L10n.telemostExpiryBody_fmt.formatted("Example", 12),
            "Le salon de \"Example\" cessera de fonctionner dans environ 12 min, et le tunnel aussi. Le renouveler maintenant coupe la connexion quelques secondes.")
        XCTAssertEqual(L10n.healthLatencyMs_fmt.formatted(42), "42 ms")
    }

    func testFrenchSecurityInstructionsPreserveExecutableCommand() {
        let english = L10nTable.english[.sshHostKeyVerificationHelp]!
        let french = L10nTable.french[.sshHostKeyVerificationHelp]!
        let command = "for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf \"$key\" -E sha256; done"
        XCTAssertTrue(english.components(separatedBy: "\n").contains(command))
        XCTAssertTrue(french.components(separatedBy: "\n").contains(command))
        XCTAssertTrue(french.contains("ssh-keyscan"))
    }
}
// eoc #488
