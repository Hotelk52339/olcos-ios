import Foundation
import Mobile

// MARK: - TunnelEngine (#243)
//
// The iOS multi-protocol seam. A `TunnelEngine` is a pluggable tunnel backend.
// `TunnelManager` owns everything generic; the engine owns the protocol's
// native runtime — for olcrtc, the gomobile `MobileRuntime` instance exposed by
// `Mobile.xcframework` (upstream master's mobile.New() API; the old package-
// level Mobile* singleton is gone — #442).
//
// `start` / `ping` / `checkReady` wrap blocking native calls; they are invoked
// from detached tasks, so the protocol is `Sendable` and methods are non-isolated.

struct TunnelEngineError: Error {
    let message: String
    /// #456: a STABLE failure code classified at the throw site, where the raw
    /// (English, core-emitted) text is still available. `message` is the
    /// user-facing string and is often ALREADY LOCALIZED here (connectNoPeer,
    /// errorPortBusy_fmt, errorRuntimeStillStopping), so classifying it later by
    /// English substring silently failed for every non-English user — the health
    /// layer then filed a real failure as "couldn't check". nil ⇒ the receiver
    /// falls back to substring mapping.
    let reason: HealthReason?
    init(_ message: String, reason: HealthReason? = nil) {
        self.message = message
        self.reason = reason
    }
}

struct EngineStartSettings: Sendable {
    let dns:                   String
    let debugEnabled:          Bool
    let timeoutMs:             Int
    let vp8FPS:                Int
    let vp8Batch:              Int
    let localSocksAuthEnabled: Bool
    let localSocksUser:        String
    let localSocksPass:        String
    let isReconnect:           Bool
}

struct EngineProbeSettings: Sendable {
    let timeoutMs: Int
    let pingURL:   String
    let vp8FPS:    Int
    let vp8Batch:  Int
}

protocol TunnelEngine: Sendable {
    func start(_ details: ConnectionDetails, port: Int, settings: EngineStartSettings) async throws
    func stop()
    /// #445 (audit fix 2): is the native runtime currently holding a generation
    /// (starting / running / stopping)? Keep-alive treats `false` as an immediate
    /// hard failure: a dead runtime means the SOCKS listener is gone, and HTTP
    /// probes can't be trusted then — URLSession silently BYPASSES a refusing
    /// proxy and completes requests direct, reporting a false "tunnel OK".
    func isRunning() -> Bool
    func ping(_ details: ConnectionDetails, settings: EngineProbeSettings) async -> PingOutcome
    func checkReady(_ details: ConnectionDetails, settings: EngineProbeSettings) async -> PingOutcome
    func validate(_ details: ConnectionDetails) -> String?
}

extension ConnectionDetails {
    var engine: any TunnelEngine {
        switch self {
        case .olcrtc: return OlcrtcEngine.shared
        }
    }
}

// Bridges the Go log-writer protocol into a Swift closure. The protocol comes
// from the iOS log shim (scripts/mobile-shim/logbridge.go, copied into the
// bound `mobile` package by scripts/build-framework.sh) — upstream master
// removed SetLogWriter, but the core still logs via stdlib `log`, so the shim
// re-adds the hook with the identical gomobile-generated Swift names (#442).
private final class LogCapture: NSObject, MobileLogWriterProtocol {
    var onLog: ((String) -> Void)?
    func writeLog(_ msg: String?) {
        guard let msg = msg?.trimmingCharacters(in: .whitespacesAndNewlines),
              !msg.isEmpty else { return }
        onLog?(msg)
    }
}

// MARK: - OlcrtcEngine
//
// The olcrtc backend. Owns the ONE `MobileRuntime` instance (mirror of the old
// Go singleton: master's Runtime returns ErrAlreadyRunning on a second Start,
// so one instance is the whole-app tunnel). `@unchecked Sendable`: both stored
// properties are assigned once in `init`; the runtime is internally mutex-
// guarded on the Go side (every setter takes r.mu).
final class OlcrtcEngine: TunnelEngine, @unchecked Sendable {
    static let shared = OlcrtcEngine()

    /// Go-side Stop() bound: blocks until the generation's goroutine exits or
    /// this many ms elapse (master's own default is 5 s; 0 would also mean 5 s).
    private static let stopTimeoutMs = 5_000

