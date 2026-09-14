import Foundation
import Network   // #462: IPv4Address / IPv6Address for the SOCKS5 ATYP choice
import NIO

// MARK: - SSHTransport (#462)
//
// Lets VPS administration ride the app's OWN tunnel.
//
// Why this exists
// ---------------
// Russian mobile networks periodically drop to a domain whitelist. During such
// a window the olcrtc tunnel keeps working (the conferencing carrier is on the
// whitelist) but a DIRECT TCP connection to the VPS's SSH port is cut — exactly
// when the owner needs to administer the server. The exit container runs with
// `--network host` and applies no address/port blocklist, so the tunnel can
// already carry an SSH session to the server's own sshd; nothing server-side
// changes. The missing piece was on the phone: `SSHRunner.connect` dialled the
// VPS's public IP and knew nothing about the app's local SOCKS listener.
//
// The shape of the fix
// --------------------
// Citadel's `SSHClient.connect(on channel:settings:)` — the obvious seam —
// cannot be used: it installs its SSH handlers by calling
// `pipeline.syncOperations.addHandlers(...)` synchronously on the CALLER's
// thread, and every one of those calls starts with `eventLoop.assertInEventLoop()`.
// A Swift `async` function never runs on a NIO event-loop thread, so that traps
// in any assertions-enabled build (CI and dev builds are Debug) and is a data
// race in Release. Its `channelHandlers:` parameter is dead code (stored into an
// `internal` settings field that nothing reads), and swift-nio-extras' NIOSOCKS
// client hardcodes `ClientGreeting(methods: [.noneRequired])` plus a
// `precondition(method == .noneRequired)`, so it cannot speak to our listener at
// all once local SOCKS auth is on.
//
// So the Citadel call site stays BYTE-FOR-BYTE what it was; we put a one-shot
// loopback -> SOCKS5 relay in front of it and let Citadel dial
// `127.0.0.1:<ephemeral>`. Everything NIO touches happens inside
// `channelInitializer`s (i.e. on the event loop), so no NIO invariant is broken.
//
// Ordering is load-bearing: `SSHTunnelRelay.open` completes the SOCKS5
// handshake BEFORE returning, so neither the handshake (1–2 RTT) nor the Go
// core's 60 s `sessionReadyTimeout` is inside Citadel's un-raisable 10 s login
// window (`ClientHandshakeHandler(loginTimeout: .seconds(10))`, a literal in
// Citadel 0.12.1 that no setting can change).

// MARK: - SSHTransportError

/// Failures of the tunnelled SSH path. These never reach the UI: a relay that
/// cannot be opened degrades to the direct path (see `SSHRunner.connect`), so
/// these strings only ever appear in the provisioning log — the same convention
/// as the other engineering lines in SSHRunner.
// #462 (audit) was: `Error` — the type defined its own `localizedDescription`,
// which is DEAD through an `Error` existential (Foundation's extension wins and
// prints "The operation couldn't be completed. (…error 3.)"). Conforming to
// `LocalizedError` and supplying `errorDescription` makes the text actually
// reachable, so a future `catch { log(error.localizedDescription) }` cannot
// silently print a useless code.
enum SSHTransportError: LocalizedError, CustomStringConvertible, Equatable {
    /// The local SOCKS listener spoke something that isn't SOCKS5.
    case protocolViolation(String)
    /// The listener demanded RFC1929 user/pass and we hold no credentials.
    case authRequired
    /// The listener rejected the credentials we presented.
    case authRejected
    /// The listener answered `0xFF` — no mutually acceptable auth method.
    case noAcceptableMethod
    /// SOCKS5 CONNECT was refused; the payload is the raw REP byte.
    case connectRejected(UInt8)
    /// A host name / credential is longer than SOCKS5 can encode.
    case fieldTooLong(String)
    /// The listener closed the connection mid-handshake.
    case closedDuringHandshake
    /// The whole open (connect + handshake) exceeded its budget.
    case timedOut
    /// The loopback listener bound but reported no port.
    case noLocalPort

