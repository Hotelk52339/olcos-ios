import XCTest
@testable import olcrtc_ios

/// Pure logic behind the add-server wizard: step validation, the carrier plan
/// and its recommendation badges, room-ID propagation into `InstallOptions`,
/// and the SSH probe parser.
final class AddServerFlowTests: XCTestCase {

    // MARK: Step 1 — access validation

    private func validDraft() -> AddServerAccessDraft {
        var d = AddServerAccessDraft()
        d.label = "VPS-1"
        d.host = "203.0.113.10"
        d.port = "22"
        d.username = "root"
        d.password = "secret"
        return d
    }

    func testValidPasswordDraftHasNoErrors() {
        XCTAssertEqual(validDraft().validate(otherLabels: []), [])
        XCTAssertNotNil(validDraft().makeHost())
        XCTAssertEqual(validDraft().makeSecret(), .password("secret"))
    }

    func testMissingFieldsAreReported() {
        var d = AddServerAccessDraft()
        d.port = "70000"
        d.username = ""
        let errors = d.validate(otherLabels: [])
        XCTAssertTrue(errors.contains(.labelMissing))
        XCTAssertTrue(errors.contains(.hostMissing))
        XCTAssertTrue(errors.contains(.portInvalid))
        XCTAssertTrue(errors.contains(.userMissing))
        XCTAssertTrue(errors.contains(.passwordMissing))
        XCTAssertNil(d.makeHost())
        XCTAssertNil(d.makeSecret())
    }

    func testDuplicateLabelIsCaseInsensitive() {
        let d = validDraft()
        XCTAssertEqual(d.validate(otherLabels: ["vps-1"]), [.labelDuplicate])
        XCTAssertEqual(d.validate(otherLabels: ["VPS-2"]), [])
    }

    func testPortBounds() {
        XCTAssertEqual(AddServerAccessDraft.validPort("1"), 1)
        XCTAssertEqual(AddServerAccessDraft.validPort(" 65535 "), 65535)
        XCTAssertNil(AddServerAccessDraft.validPort("0"))
        XCTAssertNil(AddServerAccessDraft.validPort("65536"))
        XCTAssertNil(AddServerAccessDraft.validPort("ssh"))
    }

    func testKeyAuthRequiresAPastedKey() {
        var d = validDraft()
        d.password = ""
        d.authMethod = .privateKey
        XCTAssertEqual(d.validate(otherLabels: []), [.keyMissing])
        XCTAssertNil(d.makeSecret())
    }

    func testUnsupportedKeyIsRejected() {
        var d = validDraft()
        d.authMethod = .privateKey
        d.keyText = "PuTTY-User-Key-File-3: ssh-ed25519"
        XCTAssertEqual(d.validate(otherLabels: []), [.keyUnsupported(.unsupportedFormat)])
        XCTAssertNil(d.makeSecret())
    }

    func testHostCarriesPortUserAndAuthMethod() throws {
        var d = validDraft()
        d.port = "2222"
        d.username = "  deploy "
        let host = try XCTUnwrap(d.makeHost())
        XCTAssertEqual(host.label, "VPS-1")
        XCTAssertEqual(host.host, "203.0.113.10")
        XCTAssertEqual(host.port, 2222)
        XCTAssertEqual(host.username, "deploy")
        XCTAssertEqual(host.authMethod, .password)
    }

    // MARK: Step 2 — probe parsing

    func testProbeOutputParses() {
        let out = """
        OS=Ubuntu 24.04.1 LTS
        ARCH=x86_64
        RUNTIME=podman
        CONTAINER=olcrtc-server-jitsi
        CONTAINER=olcrtc-server-telemost
        """
        let facts = AddServerHostFacts.parse(out)
        XCTAssertEqual(facts.osName, "Ubuntu 24.04.1 LTS")
        XCTAssertEqual(facts.arch, "x86_64")
        XCTAssertEqual(facts.runtime, .podman)
        XCTAssertEqual(facts.existing, ["olcrtc-server-jitsi", "olcrtc-server-telemost"])
    }

