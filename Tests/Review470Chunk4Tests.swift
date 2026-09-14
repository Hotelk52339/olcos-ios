import XCTest
@testable import olcrtc_ios

// #470: regression pins for the review batch on top of #469 (chunk 4). Every
// fix pinned here is pure or store-level; the view-side fixes (the Logs phase
// line, the protocol-chip reset, the latency listener gate, the IP / speed
// route attribution, the editor's key validation) are integration-only and
// documented at their sites.
@MainActor
final class Review470Chunk4Tests: XCTestCase {

    private var savedLanguage = ""

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: ContainerLogTargets — the #468 protocol picker's derivation (LogsView)

    private func record(_ id: UUID, carrier: String) -> ConnectionRecord {
        ConnectionRecord(
            id: id, name: carrier,
            details: .olcrtc(OlcrtcConnection(
                carrier: carrier, transport: "datachannel", roomID: "room",
                key: String(repeating: "a", count: 64), clientID: "default")))
    }

    private func multiHost(primary: UUID, extras: [UUID]) -> ServerHost {
        var host = ServerHost(label: "vps", host: "1.2.3.4")
        host.lastContainerName  = "olcrtc-server-abc"
        host.lastConnectionID   = primary
        host.extraConnectionIDs = extras
        return host
    }

    func testTargetsListThePrimaryFirstAndSiblingsAsBaseDashCarrier() {
        let primary = UUID(), telemost = UUID(), jitsi = UUID()
        let host = multiHost(primary: primary, extras: [telemost, jitsi])
        let records = [record(primary, carrier: "wbstream"),
                       record(telemost, carrier: "telemost"),
                       record(jitsi, carrier: "jitsi")]
        let targets = ContainerLogTargets.targets(host: host, records: records)
        XCTAssertEqual(targets.map(\.name),
                       ["olcrtc-server-abc", "olcrtc-server-abc-telemost", "olcrtc-server-abc-jitsi"])
        XCTAssertEqual(targets.map(\.carrier), ["wbstream", "telemost", "jitsi"])
        // A sibling is the `<base>-<carrier>` container, never the bare carrier
        // — `podman logs telemost` is the refactor this pins against.
        XCTAssertEqual(targets[1].name,
                       SSHRunner.siblingContainerName(base: "olcrtc-server-abc", carrier: "telemost"))
    }

    func testTargetsWithoutAKnownPrimaryAreEmpty() {
        let extra = UUID()
        var host = multiHost(primary: UUID(), extras: [extra])
        host.lastContainerName = nil
        XCTAssertTrue(ContainerLogTargets.targets(host: host,
                                                  records: [record(extra, carrier: "jitsi")]).isEmpty,
                      "a sibling name cannot be formed without the base")
    }

    func testTargetsSkipASiblingWhoseRecordIsGoneAndKeepAnUnknownPrimary() {
        let orphan = UUID(), jitsi = UUID()
        var host = multiHost(primary: UUID(), extras: [orphan, jitsi])
        host.lastConnectionID = nil                       // primary connection unknown
        let targets = ContainerLogTargets.targets(host: host, records: [record(jitsi, carrier: "jitsi")])
        XCTAssertEqual(targets.map(\.name), ["olcrtc-server-abc", "olcrtc-server-abc-jitsi"])
        XCTAssertNil(targets[0].carrier, "an unknown primary is listed, unlabelled")
    }

    func testResolveHonoursAPickThatBelongsToTheHost() {
        let targets = [ContainerLogTargets.Target(name: "olcrtc-server-abc", carrier: "jitsi"),
                       ContainerLogTargets.Target(name: "olcrtc-server-abc-telemost", carrier: "telemost")]
        XCTAssertEqual(ContainerLogTargets.resolve(selected: "olcrtc-server-abc-telemost", in: targets),
                       "olcrtc-server-abc-telemost")
        XCTAssertEqual(ContainerLogTargets.resolve(selected: "olcrtc-server-abc", in: targets),
                       "olcrtc-server-abc")
    }

    func testResolveFallsBackToThePrimaryForAForeignOrMissingPick() {
        let targets = [ContainerLogTargets.Target(name: "olcrtc-server-abc", carrier: "jitsi"),
                       ContainerLogTargets.Target(name: "olcrtc-server-abc-telemost", carrier: "telemost")]
        // A chip picked on ANOTHER host must never become this host's command.
        XCTAssertEqual(ContainerLogTargets.resolve(selected: "olcrtc-server-xyz-telemost", in: targets),
                       "olcrtc-server-abc")
        XCTAssertEqual(ContainerLogTargets.resolve(selected: nil, in: targets), "olcrtc-server-abc")
    }

