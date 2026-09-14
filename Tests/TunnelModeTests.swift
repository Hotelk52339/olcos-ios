import XCTest
@testable import olcrtc_ios

// #vpn: TunnelMode is the persisted proxy-vs-VPN switch. Its rawValue is the
// UserDefaults wire format (`settings.tunnelMode`), so the round-trip and the
// exact raw strings are contract, not implementation detail.

final class TunnelModeTests: XCTestCase {

    func testAllCasesAndOrder() {
        // Order matters: it is the chip order in the Config tab picker.
        XCTAssertEqual(TunnelMode.allCases, [.proxy, .vpn])
    }

    func testRawValuesAreStable() {
        // These strings live in UserDefaults on real devices — renaming a case
        // would silently reset users to .proxy on update.
        XCTAssertEqual(TunnelMode.proxy.rawValue, "proxy")
        XCTAssertEqual(TunnelMode.vpn.rawValue, "vpn")
    }

    func testRawValueRoundTrip() {
        for mode in TunnelMode.allCases {
            XCTAssertEqual(TunnelMode(rawValue: mode.rawValue), mode)
        }
    }

    func testUnknownRawValueFails() {
        // SettingsStore falls back to .proxy via `?? .proxy` when this is nil.
        XCTAssertNil(TunnelMode(rawValue: "wireguard"))
        XCTAssertNil(TunnelMode(rawValue: ""))
        XCTAssertNil(TunnelMode(rawValue: "PROXY"))
    }

    func testIdentifiableIDIsRawValue() {
        for mode in TunnelMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    func testCodableRoundTrip() throws {
        let modes = TunnelMode.allCases
        let data = try JSONEncoder().encode(modes)
        let decoded = try JSONDecoder().decode([TunnelMode].self, from: data)
        XCTAssertEqual(decoded, modes)
        // Encodes as the raw string (the same wire format UserDefaults uses).
        XCTAssertEqual(String(data: data, encoding: .utf8), #"["proxy","vpn"]"#)
    }

    func testTitlesAreNonEmpty() {
        for mode in TunnelMode.allCases {
            XCTAssertFalse(mode.title.isEmpty, "\(mode.rawValue) has an empty title")
        }
    }
}
