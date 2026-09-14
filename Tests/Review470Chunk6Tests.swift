import XCTest
@testable import olcrtc_ios

// #470: regression pins for the chunk-6 findings of the post-#469 review —
// every fix that is a pure function, a persisted contract or a deterministic
// ordering gets the cheapest test that would have caught it. The appex
// changes (a stop that unblocks `waitReady`, the packet pump hopping onto
// workQueue) and the queued-link cancellation are integration-only and
// documented at their sites.
//
// Like ConnectionStoreTests, the store tests run against the real
// UserDefaults + Keychain: every key touched is snapshotted in setUp and
// restored in tearDown, and every record id created has its Keychain entries
// removed.
@MainActor
final class Review470Chunk6Tests: XCTestCase {

    private let recordsKey = "olcrtc_records_v2"
    private let primaryKey = "olcrtc_primary_id"
    private let metaKey    = "olcrtc_sub_meta_v1"

    private var savedRecords: Data?
    private var savedPrimary: String?
    private var savedMeta: Data?
    private var savedLanguage = ""
    private var createdIDs: [UUID] = []

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        savedRecords = d.data(forKey: recordsKey)
        savedPrimary = d.string(forKey: primaryKey)
        savedMeta    = d.data(forKey: metaKey)
        d.removeObject(forKey: recordsKey)
        d.removeObject(forKey: primaryKey)
        d.removeObject(forKey: metaKey)
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        for id in createdIDs { ConnectionSecretStore.remove(connectionID: id) }
        createdIDs.removeAll()
        let d = UserDefaults.standard
        if let v = savedRecords { d.set(v, forKey: recordsKey) } else { d.removeObject(forKey: recordsKey) }
        if let v = savedMeta    { d.set(v, forKey: metaKey) }    else { d.removeObject(forKey: metaKey) }
        if let v = savedPrimary { d.set(v, forKey: primaryKey) } else { d.removeObject(forKey: primaryKey) }
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: Fixtures

    private let key64 = String(repeating: "a", count: 64)

    private func record(socksPass: String, wbToken: String) -> ConnectionRecord {
        var p = OlcrtcConnection(carrier: "wbstream", transport: "datachannel", roomID: "room-1",
                                 key: key64, clientID: "ios-test")
        p.socksPass = socksPass
        p.wbToken   = wbToken
        let r = ConnectionRecord(name: "t", details: .olcrtc(p))
        createdIDs.append(r.id)
        return r
    }

    private let twoNodes = """
    #name: Pool
    olcrtc://wbstream?datachannel@room-a#aa
    ##name: A
    olcrtc://wbstream?datachannel@room-b#bb
    ##name: B
    """

    // MARK: ConnectionStore.update — a cleared secret stays cleared

    func testUpdateBlanksAClearedSocksPassAndWbToken() {
        let store = ConnectionStore()
        var r = record(socksPass: "pw", wbToken: "tok")
        store.add(r)
        XCTAssertEqual(ConnectionSecretStore.wbToken(for: r.id), "tok")
        XCTAssertEqual(ConnectionSecretStore.socksPass(for: r.id), "pw")

        // What reconfigure does when the carrier leaves wbstream (or the token
        // field is cleared): the record says "", the server has dropped
        // auth.token — and the Keychain used to disagree until the next launch.
        guard case .olcrtc(var p) = r.details else { return XCTFail("olcrtc record expected") }
        p.socksPass = ""
        p.wbToken   = ""
        r.details = .olcrtc(p)
        store.update(r)

        XCTAssertEqual(ConnectionSecretStore.wbToken(for: r.id) ?? "", "",
                       "the removed token must not survive in the Keychain")
        XCTAssertEqual(ConnectionSecretStore.socksPass(for: r.id) ?? "", "")
        XCTAssertEqual(ConnectionSecretStore.key(for: r.id), key64, "a blank never touches the key")

        // The relaunch that used to resurrect it.
        let reloaded = ConnectionStore()
        guard case .olcrtc(let q) = reloaded.connections.first(where: { $0.id == r.id })?.details else {
            return XCTFail("the record must survive the reload")
        }
        XCTAssertEqual(q.wbToken, "")
        XCTAssertEqual(q.socksPass, "")
        XCTAssertEqual(q.key, key64)
    }

