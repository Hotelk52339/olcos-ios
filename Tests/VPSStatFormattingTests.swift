import XCTest
@testable import olcrtc_ios

// #341: pins the compact stat formatting used by the Manage VPS card's
// one-line metrics strip — shared-suffix hoisting ("36G/40G" → "36/40G"),
// uptime shortening ("3 days" → "3d"), and the "—" placeholders that keep
// the fixed-footprint card from collapsing when stats are unknown.
final class VPSStatFormattingTests: XCTestCase {

    func testUsageSharedSuffixHoisted() {
        XCTAssertEqual(ServersView.shortUsage("36G/40G"), "36/40G")
        XCTAssertEqual(ServersView.shortUsage("241M/2048M"), "241/2048M")
    }

    func testUsageMixedUnitsUntouched() {
        XCTAssertEqual(ServersView.shortUsage("980M/20G"), "980M/20G")
    }

    func testUsageMalformedOrMissingFallsBack() {
        XCTAssertEqual(ServersView.shortUsage("garbage"), "garbage")
        XCTAssertEqual(ServersView.shortUsage("36/40"), "36/40")   // no unit suffix
        XCTAssertEqual(ServersView.shortUsage(""), "—")
        XCTAssertEqual(ServersView.shortUsage(nil), "—")
    }

    func testUptimeShortened() {
        XCTAssertEqual(ServersView.shortUptime("3 days"), "3d")
        XCTAssertEqual(ServersView.shortUptime("1 day"), "1d")
        XCTAssertEqual(ServersView.shortUptime("35 min"), "35m")
        XCTAssertEqual(ServersView.shortUptime("4:22"), "4:22")   // <1 day form stays
        XCTAssertEqual(ServersView.shortUptime(""), "—")
        XCTAssertEqual(ServersView.shortUptime(nil), "—")
    }

    // MARK: #451 — shortRAM (the "RAM shows crooked" fix)
    //
    // `free -m` reports MB, so every 2 GB VPS yields a 4-digit total
    // ("407M/1967M") whose 9-char shortUsage form overflowed the 4-stat
    // metrics strip and ellipsized mid-value. shortRAM compacts a ≥1000M
    // total to the shared-G form; smaller totals and unparseable input keep
    // the shortUsage behaviour.

    func testShortRAMCompactsGigabyteTotals() {
        XCTAssertEqual(ServersView.shortRAM("407M/1967M"), "0.4/1.9G")
        XCTAssertEqual(ServersView.shortRAM("1024M/2048M"), "1.0/2.0G")
        XCTAssertEqual(ServersView.shortRAM("0M/1000M"), "0.0/1.0G")   // threshold is inclusive
    }

    func testShortRAMKeepsSubGigTotalsInMegabytes() {
        XCTAssertEqual(ServersView.shortRAM("241M/512M"), "241/512M")
        XCTAssertEqual(ServersView.shortRAM("100M/999M"), "100/999M")
    }

    func testShortRAMMalformedOrMissingFallsBack() {
        XCTAssertEqual(ServersView.shortRAM(nil), "—")
        XCTAssertEqual(ServersView.shortRAM(""), "—")
        XCTAssertEqual(ServersView.shortRAM("garbage"), "garbage")     // passthrough via shortUsage
        XCTAssertEqual(ServersView.shortRAM("980M/20G"), "980M/20G")   // mixed units untouched
    }
}
