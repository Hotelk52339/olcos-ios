import XCTest
@testable import olcrtc_ios

// MARK: - SSHRunnerCarrierTests (#452)
//
// Pure-function tests for the multi-carrier plumbing: sibling naming, the
// add-carrier env builder, the carrier-list block parser, the remove script,
// and rotate-key's sibling-URI lines. No network. addCarrierEnv reads
// SettingsStore.shared (dnsServer / vp8 sliders) but the assertions check
// only variable NAMES, never values, so no snapshot/restore is needed.
// The async addCarrier(host:...) path is integration-only (real SSH).

final class SSHRunnerCarrierTests: XCTestCase {

    // MARK: Naming helpers

    func testCarrierYAMLFile() {
        XCTAssertEqual(SSHRunner.carrierYAMLFile("jitsi"), "server-jitsi.yaml")
        XCTAssertEqual(SSHRunner.carrierYAMLFile("telemost"), "server-telemost.yaml")
    }

    func testSiblingContainerName() {
        XCTAssertEqual(SSHRunner.siblingContainerName(base: "olcrtc-server-abc", carrier: "jitsi"),
                       "olcrtc-server-abc-jitsi")
        // Keeps the scan/uninstall/bot prefix contract.
        XCTAssertTrue(SSHRunner.siblingContainerName(base: "olcrtc-server-abc", carrier: "wbstream")
            .hasPrefix(SSHRunner.containerNamePrefix))
    }

    // MARK: addCarrierEnv

    func testAddCarrierEnvAlwaysPresentVars() {
        let env = SSHRunner.addCarrierEnv(.init(carrier: "telemost", transport: "vp8channel", roomID: "r"),
                                          baseContainer: "olcrtc-server-x")
        XCTAssertTrue(env.contains("OLCRTC_BASE_CONTAINER=olcrtc-server-x"))
        XCTAssertTrue(env.contains("OLCRTC_CARRIER=telemost"))
        XCTAssertTrue(env.contains("OLCRTC_TRANSPORT=vp8channel"))
        XCTAssertTrue(env.contains("OLCRTC_DNS="))
        XCTAssertTrue(env.contains("OLCRTC_CONFIG_NAME=auto-provisioned"))
    }

    func testAddCarrierEnvOmitsPin() {
        // No build happens on the add-carrier path — the sibling reuses the
        // binary srv.sh already built, so the pin must not leak in.
        let env = SSHRunner.addCarrierEnv(.init(carrier: "jitsi", transport: "datachannel", roomID: "r"),
                                          baseContainer: "olcrtc-server-x")
        XCTAssertFalse(env.contains("OLCRTC_PIN"))
    }

    func testAddCarrierEnvRoomOmittedWhenEmpty() {
        let env = SSHRunner.addCarrierEnv(.init(carrier: "jitsi", transport: "datachannel", roomID: ""),
                                          baseContainer: "olcrtc-server-x")
        XCTAssertFalse(env.contains("OLCRTC_ROOM_ID"))
    }

    func testAddCarrierEnvJitsiURLOnlyForJitsi() {
        let jitsi = SSHRunner.addCarrierEnv(.init(carrier: "jitsi", transport: "datachannel", roomID: "r"),
                                            baseContainer: "b")
        let telemost = SSHRunner.addCarrierEnv(.init(carrier: "telemost", transport: "vp8channel", roomID: "r"),
                                               baseContainer: "b")
        XCTAssertTrue(jitsi.contains("OLCRTC_JITSI_URL="))
        XCTAssertFalse(telemost.contains("OLCRTC_JITSI_URL"))
    }

    func testAddCarrierEnvWBTokenOnlyForWBStreamWithToken() {
        var with = InstallOptions(carrier: "wbstream", transport: "vp8channel", roomID: "r")
        with.wbToken = "tok"
        XCTAssertTrue(SSHRunner.addCarrierEnv(with, baseContainer: "b").contains("OLCRTC_WB_TOKEN=tok"))

        let without = InstallOptions(carrier: "wbstream", transport: "vp8channel", roomID: "r")
        XCTAssertFalse(SSHRunner.addCarrierEnv(without, baseContainer: "b").contains("OLCRTC_WB_TOKEN"))

        var wrongCarrier = InstallOptions(carrier: "telemost", transport: "vp8channel", roomID: "r")
        wrongCarrier.wbToken = "tok"
        XCTAssertFalse(SSHRunner.addCarrierEnv(wrongCarrier, baseContainer: "b").contains("OLCRTC_WB_TOKEN"))
    }

