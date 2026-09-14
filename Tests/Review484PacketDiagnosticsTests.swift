import XCTest
@testable import olcrtc_ios

// boc #484: D2-D21/D22/D23 — deterministic policy and suspended-completion
// regressions. No URLSession request, listener, real carrier or live server.
final class Review484PacketDiagnosticsTests: XCTestCase {
    func testThreeConsecutiveDataPathFailuresAreFatal() {
        var health = VPNDataPathHealth()
        XCTAssertFalse(health.record(success: false))
        XCTAssertFalse(health.record(success: false))
        XCTAssertTrue(health.record(success: false))
        XCTAssertEqual(health.failures, 3)
        XCTAssertTrue(health.record(success: false))
        XCTAssertEqual(health.failures, 3, "failure count saturates")
    }

    func testOnlyADataPathSuccessResetsTheFailureStreak() {
        var health = VPNDataPathHealth()
        XCTAssertFalse(health.record(success: false))
        XCTAssertFalse(health.record(success: false))
        XCTAssertFalse(health.record(success: true))
        XCTAssertEqual(health.failures, 0)
        XCTAssertFalse(health.record(success: false))
        XCTAssertFalse(health.record(success: false))
        XCTAssertTrue(health.record(success: false))
        XCTAssertGreaterThan(VPNDataPathHealth.timeout, 0)
        XCTAssertLessThan(VPNDataPathHealth.timeout, VPNDataPathHealth.interval,
                          "one absolute deadline expires before the next scheduled probe")
        let initialBound = VPNDataPathHealth.startupGrace
            + Double(VPNDataPathHealth.failureLimit - 1) * VPNDataPathHealth.interval
            + VPNDataPathHealth.timeout
        XCTAssertLessThanOrEqual(initialBound, 100)
    }

    func testDNSHealthRequiresMatchingResponseNotJustBytesOrAGreeting() {
        let id: UInt16 = 0x1234
        let query = VPNDataPathHealth.dnsQuery(id: id)
        XCTAssertEqual(Array(query), [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1])
        XCTAssertFalse(VPNDataPathHealth.validDNSResponse(query, id: id), "an echoed request is not a response")
        XCTAssertFalse(VPNDataPathHealth.validDNSResponse(Data([5, 0]), id: id), "SOCKS greeting is not data health")
        var reply = query
        reply[2] = 0x81
        XCTAssertTrue(VPNDataPathHealth.validDNSResponse(reply, id: id))
        XCTAssertFalse(VPNDataPathHealth.validDNSResponse(reply, id: id + 1))
        for count in 0..<reply.count {
            XCTAssertFalse(VPNDataPathHealth.validDNSResponse(reply.prefix(count), id: id))
        }
        var wrongQuestion = reply
        wrongQuestion[14] = 1 // A instead of the root NS question.
        XCTAssertFalse(VPNDataPathHealth.validDNSResponse(wrongQuestion, id: id))
        var wrongOpcode = reply
        wrongOpcode[2] = 0x89
        XCTAssertFalse(VPNDataPathHealth.validDNSResponse(wrongOpcode, id: id))
        var noQuestion = reply
        noQuestion[5] = 0
        XCTAssertFalse(VPNDataPathHealth.validDNSResponse(noQuestion, id: id))
        XCTAssertFalse(VPNDataPathHealth.validDNSResponse(reply + Data(count: 4096), id: id))
        reply[3] = 5 // REFUSED is evidence of a remote answer, not DNS usefulness.
        XCTAssertTrue(VPNDataPathHealth.validDNSResponse(reply, id: id))
    }

    func testPacketDNSRejectsUnsupportedPathsWithoutChangingCoreResolver() throws {
        for resolver in ["[2001:db8::1]:53", "[::1]:5353", "::1", "dns.example.net:53",
                         "1.1.1.1:5353", "", "1.2.3", "256.2.3.4:53", "1.1.1.1:"] {
            XCTAssertFalse(VPNConfig.supportsPacketDNS(resolver), resolver)
        }
        for resolver in ["1.1.1.1:53", "8.8.8.8", " 9.9.9.9:53 "] {
            XCTAssertTrue(VPNConfig.supportsPacketDNS(resolver), resolver)
        }
        let v6 = "[2001:db8::1]:53"
        let config = VPNConfig(carrier: "telemost", transport: "datachannel", roomID: "r",
                               clientID: "c", keyHex: String(repeating: "a", count: 64),
                               dns: v6)
        XCTAssertFalse(config.supportsPacketDNS)
        var legacy = config.providerConfiguration()
        legacy.removeValue(forKey: "systemDNS")
        let restored = try XCTUnwrap(VPNConfig(providerConfiguration: legacy))
        XCTAssertFalse(restored.supportsPacketDNS, "old persisted profiles cannot bypass the extension guard")
        XCTAssertEqual(restored.dns, v6, "provider/core resolver is not rewritten")
        var split = config
        split.systemDNS = "1.1.1.1:53"
        XCTAssertTrue(split.supportsPacketDNS, "IPv6 core DNS works with an explicit IPv4 packet DNS")
        XCTAssertEqual(split.dns, v6)
    }

