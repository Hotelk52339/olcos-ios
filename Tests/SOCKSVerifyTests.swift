import XCTest
import Network
@testable import olcrtc_ios

// #445 (audit fixes 1 + 2): SOCKS credential plumbing and the fail-closed
// listener probe.
//
//   Fix 1 — enabling local SOCKS auth used to brick every connect: master's
//   listener (internal/client/socks.go) REQUIRES RFC1929 user/pass on every
//   SOCKS connection once a username is set, but the app's own URLSessions
//   never presented credentials, so verifyTunnel always failed. The proxy
//   dictionary is now built by a pure function that carries the live session's
//   credentials, themselves derived by the pure `effectiveSocksCredentials`
//   (the same expression `OlcrtcEngine.start` feeds the Go listener).
//
//   Fix 2 — URLSession silently BYPASSES a SOCKS proxy that refuses the
//   connection and completes requests DIRECT (Apple-confirmed design), so a
//   dead loopback listener yielded a false "tunnel OK". Verification now gates
//   on a raw SOCKS5 greeting (`socksListenerAnswers`) that cannot be bypassed.

final class SOCKSVerifyTests: XCTestCase {

    // MARK: fix 1 — proxy dictionary builder

    func testProxyDictionaryWithoutCredentials() {
        let dict = SOCKSSession.proxyDictionary(port: 8808, credentials: nil)
        XCTAssertEqual(dict["SOCKSEnable"] as? Int, 1)
        XCTAssertEqual(dict["SOCKSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dict["SOCKSPort"] as? Int, 8808)
        XCTAssertNil(dict["SOCKSUser"], "no credentials → no auth keys")
        XCTAssertNil(dict["SOCKSPassword"])
    }

    func testProxyDictionaryWithCredentials() {
        let dict = SOCKSSession.proxyDictionary(port: 1080, credentials: (user: "u", pass: "p"))
        XCTAssertEqual(dict["SOCKSEnable"] as? Int, 1)
        XCTAssertEqual(dict["SOCKSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dict["SOCKSPort"] as? Int, 1080)
        XCTAssertEqual(dict["SOCKSUser"] as? String, "u")
        XCTAssertEqual(dict["SOCKSPassword"] as? String, "p")
    }

    // MARK: fix 1 — effective credentials

    func testEffectiveCredentialsPreferSettingsWhenLocalAuthOn() {
        let c = TunnelManager.effectiveSocksCredentials(
            localAuthEnabled: true, settingsUser: "su", settingsPass: "sp",
            recordUser: "ru", recordPass: "rp")
        XCTAssertEqual(c?.user, "su")
        XCTAssertEqual(c?.pass, "sp")
    }

    func testEffectiveCredentialsFallBackToRecordWhenLocalAuthOff() {
        let c = TunnelManager.effectiveSocksCredentials(
            localAuthEnabled: false, settingsUser: "su", settingsPass: "sp",
            recordUser: "ru", recordPass: "rp")
        XCTAssertEqual(c?.user, "ru")
        XCTAssertEqual(c?.pass, "rp")
    }

    func testEffectiveCredentialsNilWhenBothHalvesEmpty() {
        XCTAssertNil(TunnelManager.effectiveSocksCredentials(
            localAuthEnabled: true, settingsUser: "", settingsPass: "",
            recordUser: "ru", recordPass: "rp"),
            "local auth ON with empty Settings creds must NOT fall back to the record — "
            + "it mirrors exactly what the engine feeds the listener")
        XCTAssertNil(TunnelManager.effectiveSocksCredentials(
            localAuthEnabled: false, settingsUser: "su", settingsPass: "sp",
            recordUser: "", recordPass: ""))
    }

    // Master gates auth on the username alone, but a half-set pair is still
    // mirrored as-is (the engine sends it verbatim too) — only the both-empty
    // pair means "no auth".
    func testEffectiveCredentialsKeepHalfSetPairs() {
        let c = TunnelManager.effectiveSocksCredentials(
            localAuthEnabled: false, settingsUser: "", settingsPass: "",
            recordUser: "ru", recordPass: "")
        XCTAssertEqual(c?.user, "ru")
        XCTAssertEqual(c?.pass, "")
    }

    // MARK: fix 2 — greeting-reply classification (pure)

    func testGreetingReplyAcceptsNoAuthAndUserPassMethods() {
        XCTAssertTrue(TunnelManager.isSocksGreetingReply(Data([0x05, 0x00])),
                      "method 0x00 (no auth) is a live listener")
        XCTAssertTrue(TunnelManager.isSocksGreetingReply(Data([0x05, 0x02])),
                      "method 0x02 (user/pass) is a live listener — auth mode must not fail the probe")
    }

    func testGreetingReplyRejectsShortOrForeignReplies() {
        XCTAssertFalse(TunnelManager.isSocksGreetingReply(Data()))
        XCTAssertFalse(TunnelManager.isSocksGreetingReply(Data([0x05])))
        XCTAssertFalse(TunnelManager.isSocksGreetingReply(Data([0x04, 0x00])),
                       "a SOCKS4 / non-SOCKS reply must not count as alive")
    }

    // MARK: fix 2 — live probe behaviour

    // A port nobody listens on: the loopback connect is refused instantly, which
    // is exactly the case URLSession's proxy bypass used to mask as "tunnel OK".
    func testListenerAnswersFalseOnRefusedPort() async throws {
        let port = try XCTUnwrap(PortAvailability.freeEphemeralPort().map(Int.init),
                                 "no free ephemeral port to test on")
        let answers = await TunnelManager.socksListenerAnswers(port: port, timeout: 3)
        XCTAssertFalse(answers, "a dead/refusing listener must fail the probe (fail-closed)")
    }

    // Minimal SOCKS5-greeting responder: accept, read the greeting, answer
    // [0x05, 0x00] — the probe must report the listener alive.
    func testListenerAnswersTrueAgainstAGreetingListener() async throws {
        let listenerQueue = DispatchQueue(label: "socks-test-listener")
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { conn in
            conn.start(queue: listenerQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16) { _, _, _, _ in
                conn.send(content: Data([0x05, 0x00]), completion: .contentProcessed { _ in })
            }
        }
        let ready = expectation(description: "listener ready")
        ready.assertForOverFulfill = false
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: listenerQueue)
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }

        let port = try XCTUnwrap(listener.port.map { Int($0.rawValue) },
                                 "listener bound no port")
        let answers = await TunnelManager.socksListenerAnswers(port: port, timeout: 5)
        XCTAssertTrue(answers, "a live greeting-answering listener must pass the probe")
    }
}
