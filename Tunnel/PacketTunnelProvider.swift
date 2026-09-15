import Foundation
import NetworkExtension
import Mobile

// MARK: - PacketTunnelProvider (#vpn)
//
// The system-VPN provider (target olcrtc-tunnel, NSExtensionPrincipalClass).
// It runs the ENTIRE olcrtc Go core in the extension process — the app can be
// suspended while the tunnel runs, and NEPacketTunnelFlow packets arrive here —
// plus the tunstack tun2socks layer from the same Mobile.xcframework:
//
//   packetFlow.readPackets ──▶ TunstackTunnel.writePacket ──▶ lwIP ──▶
//   SOCKS5 CONNECT to 127.0.0.1:<socksPort> (the in-process core listener)
//   ──▶ olcrtc carrier ▶ … and back via TunWriter ──▶ packetFlow.writePackets
//
// Loop avoidance: iOS routes provider-process-originated sockets (pion
// ICE/DTLS, the core's protected DNS) to the underlying interface, NOT into
// this tunnel — so there are NO excludedRoutes and includeAllNetworks is
// NEVER set (it would pull our own traffic into the tunnel and loop).
//
// Memory: the extension lives under a ~50 MB jetsam cap. Before the core
// starts we set a 30 MiB Go soft memory limit + GC at 20% (shim
// MobileTuneForNetworkExtension) and shrink smux receive buffers from
// 32 MiB/4 MiB to 8 MiB/1 MiB (MobileSetMuxBuffers); memory-pressure events
// trigger MobileFreeOSMemory.
//
// UDP: the core's SOCKS5 is CONNECT-only, so no UDP crosses the tunnel.
// tunstack's dnstruncate answers UDP DNS with the TC bit → the OS resolver
// retries DNS over TCP:53 through the tunnel; all other UDP is dropped
// (QUIC falls back to TCP; mandatory-UDP apps do not work in VPN mode).
//
// NAMING CAUTION — this machine cannot run gomobile; verify the generated
// selector names against Mobile.objc.h on the first CI bind:
//   MobileNew() -> MobileRuntime?                      (mobile.New)
//   MobileSetLogWriter(MobileLogWriterProtocol?)       (logbridge shim)
//   MobileTuneForNetworkExtension(Int64)               (memory shim)
//   MobileSetMuxBuffers(Int, Int)                      (memory shim)
//   MobileFreeOSMemory()                               (memory shim)
//   TunstackNewTunnel(String?, Int, TunstackTunWriterProtocol?, NSErrorPointer) -> TunstackTunnel?
//   TunstackTunnel.writePacket(Data?) throws           (WritePacket([]byte) error)
//   TunstackTunnel.close() throws / rxBytes() -> Int64 / txBytes() -> Int64
//   TunstackTunWriterProtocol { func writePacket(_ p: Data?) }
//   runtime.set*(...) throws for error-returning Go setters; state()/isRunning()