    var description: String {
        switch self {
        case .protocolViolation(let why): return "SOCKS5 protocol violation: \(why)"
        case .authRequired:               return "the local SOCKS proxy requires a username and password"
        case .authRejected:               return "the local SOCKS proxy rejected the credentials"
        case .noAcceptableMethod:         return "the local SOCKS proxy accepted none of the offered auth methods"
        case .connectRejected(let rep):   return "SOCKS5 CONNECT refused: \(SSHSocks5.replyText(rep))"
        case .fieldTooLong(let field):    return "\(field) is too long for SOCKS5 (max 255 bytes)"
        case .closedDuringHandshake:      return "the local SOCKS proxy closed the connection during the handshake"
        case .timedOut:                   return "the local SOCKS proxy did not complete the handshake in time"
        case .noLocalPort:                return "the loopback relay bound no port"
        }
    }

    var errorDescription: String? { description }
}

// MARK: - SSHSocks5 (pure RFC1928 / RFC1929 codec)

/// Byte-level SOCKS5 client codec, split out as PURE builders/parsers so the
/// wire format is unit-testable with zero networking — the same convention as
/// `SSHRunner.parse*` and `HostDisplay`. `Socks5ConnectHandler` below is the
/// only thing here that owns I/O.
///
/// The peculiarity of OUR server that shaped this (olcrtc-upstream
/// `internal/client/socks.go`, `socks5Handshake`): the Go listener DISCARDS the
/// client's offered method list and unconditionally answers `05 02` whenever a
/// username is configured, `05 00` otherwise. So we always offer BOTH methods
/// when we hold credentials, and treat a `02` selection with no credentials as
/// a clean typed error rather than a trap.
enum SSHSocks5 {

    static let version: UInt8       = 0x05
    static let cmdConnect: UInt8    = 0x01
    static let methodNoAuth: UInt8  = 0x00
    static let methodUserPass: UInt8 = 0x02
    static let methodNone: UInt8    = 0xFF
    static let atypIPv4: UInt8      = 0x01
    static let atypDomain: UInt8    = 0x03
    static let atypIPv6: UInt8      = 0x04

    /// Which auth method the server selected.
    enum MethodSelection: Equatable {
        case noAuth
        case userPass
        case unacceptable
    }

    // MARK: Builders

    /// Method-selection greeting. We advertise user/pass only when we actually
    /// hold credentials — offering it unconditionally would let a listener pick
    /// an auth method we cannot satisfy.
    static func greeting(offerUserPass: Bool) -> [UInt8] {
        offerUserPass
            ? [version, 0x02, methodNoAuth, methodUserPass]
            : [version, 0x01, methodNoAuth]
    }

    /// RFC1929 username/password sub-negotiation request.
    static func userPassRequest(user: String, pass: String) throws -> [UInt8] {
        let userBytes = Array(user.utf8)
        let passBytes = Array(pass.utf8)
        guard userBytes.count <= 255 else { throw SSHTransportError.fieldTooLong("SOCKS username") }
        guard passBytes.count <= 255 else { throw SSHTransportError.fieldTooLong("SOCKS password") }
        var out: [UInt8] = [0x01, UInt8(userBytes.count)]
        out.append(contentsOf: userBytes)
        out.append(UInt8(passBytes.count))
        out.append(contentsOf: passBytes)
        return out
    }

    /// CONNECT request. Address type is chosen from the literal form of `host`:
    /// an IPv4 literal becomes ATYP 1, an IPv6 literal ATYP 4, anything else a
    /// length-prefixed domain (ATYP 3). The Go exit accepts all three
    /// (`readSocks5Addr`), so this only avoids a pointless remote DNS lookup for
    /// the common "the VPS is an IP address" case.
    static func connectRequest(host: String, port: Int) throws -> [UInt8] {
        guard (0...65_535).contains(port) else {
            throw SSHTransportError.protocolViolation("port \(port) out of range")
        }
        var out: [UInt8] = [version, cmdConnect, 0x00]
        if let v4 = ipv4Bytes(host) {
            out.append(atypIPv4)
            out.append(contentsOf: v4)
        } else if let v6 = ipv6Bytes(host) {
            out.append(atypIPv6)
            out.append(contentsOf: v6)
        } else {
            let name = Array(host.utf8)
            guard !name.isEmpty else { throw SSHTransportError.protocolViolation("empty host") }
            guard name.count <= 255 else { throw SSHTransportError.fieldTooLong("SOCKS host name") }
            out.append(atypDomain)
            out.append(UInt8(name.count))
            out.append(contentsOf: name)
        }
        out.append(UInt8((port >> 8) & 0xFF))
        out.append(UInt8(port & 0xFF))
        return out
    }

