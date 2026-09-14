import XCTest
@testable import olcrtc_ios

// #463 — one-button Telemost room rotation.
//
// Everything covered here is PURE: the two parsers on `TelemostRoomService`
// (`roomID(fromURI:)`, `decodeRoom`), the error taxonomy, and the pure halves of
// `YandexSessionStore` (`normalize`, `isSessionCookie`, `sessionCookie(in:)`).
// The Keychain round-trip is covered too — it runs against the simulator's own
// keychain and snapshots/restores whatever was there, per the repo convention.
//
// INTEGRATION-ONLY (not covered here, by design):
//   * `TelemostRoomService.createRoom()` — a live authenticated POST to
//     cloud-api.yandex.ru. It needs a real `Session_id`, so a unit test could
//     only ever assert against a mock we wrote ourselves. The parts that CAN be
//     wrong without a network — the URL, the parsers, the status mapping shape —
//     are pinned below; the header set is pinned by construction (it is copied
//     from upstream `internal/auth/telemost/api.go`, which talks to the same
//     host and base URL).
//   * The route choice, which is `SSHTransport.route` / `.nextRoute` — already
//     covered by `SSHTransportTests`.
//
// SECURITY NOTE: no test here may ever assert on a real session value, and none
// of the fixtures is a real cookie.

// MARK: - roomID(fromURI:)

final class TelemostRoomIDTests: XCTestCase {

    func testCanonicalURIYieldsBareID() {
        XCTAssertEqual(
            TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/j/1234567890"),
            "1234567890")
    }

    func testTrailingSlashIsIgnored() {
        XCTAssertEqual(
            TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/j/1234567890/"),
            "1234567890")
    }

    func testQueryAndFragmentAreStripped() {
        XCTAssertEqual(
            TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/j/abc123?utm_source=x"),
            "abc123")
        XCTAssertEqual(
            TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/j/abc123#anchor"),
            "abc123")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(
            TelemostRoomService.roomID(fromURI: "  https://telemost.yandex.ru/j/xyz\n"),
            "xyz")
    }

    func testMarkerMatchIsCaseInsensitive() {
        // A hand-pasted link can arrive upper-cased; the id's own case is kept.
        XCTAssertEqual(
            TelemostRoomService.roomID(fromURI: "HTTPS://TELEMOST.YANDEX.RU/J/AbC123"),
            "AbC123")
    }

    func testIDMayCarryDashesAndUnderscores() {
        XCTAssertEqual(
            TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/j/a-b_c123"),
            "a-b_c123")
    }

    func testLastPathComponentWins() {
        // Documented behaviour: the id is the LAST path component after `/j/`.
        // Telemost never returns a deeper path, so this only pins the rule.
        XCTAssertEqual(
            TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/j/111/222"),
            "222")
    }

    // MARK: rejections

    func testEmptyStringIsRejected() {
        XCTAssertNil(TelemostRoomService.roomID(fromURI: ""))
        XCTAssertNil(TelemostRoomService.roomID(fromURI: "   "))
    }

