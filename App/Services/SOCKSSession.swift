import Foundation

// MARK: - RouteMode
//
// Per-request choice of whether to use the local olcrtc SOCKS5 tunnel
// or hit the network directly. Different from `RoutingMode`, which is
// the user's overall routing policy. Per-request decisions are made by
// IP checks and the speed test based on the current tunnel state.

enum RouteMode: String {
    case direct
    case tunnel // #484: existing spelling/raw value means in-app SOCKS proxy only.
    case systemVPN // #484: OS routing provenance, NOT an instruction to use SOCKS.

    // boc #484: separate transfer policy/provenance from socket configuration.
    var usesSOCKS: Bool { self == .tunnel }
    var isTunnelled: Bool { self != .direct }

    static func current(isConnected: Bool, activeMode: TunnelMode) -> RouteMode {
        guard isConnected else { return .direct }
        return activeMode == .vpn ? .systemVPN : .tunnel
    }
    // eoc #484

    var label: String {
        switch self {
        case .direct: return L10n.routingDirect.localized()
        case .tunnel: return L10n.routingViaTunnel.localized()
        case .systemVPN: return L10n.tunnelModeVPN.localized() // #484: existing localized VPN label.
        }
    }
}

// MARK: - SOCKSSession
//
// Single source of truth for building URLSessions that optionally route
// through the local SOCKS5 listener. Used by TunnelManager (for tunnel
// verification), IPChecker, and SpeedTest. Without this helper the same
// proxy dictionary appeared in three places and drifted independently.
//
// NOTE on the dictionary keys: kCFNetworkProxiesSOCKS* constants are
// macOS-only. iOS accepts the literal string keys below and routes
// URLSession through the in-process socks5 proxy at the given port.

enum SOCKSSession {
    static func make(mode: RouteMode, timeout: TimeInterval = 20) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = timeout
        cfg.timeoutIntervalForResource = timeout + 10
        // #484 was: if mode == .tunnel — make the no-SOCKS VPN invariant explicit.
        if mode.usesSOCKS {
            // #351 was: TunnelManager.socksPort (the *configured* port) — after
            // a live port edit while connected that targeted the wrong port, so
            // keep-alive's verify probe failed and tore down a healthy tunnel.
            // `activeSocksPort` prefers the port the live session actually bound.
            // #445 (audit fix 1): also present the live session's SOCKS
            // credentials. The Go listener REQUIRES RFC1929 user/pass on every
            // SOCKS connection once a username is configured (master
            // internal/client/socks.go) — without these keys, enabling local
            // SOCKS auth made verifyTunnel fail the auth sub-negotiation and
            // every connect ended "Server is not responding" while the tunnel
            // was actually fine.
            cfg.connectionProxyDictionary = proxyDictionary(
                port:        TunnelManager.activeSocksPort,
                credentials: TunnelManager.liveSocksCredentials)
        }
        return URLSession(configuration: cfg)
    }

    /// #445 (audit fix 1): the tunnel-mode proxy dictionary, as a pure function so
    /// the credential plumbing is unit-testable (Tests/SOCKSVerifyTests.swift).
    /// "SOCKSUser"/"SOCKSPassword" are the literal-string forms of
    /// kCFStreamPropertySOCKSUser/Password — like the base keys above, the
    /// kCFNetworkProxies* constants are macOS-only, but iOS accepts the literals.
    static func proxyDictionary(port: Int,
                                credentials: (user: String, pass: String)?) -> [AnyHashable: Any] {
        var dict: [AnyHashable: Any] = [
            "SOCKSEnable": 1,
            "SOCKSProxy" : "127.0.0.1",
            "SOCKSPort"  : port,
        ]
        if let credentials {
            dict["SOCKSUser"]     = credentials.user
            dict["SOCKSPassword"] = credentials.pass
        }
        return dict
    }

    /// Notify TunnelManager that a successful tunnel request just completed.
    /// Call after any successful transfer through the SOCKS5 tunnel so keep-alive
    /// skips its HTTP probe when the tunnel is clearly busy.
    static func noteTunnelActivity(forAtLeast seconds: TimeInterval = 0) {
        TunnelManager.lastTunnelActivityDate = Date().addingTimeInterval(seconds)
    }
}
