import XCTest
@testable import olcrtc_ios

// #415: coverage for the subscription-refresh helpers (#362 + #411) — the
// `fetchURL(for:)` scheme mapping and the refresh loop's skip-on-failure /
// due-vs-force behaviour. The fetch is injected, so no network is touched.
// Per-source assertions keep the tests robust to any subscription meta left in
// the shared UserDefaults by other tests.

// `@MainActor`: ConnectionStore (and its static `fetchURL`) is MainActor-isolated.
@MainActor
final class SubscriptionRefreshTests: XCTestCase {

    // boc #469: the refresh path now refuses a body with no server lines (a
    // captive portal's HTML used to wipe the source's records), so a fetch mock
    // has to answer with a real list. That list becomes a real record in the
    // app-process store, so every key it touches is snapshotted and put back.
    private static let key = String(repeating: "a", count: 64)
    static let oneServer = "olcrtc://telemost?datachannel@room-1#" + key

    private var savedRecords: Data?
    private var savedMeta: Data?
    private var savedPrimary: String?

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        savedRecords = d.data(forKey: "olcrtc_records_v2")
        savedMeta    = d.data(forKey: "olcrtc_sub_meta_v1")
        savedPrimary = d.string(forKey: "olcrtc_primary_id")
    }

    override func tearDown() {
        let d = UserDefaults.standard
        // Drop the Keychain keys of whatever the test imported before restoring.
        if let data = d.data(forKey: "olcrtc_records_v2"),
           let now = try? JSONDecoder().decode([ConnectionRecord].self, from: data) {
            let before = savedRecords.flatMap { try? JSONDecoder().decode([ConnectionRecord].self, from: $0) } ?? []
            let keep = Set(before.map(\.id))
            for r in now where !keep.contains(r.id) { ConnectionSecretStore.remove(connectionID: r.id) }
        }
        for (key, value) in [("olcrtc_records_v2", savedRecords), ("olcrtc_sub_meta_v1", savedMeta)] {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
        if let savedPrimary { d.set(savedPrimary, forKey: "olcrtc_primary_id") } else { d.removeObject(forKey: "olcrtc_primary_id") }
        super.tearDown()
    }
    // eoc #469

    // MARK: fetchURL(for:) — static, pure

    func testFetchURLMapsOlcrtcSubToHTTPS() {
        XCTAssertEqual(
            ConnectionStore.fetchURL(for: "olcrtc-sub://host.example/list")?.absoluteString,
            "https://host.example/list")
    }

    func testFetchURLPassesHTTPSThrough() {
        XCTAssertEqual(
            ConnectionStore.fetchURL(for: "https://host.example/list")?.absoluteString,
            "https://host.example/list")
    }

    func testFetchURLRejectsOtherSchemes() {
        XCTAssertNil(ConnectionStore.fetchURL(for: "olcrtc://wbstream?datachannel@room#key"))
        XCTAssertNil(ConnectionStore.fetchURL(for: "ftp://host.example/list"))
        XCTAssertNil(ConnectionStore.fetchURL(for: "mailto:x@example.com"))
    }

    // MARK: refresh loop

    /// A fetch failure for one source is skipped; the others still refresh.
    @MainActor
    func testRefreshSkipsFailedSourceAndContinues() async {
        let store = ConnectionStore()
        var sub = OlcrtcSubscription()
        sub.refresh = "60s"   // #refresh → 60 s interval; due in the future
        store.importSubscription(sub, source: "https://skip-a.example/sub")
        store.importSubscription(sub, source: "https://ok-b.example/sub")

        let future = Date().addingTimeInterval(3600)   // both sources are now due
        let refreshed = await store.refreshDueSources(now: future) { url in
            if url.host == "skip-a.example" { throw URLError(.timedOut) }
            return Self.oneServer   // #469: a body with no servers is a failed fetch now
        }

        XCTAssertTrue(refreshed.contains("https://ok-b.example/sub"))   // succeeded
        XCTAssertFalse(refreshed.contains("https://skip-a.example/sub")) // fetch threw → skipped
    }

    /// #411: refreshAllSources re-fetches a source even when its `#refresh`
    /// interval hasn't elapsed; refreshDueSources leaves it alone until then.
    @MainActor
    func testRefreshAllForcesEvenWhenNotDue() async {
        let store = ConnectionStore()
        var sub = OlcrtcSubscription()
        sub.refresh = "1d"   // #refresh → a day; not due right after import
        store.importSubscription(sub, source: "https://force-c.example/sub")

        let fetch: (URL) async throws -> String = { _ in Self.oneServer }   // #469
        let due = await store.refreshDueSources(fetch: fetch)
        XCTAssertFalse(due.contains("https://force-c.example/sub"))   // not due yet
        let all = await store.refreshAllSources(fetch: fetch)
        XCTAssertTrue(all.contains("https://force-c.example/sub"))    // force-refreshed
    }
}