    // MARK: Parsers
    //
    // All three return `nil` for "need more bytes" (TCP gives no message
    // boundaries) and throw only for a genuinely malformed stream.

    static func parseMethodSelection(_ bytes: [UInt8]) throws -> MethodSelection? {
        guard bytes.count >= 2 else { return nil }
        guard bytes[0] == version else {
            throw SSHTransportError.protocolViolation("greeting version \(bytes[0])")
        }
        switch bytes[1] {
        case methodNoAuth:   return .noAuth
        case methodUserPass: return .userPass
        case methodNone:     return .unacceptable
        default:
            throw SSHTransportError.protocolViolation("unsupported auth method \(bytes[1])")
        }
    }

    /// RFC1929 reply: `01 STATUS`, status 0 == success. Consumes 2 bytes.
    static func parseAuthReply(_ bytes: [UInt8]) throws -> Bool? {
        guard bytes.count >= 2 else { return nil }
        guard bytes[0] == 0x01 else {
            throw SSHTransportError.protocolViolation("auth reply version \(bytes[0])")
        }
        return bytes[1] == 0x00
    }

    /// CONNECT reply: `05 REP RSV ATYP BND.ADDR BND.PORT`. The bound-address
    /// length is variable, so the caller needs `consumed` to know where the
    /// relayed stream begins. RSV is not validated — nothing depends on it and
    /// being permissive costs nothing.
    static func parseConnectReply(_ bytes: [UInt8]) throws -> (consumed: Int, reply: UInt8)? {
        guard bytes.count >= 4 else { return nil }
        guard bytes[0] == version else {
            throw SSHTransportError.protocolViolation("reply version \(bytes[0])")
        }
        let addrLen: Int
        switch bytes[3] {
        case atypIPv4: addrLen = 4
        case atypIPv6: addrLen = 16
        case atypDomain:
            guard bytes.count >= 5 else { return nil }
            addrLen = 1 + Int(bytes[4])
        default:
            throw SSHTransportError.protocolViolation("reply address type \(bytes[3])")
        }
        let total = 4 + addrLen + 2
        guard bytes.count >= total else { return nil }
        return (consumed: total, reply: bytes[1])
    }

    /// Human text for a REP byte — log-only, English (engineering line).
    static func replyText(_ rep: UInt8) -> String {
        switch rep {
        case 0x00: return "succeeded"
        case 0x01: return "general SOCKS server failure"
        case 0x02: return "connection not allowed by ruleset"
        case 0x03: return "network unreachable"
        case 0x04: return "host unreachable"
        case 0x05: return "connection refused"
        case 0x06: return "TTL expired"
        case 0x07: return "command not supported"
        case 0x08: return "address type not supported"
        default:   return "unknown reply \(rep)"
        }
    }

    // MARK: Address literals
    //
    // `Network`'s parsers rather than raw `inet_pton`: no C interop, and the same
    // types the rest of the app already uses for addresses. Both return the wire
    // representation (network byte order) directly, which is what SOCKS5 wants.

    static func ipv4Bytes(_ text: String) -> [UInt8]? {
        // Apple's `IPv4Address(_:)` follows `inet_aton` and accepts abbreviated
        // forms like "1.2.3" (read as 1.2.0.3), so require the dotted quad —
        // exactly the guard `IPChecker.isValidIP` already applies. Without it a
        // short hostname could be mis-encoded as an address literal, and the exit
        // would dial the wrong machine instead of resolving the name.
        guard text.split(separator: ".", omittingEmptySubsequences: false).count == 4,
              let address = IPv4Address(text) else { return nil }
        return Array(address.rawValue)
    }

    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        guard let address = IPv6Address(text) else { return nil }
        return Array(address.rawValue)
    }
}

