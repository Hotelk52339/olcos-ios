import XCTest
@testable import olcrtc_ios

// boc #482: C1/C2 regressions. No network, SSH, VPN or native engine calls.
// Preferences use a private suite. Only generated UUIDs touch Keychain/health;
// their entries are removed and the persisted health snapshot is restored.
@MainActor
final class Review482StoresTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var ids: [UUID] = []
    private var previousStore: ConnectionStore?
    private var savedHealth: Data?
    private var savedLogLevel: LogLevel!
    private let recordsKey = "olcrtc_records_v2"
    private let hostsKey = "olcrtc_server_hosts"

    override func setUp() async throws {
        try await super.setUp()
        suite = "Review482StoresTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        previousStore = ConnectionStore.shared
        HealthCoordinator.flushPendingWrites()
        savedHealth = UserDefaults.standard.data(forKey: "olcrtc_health_v1")
        savedLogLevel = SettingsStore.shared.logLevel
        SettingsStore.shared.logLevel = .off
    }

    override func tearDown() async throws {
        for id in ids {
            ConnectionSecretStore.remove(connectionID: id)
            HealthCoordinator.shared.forget(recordID: id)
        }
        HealthCoordinator.flushPendingWrites()
        if let savedHealth {
            UserDefaults.standard.set(savedHealth, forKey: "olcrtc_health_v1")
        } else {
            UserDefaults.standard.removeObject(forKey: "olcrtc_health_v1")
        }
        ConnectionStore.shared = previousStore
        SettingsStore.shared.logLevel = savedLogLevel
        SettingsStore.flushPendingWrites()
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func record(name: String = "Recovered") -> ConnectionRecord {
        let record = ConnectionRecord(name: name, details: .olcrtc(OlcrtcConnection(
            carrier: "telemost", transport: "datachannel", roomID: "room",
            key: "", clientID: "test")))
        ids.append(record.id)
        return record
    }

    func testSubscriptionKeyRotationInvalidatesExistingHealthInPlace() throws {
        let store = ConnectionStore(defaults: defaults)
        let source = "https://example.invalid/list"
        store.importSubscription(OlcrtcSubscription.parse(
            "olcrtc://telemost?datachannel@room#aa"), source: source)
        let before = try XCTUnwrap(store.connections.first)
        ids.append(before.id)
        store.setPrimary(before.id)
        HealthCoordinator.shared.noteLiveVerified(recordID: before.id, rttMs: 12)
        let diff = store.importSubscription(OlcrtcSubscription.parse(
            "olcrtc://telemost?datachannel@room#bb"), source: source)
        XCTAssertEqual(diff.toUpdate.count, 1)
        XCTAssertEqual(store.connections.map(\.id), [before.id])
        XCTAssertEqual(store.primaryID, before.id)
        XCTAssertNil(HealthCoordinator.shared.health(for: before.id))
        XCTAssertTrue(HealthCoordinator.shouldProbe(existing: nil, force: false, now: Date()))
    }

    func testSubscriptionRenameKeepsExistingHealth() throws {
        let store = ConnectionStore(defaults: defaults)
        let source = "https://example.invalid/list"
        store.importSubscription(OlcrtcSubscription.parse(
            "olcrtc://telemost?datachannel@room#aa\n##name: Before"), source: source)
        let before = try XCTUnwrap(store.connections.first)
        ids.append(before.id)
        HealthCoordinator.shared.noteLiveVerified(recordID: before.id, rttMs: 12)
        store.importSubscription(OlcrtcSubscription.parse(
            "olcrtc://telemost?datachannel@room#aa\n##name: After"), source: source)
        XCTAssertEqual(store.connections.first?.name, "After")
        XCTAssertTrue(HealthCoordinator.shared.display(for: before.id).isVerified)
    }

    func testConnectionInitPreservesUnreadableLiveBytesAcrossLaunches() {
        let raw = Data("[{\"futureProtocol\":".utf8)
        defaults.set(raw, forKey: recordsKey)
        XCTAssertTrue(ConnectionStore(defaults: defaults).connections.isEmpty)
        XCTAssertTrue(ConnectionStore(defaults: defaults).connections.isEmpty)
        XCTAssertEqual(defaults.data(forKey: recordsKey), raw)
        XCTAssertEqual(defaults.data(forKey: recordsKey + ".unreadable"), raw)
    }

    func testHostInitPreservesUnreadableLiveBytesAcrossLaunches() {
        let raw = Data("[{\"futureAuthMethod\":".utf8)
        defaults.set(raw, forKey: hostsKey)
        XCTAssertTrue(ServerHostStore(defaults: defaults).hosts.isEmpty)
        XCTAssertTrue(ServerHostStore(defaults: defaults).hosts.isEmpty)
        XCTAssertEqual(defaults.data(forKey: hostsKey), raw)
        XCTAssertEqual(defaults.data(forKey: hostsKey + ".unreadable"), raw)
    }

    func testReadableConnectionInitDoesNotReencodeUnknownFields() throws {
        let original = try JSONEncoder().encode([record()])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [[String: Any]])
        json[0]["futureField"] = "must survive loading"
        let raw = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        defaults.set(raw, forKey: recordsKey)
        XCTAssertEqual(ConnectionStore(defaults: defaults).connections.count, 1)
        XCTAssertEqual(defaults.data(forKey: recordsKey), raw)
    }

    func testLegacyEmptyConnectionListRecoversBackupAndHydratesSecrets() throws {
        let r = record()
        ConnectionSecretStore.setKey(connectionID: r.id, key: "key-in-keychain-only")
        let raw = try JSONEncoder().encode([r])
        defaults.set(Data("[]".utf8), forKey: recordsKey)
        defaults.set(raw, forKey: recordsKey + ".unreadable")
        let store = ConnectionStore(defaults: defaults)
        XCTAssertEqual(store.connections.map(\.id), [r.id])
        guard case .olcrtc(let p) = store.connections.first?.details else {
            return XCTFail("Expected recovered record")
        }
        XCTAssertEqual(p.key, "key-in-keychain-only")
        XCTAssertEqual(defaults.data(forKey: recordsKey), raw)
        XCTAssertEqual(defaults.data(forKey: recordsKey + ".unreadable"), raw)
    }

    func testLegacyEmptyHostListRecoversBackup() throws {
        let host = ServerHost(label: "Recovered", host: "example.invalid")
        let raw = try JSONEncoder().encode([host])
        defaults.set(Data("[]".utf8), forKey: hostsKey)
        defaults.set(raw, forKey: hostsKey + ".unreadable")
        XCTAssertEqual(ServerHostStore(defaults: defaults).hosts.map(\.id), [host.id])
        XCTAssertEqual(defaults.data(forKey: hostsKey), raw)
        XCTAssertEqual(defaults.data(forKey: hostsKey + ".unreadable"), raw)
    }

    func testNewerConnectionAndHostListsAlwaysWinWithoutMerging() throws {
        let old = record(name: "Old")
        var newer = old
        newer.name = "Newer"
        let extra = record(name: "Do not resurrect")
        let live = try JSONEncoder().encode([newer])
        let backup = try JSONEncoder().encode([old, extra])
        defaults.set(live, forKey: recordsKey)
        defaults.set(backup, forKey: recordsKey + ".unreadable")
        let records = ConnectionStore(defaults: defaults).connections
        XCTAssertEqual(records.map(\.name), ["Newer"])
        XCTAssertEqual(defaults.data(forKey: recordsKey), live)
        XCTAssertEqual(defaults.data(forKey: recordsKey + ".unreadable"), backup)

        let host = ServerHost(label: "Old", host: "example.invalid")
        var changedHost = host
        changedHost.label = "Newer"
        let hostLive = try JSONEncoder().encode([changedHost])
        let hostBackup = try JSONEncoder().encode([host])
        defaults.set(hostLive, forKey: hostsKey)
        defaults.set(hostBackup, forKey: hostsKey + ".unreadable")
        XCTAssertEqual(ServerHostStore(defaults: defaults).hosts.map(\.label), ["Newer"])
        XCTAssertEqual(defaults.data(forKey: hostsKey), hostLive)
        XCTAssertEqual(defaults.data(forKey: hostsKey + ".unreadable"), hostBackup)
    }

    func testExplicitEmptySaveDoesNotResurrectBackupInEitherStore() throws {
        let r = record()
        let host = ServerHost(label: "Old", host: "example.invalid")
        defaults.set(try JSONEncoder().encode([r]), forKey: recordsKey + ".unreadable")
        defaults.set(try JSONEncoder().encode([host]), forKey: hostsKey + ".unreadable")
        let connections = ConnectionStore(defaults: defaults)
        connections.connections = []
        let hosts = ServerHostStore(defaults: defaults)
        hosts.hosts = []
        XCTAssertTrue(ConnectionStore(defaults: defaults).connections.isEmpty)
        XCTAssertTrue(ServerHostStore(defaults: defaults).hosts.isEmpty)
        XCTAssertNotNil(defaults.data(forKey: recordsKey + ".unreadable"))
        XCTAssertNotNil(defaults.data(forKey: hostsKey + ".unreadable"))
    }

    func testRepeatedDistinctFailuresKeepFirstAndLaterRawBlobs() throws {
        for key in [recordsKey, hostsKey] {
            let first = Data("old-broken".utf8)
            let second = Data("new-broken".utf8)
            defaults.set(first, forKey: key + ".unreadable")
            defaults.set(second, forKey: key)
            if key == recordsKey {
                let store = ConnectionStore(defaults: defaults)
                store.connections = [record(name: "New work")]
            } else {
                let store = ServerHostStore(defaults: defaults)
                store.hosts = [ServerHost(label: "New work", host: "example.invalid")]
            }
            XCTAssertEqual(defaults.data(forKey: key + ".unreadable"), first)
            XCTAssertEqual(defaults.array(forKey: key + ".unreadable.history") as? [Data], [second])
        }
        XCTAssertEqual(ConnectionStore(defaults: defaults).connections.map(\.name), ["New work"])
        XCTAssertEqual(ServerHostStore(defaults: defaults).hosts.map(\.label), ["New work"])
    }
}
// eoc #482