    func testProbeOutputWithoutRuntimeOrContainers() {
        let facts = AddServerHostFacts.parse("OS=\nARCH=aarch64\nRUNTIME=none\nbash: podman: not found\n")
        XCTAssertNil(facts.osName)
        XCTAssertEqual(facts.arch, "aarch64")
        XCTAssertNil(facts.runtime)
        XCTAssertEqual(facts.existing, [])
    }

    // MARK: Step 3 — recommendation follows upstream

    func testDefaultPlanIsJitsiDataChannel() {
        XCTAssertEqual(AddServerCarrierPlan.defaultPlan.primary, "jitsi")
        XCTAssertEqual(AddServerCarrierPlan.defaultPlan.transport(for: "jitsi"), "datachannel")
    }

    func testBadgesMatchUpstreamGuidance() {
        XCTAssertEqual(AddServerCarrierPlan.badge(for: "jitsi"), .recommended)
        XCTAssertEqual(AddServerCarrierPlan.badge(for: "wbstream"), .alternative)
        XCTAssertEqual(AddServerCarrierPlan.badge(for: "telemost"), .none)
    }

    func testRecommendedTransportPerCarrier() {
        XCTAssertEqual(AddServerCarrierPlan.recommendedTransport(for: "jitsi"), "datachannel")
        XCTAssertEqual(AddServerCarrierPlan.recommendedTransport(for: "wbstream"), "vp8channel")
        XCTAssertEqual(AddServerCarrierPlan.recommendedTransport(for: "telemost"), "vp8channel")
    }

    func testTransportOptionsHideFailingCombos() {
        XCTAssertFalse(AddServerCarrierPlan.transportOptions(for: "telemost").contains("datachannel"))
        XCTAssertFalse(AddServerCarrierPlan.transportOptions(for: "telemost").contains("seichannel"))
        XCTAssertTrue(AddServerCarrierPlan.transportOptions(for: "jitsi").contains("datachannel"))
    }

    func testToggleAndPrimaryOrdering() {
        var plan = AddServerCarrierPlan()
        XCTAssertTrue(plan.isEmpty)
        plan.toggle("telemost")
        plan.toggle("jitsi")
        XCTAssertEqual(plan.primary, "telemost")
        XCTAssertEqual(plan.extras, ["jitsi"])
        XCTAssertEqual(plan.transport(for: "telemost"), "vp8channel")
        plan.makePrimary("jitsi")
        XCTAssertEqual(plan.selected, ["jitsi", "telemost"])
        plan.toggle("telemost")
        XCTAssertEqual(plan.selected, ["jitsi"])
    }

    // MARK: Step 4 — room validation

    func testRoomValidationPerCarrier() {
        var plan = AddServerCarrierPlan()
        plan.toggle("telemost"); plan.toggle("wbstream"); plan.toggle("jitsi")
        var rooms = AddServerRoomDraft()
        XCTAssertEqual(rooms.validate(plan: plan), [.missing(carrier: "telemost"), .missing(carrier: "wbstream")])
        rooms.telemostRoomID = "352854101234"
        rooms.wbRoomID = "  9988 "
        XCTAssertEqual(rooms.validate(plan: plan), [])
        rooms.jitsiBaseURL = "   "
        XCTAssertEqual(rooms.validate(plan: plan), [.missing(carrier: "jitsi")])
    }

    // MARK: Step 5 — room IDs land in InstallOptions

    func testTelemostRoomIDPropagatesIntoPrimaryInstallOptions() throws {
        var plan = AddServerCarrierPlan()
        plan.toggle("telemost")
        var rooms = AddServerRoomDraft()
        rooms.telemostRoomID = "352854101234"
        let options = try XCTUnwrap(plan.installOptions(rooms: rooms))
        XCTAssertEqual(options.primary.carrier, "telemost")
        XCTAssertEqual(options.primary.transport, "vp8channel")
        XCTAssertEqual(options.primary.roomID, "352854101234")
        XCTAssertEqual(options.extras, [])
        XCTAssertTrue(SSHRunner.installEnv(options.primary).contains("OLCRTC_ROOM_ID=352854101234"))
    }