// MARK: - SSHTransport (route selection)

/// Decides — and only decides — whether an SSH operation goes through the app's
/// own tunnel or straight out of the device.
enum SSHTransport {

    /// Where the next SSH dial should go. `.tunnel` carries the SOCKS port to
    /// relay through, so the decision and the port it implies can never drift.
    enum Route: Equatable, Sendable, CustomStringConvertible {
        case direct
        case tunnel(port: Int)

        var isTunnel: Bool {
            if case .tunnel = self { return true }
            return false
        }

        /// User-visible route name for the connection log. Localized at the point
        /// of use (never cached) — `routingViaTunnel` / `routingDirect` already
        /// exist for the IP-check and speed-test route labels, so this adds no
        /// new L10n keys.
        var label: String {
            switch self {
            case .direct: return L10n.routingDirect.localized()
            case .tunnel: return L10n.routingViaTunnel.localized()
            }
        }

        /// Engineering rendering for non-localized log lines.
        var description: String {
            switch self {
            case .direct:           return "direct"
            case .tunnel(let port): return "tunnel(socks:\(port))"
            }
        }
    }

    // MARK: The pure decision

    /// PURE: is the in-app SOCKS proxy REALLY there to carry an SSH session?
    ///
    /// The owner's rule, literally: "SSH should only be forced through the
    /// tunnel when the tunnel is actually active. If the VPN/tunnel is not
    /// active then it is not active." So all three must hold:
    ///
    ///   * `state == .connected` — NOT `.connecting`. `preflight` publishes
    ///     `boundPort` while still `.connecting`, before a single byte has
    ///     crossed the tunnel; `.connected` is reached only after `verifyTunnel`
    ///     got an HTTP 200 through that very port.
    ///   * `mode == .proxy` — see below.
    ///   * a non-nil, non-zero bound port — the listener the engine actually holds.
    ///
    /// VPN mode is deliberately `.direct`: the packet-tunnel appex installs a
    /// DEFAULT route (`NEIPv4Route.default()`, no excludedRoutes) and there is
    /// no in-app SOCKS listener at all, so a plain direct dial to the VPS is
    /// ALREADY inside the tunnel. Relaying it would mean routing through a
    /// socket that does not exist.
    ///
    /// `.waitingForNetwork` and `.failed` are sessions that are down; they get
    /// `.direct` for the same reason `.connecting` does.
    static func route(state: ConnectionState, mode: TunnelMode, boundPort: Int?) -> Route {
        guard mode == .proxy, state == .connected, let port = boundPort, port > 0 else {
            return .direct
        }
        return .tunnel(port: port)
    }

    /// PURE: the route for `attempt` of `SSHRunner.connect`'s existing 2-attempt
    /// retry loop, given what the previous attempt used and what is available now.
    ///
    /// This is the "fallback, both ways, but only once" rule:
    ///   * attempt 1 always takes whatever is available (tunnel when live);
    ///   * a failed TUNNEL attempt falls back to direct;
    ///   * a failed DIRECT attempt retries through the tunnel — but only if one
    ///     genuinely exists now (`available.isTunnel`), never speculatively.
    /// There is no third attempt, so neither fallback can loop, and the existing
    /// retry count / 4 s backoff are untouched.
    static func nextRoute(attempt: Int, previous: Route?, available: Route) -> Route {
        guard attempt > 1, let previous else { return available }
        switch previous {
        case .tunnel:
            return .direct
        case .direct:
            return available.isTunnel ? available : .direct
        }
    }

    // MARK: Live snapshot

