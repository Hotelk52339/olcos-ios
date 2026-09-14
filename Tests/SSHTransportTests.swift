import XCTest
@testable import olcrtc_ios

// #462 — SSH over the app's own tunnel.
//
// Everything covered here is PURE: the RFC1928/RFC1929 wire codec
// (`SSHSocks5`) and the two route decisions (`SSHTransport.route`,
// `SSHTransport.nextRoute`). No sockets, no simulator networking, no MainActor.
//
// INTEGRATION-ONLY (not covered here, by design — the repo's convention for
// async/native paths):
//   * `SSHTunnelRelay.open` — needs a live local SOCKS5 listener and a real VPS.
//   * `SSHTransport.currentRoute()` — reads the live `TunnelManager.shared`,
//     which is a weak last-init-wins static every `TunnelManager()` in the test
//     bundle overwrites; the decision it delegates to (`route(state:mode:
//     boundPort:)`) is what is pinned below.
//   * `SSHRunner.connect`'s Citadel dial and its two-way fallback in situ.
//   * `SSHTransport.probeReachable` — the tunnel branch opens a real relay, and
//     its #462-audit direct fallback needs a live listener to exercise.
//   * `SSHTunnelRelay.isTransportDown` (#462 audit) — needs a live channel.
//
// The byte fixtures are taken from the SERVER we actually talk to
// (olcrtc-upstream `internal/client/socks.go` + `client_test.go`), not from the
// RFC in the abstract — that is what makes them worth asserting.

final class SSHTransportTests: XCTestCase {

    // MARK: - greeting

    func testGreetingWithoutCredentialsOffersOnlyNoAuth() {
        XCTAssertEqual(SSHSocks5.greeting(offerUserPass: false), [0x05, 0x01, 0x00])
    }

    func testGreetingWithCredentialsOffersBothMethods() {
        // Our Go listener DISCARDS the offered list and answers `05 02` whenever a
        // username is configured, so no-auth must never be the only offer.
        XCTAssertEqual(SSHSocks5.greeting(offerUserPass: true), [0x05, 0x02, 0x00, 0x02])
    }

    // MARK: - userPassRequest (RFC1929)

    func testUserPassRequestIsLengthPrefixed() throws {
        let bytes = try SSHSocks5.userPassRequest(user: "ab", pass: "xyz")
        XCTAssertEqual(bytes, [0x01, 0x02, 0x61, 0x62, 0x03, 0x78, 0x79, 0x7A])
    }

    func testUserPassRequestAllowsEmptyHalves() throws {
        let bytes = try SSHSocks5.userPassRequest(user: "", pass: "")
        XCTAssertEqual(bytes, [0x01, 0x00, 0x00])
    }

    func testUserPassRequestCountsUTF8BytesNotCharacters() throws {
        // "é" is 2 UTF-8 bytes — the length prefix must be the byte count.
        let bytes = try SSHSocks5.userPassRequest(user: "é", pass: "")
        XCTAssertEqual(bytes, [0x01, 0x02, 0xC3, 0xA9, 0x00])
    }

    func testUserPassRequestRejectsOversizedUsername() {
        let long = String(repeating: "u", count: 256)
        XCTAssertThrowsError(try SSHSocks5.userPassRequest(user: long, pass: "p")) { error in
            XCTAssertEqual(error as? SSHTransportError, .fieldTooLong("SOCKS username"))
        }
    }

    func testUserPassRequestRejectsOversizedPassword() {
        let long = String(repeating: "p", count: 256)
        XCTAssertThrowsError(try SSHSocks5.userPassRequest(user: "u", pass: long)) { error in
            XCTAssertEqual(error as? SSHTransportError, .fieldTooLong("SOCKS password"))
        }
    }

    // MARK: - connectRequest

    func testConnectRequestUsesATYP1ForIPv4Literal() throws {
        // #469 was: the owner's REAL VPS address as the fixture — an
        // infrastructure identifier committed to a public repo (and since
        // forked). Fixtures use RFC 5737 documentation space, which is
        // reserved and routes nowhere.
        let bytes = try SSHSocks5.connectRequest(host: "203.0.113.5", port: 22)
        XCTAssertEqual(bytes, [0x05, 0x01, 0x00, 0x01, 203, 0, 113, 5, 0x00, 0x16])
    }

    func testConnectRequestUsesATYP3ForHostname() throws {
        let bytes = try SSHSocks5.connectRequest(host: "vps.example", port: 2222)
        var expected: [UInt8] = [0x05, 0x01, 0x00, 0x03, 11]
        expected.append(contentsOf: Array("vps.example".utf8))
        expected.append(contentsOf: [0x08, 0xAE])   // 2222 big-endian
        XCTAssertEqual(bytes, expected)
    }

