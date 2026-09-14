import Foundation
import Darwin

// MARK: - PortAvailability
//
// Tiny synchronous probe to check whether the local SOCKS5 port we're about
// to hand to the Go runtime is actually free. Without this, a port conflict
// surfaces as a generic "MobileStart failed" deep in the log with no
// actionable hint — the user just sees "connection failed" and gives up.
//
// We mirror the address+family the Go side binds on (127.0.0.1, AF_INET)
// AND the socket option it binds with.
//
// boc #479 was: "SO_REUSEADDR is intentionally OFF — we want an honest
// 'is anyone here?' answer". That made the probe STRICTER than the thing it
// predicts. The core binds through `(&net.ListenConfig{}).Listen(…)`
// (olcrtc-upstream/internal/client/client.go), and Go's listener path always
// sets SO_REUSEADDR. So a port carrying nothing but sockets in TIME_WAIT —
// the residue of connections that have already closed — reads "busy" here
// while the core would bind it without trouble.
//
// That is not a corner case: an external VPN app pointed at our SOCKS port
// pushes the whole device through it, so a single blip closes hundreds of
// connections at once and leaves a minute of TIME_WAIT behind. The reconnect
// two seconds later then failed with "Port 8808 is busy" about a port nothing
// was listening on.
//
// SO_REUSEADDR does NOT let two listeners share a port (that is SO_REUSEPORT),
// so a real conflict — another process actually listening — still fails the
// bind and is still reported. eoc #479

enum PortAvailability {

    // #300: three explicit outcomes for "what's going on with this port?",
    // replacing a binary isFree() check plus a heuristic in SettingsView
    // ("does the configured port equal the configured tunnel port?") that
    // reported "in use by tunnel" even while the tunnel was disconnected
    // (false positive — #177 partial fix). `.busyOurs` now requires the
    // caller to confirm the *live* tunnel state actually holds this port.
    enum PortState: Equatable {
        /// Nothing is bound to this port — safe to start the tunnel.
        case free
        /// Something other than our tunnel is bound to this port.
        case busyOther
        /// Our own tunnel is currently bound to this port — a reservation,
        /// not a conflict.
        case busyOurs
    }

    /// Classifies `port` into one of three `PortState`s. `tunnelHoldsPort`
    /// must be supplied by the caller from live state — e.g.
    /// `tunnel.boundPort == Int(port)` (#313: the port the tunnel actually
    /// bound, not the live-editable configured one) — this function only
    /// probes the socket, it does not guess at the tunnel's state.
    static func state(_ port: UInt16, tunnelHoldsPort: Bool) -> PortState {
        if tunnelHoldsPort { return .busyOurs }
        return isFree(port) ? .free : .busyOther
    }

    // #308 was: nextFreePort(startingAt:maxAttempts:) + autoRetryAttempts — the
    // connect preflight used to slide the user's busy SOCKS port one slot up and
    // bind the next free one. Removed: the SOCKS port is the contract with external
    // SOCKS clients (Shadowrocket, browsers) configured to point at exactly it, so
    // silently bumping it broke them. The preflight now does a single isFree() check
    // on the configured port and fails fast (reverses closed #108/#148).

    /// Returns a free local TCP port in the IANA ephemeral range
    /// (49152–65535), or nil if none of `maxAttempts` random candidates is
    /// free. Used by the isolated per-connection ping client
    /// (`TunnelManager.ping`, #234) so its temporary SOCKS listener never
    /// collides with the live tunnel's port. Picks at random rather than
    /// walking sequentially so two near-simultaneous pings are unlikely to
    /// land on the same port. The chosen port is bound a moment later by the
    /// Go side; the benign TOCTOU gap means a rare conflict just fails one
    /// ping, which the user can re-trigger.
    static func freeEphemeralPort(maxAttempts: Int = 20) -> UInt16? {
        for _ in 0..<maxAttempts {
            let candidate = UInt16.random(in: 49_152...65_535)
            if isFree(candidate) { return candidate }
        }
        return nil
    }

    /// Returns true if 127.0.0.1:<port> can be bound right now.
    /// Synchronous and fast (microseconds) — safe to call before MobileStart.
    static func isFree(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        // #479: bind with the same option the Go listener uses, so this answers
        // "could the core bind here?" rather than a stricter question.
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
}