    /// The route the tunnel state machine says is available RIGHT NOW.
    ///
    /// State + mode + bound port are read in ONE MainActor hop so the three can
    /// never disagree (`activeMode` and `state` are MainActor-isolated on
    /// `TunnelManager`; the nonisolated `liveBoundPort` mirror is not a liveness
    /// signal on its own — it is non-nil throughout `.connecting` too).
    ///
    /// `TunnelManager.shared` is weak and last-init-wins. A nil manager (unit
    /// tests, previews, a torn-down app) yields `.direct`, which is the honest
    /// answer: no manager, no tunnel.
    static func currentRoute() async -> Route {
        await MainActor.run { () -> Route in
            guard let manager = TunnelManager.shared else { return .direct }
            return route(state: manager.state,
                         mode: manager.activeMode,
                         boundPort: manager.boundPort)
        }
    }

    // MARK: Reachability

    /// Reachability probe that honours the SSH route.
    ///
    /// A direct `NetPing.tcp` to the VPS's public port 22 is exactly what a
    /// whitelist window kills, so probing that way would veto an SSH path that
    /// works. When the tunnel is live this opens a one-shot relay (a real SOCKS5
    /// CONNECT to host:port through the tunnel) and closes it again; a `0x00`
    /// reply proves the whole path end to end.
    ///
    /// A tunnel probe that fails falls back to the direct probe before
    /// answering (#462 audit) — the verdict gates real aborts, so it must mean
    /// "no path reaches this VPS", not "the tunnel path did not work".
    ///
    /// `viaTunnel` is returned so callers can say which path they measured.
    static func probeReachable(host: String, port: Int, timeout: TimeInterval = 5)
        async -> (success: Bool, ms: Double?, viaTunnel: Bool)
    {
        let available = await currentRoute()
        guard case .tunnel(let socksPort) = available else {
            let result = await NetPing.tcp(host: host,
                                           port: UInt16(clamping: port),
                                           timeout: timeout)
            return (success: result.success, ms: result.ms, viaTunnel: false)
        }
        let started = Date()
        do {
            let relay = try await SSHTunnelRelay.open(targetHost: host,
                                                      targetPort: port,
                                                      socksPort: socksPort,
                                                      credentials: TunnelManager.liveSocksCredentials,
                                                      timeout: timeout)
            relay.close()
            return (success: true,
                    ms: Date().timeIntervalSince(started) * 1000,
                    viaTunnel: true)
        } catch {
            // #462 (audit): a failed tunnel probe must never be reported as
            // "this server is unreachable" — that verdict aborts an install
            // mid-flight (pollLoop's probeFailureAbortThreshold) and rejects
            // every op (Provisioner.ensureReachable). The tunnel path can fail
            // on its own (stream refused, listener busy, 15 s handshake budget)
            // while the VPS answers a direct dial perfectly well, so fall back
            // to the direct probe before answering — the same "both ways, once"
            // rule `nextRoute` applies to the dial itself.
            // #462 was: `return (success: false, ms: nil, viaTunnel: true)`
            // #470: say so. This probe decides aborts, and a log that read
            // "reachable (direct)" or "not responding" with no trace of the
            // tunnel attempt could not tell "tunnel never used" from "tunnel
            // refused" (REP byte, auth rejection, handshake timeout).
            // `SSHTransportError` descriptions carry no credentials; the port is
            // the only detail — the same rule as `SSHRunner.openRelay`.
            let detail = "\(error)"
            await MainActor.run {
                LogStore.shared.log(.provisioning,
                    "⚠ tunnel probe failed (SOCKS 127.0.0.1:\(socksPort)): \(detail) — probing direct")
            }
            let result = await NetPing.tcp(host: host,
                                           port: UInt16(clamping: port),
                                           timeout: timeout)
            return (success: result.success, ms: result.ms, viaTunnel: false)
        }
    }
}

// MARK: - SSHHandshakeSignal

/// Fire-once completion for the SOCKS handshake. Completing a NIO promise twice
/// traps exactly like resuming a continuation twice, and two racers can settle
/// this one (the handler on the event loop, `SSHTunnelRelay.open` on the calling
/// task), so the existing `ContinuationGate` (#400) guards both sites.
final class SSHHandshakeSignal: @unchecked Sendable {
    private let gate = ContinuationGate()
    private let promise: EventLoopPromise<Void>