    func testConnectRequestUsesATYP4ForIPv6Literal() throws {
        let bytes = try SSHSocks5.connectRequest(host: "2001:db8::1", port: 22)
        var expected: [UInt8] = [0x05, 0x01, 0x00, 0x04]
        expected.append(contentsOf: [0x20, 0x01, 0x0D, 0xB8])
        expected.append(contentsOf: [UInt8](repeating: 0, count: 11))
        expected.append(0x01)
        expected.append(contentsOf: [0x00, 0x16])
        XCTAssertEqual(bytes, expected)
    }

    func testConnectRequestPortIsBigEndian() throws {
        let bytes = try SSHSocks5.connectRequest(host: "127.0.0.1", port: 65_535)
        XCTAssertEqual(Array(bytes.suffix(2)), [0xFF, 0xFF])
        let low = try SSHSocks5.connectRequest(host: "127.0.0.1", port: 1)
        XCTAssertEqual(Array(low.suffix(2)), [0x00, 0x01])
    }

    func testConnectRequestRejectsOversizedHostname() {
        let long = String(repeating: "h", count: 256)
        XCTAssertThrowsError(try SSHSocks5.connectRequest(host: long, port: 22)) { error in
            XCTAssertEqual(error as? SSHTransportError, .fieldTooLong("SOCKS host name"))
        }
    }

    func testConnectRequestAcceptsExactly255ByteHostname() throws {
        let host = String(repeating: "h", count: 255)
        let bytes = try SSHSocks5.connectRequest(host: host, port: 22)
        XCTAssertEqual(bytes[3], 0x03)
        XCTAssertEqual(bytes[4], 255)
        XCTAssertEqual(bytes.count, 4 + 1 + 255 + 2)
    }

    func testConnectRequestRejectsEmptyHost() {
        // The Go exit rejects an empty host too (ErrEmptySOCKSDomain) — fail before
        // burning a tunnel stream on it.
        XCTAssertThrowsError(try SSHSocks5.connectRequest(host: "", port: 22))
    }

    func testConnectRequestRejectsOutOfRangePort() {
        XCTAssertThrowsError(try SSHSocks5.connectRequest(host: "127.0.0.1", port: 65_536))
        XCTAssertThrowsError(try SSHSocks5.connectRequest(host: "127.0.0.1", port: -1))
    }

    // MARK: - address literal detection

    func testIPv4DetectionRejectsHostnamesAndMalformedLiterals() {
        XCTAssertNotNil(SSHSocks5.ipv4Bytes("10.0.0.1"))
        XCTAssertNil(SSHSocks5.ipv4Bytes("vps.example"))
        XCTAssertNil(SSHSocks5.ipv4Bytes("999.1.1.1"))
        XCTAssertNil(SSHSocks5.ipv4Bytes("1.2.3.4.5"))
        XCTAssertNil(SSHSocks5.ipv4Bytes("2001:db8::1"))
    }

    func testIPv4DetectionRequiresTheDottedQuad() {
        // Apple's IPv4Address follows inet_aton, so "1.2.3" would otherwise parse
        // as 1.2.0.3 and a short hostname would be encoded as an address literal.
        XCTAssertNil(SSHSocks5.ipv4Bytes("1.2.3"))
        XCTAssertNil(SSHSocks5.ipv4Bytes("10.1"))
    }

    func testHostnameThatLooksLikeAQuadIsStillATYP3() throws {
        // Four dot-separated labels, but not an address — must go out as a domain.
        let bytes = try SSHSocks5.connectRequest(host: "a.b.c.example", port: 22)
        XCTAssertEqual(bytes[3], 0x03)
    }

    func testIPv4BytesAreInNetworkOrder() {
        XCTAssertEqual(SSHSocks5.ipv4Bytes("1.2.3.4"), [1, 2, 3, 4])
    }

    func testIPv6DetectionRejectsIPv4AndHostnames() {
        XCTAssertEqual(SSHSocks5.ipv6Bytes("::1")?.count, 16)
        XCTAssertNil(SSHSocks5.ipv6Bytes("10.0.0.1"))
        XCTAssertNil(SSHSocks5.ipv6Bytes("vps.example"))
    }

    // MARK: - parseMethodSelection

    func testParseMethodSelectionNoAuth() throws {
        XCTAssertEqual(try SSHSocks5.parseMethodSelection([0x05, 0x00]), .noAuth)
    }

    func testParseMethodSelectionUserPass() throws {
        // What our listener always answers once a SOCKS username is configured.
        XCTAssertEqual(try SSHSocks5.parseMethodSelection([0x05, 0x02]), .userPass)
    }

    func testParseMethodSelectionUnacceptable() throws {
        XCTAssertEqual(try SSHSocks5.parseMethodSelection([0x05, 0xFF]), .unacceptable)
    }

