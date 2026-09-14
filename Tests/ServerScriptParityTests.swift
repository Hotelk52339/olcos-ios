import XCTest
@testable import olcrtc_ios

// MARK: - ServerScriptParityTests
//
// Verifies that SSHRunner.installEnv() sets exactly the env var names that
// scripts/srv.sh expects in its # boc olcrtc-ios patches.
//
// Relationship to parity_check.py (the build-phase script):
//   - parity_check.py: every non-boc line in scripts/srv.sh must appear
//     verbatim in upstream olcrtc-upstream/script/srv.sh. Catches upstream changes.
//   - These tests: every OLCRTC_* var read inside boc patches must be set
//     by installEnv(). Catches our own drift between Swift and srv.sh.
//
// Only srv.sh (server-side script) is tested. cnc.sh (client-side CLI) has
// no iOS equivalent — the client is Mobile.xcframework (gomobile bindings).

final class ServerScriptParityTests: XCTestCase {

    // MARK: Required variables always present

    func testEnvCarrier() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_CARRIER=telemost"))
    }

    func testEnvTransport() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_TRANSPORT=datachannel"))
    }

    func testEnvClientIDOmitted() {
        // client-id no longer exists: upstream dropped it from the URI scheme
        // and from srv.sh (YAML config has no client-id field). installEnv must
        // not set OLCRTC_CLIENT_ID.
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertFalse(env.contains("OLCRTC_CLIENT_ID"),
                       "OLCRTC_CLIENT_ID must be absent — client-id was removed upstream")
    }

    func testEnvDNS() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_DNS="))
    }

    func testEnvConfigName() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_CONFIG_NAME="))
    }

    // MARK: Conditional variables

    func testRoomIDSetWhenProvided() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "my-room"))
        XCTAssertTrue(env.contains("OLCRTC_ROOM_ID=my-room"))
    }

    func testRoomIDOmittedWhenEmpty() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: ""))
        XCTAssertFalse(env.contains("OLCRTC_ROOM_ID"),
                       "installEnv must omit OLCRTC_ROOM_ID when the room ID is empty")
    }

    func testJitsiURLSetForJitsi() {
        let env = SSHRunner.installEnv(.init(carrier: "jitsi", transport: "datachannel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_JITSI_URL="),
                      "installEnv must set OLCRTC_JITSI_URL for the jitsi carrier")
    }

    func testJitsiURLAbsentForNonJitsi() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertFalse(env.contains("OLCRTC_JITSI_URL"),
                       "OLCRTC_JITSI_URL must not be set for non-jitsi carriers")
    }

    func testVP8VarsSetForVP8Channel() {
        let env = SSHRunner.installEnv(.init(carrier: "wbstream", transport: "vp8channel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_VP8_FPS="),   "VP8 FPS must be set for vp8channel")
        XCTAssertTrue(env.contains("OLCRTC_VP8_BATCH="), "VP8 batch must be set for vp8channel")
    }

    func testVP8VarsAbsentForDatachannel() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertFalse(env.contains("OLCRTC_VP8_FPS"))
        XCTAssertFalse(env.contains("OLCRTC_VP8_BATCH"))
    }

    // MARK: Alignment between installEnv() and srv.sh boc patches

    func testEnvVarNamesMatchSrvShBocPatches() throws {
        // Load scripts/srv.sh — try bundle first, fall back to source tree
        let scriptURL: URL = Bundle.main.url(forResource: "srv", withExtension: "sh")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()          // Tests/
                .deletingLastPathComponent()          // olcrtc-ios/
                .appendingPathComponent("scripts/srv.sh")

        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        // Extract lines inside boc/eoc blocks.
        var inBOC = false
        var bocLines: [String] = []
        for line in script.components(separatedBy: "\n") {
            if line.contains("# boc olcrtc-ios") { inBOC = true;  continue }
            if line.contains("# eoc olcrtc-ios") { inBOC = false; continue }
            if inBOC { bocLines.append(line) }
        }

        // Extract all OLCRTC_* variable names read in boc patches.
        let bocText = bocLines.joined(separator: "\n")
        // #470 was: `[A-Z_]+` — no digits, so `${OLCRTC_VP8_FPS:-25}` was captured
        // as "OLCRTC_VP", which the substring check below matched against ANY
        // OLCRTC_VP8_* emission; a new digit-bearing var could never be caught.
        let pattern = try NSRegularExpression(pattern: #"\$\{?(OLCRTC_[A-Z0-9_]+)"#)
        let matches = pattern.matches(in: bocText, range: NSRange(bocText.startIndex..., in: bocText))
        let reads   = Set(matches.compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: bocText) else { return nil }
            return String(bocText[r])
        })

        // Variables that are read with default values (${VAR:-default}) and
        // intentionally NOT passed by installEnv() because the script defaults suffice.
        let scriptDefaults: Set<String> = [
            // client-id: removed upstream; the var is still tolerated by older
            // boc patches but installEnv no longer sets it.
            "OLCRTC_CLIENT_ID",
            // SOCKS5 egress proxy — read with ${VAR:-default} in a boc patch;
            // off by default and not exposed in the UI, so installEnv omits it.
            "OLCRTC_SOCKS_PROXY_ADDR", "OLCRTC_SOCKS_PROXY_PORT",
            // #436: wbstream token — read as ${OLCRTC_WB_TOKEN:-}; installEnv sets it
            // only for wbstream with a non-empty token, so the default covers the rest.
            "OLCRTC_WB_TOKEN",
            // deferred transports — read with defaults in boc patches
            "OLCRTC_SEI_FPS", "OLCRTC_SEI_BATCH", "OLCRTC_SEI_FRAG", "OLCRTC_SEI_ACK",
            // #442: master dropped the bitrate:/hw: config keys, so srv.sh no
            // longer reads OLCRTC_VIDEO_BITRATE / OLCRTC_VIDEO_HW.
            "OLCRTC_VIDEO_W", "OLCRTC_VIDEO_H", "OLCRTC_VIDEO_FPS",
            "OLCRTC_VIDEO_CODEC", "OLCRTC_VIDEO_QR_RECOVERY",
            "OLCRTC_VIDEO_QR_SIZE", "OLCRTC_VIDEO_TILE_MODULE", "OLCRTC_VIDEO_TILE_RS",
            "OLCRTC_CACHE_DIR",
        ]

        // Build env string covering all carrier/transport combinations.
        let allEnvs = [
            SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r")),
            SSHRunner.installEnv(.init(carrier: "jitsi",    transport: "datachannel", roomID: "r")),
            SSHRunner.installEnv(.init(carrier: "wbstream", transport: "vp8channel",  roomID: "r")),
        ].joined(separator: " ")

        let emitted = try Self.emittedEnvNames(in: allEnvs)   // #470
        for varName in reads where !scriptDefaults.contains(varName) {
            // #470 was: `allEnvs.contains(varName)` — a substring check.
            XCTAssertTrue(emitted.contains(varName),
                "\(varName) is read in a srv.sh boc patch but never set by SSHRunner.installEnv()")
        }
    }

    /// #470: the NAMES an env string assigns (`OLCRTC_X=…`), as a set, so the
    /// contract checks above compare whole names instead of substrings.
    private static func emittedEnvNames(in env: String) throws -> Set<String> {
        let re = try NSRegularExpression(pattern: #"(OLCRTC_[A-Z0-9_]+)="#)
        let matches = re.matches(in: env, range: NSRange(env.startIndex..., in: env))
        return Set(matches.compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: env) else { return nil }
            return String(env[r])
        })
    }

    // MARK: #452 — Alignment between addCarrierEnv() and scripts/add-carrier.sh

    /// Mirror of testEnvVarNamesMatchSrvShBocPatches for the sibling-carrier
    /// script: every $OLCRTC_* var scripts/add-carrier.sh reads must be
    /// emitted by SSHRunner.addCarrierEnv() or listed as a script-default
    /// below. The whole file is scanned — it is fully ours, so no boc
    /// filtering applies.
    func testEnvVarNamesMatchAddCarrierScript() throws {
        let url: URL = Bundle.main.url(forResource: "add-carrier", withExtension: "sh")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()          // Tests/
                .deletingLastPathComponent()          // olcrtc-ios/
                .appendingPathComponent("scripts/add-carrier.sh")
        // #470 was: `try?` + XCTSkip — a script dropped from the bundle made the
        // whole contract silently "skipped" on device; the sibling loaders throw.
        let script = try String(contentsOf: url, encoding: .utf8)

        let pattern = try NSRegularExpression(pattern: #"\$\{?(OLCRTC_[A-Z0-9_]+)"#)   // #470 was: [A-Z_]+
        let matches = pattern.matches(in: script, range: NSRange(script.startIndex..., in: script))
        let reads = Set(matches.compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: script) else { return nil }
            return String(script[r])
        })

        // Read with ${VAR:-default} and intentionally not passed — the script
        // defaults suffice (same rationale as the srv.sh set; videochannel
        // tuning is never exposed in the UI).
        let scriptDefaults: Set<String> = [
            "OLCRTC_SOCKS_PROXY_ADDR", "OLCRTC_SOCKS_PROXY_PORT",
            "OLCRTC_VIDEO_W", "OLCRTC_VIDEO_H", "OLCRTC_VIDEO_FPS",
            "OLCRTC_VIDEO_CODEC", "OLCRTC_VIDEO_QR_RECOVERY",
            "OLCRTC_VIDEO_QR_SIZE", "OLCRTC_VIDEO_TILE_MODULE", "OLCRTC_VIDEO_TILE_RS",
        ]

        // Cover every conditional branch of addCarrierEnv so each emittable
        // var name appears at least once.
        var wbOpts = InstallOptions(carrier: "wbstream", transport: "seichannel", roomID: "r")
        wbOpts.wbToken = "tok"
        let allEnvs = [
            SSHRunner.addCarrierEnv(.init(carrier: "telemost", transport: "vp8channel", roomID: "r"),
                                    baseContainer: "olcrtc-server-x"),
            SSHRunner.addCarrierEnv(.init(carrier: "jitsi", transport: "datachannel", roomID: "r"),
                                    baseContainer: "olcrtc-server-x"),
            SSHRunner.addCarrierEnv(wbOpts, baseContainer: "olcrtc-server-x"),
        ].joined(separator: " ")

        XCTAssertFalse(reads.contains("OLCRTC_PIN"),
            "add-carrier.sh must not read OLCRTC_PIN — siblings reuse the already-built binary")
        let emitted = try Self.emittedEnvNames(in: allEnvs)   // #470
        for varName in reads where !scriptDefaults.contains(varName) {
            // #470 was: `allEnvs.contains(varName)` — a substring check.
            XCTAssertTrue(emitted.contains(varName),
                "\(varName) is read by scripts/add-carrier.sh but never set by SSHRunner.addCarrierEnv()")
        }
    }

    // MARK: #451 — golang builder-image tag parity (drift guard)

    /// The Swift side references the Go builder image in three places (the
    /// readiness probe, the Update Binary rebuild, deep uninstall's rmi), all
    /// via AppConstants.serverGoImage. If a future upstream rebase bumps the
    /// tag in scripts/srv.sh without the constant, readiness would report
    /// `.noImage` forever and deep uninstall would strand the old image —
    /// this pins the two together.
    func testGoImageMatchesSrvShImageName() throws {
        let script = try Self.loadSrvSh()
        let imageLine = script.components(separatedBy: "\n")
            .first { $0.hasPrefix("IMAGE_NAME=") }
        let line = try XCTUnwrap(imageLine, "scripts/srv.sh has no IMAGE_NAME= line")
        XCTAssertTrue(line.contains(AppConstants.serverGoImage),
            "scripts/srv.sh IMAGE_NAME (\(line)) != AppConstants.serverGoImage (\(AppConstants.serverGoImage)) — bump both together")
    }

    /// #451: the scripts SSHRunner composes must themselves use the constant —
    /// updateScript's detached rebuild (the stopped-container fix), the
    /// readiness probe, and deep uninstall's rmi.
    func testSwiftScriptsUseServerGoImage() {
        XCTAssertTrue(SSHRunner.updateScript(containerName: "olcrtc-server-x")
            .contains(AppConstants.serverGoImage))
        XCTAssertTrue(SSHRunner.readinessScript(containerName: nil)
            .contains(AppConstants.serverGoImage))
        XCTAssertTrue(SSHRunner.deepUninstallScript(containerName: nil, removeImage: true)
            .contains(AppConstants.serverGoImage))
    }

    // MARK: #451 — update script (stopped-container rebuild path)

    func testUpdateScriptBuildsDetachedAndEmitsContainerKey() {
        let script = SSHRunner.updateScript(containerName: "olcrtc-server-abc")
        // Detached builder — works whether the target container is running or
        // stopped (podman exec required a running one).
        XCTAssertTrue(script.contains("podman run --rm"))
        XCTAssertFalse(script.contains("podman exec"),
            "update must not rebuild via podman exec — it fails on stopped containers")
        XCTAssertTrue(script.contains("go build -trimpath -ldflags='-s -w' -o olcrtc ./cmd/olcrtc"))
        // `podman restart` also starts a stopped container.
        XCTAssertTrue(script.contains("podman restart"))
        // Adoption contract for ServersView.update.
        XCTAssertTrue(script.contains("OLCRTC_UPDATE_CONTAINER=$CNAME"))
        // Still pinned to the framework's upstream commit (#442).
        XCTAssertTrue(script.contains(AppConstants.upstreamCorePin))
    }

    // MARK: #466 — reconfigure must edit the config its OWN container reads

    func testReconfigureResolvesTheConfigFromTheContainerCommand() {
        // Every sibling carrier mounts the SAME deploy dir, so a hardcoded
        // "$DEPLOY_DIR/server.yaml" is the PRIMARY's config whatever container is
        // named. That is what #466 was: reconfiguring a sibling overwrote the
        // primary's carrier and room — destroying that protocol outright — while
        // the restart re-read the sibling's own untouched file, so the change
        // reported success and landed nowhere.
        let script = SSHRunner.reconfigureScript(
            containerName: "olcrtc-server-abc-telemost",
            env: ["OLCRTC_CARRIER=telemost", "OLCRTC_TRANSPORT=vp8channel",
                  "OLCRTC_ROOM_ID=room1"])
        // The container's command names the file it actually reads.
        XCTAssertTrue(script.contains("{{range .Config.Cmd}}"),
            "the config must be resolved from the container's own command")
        XCTAssertTrue(script.contains(#"grep -oE 'server[A-Za-z0-9_.-]*[.]yaml'"#))
        XCTAssertTrue(script.contains(#"CONFIG="${DEPLOY_DIR}/${CONFIG_NAME}""#),
            "the edit target must be the resolved name, not a fixed one")
        // The regression itself: never again assemble the path from a literal.
        XCTAssertFalse(script.contains(#"CONFIG="${DEPLOY_DIR}/server.yaml""#),
            "#466: hardcoding server.yaml edits a sibling's neighbour")
    }

    func testReconfigureStillDefaultsToServerYamlForAPrimary() {
        // A primary container's command names server.yaml anyway; the fallback
        // only covers a container whose command cannot be read, and it must not
        // leave CONFIG empty (which would edit the deploy dir itself).
        let script = SSHRunner.reconfigureScript(
            containerName: "olcrtc-server-abc",
            env: ["OLCRTC_CARRIER=jitsi", "OLCRTC_TRANSPORT=datachannel",
                  "OLCRTC_ROOM_ID=room1"])
        XCTAssertTrue(script.contains(#"if [ -z "$CONFIG_NAME" ]; then CONFIG_NAME="server.yaml"; fi"#))
    }

    func testReconfigureRestartsTheSameContainerItEdited() {
        // The pair that has to stay together: whatever config was edited, the
        // container restarted must be the one that reads it. #466 broke exactly
        // this pairing — it edited the primary's file and restarted the sibling.
        let script = SSHRunner.reconfigureScript(
            containerName: "olcrtc-server-abc-telemost",
            env: ["OLCRTC_CARRIER=telemost", "OLCRTC_TRANSPORT=vp8channel",
                  "OLCRTC_ROOM_ID=room1"])
        XCTAssertTrue(script.contains(#"CNAME="olcrtc-server-abc-telemost""#))
        XCTAssertTrue(script.contains("podman restart"))
        // CONFIG_NAME is derived from ${CNAME}, so the two cannot drift apart.
        XCTAssertTrue(script.contains(#"'{{range .Config.Cmd}}{{.}} {{end}}' "${CNAME}""#))
    }

    // MARK: #451 — reconfigure script (wbstream token + key fallback)

    func testReconfigureScriptManagesWBToken() {
        let withToken = SSHRunner.reconfigureScript(
            containerName: "olcrtc-server-abc",
            env: ["OLCRTC_CARRIER=wbstream", "OLCRTC_TRANSPORT=datachannel",
                  "OLCRTC_ROOM_ID=room1", "OLCRTC_WB_TOKEN=tok123"])
        // Always drop any stale auth.token line…
        XCTAssertTrue(withToken.contains("-e '/^  token: /d'"))
        // …and re-insert the new one right after the rewritten provider line,
        // 2-space-indented (the `s|…|&\n  token…|` form keeps the indent that
        // a one-line `a\` would strip).
        XCTAssertTrue(withToken.contains(#"&\n  token: "tok123""#))

        let otherCarrier = SSHRunner.reconfigureScript(
            containerName: "olcrtc-server-abc",
            env: ["OLCRTC_CARRIER=telemost", "OLCRTC_TRANSPORT=datachannel",
                  "OLCRTC_ROOM_ID=room1"])
        XCTAssertTrue(otherCarrier.contains("-e '/^  token: /d'"),
            "switching away from wbstream must still clear a stale token line")
        XCTAssertFalse(otherCarrier.contains("token: \""),
            "non-wbstream reconfigure must not insert a token line")

        let wbNoToken = SSHRunner.reconfigureScript(
            containerName: "olcrtc-server-abc",
            env: ["OLCRTC_CARRIER=wbstream", "OLCRTC_TRANSPORT=datachannel",
                  "OLCRTC_ROOM_ID=room1"])
        XCTAssertFalse(wbNoToken.contains(#"&\n  token:"#),
            "wbstream with an empty token must not insert an empty token line")
    }

    func testReconfigureScriptFallsBackToConfigKey() {
        // #451: when ~/.olcrtc_key is missing the URI used to end in a bare
        // '#' (OlcrtcURI.parse → missingField(key) → silent no-update); the
        // script now falls back to the key server.yaml still holds.
        let script = SSHRunner.reconfigureScript(
            containerName: "olcrtc-server-abc",
            env: ["OLCRTC_CARRIER=telemost", "OLCRTC_TRANSPORT=datachannel",
                  "OLCRTC_ROOM_ID=room1"])
        XCTAssertTrue(script.contains(#"[ -n "$KEY" ] || KEY=$(sed -n 's/^  key: "\(.*\)"/\1/p' "$CONFIG")"#))
    }

    // MARK: srv.sh loader (shared by the parity tests)

    private static func loadSrvSh() throws -> String {
        let scriptURL: URL = Bundle.main.url(forResource: "srv", withExtension: "sh")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()          // Tests/
                .deletingLastPathComponent()          // olcrtc-ios/
                .appendingPathComponent("scripts/srv.sh")
        return try String(contentsOf: scriptURL, encoding: .utf8)
    }
}

// MARK: - OlcrtcURITests

final class OlcrtcURITests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let conn   = OlcrtcConnection(carrier: "telemost", transport: "datachannel",
                                      roomID: "room-123", key: String(repeating: "a", count: 64),
                                      clientID: "default")
        let parsed = try OlcrtcURI.parse(OlcrtcURI.encode(conn, mimo: "test comment"))
        XCTAssertEqual(parsed.carrier,   conn.carrier)
        XCTAssertEqual(parsed.transport, conn.transport)
        XCTAssertEqual(parsed.roomID,    conn.roomID)
        XCTAssertEqual(parsed.key,       conn.key)
        XCTAssertEqual(parsed.clientID,  conn.clientID)
        XCTAssertEqual(parsed.mimo,      "test comment")
    }

    // A Jitsi room is a full URL. The `@…#` delimiters bracket it cleanly as
    // long as the URL has no `@`/`#`/`?`, so it must survive a round trip even
    // though it contains `://` and `/`.
    func testJitsiURLRoomRoundTrip() throws {
        let url    = "https://meet1.arbitr.ru/olcrtc-ab12cd34"
        let conn   = OlcrtcConnection(carrier: "jitsi", transport: "datachannel",
                                      roomID: url, key: String(repeating: "e", count: 64),
                                      clientID: "default")
        let parsed = try OlcrtcURI.parse(OlcrtcURI.encode(conn))
        XCTAssertEqual(parsed.carrier, "jitsi")
        XCTAssertEqual(parsed.roomID,  url)
    }

    func testVP8RoundTripPreservesParams() throws {
        let conn   = OlcrtcConnection(carrier: "wbstream", transport: "vp8channel",
                                      roomID: "r", key: String(repeating: "b", count: 64),
                                      clientID: "default", vp8FPS: 45, vp8BatchSize: 6)
        let parsed = try OlcrtcURI.parse(OlcrtcURI.encode(conn))
        XCTAssertEqual(parsed.vp8FPS,       45)
        XCTAssertEqual(parsed.vp8BatchSize, 6)
    }

    func testParseServerFormatURI() throws {
        let uri    = "olcrtc://wbstream?vp8channel<vp8-fps=25&vp8-batch=1>@room-abc#" +
                     String(repeating: "c", count: 64) + "%default$auto-provisioned"
        let parsed = try OlcrtcURI.parse(uri)
        XCTAssertEqual(parsed.carrier,      "wbstream")
        XCTAssertEqual(parsed.transport,    "vp8channel")
        XCTAssertEqual(parsed.vp8FPS,       25)
        XCTAssertEqual(parsed.vp8BatchSize, 1)
        XCTAssertEqual(parsed.mimo,         "auto-provisioned")
    }

    func testParseClientFormatURI() throws {
        let uri    = "olcrtc://wbstream?vp8channel[vp8-fps=60,vp8-batch=8]@room-xyz#" +
                     String(repeating: "d", count: 64) + "%default"
        let parsed = try OlcrtcURI.parse(uri)
        XCTAssertEqual(parsed.vp8FPS,       60)
        XCTAssertEqual(parsed.vp8BatchSize, 8)
        XCTAssertEqual(parsed.mimo,         "")
    }

    // New upstream URI format: no %clientID field (removed in olcrtc @ 6ba8fcd).
    func testParseURIWithoutClientID() throws {
        let key = String(repeating: "f", count: 64)
        let uri = "olcrtc://telemost?datachannel@room-123#\(key)"
        let parsed = try OlcrtcURI.parse(uri)
        XCTAssertEqual(parsed.carrier,   "telemost")
        XCTAssertEqual(parsed.transport, "datachannel")
        XCTAssertEqual(parsed.roomID,    "room-123")
        XCTAssertEqual(parsed.key,       key)
        XCTAssertEqual(parsed.clientID,  "default",
                       "clientID must default to 'default' when %field absent")
        XCTAssertEqual(parsed.mimo,      "")
    }

    func testParseURIWithMimoButNoClientID() throws {
        let key = String(repeating: "g", count: 64)
        let uri = "olcrtc://jitsi?datachannel@jitsi-room#\(key)$auto-provisioned"
        let parsed = try OlcrtcURI.parse(uri)
        XCTAssertEqual(parsed.clientID, "default")
        XCTAssertEqual(parsed.mimo,     "auto-provisioned")
    }

    // Encoder must NOT emit %clientID when it is "default".
    func testEncodeDefaultClientIDOmitted() {
        let conn = OlcrtcConnection(carrier: "telemost", transport: "datachannel",
                                    roomID: "r", key: String(repeating: "h", count: 64),
                                    clientID: "default")
        let uri = OlcrtcURI.encode(conn)
        XCTAssertFalse(uri.contains("%"), "URI must not contain % when clientID is 'default'")
    }

    // Encoder must emit %clientID when it is non-default (preserves existing connections).
    func testEncodeNonDefaultClientIDPresent() {
        let conn = OlcrtcConnection(carrier: "telemost", transport: "datachannel",
                                    roomID: "r", key: String(repeating: "i", count: 64),
                                    clientID: "ios-abc12345")
        let uri = OlcrtcURI.encode(conn)
        XCTAssertTrue(uri.contains("%ios-abc12345"),
                      "URI must contain %clientID when clientID is non-default")
    }

    func testInvalidSchemeThrows() {
        XCTAssertThrowsError(try OlcrtcURI.parse("https://example.com"))
    }

    func testEmptyRoomIDThrows() {
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://telemost?datachannel@#" + String(repeating: "e", count: 64) + "%default"
        ))
    }

    // MARK: Edge cases (P3 Code Review)

    func testMissingTransportDelimiterThrows() {
        // No "?" between carrier and transport
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://telemost-datachannel@room#" + String(repeating: "a", count: 64)
        ))
    }

    func testMissingRoomDelimiterThrows() {
        // No "@" between transport and roomID
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://telemost?datachannel.roomID#" + String(repeating: "a", count: 64)
        ))
    }

    func testMissingKeyDelimiterThrows() {
        // No "#" between roomID and key
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://telemost?datachannel@room.key"
        ))
    }

    func testEmptyKeyThrows() {
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://telemost?datachannel@room#"
        ))
    }

    func testEmptyCarrierThrows() {
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://?datachannel@room#" + String(repeating: "a", count: 64)
        ))
    }

    func testRoomIDWithSpecialCharsParsedRaw() throws {
        // Special chars in roomID survive parsing — the server-side validator
        // can reject them later if it doesn't like them.
        let key = String(repeating: "a", count: 64)
        let parsed = try OlcrtcURI.parse("olcrtc://telemost?datachannel@room-with-dashes_and.dots#\(key)")
        XCTAssertEqual(parsed.roomID, "room-with-dashes_and.dots")
    }

    func testWhitespaceAroundURIIsTrimmed() throws {
        let key = String(repeating: "a", count: 64)
        let parsed = try OlcrtcURI.parse("  \n olcrtc://telemost?datachannel@room#\(key) \n  ")
        XCTAssertEqual(parsed.roomID, "room")
        XCTAssertEqual(parsed.key, key)
    }

    func testMimoWithEqualsAndPercent() throws {
        // $mimo is opaque — anything after $ is preserved verbatim.
        let key = String(repeating: "a", count: 64)
        let parsed = try OlcrtcURI.parse(
            "olcrtc://telemost?datachannel@room#\(key)%ios-abc12345$comment=v1&extra%data"
        )
        XCTAssertEqual(parsed.clientID, "ios-abc12345")
        XCTAssertEqual(parsed.mimo,     "comment=v1&extra%data")
    }

    func testVP8PayloadWithUnknownKeysIgnored() throws {
        // Forward-compat: unknown keys in the payload block are silently dropped.
        let key = String(repeating: "a", count: 64)
        let parsed = try OlcrtcURI.parse(
            "olcrtc://wbstream?vp8channel[vp8-fps=30,unknown-key=99,vp8-batch=4]@room#\(key)"
        )
        XCTAssertEqual(parsed.vp8FPS,       30)
        XCTAssertEqual(parsed.vp8BatchSize, 4)
    }
}