    init(promise: EventLoopPromise<Void>) { self.promise = promise }

    var future: EventLoopFuture<Void> { promise.futureResult }

    func succeed() { if gate.fire() { promise.succeed(()) } }
    func fail(_ error: Error) { if gate.fire() { promise.fail(error) } }
}

// MARK: - SSHRelayAcceptGate

/// One-shot accept guard for the loopback listener.
///
/// The relay exists to carry exactly ONE SSH connection. Loopback is device-wide
/// on iOS, so the listener is single-use and closes itself the instant the
/// expected dial lands: the exposure window is the few milliseconds between
/// `open()` returning and Citadel connecting.
final class SSHRelayAcceptGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var listener: Channel?

    /// Called once, right after `bind` succeeds, so `claim()` can close it.
    func attach(_ channel: Channel) {
        lock.lock()
        listener = channel
        lock.unlock()
    }

    /// True for the first caller only; also stops accepting.
    func claim() -> Bool {
        lock.lock()
        if claimed {
            lock.unlock()
            return false
        }
        claimed = true
        let channel = listener
        lock.unlock()
        channel?.close(promise: nil)
        return true
    }
}

// MARK: - Socks5ConnectHandler

/// Drives the SOCKS5 handshake on the relay's outbound leg, then gets removed.
///
/// It is deliberately the ONLY handler on that channel until the handshake is
/// done, so bytes the target sends immediately after CONNECT succeeds (an sshd
/// banner arrives unprompted) are buffered here and handed downstream in
/// `removeHandler` — after the glue handler has been spliced in behind it.
/// Dropping them would corrupt the SSH version exchange.
final class Socks5ConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private enum Step { case greeting, auth, request, done }

    private let targetHost: String
    private let targetPort: Int
    private let credentials: (user: String, pass: String)?
    private let signal: SSHHandshakeSignal

    private var step: Step = .greeting
    private var pending: [UInt8] = []
    private var started = false

    init(targetHost: String, targetPort: Int,
         credentials: (user: String, pass: String)?,
         signal: SSHHandshakeSignal) {
        self.targetHost  = targetHost
        self.targetPort  = targetPort
        self.credentials = credentials
        self.signal      = signal
    }

    // MARK: Lifecycle

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { begin(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        begin(context: context)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        // No-op once the handshake has been settled (the gate is fire-once), so
        // this only reports a listener that hung up mid-negotiation.
        signal.fail(SSHTransportError.closedDuringHandshake)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        signal.fail(error)
        context.close(promise: nil)
    }

    /// Splices the buffered post-CONNECT bytes into the pipeline on the way out.
    /// By the time the relay removes this handler the glue handler is already
    /// installed behind it, so `fireChannelRead` reaches the SSH client.
    func removeHandler(context: ChannelHandlerContext,
                       removalToken: ChannelHandlerContext.RemovalToken) {
        if !pending.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: pending.count)
            buffer.writeBytes(pending)
            pending.removeAll()
            context.fireChannelRead(self.wrapInboundOut(buffer))
            context.fireChannelReadComplete()
        }
        context.leavePipeline(removalToken: removalToken)
    }

    // MARK: Data

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = self.unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            pending.append(contentsOf: bytes)
        }
        guard step != .done else { return }   // buffering for the glue handler
        do {
            try advance(context: context)
        } catch {
            signal.fail(error)
            context.close(promise: nil)
        }
    }

    // MARK: Machine

    private func begin(context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        write(SSHSocks5.greeting(offerUserPass: credentials != nil), context: context)
    }

    private func write(_ bytes: [UInt8], context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(NIOAny(buffer), promise: nil)
    }

    private func advance(context: ChannelHandlerContext) throws {
        while true {
            switch step {
            case .greeting:
                guard let selection = try SSHSocks5.parseMethodSelection(pending) else { return }
                pending.removeFirst(2)
                switch selection {
                case .noAuth:
                    // Our listener answers `05 00` only when no username is set,
                    // so holding unused credentials here is fine — just connect.
                    try sendConnect(context: context)
                case .userPass:
                    guard let credentials else { throw SSHTransportError.authRequired }
                    write(try SSHSocks5.userPassRequest(user: credentials.user,
                                                        pass: credentials.pass),
                          context: context)
                    step = .auth
                case .unacceptable:
                    throw SSHTransportError.noAcceptableMethod
                }
            case .auth:
                guard let accepted = try SSHSocks5.parseAuthReply(pending) else { return }
                pending.removeFirst(2)
                guard accepted else { throw SSHTransportError.authRejected }
                try sendConnect(context: context)
            case .request:
                guard let reply = try SSHSocks5.parseConnectReply(pending) else { return }
                pending.removeFirst(reply.consumed)
                guard reply.reply == 0x00 else {
                    throw SSHTransportError.connectRejected(reply.reply)
                }
                step = .done
                signal.succeed()
                return
            case .done:
                return
            }
        }
    }

    private func sendConnect(context: ChannelHandlerContext) throws {
        write(try SSHSocks5.connectRequest(host: targetHost, port: targetPort), context: context)
        step = .request
    }
}