    func testParseMethodSelectionNeedsTwoBytes() throws {
        XCTAssertNil(try SSHSocks5.parseMethodSelection([]))
        XCTAssertNil(try SSHSocks5.parseMethodSelection([0x05]))
    }

    func testParseMethodSelectionIgnoresTrailingBytes() throws {
        XCTAssertEqual(try SSHSocks5.parseMethodSelection([0x05, 0x00, 0x99, 0x99]), .noAuth)
    }

    func testParseMethodSelectionRejectsWrongVersion() {
        XCTAssertThrowsError(try SSHSocks5.parseMethodSelection([0x04, 0x00]))
    }

    func testParseMethodSelectionRejectsUnknownMethod() {
        XCTAssertThrowsError(try SSHSocks5.parseMethodSelection([0x05, 0x01]))  // GSSAPI
    }

    // MARK: - parseAuthReply

    func testParseAuthReplySuccessAndFailure() throws {
        XCTAssertEqual(try SSHSocks5.parseAuthReply([0x01, 0x00]), true)
        XCTAssertEqual(try SSHSocks5.parseAuthReply([0x01, 0x01]), false)
    }

    func testParseAuthReplyNeedsTwoBytes() throws {
        XCTAssertNil(try SSHSocks5.parseAuthReply([0x01]))
    }

    func testParseAuthReplyRejectsWrongVersion() {
        XCTAssertThrowsError(try SSHSocks5.parseAuthReply([0x05, 0x00]))
    }

    // MARK: - parseConnectReply

    func testParseConnectReplyMatchesTheGoServerSuccessFrame() throws {
        // olcrtc-upstream client_test.go pins this exact frame for an IPv4 or
        // hostname target: replySuccess() == [5 0 0 1 0 0 0 0 0 0].
        let frame: [UInt8] = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        let parsed = try XCTUnwrap(try SSHSocks5.parseConnectReply(frame))
        XCTAssertEqual(parsed.consumed, 10)
        XCTAssertEqual(parsed.reply, 0x00)
    }

