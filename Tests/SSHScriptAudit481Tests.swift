// boc #481: bundled-script contracts. Full offline shell execution is covered
// by scripts/test_ssh_audit_481.py; neither suite connects to a server.
import XCTest
@testable import olcrtc_ios

final class SSHScriptAudit481Tests: XCTestCase {
    private func loadScript(_ name: String) throws -> String {
        let url = Bundle.main.url(forResource: name, withExtension: "sh")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("scripts/\(name).sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testUpdateOnlyRestartsRunningSiblings() {
        let script = SSHRunner.updateScript(containerName: "olcrtc-server-audit")
        XCTAssertTrue(script.contains("for c in $(podman ps --format"))
        XCTAssertFalse(script.contains("for c in $(podman ps -a --format"))
        XCTAssertTrue(script.contains("podman restart \"$CNAME\""), "Primary update still starts primary")
    }

    func testAddRejectsOccupiedFileOrContainerBeforeFirstWrite() throws {
        let script = try loadScript("add-carrier")
        let guardStart = try XCTUnwrap(script.range(of: "EXISTING_NAMES=$(podman ps"))
        let write = try XCTUnwrap(script.range(of: "cat > \"$CONFIG_FILE\""))
        let guardBlock = String(script[guardStart.lowerBound..<write.lowerBound])
        XCTAssertTrue(guardBlock.contains("[ -e \"$CONFIG_FILE\" ]"))
        XCTAssertTrue(guardBlock.contains("[ -L \"$CONFIG_FILE\" ]"))
        XCTAssertTrue(guardBlock.contains("grep -Fxq -- \"$NEW_NAME\""))
        XCTAssertTrue(guardBlock.contains("exit 1"))
        XCTAssertTrue(guardBlock.contains("set -o noclobber"))
        XCTAssertFalse(guardBlock.contains("podman rm"))
    }

    func testPrimaryRestartFailureDoesNotLoseCommittedKeyResult() throws {
        let script = try loadScript("rotate-key")
        XCTAssertTrue(script.contains("podman restart \"$CONTAINER_NAME\" \\\n    || echo"))
        XCTAssertTrue(script.contains("new key is saved"))
        let restart = try XCTUnwrap(script.range(of: "podman restart \"$CONTAINER_NAME\" \\"))
        let result = try XCTUnwrap(script.range(of: "echo \"OLCRTC_URI=$OLC_URI\""))
        let siblings = try XCTUnwrap(script.range(of: "for SIB_CONFIG in"))
        XCTAssertLessThan(restart.lowerBound, result.lowerBound)
        XCTAssertLessThan(result.lowerBound, siblings.lowerBound)
    }
}
// eoc #481
