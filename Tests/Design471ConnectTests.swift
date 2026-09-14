import XCTest
@testable import olcrtc_ios

// #471: regression pins for the Connect tab's half of the design pass.
//
// The pass is mostly SUBTRACTION — a deleted Diagnostics row, a deleted hero
// eyebrow, a deleted "only one protocol" note, a card's decorative glyph — and a
// deletion is pinned by the code that no longer exists, not by a test. What it
// ADDED is exactly one decision: whether a switcher row should print its host
// label at all. That decision is a pure static (`ConnectionNaming
// .spansMultipleHosts`) precisely so it can be pinned here without a SwiftUI
// host, in the pattern the rest of Tests/ uses; `ConnectionsView.recompute()`
// calls it once per store change and passes the answer down as
// `ConnectionRowView.showHost`, because that view is rebuilt ~10x/s during a
// speed test and may not derive it per row.
//
// WHY THE RULE: one VPS runs several protocol containers here, so with a single
// server every row printed the same word under its own name. A line identical on
// every row carries no bits. `ConnectionNaming.host` is what a row prints, so
// this asks the question in exactly the terms the row answers it — including the
// carrier-suffix stripping, which is what makes "zaza · telemost" and
// "zaza · jitsi" ONE host rather than two.
//
// The language is locked to English and restored: `host` compares a name's tail
// against the CURRENT localized carrier label, so the strip is language-sensitive
// (see `Review470ServersTests` for the locale-stability pin on the raw ids).
final class Design471ConnectTests: XCTestCase {

    private var savedLanguage = ""

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        SettingsStore.flushPendingWrites()
        super.tearDown()
    }

    // MARK: Fixtures

    private func record(_ name: String, carrier: String) -> ConnectionRecord {
        ConnectionRecord(name: name, details: .olcrtc(OlcrtcConnection(
            carrier: carrier, transport: "vp8channel", roomID: "r", key: "k", clientID: "default")))
    }

    // MARK: #471 the host line renders only when it distinguishes rows

    func testEmptyAndSingleListsDoNotSpanMultipleHosts() {
        XCTAssertFalse(ConnectionNaming.spansMultipleHosts([]))
        XCTAssertFalse(ConnectionNaming.spansMultipleHosts([record("zaza", carrier: "telemost")]))
    }

    /// The shape this product is built around: ONE server, several protocols.
    /// `ServersView.recordName` stamps "<label> · <raw carrier>" on each, and
    /// `host` strips that suffix back off — so all three rows are the same host
    /// and none of them should print it.
    func testSeveralProtocolsOnOneServerAreOneHost() {
        let records = [record("zaza · telemost", carrier: "telemost"),
                       record("zaza · jitsi", carrier: "jitsi"),
                       record("zaza", carrier: "wbstream")]
        XCTAssertFalse(ConnectionNaming.spansMultipleHosts(records))
    }

    func testTwoServersSpanMultipleHosts() {
        let records = [record("zaza · telemost", carrier: "telemost"),
                       record("prod · telemost", carrier: "telemost")]
        XCTAssertTrue(ConnectionNaming.spansMultipleHosts(records))
    }

    /// The disagreement can arrive anywhere in the list, including last — the
    /// loop short-circuits on the first one, and must not stop looking before it.
    func testADifferentHostAtTheEndIsStillFound() {
        let records = [record("zaza · telemost", carrier: "telemost"),
                       record("zaza · jitsi", carrier: "jitsi"),
                       record("prod", carrier: "telemost")]
        XCTAssertTrue(ConnectionNaming.spansMultipleHosts(records))
    }

    /// A user label the suffix rule deliberately does NOT strip ("prod ·
    /// Frankfurt", whose tail is not this record's carrier) stays whole, so it is
    /// a genuinely different host from "prod".
    func testAUserSeparatorInTheLabelIsNotACarrierSuffix() {
        let records = [record("prod · Frankfurt", carrier: "telemost"),
                       record("prod", carrier: "telemost")]
        XCTAssertEqual(ConnectionNaming.host(records[0]), "prod · Frankfurt")
        XCTAssertTrue(ConnectionNaming.spansMultipleHosts(records))
    }

    /// `host` never returns "" (it falls back to `displayName`, which falls back
    /// to `details.fallbackName`), so two blank-named records agree rather than
    /// registering as two empty hosts.
    func testBlankNamesAgreeWithEachOther() {
        let records = [record("", carrier: "telemost"), record("   ", carrier: "telemost")]
        XCTAssertFalse(ConnectionNaming.host(records[0]).isEmpty)
        XCTAssertFalse(ConnectionNaming.spansMultipleHosts(records))
    }
}
