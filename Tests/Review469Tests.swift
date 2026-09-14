import XCTest
@testable import olcrtc_ios

// #469: regression pins for the review batch — every fix here is either a pure
// function or a generated script, so each bug gets the cheapest test that
// would have caught it. The behavioural fixes (tunnel switch, VPN adoption,
// data-loss guards) are integration-only and documented at their sites.
final class Review469Tests: XCTestCase {

    // MARK: Multi-carrier — scripts must act on the WHOLE server, not the primary

    func testStopScriptSweepsSiblingsBeforeThePrimary() {
        let s = SSHRunner.stopScript(containerName: "olcrtc-server-abc")
        // "Stop server" means every protocol: the `<base>-<carrier>` siblings
        // used to keep serving while the card read "Server stopped".
        XCTAssertTrue(s.contains("grep '^olcrtc-server-abc-'"), "siblings are found by the base-name prefix")
        XCTAssertTrue(s.contains("podman stop \"$c\""))
        XCTAssertTrue(s.contains("podman stop \"olcrtc-server-abc\""))
        // The primary's result still decides the exit code (siblings are best-effort).
        XCTAssertTrue(s.contains("OLCRTC_STOPPED=error"))
    }

    func testUpdateScriptRestartsSiblingsThatMapTheSameBinary() {
        let s = SSHRunner.updateScript(containerName: "olcrtc-server-abc")
        XCTAssertTrue(s.contains("podman restart \"$CNAME\""))
        XCTAssertTrue(s.contains("grep \"^${CNAME}-\""), "every sibling runs the binary that was just rebuilt")
        XCTAssertTrue(s.contains("podman restart \"$c\""))
    }

    func testUninstallScriptRemovesSiblingsBeforeDeletingTheDirTheyMount() {
        let s = SSHRunner.uninstallScript(containerName: "olcrtc-server-abc")
        let siblings = s.range(of: "grep '^olcrtc-server-abc-'")
        let rmrf = s.range(of: "rm -rf /opt/olcrtc-deploy-*")
        XCTAssertNotNil(siblings, "siblings must be swept")
        XCTAssertNotNil(rmrf)
        if let siblings, let rmrf {
            XCTAssertLessThan(siblings.lowerBound, rmrf.lowerBound,
                              "containers come down BEFORE the deploy dir they bind-mount is deleted")
        }
    }

    // MARK: Remove protocol — by the row's own container and file

    func testRemoveCarrierScriptDeletesExactlyTheNamedPair() {
        let s = SSHRunner.removeCarrierScript(baseContainer: "olcrtc-server-abc",
                                              container: "olcrtc-server-abc-jitsi",
                                              configFile: "server-jitsi.yaml")
        XCTAssertTrue(s.contains("TARGET=\"olcrtc-server-abc-jitsi\""))
        XCTAssertTrue(s.contains("FILE=\"server-jitsi.yaml\""))
        XCTAssertTrue(s.contains("podman rm -f \"${TARGET}\""))
        XCTAssertTrue(s.contains("rm -f \"${DEPLOY_DIR}/${FILE}\""))
        // The name is no longer DERIVED from a carrier that reconfigure may
        // have changed underneath it.
        XCTAssertFalse(s.contains("${CNAME}-jitsi"))
    }

    func testRemoveCarrierScriptRefusesThePrimary() {
        let byName = SSHRunner.removeCarrierScript(baseContainer: "olcrtc-server-abc",
                                                   container: "olcrtc-server-abc",
                                                   configFile: "server-jitsi.yaml")
        let byFile = SSHRunner.removeCarrierScript(baseContainer: "olcrtc-server-abc",
                                                   container: "olcrtc-server-abc-x",
                                                   configFile: "server.yaml")
        for s in [byName, byFile] {
            XCTAssertTrue(s.contains("refusing to remove the primary protocol"))
            // The guard precedes the destructive commands.
            let guardPos = s.range(of: "refusing to remove")!.lowerBound
            let rmPos = s.range(of: "podman rm -f")!.lowerBound
            XCTAssertLessThan(guardPos, rmPos)
        }
    }

    func testCarrierOnlyRemoveWrapperStillDerivesTheSamePair() {
        // Callers that only know the carrier keep working, and land on the
        // exact pair add-carrier.sh created.
        let s = SSHRunner.removeCarrierScript(baseContainer: "olcrtc-server-abc", carrier: "jitsi")
        XCTAssertTrue(s.contains("TARGET=\"olcrtc-server-abc-jitsi\""))
        XCTAssertTrue(s.contains("FILE=\"server-jitsi.yaml\""))
    }

    // MARK: Host headline — measured evidence outranks one container's state

    func testHeadlinePrefersAVerifiedProtocolOverAStoppedPrimary() {
        // Primary stopped, a sibling verified 30 s ago and carrying the tunnel:
        // "Server stopped · tap Start" above a green row was a lie.
        let h = HostHeadline.reduce(display: .base(.stopped), reachable: true,
                                    lastProbeAge: 10, health: .verified(ms: 120, age: 30))
        if case .health(let hd, _, _, _) = h { XCTAssertTrue(hd.isVerified) } else { XCTFail("got \(h)") }   // #471
    }

    func testHeadlineStillSaysStoppedWhenNothingIsVerified() {
        let h = HostHeadline.reduce(display: .base(.stopped), reachable: true,
                                    lastProbeAge: 10, health: .never)
        XCTAssertEqual(h, .containerStopped(age: 10))   // #471
    }

    func testHeadlineNamesAFailedProbeInsteadOfCheckingForever() {
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: nil, health: .never,
                                    probeError: "authentication failed")
        XCTAssertEqual(h, .probeFailed("authentication failed"))
        XCTAssertEqual(h.subtitle, "authentication failed")
        XCTAssertEqual(h.tone, .unknown, "could not check is grey, never red")
        // Without an error the honest blank stays.
        XCTAssertEqual(HostHeadline.reduce(display: .base(.running), reachable: true,
                                           lastProbeAge: nil, health: .never), .notChecked)
    }

    // MARK: Port validation — a real port, or nothing

    func testValidPortAcceptsOnlyRoutablePorts() {
        XCTAssertEqual(AddServerHostView.validPort("22"), 22)
        XCTAssertEqual(AddServerHostView.validPort(" 65535 "), 65535)
        XCTAssertNil(AddServerHostView.validPort("0"))
        XCTAssertNil(AddServerHostView.validPort("65536"), "UInt16(70000) trapped on the next auto-ping")
        XCTAssertNil(AddServerHostView.validPort("70000"))
        XCTAssertNil(AddServerHostView.validPort("-1"))
        XCTAssertNil(AddServerHostView.validPort("abc"))
    }
}
