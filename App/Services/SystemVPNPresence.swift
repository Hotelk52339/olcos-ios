import Foundation
import CFNetwork

// MARK: - SystemVPNPresence (#479)
//
// Is SOME system VPN carrying this device right now — ours or anybody's?
//
// `TunnelManager.systemTunnelIsUp` (#477) could only ever answer for OUR OWN
// packet-tunnel extension, because that is the only one `NETunnelProviderManager`
// can see: iOS shows an app its own VPN configurations and nobody else's. Which
// means the case this app is most often used in was invisible to it — a device
// with no paid Apple signature cannot run our extension at all, so the user
// pairs our SOCKS listener with a THIRD-PARTY VPN client that owns the system
// tunnel and points its traffic at our port.
//
// That arrangement has a sharp edge. Unless the user has excluded us from that
// VPN's routes, our own WebRTC transport is captured by it and handed straight
// back to our SOCKS port, which is a loop. An established session survives it
// (the socket predates the tunnel), but every NEW connection we open —
// a health probe, a keep-alive verification, a reconnect — goes round that loop
// and hangs until its own timeout. Three hung verifications in a row is 90 s,
// which is exactly the point where the keep-alive loop tears a WORKING session
// down and the reconnect then fails on a port thick with TIME_WAIT.
//
// So the app has to be able to see any tunnel, not just its own.
//
// HOW: the system's proxy settings carry a `__SCOPED__` dictionary keyed by
// interface name, and a live VPN adds its virtual interface there (`utun…` for
// IKEv2 / NEPacketTunnelProvider / WireGuard, `ipsec…` for legacy IPsec,
// `ppp…` for L2TP). This is the long-standing way to ask the question on iOS —
// there is no public API for "is a VPN up" — and it costs a dictionary read.
//
// LIMITS, stated plainly: it reports the INTERFACE, not the routes. A split
// tunnel that excludes us still reads as present, so treating "present" as
// "our transport may be looping" is deliberately conservative — the cost of a
// false positive is a skipped side-channel probe, the cost of a false negative
// is a torn-down session.
enum SystemVPNPresence {

    /// Interface-name prefixes a system VPN installs.
    private static let vpnInterfacePrefixes = ["utun", "tap", "tun", "ppp", "ipsec", "ipsec0"]

    /// True when a VPN interface is present in the system's scoped proxy
    /// settings. Cheap enough to call per probe; no caching, because the whole
    /// point is to notice a tunnel that came up while we were not looking.
    static var isActive: Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
                as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any]
        else { return false }
        return containsVPNInterface(Array(scoped.keys))
    }

    /// Pure half, so the prefix table is pinned by a test rather than trusted.
    /// Interface names carry a unit suffix (`utun0`, `ipsec1`); match on prefix.
    static func containsVPNInterface(_ interfaceNames: [String]) -> Bool {
        interfaceNames.contains { name in
            let lower = name.lowercased()
            return vpnInterfacePrefixes.contains { lower.hasPrefix($0) }
        }
    }
}