final class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Matches OlcrtcEngine.stopTimeoutMs — Runtime.Stop blocks until the
    /// generation's goroutine exits or this many ms pass.
    private static let stopTimeoutMs = 5_000

    /// Serialises start/stop/teardown so completion-handler callbacks and the
    /// system's stop cannot race the blocking Go calls.
    private let workQueue = DispatchQueue(label: "io.github.hotelk52339.olcrtc-ios.tunnel.work")

    private var runtime: MobileRuntime?
    private var tunnel: TunstackTunnel?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var startedAt: Date?

    private let logBuffer = LogRingBuffer(capacity: 400)
    private let logCapture = ExtensionLogCapture()

    // MARK: Start

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let dict = proto.providerConfiguration,
              let config = VPNConfig(providerConfiguration: dict) else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        // boc #484: owner-selected app-only VPN launch (D14). The saved profile
        // deliberately omits credentials; external starts must explain how to
        // restore them, not report that the saved connection's room key is bad.
        guard !config.keyHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completionHandler(NSError(
                domain: "io.github.hotelk52339.olcrtc-ios.tunnel",
                code: 48414,
                userInfo: [NSLocalizedDescriptionKey:
                    // #485: extension resources are isolated from the app's
                    // L10n tables; use its own localized bundle, never app state.
                    Self.localizedMessage("vpn.startRequiresApp", language: dict["uiLanguage"] as? String)]))
            return
        }
        // eoc #484
        // videochannel runs a real 1080p VP8 codec (~16 MiB decoder queue per
        // remote track) — it cannot fit the extension's memory cap. VPN mode
        // allows datachannel / vp8channel / seichannel only (the latter two
        // are header-wrapping fakes with no codec).
        guard config.transport != "videochannel" else {
            logBuffer.append("startTunnel rejected: videochannel transport exceeds the Network Extension memory budget")
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        // boc #484: IPv6 is intentionally fail-closed in the packet pump.
        // #484 was: every accepted DNS setting was installed and could leave a
        // Connected device unable to resolve anything. Reject before starting
        // Go or installing routes; never remove ::/0 to make DNS appear to work.
        guard config.supportsPacketDNS else {
            logBuffer.append("startTunnel rejected: system DNS must be an IPv4 literal on port 53; IPv6 DNS remains supported for proxy/core resolution")
            // #485 was: generic configurationInvalid without an actionable cause.
            completionHandler(NSError(
                domain: "io.github.hotelk52339.olcrtc-ios.tunnel",
                code: 48422,
                userInfo: [NSLocalizedDescriptionKey:
                    Self.localizedMessage("vpn.unsupportedDNS", language: dict["uiLanguage"] as? String)]))
            return
        }
        // eoc #484
        workQueue.async { self.doStart(config, completionHandler) }
    }

    // boc #488: the app's selected language can differ from the device language.
    // Pass only an allowlisted language code in nonsecret profile metadata;
    // old profiles without it retain the extension's normal system localization.
    private static func localizedMessage(_ key: String, language: String?) -> String {
        var resources = Bundle.main
        if let language, ["en", "ru", "fr"].contains(language),
           let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let localized = Bundle(path: path) {
            resources = localized
        }
        return resources.localizedString(forKey: key, value: nil, table: nil)
    }
    // eoc #488

    private func doStart(_ config: VPNConfig, _ completionHandler: @escaping (Error?) -> Void) {
        // Memory knobs FIRST: the smux limits are read when a session is
        // created, and the GC limit should precede any real allocation.
        MobileTuneForNetworkExtension(30 << 20)      // 30 MiB Go soft limit + GC 20%
        MobileSetMuxBuffers(8 << 20, 1 << 20)        // smux session 8 MiB, stream 1 MiB

        // Core log lines -> in-extension ring buffer (served via
        // handleAppMessage "logs"; no App Group in v1, by design).
        // Capture the buffer, not self: logCapture is retained by the Go side
        // via MobileSetLogWriter and must not create a cycle through self.
        logCapture.onLog = { [buffer = logBuffer] line in buffer.append(line) }
        MobileSetLogWriter(logCapture)

        guard let rt = MobileNew() else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }

        // Setter sequence mirrors OlcrtcEngine.start (App/Core/TunnelEngine
        // .swift); master's setters VALIDATE and THROW — surface the Go error.
        do {
            try rt.setDNS(config.dns)
            try rt.setProvider(config.carrier)      // jitsi | telemost | wbstream | none
            try rt.setTransport(config.transport)
            try rt.setRoom(config.roomID)           // ID or URL, verbatim
            rt.setDeviceID(config.clientID)
            try rt.setKey(config.keyHex)
            if config.transport == "vp8channel", let fps = config.vp8FPS, let batch = config.vp8Batch {
                try rt.setVP8Options(fps, batchSize: batch)
                // nil overrides fall through to the core defaults (30 / 64).
            }
            if config.transport == "seichannel" {
                try rt.setSEIOptions(config.seiFPS, batchSize: config.seiBatch,
                                     fragmentSize: config.seiFrag,
                                     ackTimeoutMillis: config.seiACK)
            }
            // Same gentle liveness values as proxy mode (#230).
            try rt.setLivenessOptions(30_000, timeoutMillis: 10_000, failures: 3)
            // Unconditional: empty clears a previous token (same rule as #436).
            rt.setProviderToken(config.wbToken)
            // Loopback listener. NO SOCKS credentials: the core requires them
            // only for non-loopback binds, and the tunstack SOCKS client
            // deliberately sends none.
            // #470 was: "private to this process" — loopback is DEVICE-wide on
            // iOS: any app can dial 127.0.0.1:<socksPort> while the tunnel is
            // up (and gains nothing by it — every app's traffic already rides
            // the tunnel), and a listener another process already holds on
            // that port fails the bind inside the run goroutine, which
            // `waitReady` below reports with the Go text ("address already in
            // use") into the ring buffer.
            try rt.setSocksListenHost("127.0.0.1")
            try rt.setSocksPort(config.socksPort)
        } catch {
            logBuffer.append("configure failed: \(error.localizedDescription)")
            completionHandler(error)
            return
        }

        do {
            try rt.start()                          // spawns the run goroutine
        } catch {
            logBuffer.append("start failed: \(error.localizedDescription)")
            completionHandler(error)
            return
        }
        runtime = rt

        // #470: a stop that arrived before this point wins — do not wait at all.
        guard beginWait(on: rt) else {
            logBuffer.append("start abandoned: stopTunnel arrived before the carrier answered")
            try? rt.stop(Self.stopTimeoutMs)
            runtime = nil
            completionHandler(NEVPNError(.connectionFailed))
            return
        }
        do {
            defer { endWait() }   // #470
            // Blocks until the carrier rendezvoused and the SOCKS listener is
            // up (0 -> core default 8 s). Safe to block: we are on workQueue —
            // and interruptible, see `interruptPendingStart` (#470).
            try rt.waitReady(config.waitReadyTimeoutMs)
        } catch {
            logBuffer.append("waitReady failed: \(error.localizedDescription)")
            try? rt.stop(Self.stopTimeoutMs)
            runtime = nil
            completionHandler(error)
            return
        }

        // tun2socks against the now-ready loopback listener.
        let writer = FlowWriter(flow: packetFlow)
        var bindError: NSError?
        guard let tun = TunstackNewTunnel("127.0.0.1", config.socksPort, writer, &bindError) else {
            let error = bindError ?? NEVPNError(.connectionFailed) as NSError
            logBuffer.append("tunstack failed: \(error.localizedDescription)")
            try? rt.stop(Self.stopTimeoutMs)
            runtime = nil
            completionHandler(error)
            return
        }
        tunnel = tun

        // #470 was: `config.dnsHost` — the core's resolver, which the OS's DNS
        // then reached THROUGH the tunnel from the VPS; a carrier-internal
        // preset answered nothing from there. `systemDNS` is the app's choice
        // for this path (VPNConfig.systemResolver).
        setTunnelNetworkSettings(Self.makeSettings(dnsHost: config.systemDNSHost)) { [weak self] settingsError in
            guard let self else {
                completionHandler(NEVPNError(.connectionFailed))
                return
            }
            self.workQueue.async {
                if let settingsError {
                    self.logBuffer.append("setTunnelNetworkSettings failed: \(settingsError.localizedDescription)")
                    self.teardownLocked()
                    completionHandler(settingsError)
                    return
                }
                self.startedAt = Date()
                self.installMemoryPressureHandler()
                // #484 was: startLivenessWatch() only sampled isRunning.
                self.startLivenessWatch(config: config)
                self.startPacketPump()
                self.logBuffer.append("tunnel up: \(config.carrier)/\(config.transport), socks 127.0.0.1:\(config.socksPort)")
                completionHandler(nil)
            }
        }
    }

    // MARK: Network settings

    static func makeSettings(dnsHost: String) -> NEPacketTunnelNetworkSettings {
        // tunnelRemoteAddress is a placeholder — a WebRTC carrier has no
        // stable remote IP. 198.18.0.0/24 is the RFC 2544 benchmark range
        // (collision-free with real LANs).
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]        // 0.0.0.0/0
        // NO excludedRoutes (provider-own sockets bypass the tunnel on iOS)
        // and NEVER includeAllNetworks (would loop our own carrier traffic).
        settings.ipv4Settings = ipv4
        // boc #469 was: no ipv6Settings at all — "v1 is IPv4-only: on v6-capable
        // networks IPv6 traffic BYPASSES the tunnel". On a dual-stack carrier
        // (the norm here) every host with an AAAA record was reached DIRECTLY
        // from the real address while the hero said "everything on this
        // device". Claim the v6 default route so that traffic enters the tunnel
        // — where the pump drops it (AF_INET only) — instead of leaking. A
        // blackhole is honest; a bypass is not. ULA address, RFC 4193.
        let ipv6 = NEIPv6Settings(addresses: ["fd6f:6c63:7274:6300::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]        // ::/0
        settings.ipv6Settings = ipv6
        // eoc #469
        settings.dnsSettings = NEDNSSettings(servers: [dnsHost])  // host only, e.g. "8.8.8.8"
        settings.mtu = NSNumber(value: 1500)
        return settings
    }

    // MARK: Packet pump (OS -> lwIP)

    private func startPacketPump() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            // boc #470: hop onto workQueue — `tunnel` is written there by
            // `teardownLocked`, and this completion runs on the flow's own
            // queue. Reading it here raced the teardown: a stale reference
            // re-armed the pump against a device that was already closed (its
            // `writePacket` failing into `try?`), and it was a Swift data race
            // on a class reference. On the queue, "nil ⇒ stop" is exact.
            // #470 was: guard let self, let tunnel = self.tunnel else { return }
            self.workQueue.async {
                guard let tunnel = self.tunnel else { return }   // stops the pump after teardown
                for (index, packet) in packets.enumerated() {
                    // AF_INET only: IPv6 enters the tunnel (#469 claims ::/0) and
                    // is dropped here — a blackhole, never a bypass.
                    if index < protocols.count, protocols[index].int32Value == AF_INET {
                        try? tunnel.writePacket(packet)
                    }
                }
                self.startPacketPump()
            }
            // eoc #470
        }
    }

    // MARK: Memory pressure

    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: workQueue)
        source.setEventHandler { [weak self] in
            self?.logBuffer.append("memory pressure: releasing Go heap to the OS")
            MobileFreeOSMemory()
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: Stop

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        interruptPendingStart()   // #470: unblock a start still waiting on the carrier
        workQueue.async {
            self.logBuffer.append("stopTunnel: reason \(reason.rawValue)")
            self.teardownLocked()
            completionHandler()
        }
    }

    // boc #470: a stop that arrives while `doStart` is blocked in `waitReady`
    // (up to the user's start timeout — 600 s at the clamp) used to queue
    // BEHIND it on workQueue, together with every app message. "Cancel" a few
    // seconds into a connect against a dead room left the system VPN icon on
    // "connecting" for the rest of that timeout, and a carrier that answered
    // late brought the tunnel UP with the app already showing Disconnected.
    // `Runtime.Stop` cancels the generation, and `WaitReady` returns as soon as
    // the run goroutine exits (ErrStoppedBeforeReady — mobile/runtime.go), so
    // the stop is issued straight away, off the queue, against the runtime the
    // wait holds; the queued teardown then finds a stopped runtime. Lock-
    // guarded: `stopTunnel` runs on the system's thread, not on workQueue.
    private let startLock = NSLock()
    /// The runtime `doStart` is blocked on, while it is.
    private var waitingRuntime: MobileRuntime?
    /// A stop arrived before the wait began (or while it ran) — the start must
    /// not proceed. Cleared by `teardownLocked` so a later start is unaffected.
    private var stopArrivedEarly = false

    /// Registers the runtime a wait is about to block on. False ⇒ a stop
    /// already arrived, and the caller must not wait at all.
    private func beginWait(on rt: MobileRuntime) -> Bool {
        startLock.lock(); defer { startLock.unlock() }
        if stopArrivedEarly { return false }
        waitingRuntime = rt
        return true
    }

    private func endWait() {
        startLock.lock()
        waitingRuntime = nil
        startLock.unlock()
    }

    /// Called from `stopTunnel` before it queues the teardown. The bounded
    /// `stop` runs on a global queue: it blocks up to `stopTimeoutMs`, and the
    /// system's callback thread must not.
    private func interruptPendingStart() {
        startLock.lock()
        stopArrivedEarly = true
        let rt = waitingRuntime
        startLock.unlock()
        guard let rt else { return }
        DispatchQueue.global(qos: .userInitiated).async { try? rt.stop(Self.stopTimeoutMs) }
    }
    // eoc #470

    /// Must run on workQueue. Order matters: close the tun2socks device first
    /// (releases the lwIP per-process singleton and ends the pump), then stop
    /// the Go runtime (blocks up to stopTimeoutMs for the WebRTC teardown).
    // boc #484
    // #484 was: #469 inferred liveness from rt.isRunning() every 5 s. Upstream
    // keeps the run goroutine AND SOCKS listener alive after exhausted handshake
    // retries (internal/client/link.go), so that never detects a stuck session.
    // Runtime exit is still fatal, but only an actual SOCKS->remote DNS exchange
    // resets the data-path failure streak. No URLSession direct fallback, no
    // second runtime, no activity-byte heuristic, no overlapping probes.
    private var livenessTimer: DispatchSourceTimer?
    private var livenessProbe: SOCKSDataPathProbe?
    private var livenessGeneration = UUID()
    private var dataPathHealth = VPNDataPathHealth()

    private func startLivenessWatch(config: VPNConfig) {
        livenessTimer?.cancel()
        livenessGeneration = UUID()
        let generation = livenessGeneration
        livenessProbe?.cancel()
        livenessProbe = nil
        dataPathHealth = VPNDataPathHealth()
        let graceEnds = ProcessInfo.processInfo.systemUptime + VPNDataPathHealth.startupGrace
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        var nextProbeAt = graceEnds
        timer.setEventHandler { [weak self] in
            guard let self, generation == self.livenessGeneration, let rt = self.runtime else { return }
            if !rt.isRunning() {
                self.logBuffer.append("core stopped (\(rt.state())) — cancelling the tunnel so the system knows")
                self.failLiveness()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard now >= nextProbeAt, self.livenessProbe == nil else { return }
            nextProbeAt = now + VPNDataPathHealth.interval
            guard let probe = SOCKSDataPathProbe(port: config.socksPort,
                                                dnsHost: config.systemDNSHost, queue: self.workQueue) else {
                self.failLiveness()
                return
            }
            self.livenessProbe = probe
            probe.start(timeout: VPNDataPathHealth.timeout) { [weak self] success in
                guard let self, generation == self.livenessGeneration else { return }
                self.livenessProbe = nil
                if !success { self.logBuffer.append("data-path probe failed (SOCKS TCP DNS)") }
                if self.dataPathHealth.record(success: success) {
                    self.logBuffer.append("data path unavailable after bounded retries — cancelling tunnel")
                    self.failLiveness()
                }
            }
        }
        timer.resume()
        livenessTimer = timer
    }

    private func failLiveness() {
        // Invalidate FIRST: cancelling an outstanding probe completes it
        // synchronously and must not re-enter failure handling.
        livenessGeneration = UUID()
        livenessTimer?.cancel()
        livenessTimer = nil
        livenessProbe?.cancel()
        livenessProbe = nil
        cancelTunnelWithError(NEVPNError(.connectionFailed))
        teardownLocked() // #484: release the runtime even if the OS does not call stop again.
    }
    // eoc #484

    private func teardownLocked() {
        // #484: late callbacks from a stopped generation cannot cancel its successor.
        livenessGeneration = UUID()
        livenessProbe?.cancel()
        livenessProbe = nil
        livenessTimer?.cancel()          // #469
        livenessTimer = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        try? tunnel?.close()
        tunnel = nil
        try? runtime?.stop(Self.stopTimeoutMs)
        runtime = nil
        startedAt = nil
        // #470: this stop is done with; a later start on this instance must
        // not read it as "arrived early".
        startLock.lock()
        stopArrivedEarly = false
        waitingRuntime = nil
        startLock.unlock()
    }

    // MARK: App messages ("stats" / "logs" from VPNController)
    //
    // "stats" is polled ~1/s by the app while it is connected and the main
    // screen is visible (TunnelThroughputMonitor); it must stay cheap.

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler else { return }
        let message = String(data: messageData, encoding: .utf8) ?? ""
        workQueue.async {
            switch message {
            case "stats":
                completionHandler(self.statsJSON())
            case "logs":
                let text = self.logBuffer.tail().joined(separator: "\n")
                completionHandler(Data(text.utf8))
            default:
                completionHandler(nil)
            }
        }
    }

    /// The "stats" message format version. Mirrors
    /// `VPNController.ProviderStats.version`; bump both on incompatible change.
    static let statsVersion = 1

    /// Runs on workQueue. JSON keys are decoded by `VPNController.ProviderStats`
    /// (app side); `TunnelThroughputMonitor` turns rx/tx deltas into the main
    /// screen's throughput readout, so the counters must stay cumulative.
    private func statsJSON() -> Data? {
        var stats: [String: Any] = [
            "v":            Self.statsVersion,
            "state":        runtime?.state() ?? "idle",
            "running":      runtime?.isRunning() ?? false,
            "tunnelActive": tunnel != nil,
            "monotonicMs":  Int64(ProcessInfo.processInfo.systemUptime * 1000),
        ]
        if let tunnel {
            stats["rxBytes"] = tunnel.rxBytes()   // toward the device
            stats["txBytes"] = tunnel.txBytes()   // from the device
        }
        if let startedAt {
            stats["uptimeSeconds"] = Int(Date().timeIntervalSince(startedAt))
        }
        return try? JSONSerialization.data(withJSONObject: stats)
    }
}

