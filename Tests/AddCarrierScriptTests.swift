import XCTest
@testable import olcrtc_ios

// #452: tests for scripts/add-carrier.sh — the multi-carrier "add protocol"
// script that attaches an extra carrier to an existing install as a sibling
// container ("<base>-<carrier>", running server-<carrier>.yaml from the same
// deploy dir / binary / key). Three contracts are guarded here:
//
//   1. srv.sh parity — blocks marked `# boc srv.sh` / `# eoc srv.sh` in
//      add-carrier.sh are verbatim copies of scripts/srv.sh lines (the shared
//      constants, the key-load branch, the room/DNS/tuning env patches, the
//      "Generate YAML config" heredocs, the URI assembly). Same guarantee
//      RotateKeyScriptTests gives rotate-key.sh: if either file drifts, this
//      fails — no silent divergence. Comparison is whitespace-trimmed
//      because srv.sh nests some copied lines at a different indent.
//
//   2. Output contract — the script must emit the same OLCRTC_URI= /
//      OLCRTC_CONTAINER= lines as srv.sh (plus OLCRTC_CARRIER_ADDED=ok) so
//      SSHRunner.parseInstallResult and OlcrtcURI.parse are reused unchanged.
//
//   3. Safety — the script may replace only ITS OWN sibling container
//      ($NEW_NAME) and write only its own server-<carrier>.yaml; the base
//      container and the primary server.yaml are read-only to it.

final class AddCarrierScriptTests: XCTestCase {