    func testUpdateNeverCreatesAnEmptySecretEntry() {
        let store = ConnectionStore()
        let r = record(socksPass: "", wbToken: "")
        store.add(r)
        store.update(r)
        XCTAssertNil(ConnectionSecretStore.wbToken(for: r.id))
        XCTAssertNil(ConnectionSecretStore.socksPass(for: r.id))
    }

    func testUpdateKeepsSecretsThatAreStillSet() {
        let store = ConnectionStore()
        var r = record(socksPass: "pw", wbToken: "tok")
        store.add(r)
        r.name = "renamed"
        store.update(r)
        XCTAssertEqual(ConnectionSecretStore.wbToken(for: r.id), "tok")
        XCTAssertEqual(ConnectionSecretStore.socksPass(for: r.id), "pw")
    }

    // MARK: One subscription, one identity (olcrtc-sub:// vs https://)

    func testCanonicalSourceSwapsOnlyTheDeepLinkScheme() {
        XCTAssertEqual(ConnectionStore.canonicalSource("olcrtc-sub://pool.example.org/sub?x=1"),
                       "https://pool.example.org/sub?x=1")
        XCTAssertEqual(ConnectionStore.canonicalSource("https://pool.example.org/sub"),
                       "https://pool.example.org/sub")
        XCTAssertEqual(ConnectionStore.canonicalSource("not a url"), "not a url")
    }

    func testTheHttpsFormOfAnImportedDeepLinkUpdatesInsteadOfDuplicating() {
        let store = ConnectionStore()
        let sub = OlcrtcSubscription.parse(twoNodes)
        store.importSubscription(sub, source: "olcrtc-sub://pool.example.org/sub")
        createdIDs += store.connections.map(\.id)
        XCTAssertEqual(store.connections.count, 2)

        // The provider's https URL pasted later: the same list, not new servers.
        let diff = store.importSubscription(sub, source: "https://pool.example.org/sub")
        createdIDs += store.connections.map(\.id)
        XCTAssertTrue(diff.toAdd.isEmpty, "the same list under its https link is not new servers")
        XCTAssertTrue(diff.toRemove.isEmpty)
        XCTAssertEqual(store.connections.count, 2)
        XCTAssertEqual(store.subscriptionMeta.count, 1, "one list, one meta — not \"2 sources\"")
        XCTAssertNotNil(store.subscriptionMeta["https://pool.example.org/sub"])
        XCTAssertEqual(store.subscriptionInfo(for: store.connections)?.source,
                       "https://pool.example.org/sub")
    }

    // MARK: Subscription meta — one unreadable entry must not drop the rest

    func testSubscriptionMetaKeepsTheEntriesThatStillDecode() {
        let json = #"{"good":{"lastRefresh":700000000,"refreshInterval":3600},"bad":{"lastRefresh":"yesterday"}}"#
        UserDefaults.standard.set(Data(json.utf8), forKey: metaKey)
        let store = ConnectionStore()
        XCTAssertEqual(store.subscriptionMeta.count, 1)
        XCTAssertEqual(store.subscriptionMeta["good"]?.refreshInterval, 3600)
        XCTAssertNil(store.subscriptionMeta["bad"])
    }

    // MARK: Probe-side sentences classify the same in every language