    private let logCapture = LogCapture()
    /// The master-API runtime. MUST come from `MobileNew()` — `MobileRuntime()`
    /// (gomobile's default ObjC init) wraps a ZERO-VALUE Go struct with no
    /// defaults and no client runner and cannot start a tunnel.
    private let runtime: MobileRuntime

    /// #440: optional observer of every core log line, on the MainActor.
    @MainActor static var coreLineObserver: ((String) -> Void)?

    private init() {
        guard let rt = MobileNew() else {
            fatalError("MobileNew() returned nil — Mobile.xcframework is broken")
        }
        runtime = rt
        logCapture.onLog = { msg in
            Task { @MainActor in
                LogStore.shared.log(.connection, msg)
                Self.coreLineObserver?(msg)   // #440: feed the wedge detector
            }
        }
        // Shim hook: routes the Go core's stdlib log output into LogStore and
        // pins log flags to time-only (master no longer manages flags).
        MobileSetLogWriter(logCapture)
        // Note: master's Runtime installs providers itself (client.RegisterDefaults()
        // inside mobile.New()) — the old MobileSetProviders() call is gone.
    }

    func validate(_ details: ConnectionDetails) -> String? {
        guard case .olcrtc(let params) = details else { return nil }
        return TunnelManager.validate(params: params)
    }

    func stop() {
        // Master Stop(ms) is idempotent (idle/stopped → nil) and blocks until the
        // WebRTC session fully closes (#409 relies on that), throwing only on the
        // stop-timeout — nothing useful to surface, teardown continues in Go.
        try? runtime.stop(Self.stopTimeoutMs)
    }

    /// #445 (audit fix 2): mirrors master `Runtime.IsRunning` (mobile/runtime.go)
    /// — true while a generation is starting/running/stopping. The Go getter takes
    /// the runtime mutex, so this is safe from any thread/actor.
    func isRunning() -> Bool { runtime.isRunning() }

    /// Carrier-aware room-settle (#271) — unchanged.
    static func rejoinSettleMs(carrier: String) -> Int {
        switch carrier.lowercased() {
        case "jitsi", "telemost": return 3000   // XMPP-MUC presence cleanup lag
        default:                  return 1500   // wbstream + anything new
        }
    }

    /// #308 port-busy mapping — unchanged, but note it is now applied to the
    /// waitReady failure (master's Start() returns before the SOCKS bind; a
    /// bind race surfaces from WaitReady via the generation error).
    static func startErrorReason(_ raw: String, port: Int) -> String {
        let lower = raw.lowercased()
        let portBusy = lower.contains("address already in use")
            || lower.contains("eaddrinuse")
            || (lower.contains("bind") && lower.contains("\(port)"))
        return portBusy ? L10n.errorPortBusy_fmt.formatted(port) : raw
    }

    /// #445 (audit fix 7): does a Start failure mean the runtime is still tearing
    /// down the PREVIOUS generation? Matches master's ErrAlreadyRunning text
    /// ("olcRTC runtime is already active", mobile/runtime.go). Deliberately
    /// narrow — "address already in use" (the bind race) must NOT match, it has
    /// its own mapping in `startErrorReason`. Pure → tested
    /// (Tests/TunnelEngineWaitErrorTests.swift).
    static func isAlreadyActiveError(_ raw: String) -> Bool {
        raw.lowercased().contains("already active")
    }

    /// #275: master WaitReady failure classification. The two readiness
    /// sentinels (mobile/runtime.go: ErrReadyTimeout "olcRTC runtime readiness
    /// timed out", ErrStoppedBeforeReady "olcRTC runtime stopped before
    /// becoming ready") mean no peer rendezvoused; anything else is a real
    /// start failure (bind race, provider/auth error) that fell out of the run
    /// goroutine. Pure → tested (Tests/TunnelEngineWaitErrorTests.swift).
    static func isNoPeerWaitError(_ raw: String) -> Bool {
        let l = raw.lowercased()
        return l.contains("readiness timed out") || l.contains("stopped before becoming ready")
    }