    /// Loads scripts/<name>.sh — bundle resource first (device builds), source
    /// tree fallback for simulator runs. Same strategy as ServerScriptParityTests.
    private func loadScript(_ name: String) throws -> String {
        let url: URL = Bundle.main.url(forResource: name, withExtension: "sh")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()          // Tests/
                .deletingLastPathComponent()          // olcrtc-ios/
                .appendingPathComponent("scripts/\(name).sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: srv.sh parity

    func testSrvShOriginBlocksStayVerbatim() throws {
        let script = try loadScript("add-carrier")
        let srv    = try loadScript("srv")
        let srvLines = Set(srv.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) })

        var inBlock = false
        var checked = 0
        for (idx, raw) in script.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# boc srv.sh") {
                XCTAssertFalse(inBlock, "add-carrier.sh:\(idx + 1): nested '# boc srv.sh'")
                inBlock = true
                continue
            }
            if line.hasPrefix("# eoc srv.sh") {
                XCTAssertTrue(inBlock, "add-carrier.sh:\(idx + 1): '# eoc srv.sh' without boc")
                inBlock = false
                continue
            }
            // Blank lines and comments inside a block may differ (same rule
            // parity_check.py applies to srv.sh vs upstream).
            guard inBlock, !line.isEmpty, !line.hasPrefix("#") else { continue }
            XCTAssertTrue(srvLines.contains(line),
                "add-carrier.sh:\(idx + 1) marked srv.sh-origin but not found verbatim in scripts/srv.sh: \(line)")
            checked += 1
        }
        XCTAssertFalse(inBlock, "add-carrier.sh: unclosed '# boc srv.sh' block")
        // The copied blocks (constants + key load + env patches + YAML
        // heredocs + URI assembly) are ~100 lines; a much smaller count means
        // the markers broke and the parity guarantee silently evaporated.
        XCTAssertGreaterThan(checked, 80,
            "only \(checked) lines inside '# boc srv.sh' blocks — markers broken?")
    }

    // MARK: Output contract (same as srv.sh → parseInstallResult reuse)

    func testEmitsOutputContract() throws {
        let script = try loadScript("add-carrier")
        XCTAssertTrue(script.contains("echo \"OLCRTC_URI=$OLC_URI\""))
        XCTAssertTrue(script.contains("echo \"OLCRTC_CONTAINER=$NEW_NAME\""))
        XCTAssertTrue(script.contains("echo \"OLCRTC_CARRIER_ADDED=ok\""))
    }

    func testParseInstallResultParsesAddCarrierOutput() throws {
        let key = String(repeating: "c", count: 64)
        // Shaped like real add-carrier.sh output (banner + uri: + contract lines).
        let output = """
        [*] Loading existing encryption key...
        [*] Writing /opt/olcrtc-deploy-ab12cd34/server-jitsi.yaml (carrier=jitsi transport=datachannel room=https://meet1.arbitr.ru/olcrtc-xy98zz76)
        [*] Starting olcrtc-server-ab12cd34-jitsi...
        [+] Carrier added!
        uri: olcrtc://jitsi?datachannel@https://meet1.arbitr.ru/olcrtc-xy98zz76#\(key)$auto-provisioned
        OLCRTC_URI=olcrtc://jitsi?datachannel@https://meet1.arbitr.ru/olcrtc-xy98zz76#\(key)$auto-provisioned
        OLCRTC_CONTAINER=olcrtc-server-ab12cd34-jitsi
        OLCRTC_CARRIER_ADDED=ok
        """
        let result = try XCTUnwrap(SSHRunner.parseInstallResult(from: output))
        XCTAssertEqual(result.containerName, "olcrtc-server-ab12cd34-jitsi")

        // End-to-end: the emitted URI must survive OlcrtcURI.parse — that is
        // what the app builds the sibling ConnectionRecord from.
        let cfg = try OlcrtcURI.parse(result.uri)
        XCTAssertEqual(cfg.carrier,   "jitsi")
        XCTAssertEqual(cfg.transport, "datachannel")
        XCTAssertEqual(cfg.roomID,    "https://meet1.arbitr.ru/olcrtc-xy98zz76")
        XCTAssertEqual(cfg.key,       key)
        XCTAssertEqual(cfg.mimo,      "auto-provisioned")
    }

    func testParseInstallResultParsesVP8PayloadFromAddCarrierOutput() throws {
        let key = String(repeating: "d", count: 64)
        let output = """
        OLCRTC_URI=olcrtc://telemost?vp8channel<vp8-fps=25&vp8-batch=1>@35285410123456#\(key)$auto-provisioned
        OLCRTC_CONTAINER=olcrtc-server-ab12cd34-telemost
        OLCRTC_CARRIER_ADDED=ok
        """
        let result = try XCTUnwrap(SSHRunner.parseInstallResult(from: output))
        let cfg = try OlcrtcURI.parse(result.uri)
        XCTAssertEqual(cfg.carrier,      "telemost")
        XCTAssertEqual(cfg.transport,    "vp8channel")
        XCTAssertEqual(cfg.vp8FPS,       25)
        XCTAssertEqual(cfg.vp8BatchSize, 1)
    }

    // MARK: Safety — sibling-only writes

    func testPodmanRmOnlyTargetsTheSiblingName() throws {
        let script = try loadScript("add-carrier")
        for (idx, line) in script.components(separatedBy: "\n").enumerated()
        where line.contains("podman rm") {
            XCTAssertTrue(line.contains("\"$NEW_NAME\""),
                "add-carrier.sh:\(idx + 1): podman rm must target only \"$NEW_NAME\": \(line)")
            XCTAssertFalse(line.contains("BASE_CONTAINER"),
                "add-carrier.sh:\(idx + 1): podman rm must never target the base container: \(line)")
        }
        // The base container must never be stopped/restarted either.
        XCTAssertFalse(script.contains("podman stop \"$BASE_CONTAINER\""))
        XCTAssertFalse(script.contains("podman restart \"$BASE_CONTAINER\""))
    }

    func testNamingConventions() throws {
        let script = try loadScript("add-carrier")
        // Container: "<base>-<carrier>" — the app derives the sibling ↔ yaml
        // mapping from this convention (SSHRunner carrier listing).
        XCTAssertTrue(script.contains("BASE_CONTAINER=\"${OLCRTC_BASE_CONTAINER:?"))
        XCTAssertTrue(script.contains("NEW_NAME=\"${BASE_CONTAINER}-${PROVIDER}\""))
        // Config: server-<carrier>.yaml next to the primary server.yaml.
        XCTAssertTrue(script.contains("CONFIG_FILE=\"$WORK_DIR/server-${PROVIDER}.yaml\""))
        // The container must run ITS yaml, not the primary's.
        XCTAssertTrue(script.contains("sh -c \"./olcrtc server-${PROVIDER}.yaml\""))
    }

    func testNeverWritesPrimaryConfig() throws {
        let script = try loadScript("add-carrier")
        // Reading the primary server.yaml (key fallback) is fine; assigning
        // CONFIG_FILE to it would make the heredocs overwrite the primary.
        XCTAssertFalse(script.contains("CONFIG_FILE=\"$WORK_DIR/server.yaml\""))
    }

    func testReusesKeyInsteadOfRotating() throws {
        let script = try loadScript("add-carrier")
        // Sibling carriers share the primary's key (that is what lets
        // rotate-key.sh rotate all of them in lockstep) — this script must
        // never generate a new one.
        XCTAssertTrue(script.contains("Loading existing encryption key"))
        XCTAssertFalse(script.contains("openssl rand"))
    }

    func testDoesNotCloneOrBuild() throws {
        let script = try loadScript("add-carrier")
        // The whole point: siblings reuse the built binary. No git, no go
        // build, no OLCRTC_PIN (nothing to pin when nothing is fetched).
        XCTAssertFalse(script.contains("git "))
        XCTAssertFalse(script.contains("go build"))
        XCTAssertFalse(script.contains("OLCRTC_PIN"))
        XCTAssertTrue(script.contains("[ ! -x \"$WORK_DIR/olcrtc\" ]"))
    }

    // MARK: Env contract

    /// Every `${OLCRTC_*}` the script reads must be in the documented set —
    /// the app-side env builder (SSHRunner) is written against exactly this
    /// list, so an undocumented read would silently fall back to its default.
    /// Same idea as ServerScriptParityTests.testEnvVarNamesMatchSrvShBocPatches.
    func testEnvVarReadsMatchDocumentedContract() throws {
        let script = try loadScript("add-carrier")
        let documented: Set<String> = [
            "OLCRTC_BASE_CONTAINER", "OLCRTC_CARRIER", "OLCRTC_TRANSPORT",
            "OLCRTC_ROOM_ID", "OLCRTC_JITSI_URL", "OLCRTC_WB_TOKEN",
            "OLCRTC_DNS", "OLCRTC_SOCKS_PROXY_ADDR", "OLCRTC_SOCKS_PROXY_PORT",
            "OLCRTC_VP8_FPS", "OLCRTC_VP8_BATCH",
            "OLCRTC_SEI_FPS", "OLCRTC_SEI_BATCH", "OLCRTC_SEI_FRAG", "OLCRTC_SEI_ACK",
            "OLCRTC_VIDEO_W", "OLCRTC_VIDEO_H", "OLCRTC_VIDEO_FPS",
            "OLCRTC_VIDEO_CODEC", "OLCRTC_VIDEO_QR_SIZE", "OLCRTC_VIDEO_QR_RECOVERY",
            "OLCRTC_VIDEO_TILE_MODULE", "OLCRTC_VIDEO_TILE_RS",
            "OLCRTC_CONFIG_NAME",
        ]
        // All env reads use the braced form `${OLCRTC_…}` (with :? / :- / plain).
        var reads = Set<String>()
        let pattern = try NSRegularExpression(pattern: #"\$\{(OLCRTC_[A-Z0-9_]+)"#)
        let ns = script as NSString
        for m in pattern.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
            reads.insert(ns.substring(with: m.range(at: 1)))
        }
        XCTAssertTrue(reads.subtracting(documented).isEmpty,
            "add-carrier.sh reads undocumented env vars: \(reads.subtracting(documented).sorted())")
        // And the required trio must actually be read.
        XCTAssertTrue(reads.isSuperset(of: ["OLCRTC_BASE_CONTAINER", "OLCRTC_CARRIER", "OLCRTC_TRANSPORT"]))
    }
}
