import XCTest
@testable import olcrtc_ios

// #479: the app could only ever see its OWN packet-tunnel extension, so the
// pairing it is most often used in — our SOCKS listener under a third-party VPN
// client, the only arrangement available without a paid Apple signature — was
// invisible to every decision that asks "is a tunnel carrying this device?".
//
// The consequence was not cosmetic. Health sweeps really started running in
// build 276 (#469 removed the `.onDisappear { health.cancelAll() }` that had
// been silently cancelling them), and each probe opens a NEW connection. Under
// a VPN that has not excluded this app, a new connection is captured and handed
// back to our own SOCKS port — a loop that hangs until its timeout. Three hung
// keep-alive verifications is 90 s, at which point the loop tore down a session
// that was carrying traffic, and the reconnect then failed on a port thick with
// TIME_WAIT: "connection timed out" or "port is busy", from a working tunnel.
final class SystemVPNPresenceTests: XCTestCase {

    // MARK: The interface table

    func testRecognisesTheInterfacesASystemVPNInstalls() {
        // A live VPN adds its virtual interface to the scoped proxy settings.
        for name in ["utun0", "utun3", "ipsec0", "ppp0", "tap0", "tun1"] {
            XCTAssertTrue(SystemVPNPresence.containsVPNInterface(["en0", name]),
                          "\(name) is a VPN interface")
        }
    }

    func testOrdinaryInterfacesAreNotAVPN() {
        XCTAssertFalse(SystemVPNPresence.containsVPNInterface(["en0", "pdp_ip0", "lo0", "awdl0"]),
                       "Wi-Fi, cellular, loopback and AWDL are not tunnels")
        XCTAssertFalse(SystemVPNPresence.containsVPNInterface([]),
                       "no interfaces at all is not a tunnel")
    }

    func testMatchIsOnThePrefixAndCaseInsensitive() {
        // Interface names carry a unit suffix, and the key casing is not ours.
        XCTAssertTrue(SystemVPNPresence.containsVPNInterface(["UTUN0"]))
        XCTAssertTrue(SystemVPNPresence.containsVPNInterface(["utun10"]))
        // Not a false positive on a name that merely contains the letters.
        XCTAssertFalse(SystemVPNPresence.containsVPNInterface(["en0-utun"]),
                       "a VPN interface starts with the prefix, it does not contain it")
    }

    // MARK: What it changes for the verdict

    // The regression this exists for: our SOCKS listener running under someone
    // else's tunnel must not read as "no tunnel", which is what sent probes out
    // through it and let keep-alive tear a working session down.
    func testAForeignTunnelCountsAsATunnelCarryingTheDevice() {
        XCTAssertTrue(
            TunnelManager.systemTunnelIsUp(activeMode: .proxy, state: .connected,
                                           vpnStatus: .invalid, foreignTunnel: true),
            "#479 was: only our own extension was ever visible")
    }

    func testWithoutFilterAForeignTunnelIsStillInvisibleToOurOwnStatus() {
        // The own-tunnel table is untouched: no profile of ours, no NEVPNStatus.
        XCTAssertFalse(
            TunnelManager.systemTunnelIsUp(activeMode: .proxy, state: .connected,
                                           vpnStatus: .invalid, foreignTunnel: false))
    }

    // #472's rule survives unchanged: in VPN mode the app's own state decides,
    // because iOS installs the routes before the state machine says `.connected`.
    func testOwnVPNModeStillDecidesFromItsOwnState() {
        for state: ConnectionState in [.connecting, .connected, .waitingForNetwork] {
            XCTAssertTrue(TunnelManager.systemTunnelIsUp(activeMode: .vpn, state: state,
                                                         vpnStatus: .invalid, foreignTunnel: false))
        }
        for state: ConnectionState in [.disconnected, .failed("x")] {
            XCTAssertFalse(TunnelManager.systemTunnelIsUp(activeMode: .vpn, state: state,
                                                          vpnStatus: .invalid, foreignTunnel: false))
        }
    }
}