// MARK: - FlowWriter (lwIP -> OS)
//
// Go-side TunWriter: tunstack's read pump calls writePacket from a Go
// goroutine for every outbound IP packet. gomobile only guarantees the Data
// view of a Go []byte for the duration of the call, so copy before handing it
// to writePackets (which retains).
private final class FlowWriter: NSObject, TunstackTunWriterProtocol {
    private let flow: NEPacketTunnelFlow
    init(flow: NEPacketTunnelFlow) { self.flow = flow }

    func writePacket(_ p: Data?) {
        guard let p, !p.isEmpty else { return }
        flow.writePackets([Data(p)], withProtocols: [NSNumber(value: AF_INET)])
    }
}

// MARK: - ExtensionLogCapture
//
// Same bridge as TunnelEngine's LogCapture, but for the extension process
// (each process statically links its own Go runtime, so MobileSetLogWriter
// here only affects this process). Feeds the ring buffer, not LogStore.
private final class ExtensionLogCapture: NSObject, MobileLogWriterProtocol {
    var onLog: ((String) -> Void)?
    func writeLog(_ msg: String?) {
        guard let msg = msg?.trimmingCharacters(in: .whitespacesAndNewlines),
              !msg.isEmpty else { return }
        onLog?(msg)
    }
}

// MARK: - LogRingBuffer
//
// Fixed-capacity, thread-safe line buffer: the Go log writer appends from
// arbitrary goroutine threads, handleAppMessage reads on workQueue.
final class LogRingBuffer {
    private let capacity: Int
    private var lines: [String] = []
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    func tail(_ maxLines: Int = Int.max) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(maxLines))
    }
}
