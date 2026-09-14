import XCTest
@testable import olcrtc_ios

// #470 (review batch, chunk 2): pins for the fixes that have a pure seam.
//
//   • ReconfigureOptionsView.jitsiRoom(_:movedTo:) — the Jitsi-server field in
//     the reconfigure sheet was a no-op for every existing install (the room is
//     seeded as the full URL srv.sh stores, and only a bare name was ever
//     prefixed with the base).
//   • scripts/rotate-key.sh — the server.yaml rewrite dropped `auth.token` (a
//     wbstream primary came back as an anonymous guest), and an unconditional
//     `podman restart` started siblings the user had stopped on purpose.
//   • L10nTable — every `_fmt` value touched by #470 keeps the same placeholder
//     sequence in both languages (L10nTests only checks "at least one").

final class Review470Chunk2Tests: XCTestCase {

    // MARK: ReconfigureOptionsView.jitsiRoom(_:movedTo:)

    func testFullURLRoomMovesToEditedInstanceKeepingPath() {
        XCTAssertEqual(
            ReconfigureOptionsView.jitsiRoom("https://meet1.arbitr.ru/abc", movedTo: "https://my.jitsi.example"),
            "https://my.jitsi.example/abc")
        // Trailing slashes on the base are ignored, like srv.sh's ${JITSI_BASE%/}.
        XCTAssertEqual(
            ReconfigureOptionsView.jitsiRoom("https://meet1.arbitr.ru/abc", movedTo: "https://my.jitsi.example//"),
            "https://my.jitsi.example/abc")
        // A deeper path survives whole.
        XCTAssertEqual(
            ReconfigureOptionsView.jitsiRoom("https://a.example/sub/room", movedTo: "https://b.example"),
            "https://b.example/sub/room")
    }

    func testSameInstanceIsUnchanged() {
        XCTAssertEqual(
            ReconfigureOptionsView.jitsiRoom("https://meet1.arbitr.ru/abc", movedTo: "https://meet1.arbitr.ru"),
            "https://meet1.arbitr.ru/abc")
        XCTAssertEqual(
            ReconfigureOptionsView.jitsiRoom("https://meet1.arbitr.ru/abc", movedTo: "https://meet1.arbitr.ru/"),
            "https://meet1.arbitr.ru/abc")
        // The same host typed without a scheme is still the same instance.
        XCTAssertEqual(
            ReconfigureOptionsView.jitsiRoom("https://meet1.arbitr.ru/abc", movedTo: "meet1.arbitr.ru"),
            "https://meet1.arbitr.ru/abc")
        // A port is part of the instance identity.
        XCTAssertEqual(
            ReconfigureOptionsView.jitsiRoom("https://h.example:8443/r", movedTo: "https://h.example:8443"),
            "https://h.example:8443/r")
        XCTAssertEqual(
            ReconfigureOptionsView.jitsiRoom("https://h.example:8443/r", movedTo: "https://h.example"),
            "https://h.example/r")
    }

    func testNonURLRoomsAndEmptyBaseAreUnchanged() {
        // A bare name is the prefix branch's job in submit(), not this helper's.
        XCTAssertEqual(ReconfigureOptionsView.jitsiRoom("abc", movedTo: "https://x.example"), "abc")
        // host/room forms pass through srv.sh verbatim — left alone here too.
        XCTAssertEqual(ReconfigureOptionsView.jitsiRoom("meet.example/abc", movedTo: "https://x.example"),
                       "meet.example/abc")
        XCTAssertEqual(ReconfigureOptionsView.jitsiRoom("https://a.example/r", movedTo: ""),
                       "https://a.example/r")
        XCTAssertEqual(ReconfigureOptionsView.jitsiRoom("https://a.example/r", movedTo: "   "),
                       "https://a.example/r")
        XCTAssertEqual(ReconfigureOptionsView.jitsiRoom("", movedTo: "https://x.example"), "")
    }

    // MARK: scripts/rotate-key.sh

    /// Bundle resource first (device builds), source tree fallback for the
    /// simulator — the same loader RotateKeyScriptTests uses.
    private func loadScript(_ name: String) throws -> String {
        let url: URL = Bundle.main.url(forResource: name, withExtension: "sh")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()          // Tests/
                .deletingLastPathComponent()          // olcrtc-ios/
                .appendingPathComponent("scripts/\(name).sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testRotateKeySalvagesAndRewritesWbstreamToken() throws {
        let rotate = try loadScript("rotate-key")
        XCTAssertTrue(rotate.contains("WB_TOKEN=$(yaml_str token)"),
                      "rotate-key.sh must salvage auth.token from the old server.yaml")
        // The exact srv.sh (#436) heredoc, so RotateKeyScriptTests' verbatim
        // check keeps covering it.
        XCTAssertTrue(rotate.contains("if [ -n \"$WB_TOKEN\" ]; then"))
        XCTAssertTrue(rotate.contains("  token: \"$WB_TOKEN\""))
        // Salvage precedes the rewrite.
        let salvage = try XCTUnwrap(rotate.range(of: "WB_TOKEN=$(yaml_str token)"))
        let write   = try XCTUnwrap(rotate.range(of: "  token: \"$WB_TOKEN\""))
        XCTAssertLessThan(salvage.lowerBound, write.lowerBound)
    }

    func testRotateKeyRestartsOnlyRunningSiblings() throws {
        let rotate = try loadScript("rotate-key")
        let block = try XCTUnwrap(rotate.range(of: "# boc #452")).upperBound
        let siblings = String(rotate[block...])
        // The restart is guarded by a running check on the sibling's name.
        XCTAssertTrue(siblings.contains("if podman ps --format '{{.Names}}' | grep -q \"^${SIB}$\""))
        XCTAssertTrue(siblings.contains("podman restart \"$SIB\""))
        XCTAssertFalse(siblings.contains("podman restart \"$SIB\" >/dev/null 2>&1 || true"),
                       "an unconditional best-effort restart would start a deliberately stopped sibling")
        // The URI is still reported for every readable sibling — the yaml holds
        // the new key whether or not the container came back.
        XCTAssertTrue(siblings.contains("echo \"OLCRTC_SIBLING_URI=${SIB}|"))
    }

    // MARK: L10n placeholder parity for the #470-touched format strings

    func testTouchedFormatStringsKeepPlaceholderSequence() throws {
        let touched: [L10n] = [.fullAccessImportBody_fmt, .errorPortBusy_fmt, .sshAttemptFailed_fmt,
                               .pingTCPOK_fmt, .subImportConfirm_fmt, .healthChipStale_fmt]
        let re = try NSRegularExpression(pattern: #"%[@d]"#)
        func placeholders(_ s: String) -> [String] {
            re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
                Range($0.range, in: s).map { String(s[$0]) }
            }
        }
        for key in touched {
            let en = try XCTUnwrap(L10nTable.english[key])
            let ru = try XCTUnwrap(L10nTable.russian[key])
            XCTAssertEqual(placeholders(en), placeholders(ru), "placeholder drift in \(key.rawValue)")
            XCTAssertFalse(placeholders(en).isEmpty, "\(key.rawValue) has no placeholder")
        }
    }
}