    func testParseConnectReplyHostUnreachable() throws {
        // What the listener writes when the 60 s sessionReadyTimeout expires.
        let frame: [UInt8] = [0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        let parsed = try XCTUnwrap(try SSHSocks5.parseConnectReply(frame))
        XCTAssertEqual(parsed.reply, 0x04)
        XCTAssertEqual(SSHSocks5.replyText(parsed.reply), "host unreachable")
    }

    func testParseConnectReplyIPv6Frame() throws {
        var frame: [UInt8] = [0x05, 0x00, 0x00, 0x04]
        frame.append(contentsOf: [UInt8](repeating: 0, count: 16))
        frame.append(contentsOf: [0x00, 0x00])
        let parsed = try XCTUnwrap(try SSHSocks5.parseConnectReply(frame))
        XCTAssertEqual(parsed.consumed, 22)
    }

    func testParseConnectReplyDomainFrame() throws {
        let frame: [UInt8] = [0x05, 0x00, 0x00, 0x03, 0x03, 0x61, 0x62, 0x63, 0x00, 0x50]
        let parsed = try XCTUnwrap(try SSHSocks5.parseConnectReply(frame))
        XCTAssertEqual(parsed.consumed, 10)
        XCTAssertEqual(parsed.reply, 0x00)
    }

    func testParseConnectReplyReportsConsumedSoTrailingBytesSurvive() throws {
        // The sshd banner can follow the reply in the same read. `consumed` is how
        // the handler knows where the relayed stream starts — losing those bytes
        // would corrupt the SSH version exchange.
        var frame: [UInt8] = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        frame.append(contentsOf: Array("SSH-2.0-OpenSSH_9.6".utf8))
        let parsed = try XCTUnwrap(try SSHSocks5.parseConnectReply(frame))
        XCTAssertEqual(parsed.consumed, 10)
        XCTAssertEqual(frame.count - parsed.consumed, 19)
    }

    func testParseConnectReplyNeedsMoreBytes() throws {
        let full: [UInt8] = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for prefixLength in 0..<full.count {
            XCTAssertNil(try SSHSocks5.parseConnectReply(Array(full.prefix(prefixLength))),
                         "a \(prefixLength)-byte prefix must read as 'need more'")
        }
    }

    func testParseConnectReplyDomainNeedsTheLengthByteBeforeSizing() throws {
        XCTAssertNil(try SSHSocks5.parseConnectReply([0x05, 0x00, 0x00, 0x03]))
    }

    func testParseConnectReplyRejectsBadVersionAndAddressType() {
        XCTAssertThrowsError(try SSHSocks5.parseConnectReply([0x04, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
        XCTAssertThrowsError(try SSHSocks5.parseConnectReply([0x05, 0x00, 0x00, 0x09, 0, 0, 0, 0, 0, 0]))
    }

    // MARK: - route: "only when the tunnel is actually active"

    func testRouteIsTunnelOnlyForAConnectedProxySession() {
        XCTAssertEqual(SSHTransport.route(state: .connected, mode: .proxy, boundPort: 8808),
                       .tunnel(port: 8808))
    }

    func testRouteCarriesTheLiveBoundPortNotTheConfiguredOne() {
        // #308/#313: the bound port is the one the engine actually holds; a live
        // edit of the configured port must not redirect the relay.
        XCTAssertEqual(SSHTransport.route(state: .connected, mode: .proxy, boundPort: 1080),
                       .tunnel(port: 1080))
    }

    func testRouteIsDirectWhileMerelyConnecting() {
        // preflight publishes boundPort during `.connecting`, before a single byte
        // has crossed the tunnel — that is not a tunnel yet.
        XCTAssertEqual(SSHTransport.route(state: .connecting, mode: .proxy, boundPort: 8808), .direct)
    }

    func testRouteIsDirectForEveryNonConnectedState() {
        let states: [ConnectionState] = [.disconnected, .connecting,
                                        .waitingForNetwork, .failed("boom")]
        for state in states {
            XCTAssertEqual(SSHTransport.route(state: state, mode: .proxy, boundPort: 8808),
                           .direct, "state \(state) must not claim a tunnel")
        }
    }

    func testRouteIsDirectInVPNModeEvenWhenConnected() {
        // The packet tunnel installs a default route and runs the core in the
        // appex: there is no in-app SOCKS listener, and a direct dial is already
        // inside the tunnel.
        XCTAssertEqual(SSHTransport.route(state: .connected, mode: .vpn, boundPort: 8808), .direct)
        XCTAssertEqual(SSHTransport.route(state: .connected, mode: .vpn, boundPort: nil), .direct)
    }

    func testRouteIsDirectWithoutABoundPort() {
        XCTAssertEqual(SSHTransport.route(state: .connected, mode: .proxy, boundPort: nil), .direct)
        XCTAssertEqual(SSHTransport.route(state: .connected, mode: .proxy, boundPort: 0), .direct)
    }

    func testRouteIsTunnelPredicate() {
        XCTAssertTrue(SSHTransport.Route.tunnel(port: 1).isTunnel)
        XCTAssertFalse(SSHTransport.Route.direct.isTunnel)
    }

    // MARK: - nextRoute: fallback both ways, exactly once

    func testFirstAttemptTakesWhateverIsAvailable() {
        XCTAssertEqual(SSHTransport.nextRoute(attempt: 1, previous: nil,
                                              available: .tunnel(port: 8808)),
                       .tunnel(port: 8808))
        XCTAssertEqual(SSHTransport.nextRoute(attempt: 1, previous: nil, available: .direct),
                       .direct)
    }

    func testFailedTunnelAttemptFallsBackToDirect() {
        XCTAssertEqual(SSHTransport.nextRoute(attempt: 2, previous: .tunnel(port: 8808),
                                              available: .tunnel(port: 8808)),
                       .direct)
    }

    func testFailedDirectAttemptRetriesThroughTheTunnelWhenOneExists() {
        XCTAssertEqual(SSHTransport.nextRoute(attempt: 2, previous: .direct,
                                              available: .tunnel(port: 8808)),
                       .tunnel(port: 8808))
    }

    func testFailedDirectAttemptStaysDirectWhenNoTunnelExists() {
        // Never "try the tunnel" when there is no tunnel.
        XCTAssertEqual(SSHTransport.nextRoute(attempt: 2, previous: .direct, available: .direct),
                       .direct)
    }

    func testSecondAttemptUsesTheCurrentPortIfTheTunnelRebound() {
        // The route is re-snapshotted per attempt, so a session that reconnected on
        // a different port between attempts is followed, not remembered.
        XCTAssertEqual(SSHTransport.nextRoute(attempt: 2, previous: .direct,
                                              available: .tunnel(port: 9999)),
                       .tunnel(port: 9999))
    }

    // MARK: - error text

    func testConnectRejectedDescribesTheReplyByte() {
        let error = SSHTransportError.connectRejected(0x04)
        XCTAssertTrue(error.description.contains("host unreachable"), error.description)
    }

    func testReplyTextCoversTheDefinedRange() {
        XCTAssertEqual(SSHSocks5.replyText(0x00), "succeeded")
        XCTAssertEqual(SSHSocks5.replyText(0x05), "connection refused")
        XCTAssertTrue(SSHSocks5.replyText(0x42).hasPrefix("unknown reply"))
    }
}
