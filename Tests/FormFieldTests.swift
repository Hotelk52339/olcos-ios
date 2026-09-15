import XCTest
@testable import olcrtc_ios

// Round 2 — `FormNote` draws the transport verdict with a tone glyph, so the
// leading ★ / ⚠ / ✗ marker the matrix strings carry for plain-text call sites is
// dropped inside the note. Pure string logic, pinned here.

final class FormFieldTests: XCTestCase {

    func testLeadingMatrixMarkersAreStripped() {
        XCTAssertEqual(FormNoteText.stripMarker("★ Рекомендуется для Jitsi."), "Рекомендуется для Jitsi.")
        XCTAssertEqual(FormNoteText.stripMarker("⚠ Working with WB Stream is uncertain."),
                       "Working with WB Stream is uncertain.")
        XCTAssertEqual(FormNoteText.stripMarker("✗ Ne fonctionne pas avec Telemost."),
                       "Ne fonctionne pas avec Telemost.")
    }

    func testMarkerWithVariationSelectorIsStripped() {
        XCTAssertEqual(FormNoteText.stripMarker("⚠\u{FE0F} Under question."), "Under question.")
    }

    func testTextWithoutMarkerIsUnchanged() {
        XCTAssertEqual(FormNoteText.stripMarker("Works with Jitsi."), "Works with Jitsi.")
        XCTAssertEqual(FormNoteText.stripMarker(""), "")
    }

    func testMarkerInsideTheSentenceIsKept() {
        // Only a LEADING marker is decoration; one in the middle is content.
        XCTAssertEqual(FormNoteText.stripMarker("Main ★ badge"), "Main ★ badge")
    }

    func testMarkerOnlyStringBecomesEmpty() {
        XCTAssertEqual(FormNoteText.stripMarker("★"), "")
        XCTAssertEqual(FormNoteText.stripMarker("★ "), "")
    }
}