    // boc #470
    /// The providerToken setter and `Start()` under ONE lock. Master's `Start()`
    /// copies the SHARED defaults at that instant (mobile/runtime.go), and a
    /// health probe pins ITS node's token on the same defaults from a detached
    /// task (`ping` / `checkReady` below) — a probe landing between the setter
    /// and `Start()` made the live session join with the probed node's token
    /// (a wbstream primary auto-connecting while the launch sweep probes a
    /// telemost sibling ⇒ an empty token ⇒ the carrier rejects the join, and a
    /// manual retry "fixes" it). The probes take the same lock around their
    /// setter, so neither side writes inside the other's window. The reverse
    /// direction — a probe whose own snapshot inside `Ping` sees a token a
    /// concurrent start just set — is left as it was: a probe false-negative,
    /// never a wrong live session.
    private static let tokenLock = NSLock()

    private static func startLocked(_ runtime: MobileRuntime, token: String) throws {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        runtime.setProviderToken(token)
        try runtime.start()
    }

    private static func setTokenLocked(_ runtime: MobileRuntime, _ token: String) {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        runtime.setProviderToken(token)
    }
    // eoc #470

    func start(_ details: ConnectionDetails, port: Int, settings s: EngineStartSettings) async throws {
        guard case .olcrtc(let params) = details else {
            throw TunnelEngineError("internal: OlcrtcEngine received non-olcrtc details", reason: .unknown)   // #456
        }
        await MainActor.run {
            LogStore.shared.log(.connection,
                L10n.connectingOlcrtc_fmt.formatted(params.carrier, params.transport, params.clientID),
                code: .connecting)  // OLC-1002
        }

        // Thread-safety: every MobileRuntime setter takes the runtime's mutex on
        // the Go side (olcrtc master mobile/config.go — r.mu.Lock() in each), so
        // calling from a detached Task is safe without iOS-side serialisation.
        try? runtime.stop(Self.stopTimeoutMs)
        // #271: carrier-aware settle on auto-reconnect — unchanged.
        if s.isReconnect {
            let settleMs = Self.rejoinSettleMs(carrier: params.carrier)
            if settleMs > 0 {
                await MainActor.run {
                    LogStore.shared.log(.connection,
                        L10n.rejoinSettle_fmt.formatted(Double(settleMs) / 1000.0))
                }
                try? await Task.sleep(for: .milliseconds(settleMs))
            }
        }

        runtime.setDebug(s.debugEnabled)
        let vp8FPS   = params.vp8FPS       ?? s.vp8FPS
        let vp8Batch = params.vp8BatchSize ?? s.vp8Batch
        do {
            // Master setters VALIDATE and THROW (old API accepted silently):
            // bad DNS host:port, non-64-hex key, out-of-range port/options all
            // fail here with the Go error text — surface it as the start reason.
            try runtime.setDNS(s.dns)
            try runtime.setProvider(params.carrier)      // jitsi | telemost | wbstream | none
            try runtime.setTransport(params.transport)
            try runtime.setRoom(params.roomID)           // ID or URL, verbatim (old buildRoomURL was identity)
            runtime.setDeviceID(params.clientID)         // old clientID == client.Config.DeviceID
            try runtime.setKey(params.key)
            if params.transport == "vp8channel" {
                try runtime.setVP8Options(vp8FPS, batchSize: vp8Batch)
            }
            if params.transport == "seichannel" {
                // New in master: client-side SEI tuning (old API had no setter).
                try runtime.setSEIOptions(params.seiFPS, batchSize: params.seiBatch,
                                          fragmentSize: params.seiFrag,
                                          ackTimeoutMillis: params.seiACK)
            }
            // #230 native control-stream liveness — same gentle values as before.
            try runtime.setLivenessOptions(30_000, timeoutMillis: 10_000, failures: 3)
            // #436 wbstream account token → master's providerToken. Set
            // UNCONDITIONALLY: empty clears any token left by a previous
            // connection on this shared runtime (fixes the old leak).
            // #470 was: `runtime.setProviderToken(params.wbToken)` here — it now
            // happens inside `startLocked`, in the same critical section as
            // `Start()`, so a probe cannot slip its own token in between.
            let (socksUser, socksPass): (String, String) = s.localSocksAuthEnabled
                ? (s.localSocksUser, s.localSocksPass)
                : (params.socksUser, params.socksPass)
            try runtime.setSocksPort(port)
            try runtime.setSocksCredentials(socksUser, password: socksPass)
        } catch {
            let raw = (error as NSError).localizedDescription
            await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartFailed_fmt.formatted(raw)) }
            throw TunnelEngineError(Self.startErrorReason(raw, port: port),
                                    reason: HealthFailureMapper.reason(forRaw: raw))   // #456
        }

        do {
            // Master Start() validates the config snapshot and spawns the run
            // goroutine — it does NOT block on the bind any more.
            // #470 was: `try runtime.start()`
            try Self.startLocked(runtime, token: params.wbToken)
        } catch {
            let raw = (error as NSError).localizedDescription
            await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartFailed_fmt.formatted(raw)) }
            // #445 (audit fix 7): stop-timeout ghost. The opening
            // `try? runtime.stop(5s)` above swallows ErrStopTimeout, so when the
            // previous generation's WebRTC teardown takes >5 s the runtime is
            // still state=stopping and Start throws ErrAlreadyRunning — which
            // used to surface verbatim as the raw, untranslated "olcRTC runtime
            // is already active". Give the ghost one longer bounded stop and
            // retry Start once; only then give up with a friendly, actionable
            // error. (#333's same-port wait covers only the port symptom — the
            // port can already be free while the goroutine still drains.)
            guard Self.isAlreadyActiveError(raw) else {
                throw TunnelEngineError(Self.startErrorReason(raw, port: port),
                                    reason: HealthFailureMapper.reason(forRaw: raw))   // #456
            }
            await MainActor.run {
                LogStore.shared.log(.connection,
                    "⏳ previous session still shutting down — waiting up to 10 s and retrying start once")
            }
            try? runtime.stop(10_000)
            do {
                // #470 was: `try runtime.start()` — a probe could have re-pinned
                // the token during the 10 s stop above; set it again with Start().
                try Self.startLocked(runtime, token: params.wbToken)
            } catch {
                let raw2 = (error as NSError).localizedDescription
                await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartFailed_fmt.formatted(raw2)) }
                // #470: this is OUR teardown still draining, not a measurement of
                // the node. `.timedOut` is a node-level verdict (not inconclusive),
                // so the chip went red "failed just now" and the hero headlined
                // "Timed out — the test ran out of time" over the actionable
                // message. `.unknown` files it as "couldn't check" (action: retry).
                // #470 was: `reason: .timedOut`
                throw TunnelEngineError(L10n.errorRuntimeStillStopping.localized(), reason: .unknown)   // #456
            }
        }
        await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartOK.localized(), code: .nativeStartOK) }  // OLC-1003

        do {
            try runtime.waitReady(s.timeoutMs)
        } catch {
            let raw = (error as NSError).localizedDescription
            try? runtime.stop(Self.stopTimeoutMs)
            let diagnostic = await MainActor.run { () -> String in
                LogStore.shared.log(.connection, L10n.waitReadyFailed_fmt.formatted(raw))
                if Self.isNoPeerWaitError(raw) {
                    // #275: transport never reached ready — no peer in the room.
                    let d = L10n.connectNoPeer.localized()
                    LogStore.shared.log(.connection, d)
                    return d
                }
                // #308: real run failure (e.g. late port race) — surfaces here
                // now, not from Start.
                return Self.startErrorReason(raw, port: port)
            }
            // #456: classify from the RAW core text (English) captured above —
            // `diagnostic` may already be a localized sentence.
            let reason: HealthReason = Self.isNoPeerWaitError(raw)
                ? .noPeer
                : HealthFailureMapper.reason(forRaw: raw)
            throw TunnelEngineError(diagnostic, reason: reason)
        }
        await MainActor.run {
            LogStore.shared.log(.connection, L10n.waitReadyOK.localized())
            LogStore.shared.log(.connection, "✓ SOCKS5 proxy ready on port \(port)", code: .socksReady)  // OLC-1004
        }
    }

    func ping(_ details: ConnectionDetails, settings s: EngineProbeSettings) async -> PingOutcome {
        guard case .olcrtc(let params) = details else { return .failure(L10n.pingFailed.localized()) }
        guard let port = PortAvailability.freeEphemeralPort() else {
            return .failure(L10n.pingNoFreePort.localized())
        }
        let vp8FPS   = params.vp8FPS       ?? s.vp8FPS
        let vp8Batch = params.vp8BatchSize ?? s.vp8Batch
        let runtime = self.runtime
        return await Task.detached {
            // Probes are isolated on the Go side (probeConfig snapshots defaults;
            // never touches the live generation) — safe alongside a running tunnel.
            // #445 (audit fix 8): BUT the snapshot copies the SHARED runtime's
            // defaults and Ping overrides only provider/transport/room/device/key/
            // port — providerToken rides along from whatever the LAST start()
            // left behind (master mobile/probe.go), so probing a wbstream node
            // used the previous connection's token (or none before any connect).
            // Pin this record's own token first.
            // #470 was: a bare `runtime.setProviderToken(params.wbToken)` and the
            // claim that overlapping a concurrent start() was "a benign last-write
            // race" — it was not: Start() snapshots the defaults, so this write
            // landing between start()'s setter and its Start() gave the LIVE
            // session this node's token. Same lock as `startLocked`.
            Self.setTokenLocked(runtime, params.wbToken)
            var result: Int64 = -1
            do {
                try runtime.ping(
                    params.carrier, transportName: params.transport,
                    roomID: params.roomID, deviceID: params.clientID,
                    keyHex: params.key,
                    socksPort: Int(port), timeoutMillis: s.timeoutMs,
                    pingURL: s.pingURL,
                    vp8FPS: vp8FPS, vp8BatchSize: vp8Batch,
                    ret0_: &result)
            } catch {
                return PingOutcome.failure((error as NSError).localizedDescription)
            }
            guard result >= 0 else { return PingOutcome.failure(L10n.pingFailed.localized()) }
            return PingOutcome.success(ms: Int(result))
        }.value
    }

    func checkReady(_ details: ConnectionDetails, settings s: EngineProbeSettings) async -> PingOutcome {
        guard case .olcrtc(let params) = details else { return .failure(L10n.pingFailed.localized()) }
        guard let port = PortAvailability.freeEphemeralPort() else {
            return .failure(L10n.pingNoFreePort.localized())
        }
        let vp8FPS   = params.vp8FPS       ?? s.vp8FPS
        let vp8Batch = params.vp8BatchSize ?? s.vp8Batch
        let runtime = self.runtime
        return await Task.detached {
            // #445 (audit fix 8): same token pinning as `ping` above — Check's
            // probe config inherits providerToken from the shared runtime defaults.
            // #470 was: `runtime.setProviderToken(params.wbToken)` — see `ping`.
            Self.setTokenLocked(runtime, params.wbToken)
            var result: Int64 = -1
            do {
                try runtime.check(
                    params.carrier, transportName: params.transport,
                    roomID: params.roomID, deviceID: params.clientID,
                    keyHex: params.key,
                    socksPort: Int(port), timeoutMillis: s.timeoutMs,
                    vp8FPS: vp8FPS, vp8BatchSize: vp8Batch,
                    ret0_: &result)
            } catch {
                return PingOutcome.failure((error as NSError).localizedDescription)
            }
            guard result >= 0 else { return PingOutcome.failure(L10n.pingFailed.localized()) }
            return PingOutcome.success(ms: Int(result))
        }.value
    }
}