    func testProbeSideSentencesClassifyTheSameInEveryLanguage() {
        for lang in ["en", "ru"] {
            SettingsStore.shared.language = lang
            XCTAssertEqual(HealthCoordinator.probeSideReason(forRaw: L10n.pingNoFreePort.localized()),
                           .unknown, lang)
            XCTAssertEqual(HealthCoordinator.probeSideReason(forRaw: L10n.pingFailed.localized()),
                           .unknown, lang)
            XCTAssertNil(HealthCoordinator.probeSideReason(
                forRaw: "dial tcp 127.0.0.1:8808: bind: address already in use"), lang)
        }
        // "could not run the check" is filed as couldn't-check, never as broken.
        XCTAssertTrue(HealthFailureMapper.isInconclusive(.unknown))
    }

    // MARK: VPN mode — the OS resolver is a separate, tunnel-reachable choice

    func testSystemResolverSwapsOnlyCarrierInternalPresets() {
        for preset in AppConstants.ruCarrierDnsPresets {
            XCTAssertEqual(VPNConfig.systemResolver(for: preset.value),
                           SettingsStore.Defaults.dnsServer, preset.value)
        }
        XCTAssertEqual(VPNConfig.systemResolver(for: "213.87.0.1"),
                       SettingsStore.Defaults.dnsServer, "matched by host, port or not")
        XCTAssertEqual(VPNConfig.systemResolver(for: "1.1.1.1:53"), "1.1.1.1:53")
        XCTAssertEqual(VPNConfig.systemResolver(for: "8.8.8.8:53"), "8.8.8.8:53")
    }

    func testBridgeInitHandsTheOSAPublicResolverForACarrierPreset() {
        let conn = OlcrtcConnection(carrier: "telemost", transport: "datachannel", roomID: "r",
                                    key: key64, clientID: "c")
        let cfg = VPNConfig(from: conn, dns: "213.87.0.1:53", timeoutMs: 1000)
        XCTAssertEqual(cfg.dns, "213.87.0.1:53", "the core's own resolver keeps the carrier DNS")
        XCTAssertEqual(cfg.systemDNS, SettingsStore.Defaults.dnsServer)
        XCTAssertEqual(cfg.dnsHost, "213.87.0.1")
        XCTAssertEqual(cfg.systemDNSHost, VPNConfig.host(of: SettingsStore.Defaults.dnsServer))
        let plain = VPNConfig(from: conn, dns: "1.1.1.1:53", timeoutMs: 1000)
        XCTAssertEqual(plain.systemDNS, "1.1.1.1:53", "a public choice passes through")
    }

    func testSystemDNSRoundTripsThroughTheProviderConfiguration() throws {
        let cfg = VPNConfig(carrier: "telemost", transport: "datachannel", roomID: "r", clientID: "c",
                            keyHex: key64, dns: "213.87.0.1:53", systemDNS: "77.88.8.8:53")
        let back = try XCTUnwrap(VPNConfig(providerConfiguration: cfg.providerConfiguration()))
        XCTAssertEqual(back, cfg)
        XCTAssertEqual(back.systemDNSHost, "77.88.8.8")
        // A profile saved by an older build has no such key: same resolver as `dns`.
        var old = cfg.providerConfiguration()
        old["systemDNS"] = nil
        let legacy = try XCTUnwrap(VPNConfig(providerConfiguration: old))
        XCTAssertEqual(legacy.systemDNS, "213.87.0.1:53")
    }

    // MARK: LogFileWriter — a replaced writer's queued lines survive, in order

