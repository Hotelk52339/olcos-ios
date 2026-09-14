import XCTest
@testable import olcrtc_ios

// #454: unit tests for CountryFlag.emoji — the pure ISO-2 → flag-emoji helper
// behind the Connection-health card's exit row. The card's live-ping loop and
// the exit-geo fetch are async/UI paths, integration-only (not covered here).

final class CountryFlagTests: XCTestCase {

    func testValidCodesProduceFlags() {
        XCTAssertEqual(CountryFlag.emoji(iso2: "RU"), "🇷🇺")
        XCTAssertEqual(CountryFlag.emoji(iso2: "US"), "🇺🇸")
        XCTAssertEqual(CountryFlag.emoji(iso2: "DE"), "🇩🇪")
    }

    func testLowercaseIsAccepted() {
        XCTAssertEqual(CountryFlag.emoji(iso2: "us"), "🇺🇸")
        XCTAssertEqual(CountryFlag.emoji(iso2: "ru"), "🇷🇺")
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(CountryFlag.emoji(iso2: "  RU "), "🇷🇺")
    }

    func testInvalidInputsReturnNil() {
        XCTAssertNil(CountryFlag.emoji(iso2: "R"))     // one letter
        XCTAssertNil(CountryFlag.emoji(iso2: "RUS"))   // three letters
        XCTAssertNil(CountryFlag.emoji(iso2: "R1"))    // digit
        XCTAssertNil(CountryFlag.emoji(iso2: ""))      // empty
        XCTAssertNil(CountryFlag.emoji(iso2: "12"))    // digits
        XCTAssertNil(CountryFlag.emoji(iso2: "R-"))    // punctuation
    }
}