    func testResolveIsNilWhenTheHostHasNoContainers() {
        XCTAssertNil(ContainerLogTargets.resolve(selected: "anything", in: []))
        XCTAssertNil(ContainerLogTargets.resolve(selected: nil, in: []))
    }

    // MARK: Health chips — the unit is localized, a stale failure is not "seen" (NodeHealth)

    func testVerifiedAndFadingChipsLocalizeTheUnit() {
        SettingsStore.shared.language = "ru"
        let verified = HealthDisplay.verified(ms: 215, age: 120).chipLabel
        XCTAssertTrue(verified.contains(L10n.healthLatencyMs_fmt.formatted(215)), verified)
        XCTAssertFalse(verified.contains("215 ms"), "the Latin unit beside a Russian age: \(verified)")
        let fading = HealthDisplay.fading(ms: 215, age: 600).chipLabel
        XCTAssertTrue(fading.contains(L10n.healthLatencyMs_fmt.formatted(215)), fading)
        XCTAssertFalse(fading.contains("215 ms"), fading)

        SettingsStore.shared.language = "en"
        XCTAssertEqual(HealthDisplay.verified(ms: 48, age: 120).chipLabel,
                       "48 ms · \(HealthAge.short(120))")
    }

    func testStaleChipNeverClaimsTheNodeWasSeenWorking() {
        // `.stale` is reached for EVERY kind past staleSeconds, a key mismatch
        // included — the chip may date the check, never imply it succeeded.
        // The key kept its name; its TEXT changed from "last seen %@" to
        // "checked %@" (L10nTable), which is what this pins in both languages.
        let en = HealthDisplay.stale(age: 7200).chipLabel
        XCTAssertEqual(en, L10n.healthChipStale_fmt.formatted(HealthAge.phrase(7200)))
        XCTAssertFalse(en.lowercased().contains("seen"), en)
        XCTAssertTrue(en.lowercased().hasPrefix("checked"), en)
        SettingsStore.shared.language = "ru"
        let ru = HealthDisplay.stale(age: 7200).chipLabel
        XCTAssertFalse(ru.lowercased().contains("последний раз"), ru)
        XCTAssertTrue(ru.lowercased().hasPrefix("проверено"), ru)
    }

    // MARK: BotStore — an unreadable registry is not a fresh install

    private let botsKey = "olcrtc_bots"

    private func withBotsBlob(_ blob: Data?, _ body: () -> Void) {
        let snapshot = UserDefaults.standard.data(forKey: botsKey)
        defer {
            if let snapshot { UserDefaults.standard.set(snapshot, forKey: botsKey) }
            else { UserDefaults.standard.removeObject(forKey: botsKey) }
        }
        if let blob { UserDefaults.standard.set(blob, forKey: botsKey) }
        else { UserDefaults.standard.removeObject(forKey: botsKey) }
        body()
    }

    func testUnreadableRegistryIsKeptOnDiskAndRendersEmpty() {
        // A platform rawValue this build does not know — the downgrade case.
        let blob = Data(#"[{"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","name":"old_bot","platform":"martian"}]"#.utf8)
        withBotsBlob(blob) {
            let store = BotStore()
            XCTAssertTrue(store.bots.isEmpty,
                          "an unreadable registry must not be replaced by the seeded default")
            XCTAssertEqual(UserDefaults.standard.data(forKey: botsKey), blob,
                           "the stored copy stays for a build that can read it")
        }
    }

    func testAbsentRegistryIsSeededWithTheDefaultBot() {
        withBotsBlob(nil) {
            let store = BotStore()
            XCTAssertEqual(store.bots.map(\.name), [BotIdentity.defaultName])
            XCTAssertEqual(store.bots.first?.platform, .telegram)
        }
    }

    func testReadableRegistryLoadsAsStored() throws {
        let bot = BotIdentity(name: "mine", platform: .telegram)
        let blob = try JSONEncoder().encode([bot])
        withBotsBlob(blob) {
            let store = BotStore()
            XCTAssertEqual(store.bots, [bot])
        }
    }
}
