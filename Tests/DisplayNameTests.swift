import XCTest
@testable import olcrtc_ios

// #283: friendly localised display names for the "Servers" group token and the
// raw carrier/transport IDs, mapped at display time (stored values stay stable).

@MainActor
final class DisplayNameTests: XCTestCase {

    func testGroupNameMapsCanonicalDefaultButPassesOthersThrough() {
        let saved = SettingsStore.shared.language
        defer { SettingsStore.shared.language = saved }

        SettingsStore.shared.language = "ru"
        XCTAssertEqual(ConnectionRecord.displayGroupName(ConnectionRecord.defaultGroupName),
                       L10n.groupDefault.localized())
        XCTAssertEqual(ConnectionRecord.displayGroupName("My VPS"), "My VPS")
    }

    func testCarrierAndTransportLabelsLocaliseAndFallBack() {
        let saved = SettingsStore.shared.language
        defer { SettingsStore.shared.language = saved }

        SettingsStore.shared.language = "ru"
        // #461: the carrier is named by its SERVICE, so the label gained its
        // vendor. #461 was: «Телемост» — renamed with `L10n.carrierTelemost`
        // («Яндекс Телемост» / "Yandex Telemost") when the Connect tab started
        // leading with the carrier instead of the server label.
        XCTAssertEqual(CarrierTransportMatrix.carrierLabel("telemost"), "Яндекс Телемост")
        // Unknown IDs pass through so a future backend still renders.
        XCTAssertEqual(CarrierTransportMatrix.carrierLabel("future"), "future")
        XCTAssertEqual(CarrierTransportMatrix.transportLabel("future"), "future")
        // Every catalogued ID resolves to a non-empty label.
        for c in CarrierTransportMatrix.carriers {
            XCTAssertFalse(CarrierTransportMatrix.carrierLabel(c).isEmpty)
        }
        for t in CarrierTransportMatrix.transports {
            XCTAssertFalse(CarrierTransportMatrix.transportLabel(t).isEmpty)
        }
    }
}
