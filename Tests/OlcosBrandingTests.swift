import XCTest
@testable import olcrtc_ios

// olcOS is display branding only; wire formats and existing storage identities
// intentionally keep their technical olcrtc names. No network or SSH operations.
final class OlcosBrandingTests: XCTestCase {
    func testAllLocalesUseExactDisplayBrand() {
        let brandedKeys: [L10n] = [
            .vpnSettingsEntryName, .actionUpdate, .logPortBusyOlcrtc_fmt,
            .installTitle, .connectingOlcrtc_fmt, .provisioningUpdating,
            .installPhaseBuild, .installPhaseStart, .installResultSuccess_fmt,
            .updateResultSuccess, .scanningContainers, .actionScanVPS,
            .scanNoContainers, .actionDeepUninstall, .deepUninstallResultSuccess,
            .portInUseByOlcrtc, .carrierEndpointsLead, .logsScanAmbiguous_fmt
        ]
        for locale in AppLocale.allCases {
            XCTAssertEqual(L10n.vpnSettingsEntryName.localized(locale), "olcOS")
            for key in brandedKeys {
                let value = key.localized(locale)
                XCTAssertTrue(value.contains("olcOS"), "\(locale.rawValue): \(key)")
                XCTAssertFalse(value.lowercased().contains("olcrtc"), "\(locale.rawValue): \(key)")
            }
        }
    }

    func testLocalizedProtocolAndBotIdentifiersAreNotRebranded() {
        for locale in AppLocale.allCases {
            XCTAssertTrue(L10n.uriErrorInvalidScheme.localized(locale).contains("olcrtc://"))
            XCTAssertTrue(L10n.subInvalidLink.localized(locale).contains("olcrtc-sub://host/path"))
            XCTAssertEqual(L10n.botNamePlaceholder.localized(locale), "olcrtc_server_bot")
        }
    }

    func testLegacyConnectionAndSubscriptionLinksStillParse() throws {
        let key = String(repeating: "a", count: 64)
        let parsed = try OlcrtcURI.parse("olcrtc://telemost?datachannel@room#\(key)")
        XCTAssertEqual(parsed.carrier, "telemost")
        XCTAssertEqual(parsed.transport, "datachannel")
        XCTAssertEqual(parsed.roomID, "room")
        XCTAssertEqual(parsed.key, key)
        XCTAssertEqual(try OlcrtcSubscription.httpsURL(
            from: URL(string: "olcrtc-sub://example.org/list?token=test")!).absoluteString,
            "https://example.org/list?token=test")
    }

    @MainActor
    func testSessionLogBannerUsesBrandWithoutChangingBundleVersionValues() {
        let (version, build) = LogExport.appVersionBuild()
        XCTAssertEqual(LogStore.appVersionString(), "olcOS \(version) build \(build)")
    }
}
