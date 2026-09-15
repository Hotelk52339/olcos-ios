import XCTest
import CoreGraphics
@testable import olcrtc_ios

// Round 2 — the wrapping arithmetic behind `FlowLayout` / `OlcChipPicker`.
//
// The bug this pins: inside a Form row the picker was measured with an
// unspecified width first (one-line height), then wrapped at the real width —
// and the row kept the one-line height, clipping the second line ("Сервис": the
// third chip cut off). `FlowLayoutMath` is proposal-driven and pure, so the
// three cases (nil / infinite / finite proposal) are checked with plain numbers.

final class FlowLayoutMathTests: XCTestCase {

    // Three "Service" chips as they measure at the default text size, roughly.
    private let chips: [CGSize] = [
        CGSize(width: 190, height: 34),   // Яндекс Телемост
        CGSize(width: 130, height: 34),   // WB Stream
        CGSize(width: 70,  height: 34),   // Jitsi
    ]
    private let spacing: CGFloat = 8

    // MARK: wrapWidth — what the flow wraps at

    func testNilProposalMeansSingleLine() {
        let w = FlowLayoutMath.wrapWidth(nil, widths: chips.map(\.width), spacing: spacing)
        XCTAssertEqual(w, 190 + 130 + 70 + 2 * 8)
    }

    func testInfiniteAndZeroProposalsAlsoMeanSingleLine() {
        let natural = FlowLayoutMath.singleLineWidth(widths: chips.map(\.width), spacing: spacing)
        XCTAssertEqual(FlowLayoutMath.wrapWidth(.infinity, widths: chips.map(\.width), spacing: spacing), natural)
        XCTAssertEqual(FlowLayoutMath.wrapWidth(.greatestFiniteMagnitude, widths: chips.map(\.width), spacing: spacing),
                       .greatestFiniteMagnitude,
                       "greatestFiniteMagnitude is finite and positive — it is honoured, and wraps nothing")
        XCTAssertEqual(FlowLayoutMath.wrapWidth(0, widths: chips.map(\.width), spacing: spacing), natural)
        XCTAssertEqual(FlowLayoutMath.wrapWidth(-1, widths: chips.map(\.width), spacing: spacing), natural)
    }

    func testFinitePositiveProposalIsHonoured() {
        XCTAssertEqual(FlowLayoutMath.wrapWidth(340, widths: chips.map(\.width), spacing: spacing), 340)
    }

    func testSingleLineWidthOfNothingIsZero() {
        XCTAssertEqual(FlowLayoutMath.singleLineWidth(widths: [], spacing: spacing), 0)
        XCTAssertEqual(FlowLayoutMath.singleLineWidth(widths: [50], spacing: spacing), 50)
    }

    // MARK: rows — which chip lands on which line

    func testThreeServiceChipsWrapToTwoLinesInAFormRow() {
        // A Form card row on a 390pt phone leaves ≈ 340pt of content width:
        // 190 + 8 + 130 = 328 fits; + 8 + 70 = 406 does not → Jitsi wraps.
        let rows = FlowLayoutMath.rows(widths: chips.map(\.width), spacing: spacing, maxWidth: 340)
        XCTAssertEqual(rows, [[0, 1], [2]])
    }

    func testEverythingFitsOnOneLineWhenWideEnough() {
        let rows = FlowLayoutMath.rows(widths: chips.map(\.width), spacing: spacing, maxWidth: 500)
        XCTAssertEqual(rows, [[0, 1, 2]])
    }

    func testNoChipIsEverDropped() {
        // Narrower than any single chip: each chip still gets its own line.
        let rows = FlowLayoutMath.rows(widths: chips.map(\.width), spacing: spacing, maxWidth: 40)
        XCTAssertEqual(rows, [[0], [1], [2]])
        XCTAssertEqual(rows.flatMap { $0 }, [0, 1, 2])
    }

    func testExactFitDoesNotWrap() {
        // 100 + 8 + 100 = 208 exactly.
        let rows = FlowLayoutMath.rows(widths: [100, 100], spacing: spacing, maxWidth: 208)
        XCTAssertEqual(rows, [[0, 1]])
    }

    func testEmptyInputGivesNoRows() {
        XCTAssertEqual(FlowLayoutMath.rows(widths: [], spacing: spacing, maxWidth: 300), [])
    }

    // MARK: size — the height the Form row must reserve

    func testWrappedSizeReportsTwoLinesOfHeight() {
        let size = FlowLayoutMath.size(sizes: chips, spacing: spacing, lineSpacing: 8, maxWidth: 340)
        XCTAssertEqual(size.height, 34 + 8 + 34, "two lines plus one line gap — the row must grow, not clip")
        XCTAssertEqual(size.width, 190 + 8 + 130, "the widest line, not the container")
    }

    func testSingleLineSizeHasOneLineOfHeight() {
        let natural = FlowLayoutMath.singleLineWidth(widths: chips.map(\.width), spacing: spacing)
        let size = FlowLayoutMath.size(sizes: chips, spacing: spacing, lineSpacing: 8, maxWidth: natural)
        XCTAssertEqual(size.height, 34)
        XCTAssertEqual(size.width, natural)
    }

    func testTallestChipSetsItsLineHeight() {
        let mixed = [CGSize(width: 100, height: 34), CGSize(width: 100, height: 50), CGSize(width: 100, height: 34)]
        let size = FlowLayoutMath.size(sizes: mixed, spacing: spacing, lineSpacing: 8, maxWidth: 208)
        // line 1: chips 0+1 (height 50); line 2: chip 2 (height 34)
        XCTAssertEqual(size.height, 50 + 8 + 34)
    }

    func testSizeOfNothingIsZero() {
        let size = FlowLayoutMath.size(sizes: [], spacing: spacing, lineSpacing: 8, maxWidth: 300)
        XCTAssertEqual(size, .zero)
    }

    // MARK: sizeThatFits ↔ placeSubviews agreement

    func testMeasureAndPlacementUseTheSameRows() {
        // What `sizeThatFits` reports for a width must be what `placeSubviews`
        // lays out at that width — otherwise the clip comes back.
        for width: CGFloat in [40, 200, 340, 400, 500] {
            let rows = FlowLayoutMath.rows(widths: chips.map(\.width), spacing: spacing, maxWidth: width)
            let size = FlowLayoutMath.size(sizes: chips, spacing: spacing, lineSpacing: 8, maxWidth: width)
            let expectedHeight = CGFloat(rows.count) * 34 + CGFloat(max(0, rows.count - 1)) * 8
            XCTAssertEqual(size.height, expectedHeight, "width \(width)")
        }
    }
}