/* NAMING CAUTION — verify against the generated Mobile.objc.h on the first CI
   bind (this machine cannot run gomobile). Expected gomobile spellings:
     MobileNew() -> MobileRuntime?                       (func New() *Runtime)
     runtime.setProvider(_:) throws                      (error-returning setters → throws)
     runtime.setSocksCredentials(_:password:) throws
     runtime.setVP8Options(_:batchSize:) throws
     runtime.setSEIOptions(_:batchSize:fragmentSize:ackTimeoutMillis:) throws
     runtime.setLivenessOptions(_:timeoutMillis:failures:) throws
     runtime.setDebug(_:) / setDeviceID(_:) / setProviderToken(_:)   (no error → non-throwing)
     runtime.start() throws / waitReady(_:) throws / stop(_:) throws
     runtime.state() -> String / isRunning() -> Bool
     runtime.check(_:transportName:roomID:deviceID:keyHex:socksPort:timeoutMillis:vp8FPS:vp8BatchSize:ret0_:) throws
     runtime.ping(_:transportName:roomID:deviceID:keyHex:socksPort:timeoutMillis:pingURL:vp8FPS:vp8BatchSize:ret0_:) throws
   Int64 results use the ret0_ out-param pattern; String params import as String?.
   SetResolver(*net.Resolver) is an unsupported type — gomobile SKIPS it with a
   warning; that is expected, not an error. */