// MARK: - SSHRelayGlueHandler
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//
// Vendored from apple/swift-nio-ssh `Sources/NIOSSHClient/GlueHandler.swift`,
// renamed to avoid confusion with the same-named type Citadel ships. Citadel's
// own copy is `internal` AND neutered — `partnerWriteEOF()` and
// `partnerCloseFull()` have their bodies commented out, so channels glued with
// it never close. This one closes properly.

final class SSHRelayGlueHandler {
    private var partner: SSHRelayGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead: Bool = false

    private init() {}

    static func matchedPair() -> (SSHRelayGlueHandler, SSHRelayGlueHandler) {
        let first  = SSHRelayGlueHandler()
        let second = SSHRelayGlueHandler()
        first.partner  = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) {
        self.context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        self.context?.flush()
    }

    private func partnerWriteEOF() {
        self.context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        self.context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if self.pendingRead {
            self.pendingRead = false
            self.context?.read()
        }
    }

    private var partnerWritable: Bool {
        self.context?.channel.isWritable ?? false
    }
}

extension SSHRelayGlueHandler: ChannelDuplexHandler {
    typealias InboundIn   = NIOAny
    typealias OutboundIn  = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        self.partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            // We have read EOF: half-close the partner's write side.
            self.partner?.partnerWriteEOF()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            self.partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner = self.partner, partner.partnerWritable {
            context.read()
        } else {
            self.pendingRead = true
        }
    }
}

// MARK: - SSHTunnelRelay

/// A single-use `127.0.0.1:<ephemeral>` -> SOCKS5 -> `<vps>:<ssh port>` relay.
///
/// `open()` returns only after the SOCKS5 CONNECT has SUCCEEDED, so by the time
/// Citadel dials the loopback port the path to sshd is already established. That
/// is what keeps the SOCKS handshake (and the Go core's 60 s
/// `sessionReadyTimeout`) out of Citadel's hardcoded 10 s login window.
///
/// Threading: every relay shares ONE single-threaded event loop, so the accepted
/// child channel and the outbound channel are always on the same loop — the glue
/// handler is not safe across loops. Citadel keeps using its own
/// `MultiThreadedEventLoopGroup.singleton`, so the SSH session and this byte pump
/// never share a loop and cannot starve each other.
final class SSHTunnelRelay: @unchecked Sendable {

    /// Named so the child-channel initializer can remove the SOCKS handler
    /// without capturing the (non-Sendable) handler object.
    private static let socksHandlerName = "olcrtc.ssh.socks5"

    /// Process-lifetime loop shared by every relay. One thread is enough because
    /// nothing on it ever blocks — a relay only pumps bytes between two sockets.
    /// (#462 audit: relays CAN overlap. `Provisioner` does not serialise itself;
    /// `ServersView.run`/`actionsDisabled` serialise that screen's ops, but
    /// LogsView owns a second `Provisioner` whose op can run concurrently.)
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    /// The loopback port Citadel must dial.
    let localPort: Int
    /// The in-app SOCKS port this relay rides (logging / diagnostics only).
    let socksPort: Int