    func testAddCarrierEnvVP8VarsOnlyForVP8Channel() {
        let vp8 = SSHRunner.addCarrierEnv(.init(carrier: "telemost", transport: "vp8channel", roomID: "r"),
                                          baseContainer: "b")
        let dc = SSHRunner.addCarrierEnv(.init(carrier: "jitsi", transport: "datachannel", roomID: "r"),
                                         baseContainer: "b")
        XCTAssertTrue(vp8.contains("OLCRTC_VP8_FPS="))
        XCTAssertTrue(vp8.contains("OLCRTC_VP8_BATCH="))
        XCTAssertFalse(dc.contains("OLCRTC_VP8_FPS"))
        XCTAssertFalse(dc.contains("OLCRTC_VP8_BATCH"))
    }

    func testAddCarrierEnvSEIVarsOnlyForSEIChannel() {
        var opts = InstallOptions(carrier: "wbstream", transport: "seichannel", roomID: "r")
        opts.seiFPS = 25; opts.seiBatch = 9; opts.seiFrag = 1100; opts.seiACK = 2
        let sei = SSHRunner.addCarrierEnv(opts, baseContainer: "b")
        XCTAssertTrue(sei.contains("OLCRTC_SEI_FPS=25"))
        XCTAssertTrue(sei.contains("OLCRTC_SEI_BATCH=9"))
        XCTAssertTrue(sei.contains("OLCRTC_SEI_FRAG=1100"))
        XCTAssertTrue(sei.contains("OLCRTC_SEI_ACK=2"))

        let dc = SSHRunner.addCarrierEnv(.init(carrier: "jitsi", transport: "datachannel", roomID: "r"),
                                         baseContainer: "b")
        XCTAssertFalse(dc.contains("OLCRTC_SEI_"))
    }

    func testAddCarrierEnvShellSafesValues() {
        let env = SSHRunner.addCarrierEnv(.init(carrier: "jitsi", transport: "datachannel",
                                                roomID: "room; rm -rf /"),
                                          baseContainer: "base`whoami`")
        XCTAssertFalse(env.contains(";"))
        XCTAssertFalse(env.contains("`"))
        XCTAssertFalse(env.contains("rm -rf /"))
    }

    // MARK: parseCarrierList

    private let twoBlockOutput = """
    some preamble noise
    OLCRTC_CARRIER_BEGIN
    FILE=server-jitsi.yaml
    PROVIDER=jitsi
    TRANSPORT=datachannel
    ROOM=https://meet1.arbitr.ru/olcrtc-x
    CONTAINER=olcrtc-server-abc-jitsi
    STATUS=Up 2 hours
    OLCRTC_CARRIER_END
    OLCRTC_CARRIER_BEGIN
    FILE=server.yaml
    PROVIDER=telemost
    TRANSPORT=vp8channel
    ROOM=35285410123456
    CONTAINER=olcrtc-server-abc
    STATUS=Exited (137) 5 minutes ago
    OLCRTC_CARRIER_END
    trailing noise
    """

    func testParseCarrierListTwoBlocksPrimaryFirst() {
        let list = SSHRunner.parseCarrierList(from: twoBlockOutput)
        XCTAssertEqual(list.count, 2)
        // Primary sorts first even though its block came second.
        XCTAssertTrue(list[0].isPrimary)
        XCTAssertEqual(list[0].file, "server.yaml")
        XCTAssertEqual(list[0].provider, "telemost")
        XCTAssertEqual(list[0].transport, "vp8channel")
        XCTAssertEqual(list[0].container, "olcrtc-server-abc")
        XCTAssertEqual(list[0].status, .stopped("Exited (137) 5 minutes ago"))
        XCTAssertFalse(list[1].isPrimary)
        XCTAssertEqual(list[1].provider, "jitsi")
        XCTAssertEqual(list[1].status, .running("Up 2 hours"))
    }