    func testExtrasCarryTheirOwnRoomsAndTokens() throws {
        var plan = AddServerCarrierPlan()
        plan.toggle("jitsi"); plan.toggle("wbstream"); plan.toggle("telemost")
        plan.transport["wbstream"] = "seichannel"
        var rooms = AddServerRoomDraft()
        rooms.jitsiBaseURL = "https://meet.example.org/"
        rooms.jitsiRoomName = "olc room"
        rooms.wbRoomID = "1234 5678"
        rooms.wbToken = " tok "
        rooms.telemostRoomID = "111222333444"
        let options = try XCTUnwrap(plan.installOptions(rooms: rooms))
        XCTAssertEqual(options.primary.carrier, "jitsi")
        XCTAssertEqual(options.primary.jitsiBaseURL, "https://meet.example.org/")
        XCTAssertEqual(options.primary.roomID, "olcroom")
        XCTAssertEqual(options.extras.map(\.carrier), ["wbstream", "telemost"])
        XCTAssertEqual(options.extras[0].transport, "seichannel")
        XCTAssertEqual(options.extras[0].roomID, "12345678")
        XCTAssertEqual(options.extras[0].wbToken, "tok")
        XCTAssertEqual(options.extras[1].roomID, "111222333444")
        XCTAssertEqual(options.extras[1].wbToken, "")
    }

    func testEmptyJitsiBaseFallsBackToDefault() throws {
        var plan = AddServerCarrierPlan()
        plan.toggle("jitsi")
        var rooms = AddServerRoomDraft()
        rooms.jitsiBaseURL = ""
        let options = try XCTUnwrap(plan.installOptions(rooms: rooms))
        XCTAssertEqual(options.primary.jitsiBaseURL, AppConstants.defaultJitsiBaseURL)
        XCTAssertEqual(options.primary.roomID, "")
    }

    func testEmptyPlanYieldsNoOptions() {
        XCTAssertNil(AddServerCarrierPlan().installOptions(rooms: AddServerRoomDraft()))
    }

    // MARK: Steps

    func testStepOrder() {
        XCTAssertEqual(AddServerStep.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
        XCTAssertEqual(AddServerStep.access.next, .check)
        XCTAssertEqual(AddServerStep.install.next, nil)
        XCTAssertEqual(AddServerStep.access.previous, nil)
        XCTAssertEqual(AddServerStep.room.previous, .protocols)
    }

    // MARK: Jitsi instances

    func testJitsiInstanceListStartsWithAppDefault() {
        XCTAssertEqual(CarrierEndpoints.jitsiInstances.first,
                       CarrierEndpoints.host(fromRoomID: AppConstants.defaultJitsiBaseURL))
        XCTAssertEqual(Set(CarrierEndpoints.jitsiInstances).count, CarrierEndpoints.jitsiInstances.count)
        XCTAssertTrue(CarrierEndpoints.jitsiInstances.contains("meet.egovm.ru"))
    }

    func testJitsiBaseURLFromInstance() {
        XCTAssertEqual(CarrierEndpoints.jitsiBaseURL(forInstance: "meet.egovm.ru"), "https://meet.egovm.ru")
        XCTAssertEqual(CarrierEndpoints.jitsiBaseURL(forInstance: "https://meet.x.org/"), "https://meet.x.org")
        XCTAssertEqual(CarrierEndpoints.jitsiBaseURL(forInstance: "  "), "")
    }

    // MARK: InstallOptionsView mapping

    func testInstallOptionsSheetMapping() {
        let o = InstallOptionsView.options(carrier: "wbstream", transport: "seichannel",
                                           roomID: " 12 34 ", jitsiBaseURL: "", wbToken: " t ",
                                           sei: (fps: 15, batch: 5, frag: 800, ack: 200))
        XCTAssertEqual(o.roomID, "1234")
        XCTAssertEqual(o.wbToken, "t")
        XCTAssertEqual(o.jitsiBaseURL, AppConstants.defaultJitsiBaseURL)
        XCTAssertEqual(o.seiFPS, 15); XCTAssertEqual(o.seiBatch, 5)
        XCTAssertEqual(o.seiFrag, 800); XCTAssertEqual(o.seiACK, 200)
        XCTAssertTrue(InstallOptionsView.roomIsValid(carrier: "jitsi", roomID: ""))
        XCTAssertFalse(InstallOptionsView.roomIsValid(carrier: "telemost", roomID: " "))
    }
}
