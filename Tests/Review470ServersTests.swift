import XCTest
@testable import olcrtc_ios

// #470: regression pins for the ServersView review batch. Everything here is a
// pure static on ServersView — the view's resolution and naming decisions live
// in `static func`s so they can be pinned without a SwiftUI host (the same
// pattern as `VPSStatFormattingTests`). The behavioural fixes of the batch —
// Retry re-targeting the failed request, the telemost phase owner, the op
// read-clock stamp, the swipe-delete confirmation, reinstall/add-carrier
// correcting records in place — are view state and documented at their sites.
final class Review470ServersTests: XCTestCase {

    private var savedLanguage = ""

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        SettingsStore.flushPendingWrites()
        super.tearDown()
    }

    // MARK: Fixtures

    private func record(_ name: String, carrier: String, room: String) -> ConnectionRecord {
        ConnectionRecord(name: name, details: .olcrtc(OlcrtcConnection(
            carrier: carrier, transport: "vp8channel", roomID: room, key: "k", clientID: "default")))
    }

    private func row(_ carrier: String, room: String, primary: Bool,
                     status: ContainerStatus = .running("Up 1 hour")) -> SSHRunner.CarrierInfo {
        SSHRunner.CarrierInfo(
            file: primary ? "server.yaml" : "server-\(carrier).yaml",
            provider: carrier, transport: "vp8channel", room: room,
            container: primary ? "olcrtc-server-abc" : "olcrtc-server-abc-\(carrier)",
            status: status, isPrimary: primary)
    }

    private func host(primary: ConnectionRecord?, extras: [ConnectionRecord]) -> ServerHost {
        var h = ServerHost(label: "zaza", host: "1.2.3.4")
        h.lastContainerName  = "olcrtc-server-abc"
        h.lastConnectionID   = primary?.id
        h.extraConnectionIDs = extras.isEmpty ? nil : extras.map(\.id)
        return h
    }

    // MARK: #467 row → record resolution (the READ resolver)

    func testResolveRecordKeepsSameCarrierPrimaryAndSiblingInTheirOwnSlots() {
        let primary = record("P", carrier: "telemost", room: "111")
        let sibling = record("S", carrier: "telemost", room: "222")
        let h = host(primary: primary, extras: [sibling])
        let records = [sibling, primary]   // store order must not matter
        XCTAssertEqual(ServersView.resolveRecord(host: h, row: row("telemost", room: "111", primary: true),
                                                 records: records)?.id, primary.id)
        XCTAssertEqual(ServersView.resolveRecord(host: h, row: row("telemost", room: "222", primary: false),
                                                 records: records)?.id, sibling.id)
    }

    func testResolveRecordSurvivesARoomChangeOnTheServer() {
        // The room is mutable state (a renewal, an edit made elsewhere): the row
        // lists a room the record has not learnt yet and must still find it —
        // the #467 bug was "no saved connection for this protocol" here.
        let primary = record("P", carrier: "telemost", room: "old-primary")
        let sibling = record("S", carrier: "jitsi", room: "https://meet.example/old")
        let h = host(primary: primary, extras: [sibling])
        let records = [primary, sibling]
        XCTAssertEqual(ServersView.resolveRecord(host: h, row: row("telemost", room: "new-primary", primary: true),
                                                 records: records)?.id, primary.id)
        XCTAssertEqual(ServersView.resolveRecord(host: h, row: row("jitsi", room: "https://meet.example/new", primary: false),
                                                 records: records)?.id, sibling.id)
    }

    func testResolveRecordOwnSlotBeatsTheOtherSlotEvenOnAnExactRoomMatch() {
        // Same carrier on both rows and the SIBLING's record holds the primary
        // row's room: the primary row still resolves inside its own slot.
        let primary = record("P", carrier: "telemost", room: "aaa")
        let sibling = record("S", carrier: "telemost", room: "bbb")
        let h = host(primary: primary, extras: [sibling])
        XCTAssertEqual(ServersView.resolveRecord(host: h, row: row("telemost", room: "bbb", primary: true),
                                                 records: [primary, sibling])?.id, primary.id)
    }

    func testResolveRecordFallsBackAcrossSlotsThenToAnExactImportOnly() {
        // Documented order past the slot: any linked exact → any linked by
        // carrier → an UNLINKED record, exact only.
        let primary  = record("P", carrier: "jitsi", room: "https://meet.example/p")
        let imported = record("I", carrier: "telemost", room: "777")
        let h = host(primary: primary, extras: [])
        let records = [primary, imported]
        // A sibling row of the primary's carrier with no record of its own
        // resolves to the primary — the read side, so Connect still has a record.
        XCTAssertEqual(ServersView.resolveRecord(host: h, row: row("jitsi", room: "https://meet.example/x", primary: false),
                                                 records: records)?.id, primary.id)
        // An unlinked import is matched on carrier AND room, never carrier alone.
        XCTAssertEqual(ServersView.resolveRecord(host: h, row: row("telemost", room: "777", primary: false),
                                                 records: records)?.id, imported.id)
        XCTAssertNil(ServersView.resolveRecord(host: h, row: row("telemost", room: "778", primary: false),
                                               records: records))
    }

    // MARK: #470 the WRITE-side resolver never leaves the slot

    func testSlotRecordNeverReachesThePrimaryOrAnImport() {
        let primary  = record("P", carrier: "jitsi", room: "https://meet.example/p")
        let imported = record("I", carrier: "jitsi", room: "https://meet.example/s")
        let h = host(primary: primary, extras: [])
        let records = [primary, imported]
        // Remove protocol on a jitsi sibling whose own record is gone: nothing
        // to delete — not the primary (same carrier), not the QR import (exact).
        XCTAssertNil(ServersView.resolveSlotRecord(host: h, isPrimary: false, carrier: "jitsi",
                                                   room: "https://meet.example/s", records: records))
        // The primary slot resolves the primary and nothing else.
        XCTAssertEqual(ServersView.resolveSlotRecord(host: h, isPrimary: true, carrier: "jitsi",
                                                     room: "anything", records: records)?.id, primary.id)
        XCTAssertNil(ServersView.resolveSlotRecord(host: h, isPrimary: true, carrier: "telemost",
                                                   room: "anything", records: records))
    }

    func testSlotRecordPrefersTheExactRoomThenTheCarrier() {
        let a = record("A", carrier: "telemost", room: "111")
        let b = record("B", carrier: "telemost", room: "222")
        let h = host(primary: nil, extras: [a, b])
        let records = [a, b]
        XCTAssertEqual(ServersView.resolveSlotRecord(host: h, isPrimary: false, carrier: "telemost",
                                                     room: "222", records: records)?.id, b.id)
        // Room drifted on the server: the carrier still finds the slot's record,
        // so a key rotation re-keys it instead of leaving it dead.
        XCTAssertEqual(ServersView.resolveSlotRecord(host: h, isPrimary: false, carrier: "telemost",
                                                     room: "333", records: records)?.id, a.id)
        XCTAssertNil(ServersView.resolveSlotRecord(host: h, isPrimary: false, carrier: "wbstream",
                                                   room: "333", records: records))
    }

    // MARK: #470 room drift — the fix is offered before the verdict is trusted

    func testRoomDriftedOnlyWhenTheRowHoldsADifferentRoom() {
        let rec = record("R", carrier: "telemost", room: "111")
        XCTAssertFalse(ServersView.roomDrifted(nil, from: row("telemost", room: "111", primary: false)))
        XCTAssertFalse(ServersView.roomDrifted(rec, from: row("telemost", room: "111", primary: false)))
        XCTAssertTrue(ServersView.roomDrifted(rec, from: row("telemost", room: "222", primary: false)))
        // An unread yaml (empty ROOM=) is not evidence of a drift.
        XCTAssertFalse(ServersView.roomDrifted(rec, from: row("telemost", room: "", primary: false)))
    }

    // MARK: #470 record names are locale-stable

    func testRecordNameCarriesTheRawCarrierIdInEveryLanguage() {
        let h = ServerHost(label: "zaza", host: "1.2.3.4")
        for lang in ["ru", "en"] {
            SettingsStore.shared.language = lang
            let name = ServersView.recordName(host: h, carrier: "telemost", multi: true)
            XCTAssertEqual(name, "zaza · telemost", "language \(lang)")
            XCTAssertFalse(name.contains(CarrierTransportMatrix.carrierLabel("telemost")),
                           "the localized label must never be persisted (language \(lang))")
            // …and the Connect tab strips it back to the host label under either language.
            XCTAssertEqual(ConnectionNaming.stripCarrierSuffix(name: name, carrier: "telemost"), "zaza")
        }
        XCTAssertEqual(ServersView.recordName(host: h, carrier: "telemost", multi: false), "zaza")
    }
}