    func testParseCarrierListMissingContainerStatus() {
        let output = """
        OLCRTC_CARRIER_BEGIN
        FILE=server-wbstream.yaml
        PROVIDER=wbstream
        TRANSPORT=vp8channel
        ROOM=r
        CONTAINER=olcrtc-server-abc-wbstream
        STATUS=missing
        OLCRTC_CARRIER_END
        """
        let list = SSHRunner.parseCarrierList(from: output)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].status, .notFound)
    }

    func testParseCarrierListRoomValueMayContainEquals() {
        let output = """
        OLCRTC_CARRIER_BEGIN
        FILE=server-jitsi.yaml
        PROVIDER=jitsi
        TRANSPORT=datachannel
        ROOM=https://meet.example.com/room?x=1
        CONTAINER=olcrtc-server-abc-jitsi
        STATUS=Up 1 second
        OLCRTC_CARRIER_END
        """
        XCTAssertEqual(SSHRunner.parseCarrierList(from: output).first?.room,
                       "https://meet.example.com/room?x=1")
    }

    func testParseCarrierListDropsIncompleteBlockAndGarbage() {
        let output = """
        OLCRTC_CARRIER_BEGIN
        PROVIDER=jitsi
        OLCRTC_CARRIER_END
        random garbage
        FILE=orphan-outside-any-block.yaml
        """
        XCTAssertTrue(SSHRunner.parseCarrierList(from: output).isEmpty)
        XCTAssertTrue(SSHRunner.parseCarrierList(from: "").isEmpty)
    }

    // MARK: parseSiblingURIs

    func testParseSiblingURIsSplitsOnFirstBar() {
        let output = """
        OLCRTC_URI=olcrtc://telemost?vp8channel@r#k
        OLCRTC_SIBLING_URI=olcrtc-server-abc-jitsi|olcrtc://jitsi?datachannel@https://m/r#k
        OLCRTC_SIBLING_URI=olcrtc-server-abc-wbstream|olcrtc://wbstream?vp8channel@r2#k
        """
        let siblings = SSHRunner.parseSiblingURIs(from: output)
        XCTAssertEqual(siblings.count, 2)
        XCTAssertEqual(siblings[0].container, "olcrtc-server-abc-jitsi")
        XCTAssertEqual(siblings[0].uri, "olcrtc://jitsi?datachannel@https://m/r#k")
        XCTAssertEqual(siblings[1].container, "olcrtc-server-abc-wbstream")
    }

    func testParseSiblingURIsKeepsBarsInsideURI() {
        let output = "OLCRTC_SIBLING_URI=c1|olcrtc://x?y@a|b#k"
        let siblings = SSHRunner.parseSiblingURIs(from: output)
        XCTAssertEqual(siblings.count, 1)
        XCTAssertEqual(siblings[0].uri, "olcrtc://x?y@a|b#k")
    }

    func testParseSiblingURIsIgnoresMalformedLines() {
        let output = """
        OLCRTC_SIBLING_URI=no-bar-here
        OLCRTC_SIBLING_URI=|missing-container
        OLCRTC_SIBLING_URI=missing-uri|
        OLCRTC_URI=olcrtc://telemost?vp8channel@r#k
        """
        XCTAssertTrue(SSHRunner.parseSiblingURIs(from: output).isEmpty)
        XCTAssertTrue(SSHRunner.parseSiblingURIs(from: "").isEmpty)
    }

    // MARK: RotateKeyResult passthrough

    func testRotateKeyResultMirrorsPrimary() {
        let result = SSHRunner.RotateKeyResult(
            primary: InstallResult(uri: "olcrtc://t?v@r#k", containerName: "olcrtc-server-abc"),
            siblings: [.init(container: "olcrtc-server-abc-jitsi", uri: "olcrtc://j?d@r#k")])
        // Pre-#452 call sites read result.uri / result.containerName.
        XCTAssertEqual(result.uri, "olcrtc://t?v@r#k")
        XCTAssertEqual(result.containerName, "olcrtc-server-abc")
        XCTAssertEqual(result.siblings.count, 1)
    }

    // MARK: Shell scripts — safety anchors

    func testCarrierListScriptIsReadOnly() {
        let script = SSHRunner.carrierListScript(baseContainerName: "olcrtc-server-abc")
        XCTAssertTrue(script.contains("podman inspect"))
        XCTAssertTrue(script.contains("OLCRTC_CARRIER_BEGIN"))
        XCTAssertTrue(script.contains("OLCRTC_CARRIER_END"))
        XCTAssertFalse(script.contains("sed -i"))
        XCTAssertFalse(script.contains("podman rm"))
        XCTAssertFalse(script.contains("podman restart"))
    }

    func testCarrierListScriptShellSafesBaseName() {
        let script = SSHRunner.carrierListScript(baseContainerName: "olcrtc-server-abc; rm -rf /")
        XCTAssertFalse(script.contains("rm -rf /"))
    }

    func testRemoveCarrierScriptTargetsOnlySibling() {
        let script = SSHRunner.removeCarrierScript(baseContainer: "olcrtc-server-abc", carrier: "jitsi")
        // #469 was: `TARGET="${CNAME}-jitsi"` — the pair is resolved in Swift now
        // (the row's own container + file), the shell no longer derives it.
        XCTAssertTrue(script.contains(#"TARGET="olcrtc-server-abc-jitsi""#))
        XCTAssertTrue(script.contains(#"FILE="server-jitsi.yaml""#))
        XCTAssertTrue(script.contains(#"podman rm -f "${TARGET}""#))
        XCTAssertTrue(script.contains("server-jitsi.yaml"))
        XCTAssertTrue(script.contains("OLCRTC_CARRIER_REMOVED=ok"))
        // The primary container must never be an rm target here.
        XCTAssertFalse(script.contains(#"podman rm -f "${CNAME}""#))
    }

    func testRemoveCarrierScriptShellSafesInputs() {
        let script = SSHRunner.removeCarrierScript(baseContainer: "olcrtc-server-abc",
                                                   carrier: "jitsi; rm -rf /")
        XCTAssertFalse(script.contains("rm -rf /"))
    }
}