    func testURIWithoutJSegmentIsRejected() {
        XCTAssertNil(TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/"))
        XCTAssertNil(TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/join/123"))
        XCTAssertNil(TelemostRoomService.roomID(fromURI: "1234567890"))
    }

    func testEmptyIDSegmentIsRejected() {
        XCTAssertNil(TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/j/"))
        XCTAssertNil(TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/j/?x=1"))
    }

    func testIDWithSpacesIsRejected() {
        // Telemost DISPLAYS ids in groups ("3528 5410 1234"); a URI never carries
        // them, and this value is about to be written into server.yaml over SSH.
        XCTAssertNil(TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/j/3528 5410"))
    }

    func testIDWithShellMetacharactersIsRejected() {
        XCTAssertNil(TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/j/a;reboot"))
        XCTAssertNil(TelemostRoomService.roomID(fromURI: "https://telemost.yandex.ru/j/a$(id)"))
        XCTAssertNil(TelemostRoomService.roomID(fromURI: #"https://telemost.yandex.ru/j/a"b"#))
    }

    func testNonASCIIIDIsRejected() {
        // U+043E CYRILLIC SMALL LETTER O is not the ASCII "o" — refuse rather than
        // silently fold. Written as escapes so no editor can "correct" the fixture.
        XCTAssertNil(TelemostRoomService.roomID(
            fromURI: "https://telemost.yandex.ru/j/r\u{043E}\u{043E}m"))
    }
}

// MARK: - decodeRoom

final class TelemostRoomDecoderTests: XCTestCase {

    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testDecodesDocumentedResponse() throws {
        let room = try TelemostRoomService.decodeRoom(
            json(#"{"uri":"https://telemost.yandex.ru/j/1234567890"}"#))
        XCTAssertEqual(room.uri, "https://telemost.yandex.ru/j/1234567890")
        XCTAssertEqual(room.id, "1234567890")
    }

    func testUnknownFieldsAreIgnored() throws {
        let room = try TelemostRoomService.decodeRoom(json("""
        {"uri":"https://telemost.yandex.ru/j/abc","id":"ignored","extra":{"a":1}}
        """))
        XCTAssertEqual(room.id, "abc")
    }

    func testWhitespaceAroundURIIsTrimmed() throws {
        let room = try TelemostRoomService.decodeRoom(
            json(#"{"uri":"  https://telemost.yandex.ru/j/abc  "}"#))
        XCTAssertEqual(room.uri, "https://telemost.yandex.ru/j/abc")
        XCTAssertEqual(room.id, "abc")
    }

    // MARK: rejections — every one must be `.malformedResponse`

    private func assertMalformed(_ data: Data,
                                 _ message: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertThrowsError(try TelemostRoomService.decodeRoom(data), message,
                             file: file, line: line) { error in
            XCTAssertEqual(error as? TelemostRoomError, TelemostRoomError.malformedResponse,
                           message, file: file, line: line)
        }
    }

    func testMissingURIKeyIsMalformed() {
        // The shape of the 401 body, in case a status mapping ever lets it through.
        assertMalformed(json(#"{"error":"UnauthorizedError","message":"no"}"#),
                        "a body with no uri is not a room")
    }

    func testEmptyURIIsMalformed() {
        assertMalformed(json(#"{"uri":""}"#), "an empty uri is not a room")
        assertMalformed(json(#"{"uri":"   "}"#), "a blank uri is not a room")
    }

    func testNullURIIsMalformed() {
        assertMalformed(json(#"{"uri":null}"#), "a null uri is not a room")
    }

    func testURIWithoutRoomIDIsMalformed() {
        assertMalformed(json(#"{"uri":"https://telemost.yandex.ru/"}"#),
                        "a link with no /j/ segment carries no id")
    }

    func testNonJSONBodyIsMalformed() {
        // What an interception / captive page would return.
        assertMalformed(json("<html><body>blocked</body></html>"), "HTML is not a room")
    }

    func testEmptyBodyIsMalformed() {
        assertMalformed(Data(), "an empty body is not a room")
    }

    func testJSONArrayIsMalformed() {
        assertMalformed(json(#"[{"uri":"https://telemost.yandex.ru/j/abc"}]"#),
                        "the envelope is an object, not an array")
    }
}

// MARK: - the error taxonomy

final class TelemostRoomErrorTests: XCTestCase {

    func testOnlyAuthFailuresAskForSignIn() {
        XCTAssertTrue(TelemostRoomError.noSession.needsSignIn)
        XCTAssertTrue(TelemostRoomError.sessionRejected.needsSignIn)
        XCTAssertFalse(TelemostRoomError.rateLimited.needsSignIn)
        XCTAssertFalse(TelemostRoomError.networkUnavailable.needsSignIn)
        XCTAssertFalse(TelemostRoomError.malformedResponse.needsSignIn)
        XCTAssertFalse(TelemostRoomError.serviceError(status: 500).needsSignIn)
    }

    func testStatusIsPartOfIdentity() {
        XCTAssertNotEqual(TelemostRoomError.serviceError(status: 500),
                          TelemostRoomError.serviceError(status: 502))
    }

    func testCreateURLIsTheFrontAPINotTheBusinessAPI() {
        // The paid business API (cloud-api.yandex.NET/v1/telemost-api) 403s
        // without a Yandex 360 subscription — pin the free front endpoint.
        XCTAssertEqual(
            TelemostRoomService.createURL.absoluteString,
            "https://cloud-api.yandex.ru/telemost_front/v2/telemost/conferences" +
            "?next_gen_media_platform_allowed=true")
    }
}

// MARK: - YandexSessionStore: pure helpers

final class YandexSessionNormalizeTests: XCTestCase {

    // Not a real cookie — a shape-alike fixture.
    private let fixture = "3:1700000000.5.0.1700000000000:AbCdEf:1a.1.2:1|123456.0.2|0:0.0.0"

    func testPlainValuePassesThrough() {
        XCTAssertEqual(YandexSessionStore.normalize(fixture), fixture)
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(YandexSessionStore.normalize("  \(fixture)\n"), fixture)
    }

    func testPastedNameValuePairIsAccepted() {
        XCTAssertEqual(YandexSessionStore.normalize("Session_id=\(fixture)"), fixture)
    }

    func testPastedCookieLineKeepsOnlyTheFirstPair() {
        XCTAssertEqual(
            YandexSessionStore.normalize("Session_id=\(fixture); yandexuid=999; yp=1"),
            fixture)
    }

    func testEmptyAndBlankAreRejected() {
        XCTAssertNil(YandexSessionStore.normalize(""))
        XCTAssertNil(YandexSessionStore.normalize("   \n "))
        XCTAssertNil(YandexSessionStore.normalize("Session_id="))
        XCTAssertNil(YandexSessionStore.normalize("Session_id=;yandexuid=1"))
    }

    func testHeaderInjectionIsRejected() {
        // The value is interpolated into a Cookie header — CR/LF must never pass.
        XCTAssertNil(YandexSessionStore.normalize("abc\r\nX-Evil: 1"))
        XCTAssertNil(YandexSessionStore.normalize("abc\nX-Evil: 1"))
    }

    func testInteriorWhitespaceAndNonASCIIAreRejected() {
        XCTAssertNil(YandexSessionStore.normalize("ab cd"))
        XCTAssertNil(YandexSessionStore.normalize("\u{0430}\u{0431}\u{0432}"))   // Cyrillic
    }
}

final class YandexSessionCookieTests: XCTestCase {

    private func makeCookie(name: String, value: String, domain: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .name:   name,
            .value:  value,
            .domain: domain,
            .path:   "/",
        ]))
    }

    func testPicksTheSessionCookieOutOfAJar() throws {
        let jar = [
            try makeCookie(name: "yandexuid",  value: "1",   domain: ".yandex.ru"),
            try makeCookie(name: "Session_id", value: "abc", domain: ".yandex.ru"),
            try makeCookie(name: "yp",         value: "2",   domain: ".yandex.ru"),
        ]
        XCTAssertEqual(YandexSessionStore.sessionCookie(in: jar)?.value, "abc")
    }

    func testSubdomainCookieIsAccepted() throws {
        let cookie = try makeCookie(name: "Session_id", value: "abc", domain: "passport.yandex.ru")
        XCTAssertTrue(YandexSessionStore.isSessionCookie(cookie))
    }

    func testBareDomainCookieIsAccepted() throws {
        let cookie = try makeCookie(name: "Session_id", value: "abc", domain: "yandex.ru")
        XCTAssertTrue(YandexSessionStore.isSessionCookie(cookie))
    }

    func testLookalikeDomainIsRejected() throws {
        // "evilyandex.ru" ends with "yandex.ru" but not with ".yandex.ru".
        let cookie = try makeCookie(name: "Session_id", value: "abc", domain: "evilyandex.ru")
        XCTAssertFalse(YandexSessionStore.isSessionCookie(cookie))
    }

    func testOtherCookieNamesAreRejected() throws {
        let cookie = try makeCookie(name: "sessionid", value: "abc", domain: ".yandex.ru")
        XCTAssertFalse(YandexSessionStore.isSessionCookie(cookie))
        XCTAssertNil(YandexSessionStore.sessionCookie(in: [cookie]))
    }

    func testEmptyValuedCookieIsRejected() throws {
        // Foundation may refuse to build a cookie with an empty value at all;
        // when it does build one, the store must still reject it.
        guard let cookie = HTTPCookie(properties: [
            .name: "Session_id", .value: "", .domain: ".yandex.ru", .path: "/",
        ]) else {
            // #470 was: `return` — a green run that had verified nothing. A skip
            // shows in the report as what it is.
            throw XCTSkip("Foundation refused an empty cookie value; the store's own guard was not exercised")
        }
        XCTAssertFalse(YandexSessionStore.isSessionCookie(cookie))
    }

    func testEmptyJarYieldsNil() {
        XCTAssertNil(YandexSessionStore.sessionCookie(in: []))
    }
}

// MARK: - YandexSessionStore: Keychain round-trip
//
// Touches the ONE real item (`olcrtc.yandex.session` / `Session_id`), so setUp
// snapshots it and tearDown puts it back — the repo's rule for tests that share
// real UserDefaults / Keychain state with the app.

@MainActor
final class YandexSessionStoreTests: XCTestCase {

    private var snapshot: String?
    private let fixture = "3:1700000000.5.0.1700000000000:AbCdEf:1a.1.2:1"

    override func setUp() {
        super.setUp()
        snapshot = YandexSessionStore.storedSession()
        YandexSessionStore().clear()
    }

    override func tearDown() {
        let store = YandexSessionStore()
        if let snapshot { store.save(snapshot) } else { store.clear() }
        super.tearDown()
    }

    func testStartsUnlinked() {
        XCTAssertFalse(YandexSessionStore().hasSession)
        XCTAssertNil(YandexSessionStore.storedSession())
    }

    func testSaveThenLoadRoundTrips() {
        let store = YandexSessionStore()
        XCTAssertTrue(store.save(fixture))
        XCTAssertTrue(store.hasSession)
        XCTAssertEqual(store.load(), fixture)
        XCTAssertEqual(YandexSessionStore.storedSession(), fixture)
        XCTAssertTrue(YandexSessionStore.hasStoredSession())
    }

    func testSaveNormalizesAPastedPair() {
        let store = YandexSessionStore()
        XCTAssertTrue(store.save("Session_id=\(fixture); yandexuid=1"))
        XCTAssertEqual(store.load(), fixture)
    }

    func testSaveOverwritesThePreviousSession() {
        let store = YandexSessionStore()
        XCTAssertTrue(store.save(fixture))
        XCTAssertTrue(store.save("\(fixture)-second"))
        XCTAssertEqual(store.load(), "\(fixture)-second")
    }

    func testUnusableValueIsRejectedWithoutClobbering() {
        let store = YandexSessionStore()
        XCTAssertTrue(store.save(fixture))
        // A bad paste must never silently unlink a working account.
        XCTAssertFalse(store.save("   "))
        XCTAssertFalse(store.save("bad value\r\nX-Evil: 1"))
        XCTAssertTrue(store.hasSession)
        XCTAssertEqual(store.load(), fixture)
    }

    func testClearRemovesTheSession() {
        let store = YandexSessionStore()
        XCTAssertTrue(store.save(fixture))
        store.clear()
        XCTAssertFalse(store.hasSession)
        XCTAssertNil(store.load())
        XCTAssertFalse(YandexSessionStore.hasStoredSession())
    }

    func testRefreshPicksUpAnotherInstancesWrite() {
        let a = YandexSessionStore()
        let b = YandexSessionStore()
        XCTAssertTrue(a.save(fixture))
        XCTAssertFalse(b.hasSession, "b was created before the write")
        b.refresh()
        XCTAssertTrue(b.hasSession)
    }

    func testStoredSessionIsNeverWrittenToUserDefaults() {
        let store = YandexSessionStore()
        XCTAssertTrue(store.save(fixture))
        // Nothing in the whole app-domain defaults may carry the value.
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in defaults {
            // #470 was: `"\(value)".contains(fixture)` — a `Data` value prints as
            // "N bytes", so a session "cached" as UTF-8 or base64 bytes passed.
            XCTAssertFalse(Self.carries(fixture, in: value),
                           "session cookie leaked into UserDefaults key \(key)")
        }
    }

    // boc #470
    /// Whether `value` — a String, a Data (raw UTF-8, or base64 text of the
    /// needle), or any array / dictionary nesting of those — contains `needle`
    /// in a form a reader of the preferences plist could recover.
    private static func carries(_ needle: String, in value: Any) -> Bool {
        let base64 = Data(needle.utf8).base64EncodedString()
        switch value {
        case let s as String:
            return s.contains(needle) || s.contains(base64)
        case let d as Data:
            let text = String(decoding: d, as: UTF8.self)
            return text.contains(needle) || text.contains(base64)
        case let a as [Any]:
            return a.contains { carries(needle, in: $0) }
        case let m as [AnyHashable: Any]:
            return m.values.contains { carries(needle, in: $0) }
        default:
            return "\(value)".contains(needle)
        }
    }
    // eoc #470
}