    func testReplacingAWriterKeepsEveryQueuedLineInOrder() throws {
        let name = "review470-\(UUID().uuidString)_container.log"
        let first = LogFileWriter(category: .containerLogs, filename: name)
        let url = try XCTUnwrap(first.fileURL)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: "/tmp/olcrtc-ios-logs/\(name)")
        }
        for i in 0..<300 { first.write("A\(i)") }
        // `startSession` does exactly this: a successor while the predecessor's
        // lines are still queued. The successor used to seek to the EOF of
        // THAT moment and overwrite whatever the predecessor wrote after it.
        let second = LogFileWriter(category: .containerLogs, filename: name)
        second.write("B")
        first.flush()
        second.flush()
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 301)
        XCTAssertEqual(lines.first, "A0")
        XCTAssertEqual(lines.dropLast().last, "A299")
        XCTAssertEqual(lines.last, "B")
    }

    // MARK: redactSecrets — quoted JSON keys

    func testRedactsQuotedJSONCredentialKeys() {
        XCTAssertEqual(LogStore.redactSecrets(#"{"platform":"telegram","token":"123456:ABC-DEF"}"#),
                       #"{"platform":"telegram","token":"<redacted>"}"#)
        XCTAssertEqual(LogStore.redactSecrets(#"{"password":"hunter2","port":22}"#),
                       #"{"password":<redacted>,"port":22}"#)
        XCTAssertEqual(LogStore.redactSecrets(#"{"Session_id":"3:1700000000.5.0:abc"}"#),
                       #"{"Session_id":<redacted>}"#)
    }

    func testUnquotedCredentialShapesStillRedactTheSameWay() {
        XCTAssertEqual(LogStore.redactSecrets(#"--password="hunter2""#), #"--password=<redacted>"#)
        XCTAssertEqual(LogStore.redactSecrets("ssh password=hunter2 connecting"),
                       "ssh password=<redacted> connecting")
        XCTAssertEqual(LogStore.redactSecrets("Cookie: Session_id=3:17:abc"),
                       "Cookie: Session_id=<redacted>")
        XCTAssertEqual(LogStore.redactSecrets(#"token: "abc""#), #"token: "<redacted>""#)
        XCTAssertEqual(LogStore.redactSecrets("GET /api?bypass=1 -> 200"), "GET /api?bypass=1 -> 200")
    }

    // MARK: Keyword classifier — the keep-alive's own healthy prefix

    func testKeepAliveSkipNotesAreInfoNotWarn() {
        XCTAssertEqual(LogStore.classify(TunnelManager.keepAliveSkipNote(ageSeconds: -180)), .info)
        XCTAssertEqual(LogStore.classify(TunnelManager.keepAliveSkipNote(ageSeconds: 12)), .info)
        XCTAssertEqual(LogStore.classify("⚠ Keep-alive failed (1/3) — retrying next interval"), .warn)
        XCTAssertEqual(LogStore.classify("device or resource busy"), .warn,
                       "the busy keyword still warns where nothing says otherwise")
    }

    // MARK: Busy pill — steps count like the bar

    func testBusyPillStepsAreOneBasedLikeTheBar() {
        let running = HostDisplay.start(.start, from: .stopped)   // phase 0 of 3
        let first = HostHeadline.reduce(display: running, reachable: true, lastProbeAge: 1, health: .never)
        XCTAssertTrue(first.subtitle.hasSuffix("1/3"), first.subtitle)
        let capped = running.advanced(note: "a").advanced(note: "b").advanced(note: "c")   // phase capped at 2
        let last = HostHeadline.reduce(display: capped, reachable: true, lastProbeAge: 1, health: .never)
        XCTAssertTrue(last.subtitle.hasSuffix("3/3"), last.subtitle)
        // The payload is still the 0-based phase (HostDisplayTests pins it).
        guard case .busy(_, _, let step, let total) = last else { return XCTFail("busy expected, got \(last)") }
        XCTAssertEqual(step, 2)
        XCTAssertEqual(total, 3)
    }

    // MARK: Quick-action identity is the verb, not a fresh UUID

    func testQuickActionIdentityIsStableAcrossRebuilds() {
        let a = ServerQuickAction(title: "Container logs", systemImage: "arrow.down.doc") {}
        let b = ServerQuickAction(title: "Container logs", systemImage: "arrow.down.doc") {}
        XCTAssertEqual(a.id, b.id, "a rebuilt array must not read as a new button")
        XCTAssertNotEqual(a.id, ServerQuickAction(title: "Other", systemImage: "arrow.down.doc") {}.id)
    }
}