    private let listener: Channel
    private let outbound: Channel
    private let lock = NSLock()
    private var isClosed = false

    /// #462 (audit): true once the SOCKS leg to the VPS has gone away, i.e. the
    /// tunnel this SSH session was riding collapsed under it. That is exactly
    /// what an op which restarts the exit container (`reconfigure`, `update`,
    /// `rotateKey`, `stop`, `uninstall`, `reboot`) does to itself when it runs
    /// through the very tunnel that container terminates — without this flag the
    /// failure surfaces as a bare Citadel channel error. `Channel.isActive` is
    /// documented thread-safe, so this is readable from any task.
    var isTransportDown: Bool { !outbound.isActive }

    private init(localPort: Int, socksPort: Int, listener: Channel, outbound: Channel) {
        self.localPort = localPort
        self.socksPort = socksPort
        self.listener  = listener
        self.outbound  = outbound
    }

    /// Opens the SOCKS leg, then binds the one-shot loopback listener.
    ///
    /// - Parameter timeout: budget for connect + handshake. The Go listener
    ///   allows 30 s for negotiation and waits up to 60 s for a live tunnel
    ///   session before answering "host unreachable"; we refuse to sit through
    ///   either, because falling back to the direct path beats stalling on a
    ///   route we are only guessing at.
    static func open(targetHost: String,
                     targetPort: Int,
                     socksPort: Int,
                     credentials: (user: String, pass: String)?,
                     timeout: TimeInterval = 15) async throws -> SSHTunnelRelay {
        let loop   = group.next()
        let signal = SSHHandshakeSignal(promise: loop.makePromise(of: Void.self))
        let deadline = loop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
            signal.fail(SSHTransportError.timedOut)
        }

        // Step 1 — the outbound leg, with the handshake completed BEFORE we
        // return so it never lands inside Citadel's login window.
        let client = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    Socks5ConnectHandler(targetHost: targetHost,
                                         targetPort: targetPort,
                                         credentials: credentials,
                                         signal: signal),
                    name: socksHandlerName)
            }

        let outbound: Channel
        do {
            outbound = try await client.connect(host: "127.0.0.1", port: socksPort).get()
        } catch {
            // The handler may never have been installed (the initializer runs only
            // once the socket exists), so settle the signal here — a NIO promise
            // must never be left unfulfilled. The gate makes this a no-op if the
            // handler already settled it.
            deadline.cancel()
            signal.fail(error)
            throw error
        }

        do {
            try await signal.future.get()
        } catch {
            deadline.cancel()
            outbound.close(promise: nil)
            throw error
        }
        deadline.cancel()

        // Step 2 — the loopback listener. Single-use: the first accepted child is
        // glued to the (already connected) outbound leg, the SOCKS handler is
        // then removed — flushing anything the target already sent — and the
        // listener closes itself.
        let gate = SSHRelayAcceptGate()
        let server: Channel
        do {
            server = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 1)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { child in
                    guard gate.claim() else { return child.close() }
                    let (childSide, outboundSide) = SSHRelayGlueHandler.matchedPair()
                    return child.pipeline.addHandler(childSide).flatMap {
                        outbound.pipeline.addHandler(outboundSide)
                    }.flatMap {
                        outbound.pipeline.removeHandler(name: socksHandlerName)
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
        } catch {
            outbound.close(promise: nil)
            throw error
        }
        gate.attach(server)

        guard let port = server.localAddress?.port else {
            server.close(promise: nil)
            outbound.close(promise: nil)
            throw SSHTransportError.noLocalPort
        }
        return SSHTunnelRelay(localPort: port, socksPort: socksPort,
                              listener: server, outbound: outbound)
    }

    /// Idempotent teardown. Closing the outbound leg drives the glue handler's
    /// `channelInactive`, which closes the accepted child too.
    func close() {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        listener.close(promise: nil)
        outbound.close(promise: nil)
    }
}