    func testRouteProvenanceAndSocketRoutingAreIndependent() {
        XCTAssertEqual(RouteMode.current(isConnected: false, activeMode: .vpn), .direct)
        XCTAssertEqual(RouteMode.current(isConnected: true, activeMode: .vpn), .systemVPN)
        XCTAssertEqual(RouteMode.current(isConnected: true, activeMode: .proxy), .tunnel)
        XCTAssertFalse(RouteMode.systemVPN.usesSOCKS)
        XCTAssertTrue(RouteMode.systemVPN.isTunnelled)
        XCTAssertTrue(RouteMode.tunnel.usesSOCKS)
        XCTAssertFalse(RouteMode.direct.isTunnelled)
        for mode in [RouteMode.direct, .systemVPN] {
            let session = SOCKSSession.make(mode: mode)
            defer { session.invalidateAndCancel() }
            XCTAssertNil(session.configuration.connectionProxyDictionary,
                         "\(mode) must never point at the app's SOCKS listener")
        }
        let proxy = SOCKSSession.make(mode: .tunnel)
        defer { proxy.invalidateAndCancel() }
        XCTAssertEqual(proxy.configuration.connectionProxyDictionary?["SOCKSProxy"] as? String, "127.0.0.1")
    }

    func testSystemVPNUsesTunnelSpeedPayloadsButNotSOCKS() {
        for provider in AppConstants.SpeedTest.providers {
            XCTAssertEqual(provider.downloadURL(mode: .systemVPN), provider.downloadURL(mode: .tunnel))
        }
    }

    @MainActor
    func testAnOldIPCompletionCannotRepopulateOrEndANewChecksSpinner() async throws {
        let saved = SettingsStore.shared.enabledIPSources
        defer { SettingsStore.shared.enabledIPSources = saved }
        let source = try XCTUnwrap(AppConstants.ipCheckServices.first)
        SettingsStore.shared.enabledIPSources = [source.label]
        let oldStarted = expectation(description: "old IP suspended")
        let newStarted = expectation(description: "new IP suspended")
        var old: CheckedContinuation<IPResult, Never>?
        var new: CheckedContinuation<IPResult, Never>?
        var calls = 0
        let checker = IPChecker(fetchIP: { _, _, _, _ in
            calls += 1
            return await withCheckedContinuation { continuation in
                if calls == 1 { old = continuation; oldStarted.fulfill() }
                else { new = continuation; newStarted.fulfill() }
            }
        })
        let first = Task { await checker.checkAll(via: .direct) }
        await fulfillment(of: [oldStarted], timeout: 1)
        checker.invalidateRoute() // connecting, even before VPN mode changes.
        let second = Task { await checker.checkAll(via: .systemVPN) }
        await fulfillment(of: [newStarted], timeout: 1)
        old?.resume(returning: IPResult(label: source.label, ip: "192.0.2.1", error: nil, mode: .direct))
        await first.value
        XCTAssertTrue(checker.isChecking, "the old defer cannot stop the new spinner")
        XCTAssertTrue(checker.results.isEmpty)
        new?.resume(returning: IPResult(label: source.label, ip: "198.51.100.1", error: nil, mode: .systemVPN))
        await second.value
        XCTAssertFalse(checker.isChecking)
        XCTAssertEqual(checker.results.map(\.ip), ["198.51.100.1"])
        XCTAssertEqual(checker.results.first?.mode, .systemVPN)
        XCTAssertNotNil(checker.resultsAt)
        checker.invalidateRoute() // same-mode reconnect must invalidate too.
        XCTAssertTrue(checker.results.isEmpty)
        XCTAssertNil(checker.resultsAt)
    }

    @MainActor
    func testGeoCompletionAfterDisconnectCannotResurrectOldExit() async {
        let began = expectation(description: "geo suspended")
        var pending: CheckedContinuation<IPChecker.ExitGeo?, Never>?
        let checker = IPChecker(fetchGeo: { _ in
            await withCheckedContinuation { pending = $0; began.fulfill() }
        })
        let task = Task { await checker.refreshExitGeo(via: .systemVPN) }
        await fulfillment(of: [began], timeout: 1)
        checker.invalidateRoute()
        pending?.resume(returning: IPChecker.ExitGeo(ip: "198.51.100.1", country: "DE"))
        await task.value
        XCTAssertNil(checker.exitGeo)
        XCTAssertNil(checker.exitGeoAt)
    }

    @MainActor
    func testSpeedRunCrossingAVPNReconnectIsDiscardedAndSkipsRemainingTransfers() async {
        let began = expectation(description: "ping suspended")
        var pending: CheckedContinuation<Double?, Never>?
        var downloads = 0
        var uploads = 0
        let speed = SpeedTest(ping: { _ in
            await withCheckedContinuation { pending = $0; began.fulfill() }
        }, download: { _ in downloads += 1; return 42 },
           upload: { _ in uploads += 1; return 12 })
        let task = Task { await speed.run(via: .systemVPN) }
        await fulfillment(of: [began], timeout: 1)
        speed.invalidateRoute()
        pending?.resume(returning: 100)
        await task.value
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(uploads, 0)
        XCTAssertNil(speed.lastResult)
        XCTAssertNil(speed.resultAt)
        XCTAssertFalse(speed.isTesting)
    }

    @MainActor
    func testSystemVPNSpeedRunDoesNotRequireInAppListener() async {
        let speed = SpeedTest(ping: { _ in 100 }, download: { _ in 2 }, upload: { _ in 1 })
        await speed.run(via: .systemVPN)
        XCTAssertEqual(speed.lastResult?.mode, .systemVPN)
        XCTAssertEqual(speed.lastResult?.downloadMbps, 2)
        XCTAssertNil(speed.lastResult?.error)
        XCTAssertNotNil(speed.resultAt)
    }
}
// eoc #484
