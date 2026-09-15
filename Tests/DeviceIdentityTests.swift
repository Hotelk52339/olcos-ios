import XCTest
@testable import olcrtc_ios

/// The `default` clientID is a placeholder: the room hears this install's own
/// generated id, so a shared link works on several devices at once.
final class DeviceIdentityTests: XCTestCase {

    /// Deterministic generator so the shape can be pinned exactly.
    struct FixedRNG: RandomNumberGenerator {
        var value: UInt64
        mutating func next() -> UInt64 { value &+= 0x9E3779B97F4A7C15; return value }
    }

    func testGeneratedNameIsTwoNeutralWordsAndANumber() {
        var rng = FixedRNG(value: 7)
        let name = DeviceIdentity.make(using: &rng)
        let parts = name.split(separator: "-")
        XCTAssertEqual(parts.count, 3, name)
        XCTAssertTrue(DeviceIdentity.adjectives.contains(String(parts[0])), name)
        XCTAssertTrue(DeviceIdentity.nouns.contains(String(parts[1])), name)
        XCTAssertEqual(parts[2].count, 2, name)
        XCTAssertTrue(DeviceIdentity.isWellFormed(name), name)
        // Lowercase ASCII only: goes into a URI-style clientID and a server log.
        XCTAssertTrue(name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }, name)
        XCTAssertFalse(name.contains(where: \.isWhitespace))
    }

    func testWordListsAreCleanAndLargeEnough() {
        for list in [DeviceIdentity.adjectives, DeviceIdentity.nouns] {
            XCTAssertGreaterThanOrEqual(list.count, 64)
            XCTAssertEqual(Set(list).count, list.count, "duplicates")
            for word in list {
                XCTAssertTrue(word.allSatisfy { $0.isASCII && $0.isLowercase }, word)
                XCTAssertFalse(word.contains("-"), word)
            }
        }
    }

    func testWellFormedRejectsPlaceholderOldFormatAndForeignWords() {
        XCTAssertFalse(DeviceIdentity.isWellFormed("default"))
        XCTAssertFalse(DeviceIdentity.isWellFormed("olcos-0123456789ab"))   // previous format
        XCTAssertFalse(DeviceIdentity.isWellFormed("iphone-harbor-42"))     // not our adjective
        XCTAssertFalse(DeviceIdentity.isWellFormed("quiet-harbor-4"))       // number is two digits
        XCTAssertTrue(DeviceIdentity.isWellFormed("quiet-harbor-42"))
    }

    func testRegenerateChangesTheNameAndPersistsIt() {
        let suite = "DeviceIdentityTests.regen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DeviceIdentity.current(defaults: defaults)
        let second = DeviceIdentity.regenerate(defaults: defaults)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(DeviceIdentity.current(defaults: defaults), second)
    }

    func testCurrentIsPersistedAndRegeneratedWhenCorrupt() {
        let suite = "DeviceIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = DeviceIdentity.current(defaults: defaults)
        XCTAssertEqual(DeviceIdentity.current(defaults: defaults), first)

        defaults.set("garbage", forKey: DeviceIdentity.storageKey)
        let regenerated = DeviceIdentity.current(defaults: defaults)
        XCTAssertTrue(DeviceIdentity.isWellFormed(regenerated))
        XCTAssertNotEqual(regenerated, "garbage")
    }

    func testPlaceholderAndBlankResolveToDeviceIDButExplicitIDPassesThrough() {
        let dev = "quiet-harbor-42"
        XCTAssertEqual(DeviceIdentity.effectiveClientID("default", deviceID: dev), dev)
        XCTAssertEqual(DeviceIdentity.effectiveClientID("  ", deviceID: dev), dev)
        XCTAssertEqual(DeviceIdentity.effectiveClientID("phone-2", deviceID: dev), "phone-2")
        // Batch pings keep their own per-probe id.
        XCTAssertEqual(DeviceIdentity.effectiveClientID("olc-ping-B1B91495", deviceID: dev), "olc-ping-B1B91495")
    }

    func testResolvingTouchesOnlyTheClientID() {
        let stored = OlcrtcConnection(carrier: "telemost", transport: "vp8channel",
                                      roomID: "86308568111527",
                                      key: String(repeating: "a", count: 64), clientID: "default")
        let live = DeviceIdentity.resolving(stored, deviceID: "quiet-harbor-42")
        XCTAssertEqual(live.clientID, "quiet-harbor-42")
        XCTAssertEqual(live.roomID, stored.roomID)
        XCTAssertEqual(live.key, stored.key)
        // The record itself keeps the placeholder, so shares stay device-neutral.
        XCTAssertEqual(stored.clientID, "default")
        XCTAssertFalse(OlcrtcURI.encode(stored).contains("%"))
    }
}
