import Foundation
import Combine   // #vpn: sink on VPNController.$status (the mode bridge below)
import Network
import os   // #372: OSAllocatedUnfairLock guards `lastTunnelActivityDate`
// No `import Mobile`: the gomobile runtime is reached only through the engine
// (OlcrtcEngine) now — TunnelManager is protocol-agnostic (#243). `Network` is
// used for the NWPathMonitor that drives reconnect-on-path-change (#269).

// MARK: - TunnelManager
//
// Drives a tunnel through a pluggable `TunnelEngine` (#243). The protocol's
// native runtime lives in the engine — for olcrtc, `OlcrtcEngine` wraps the
// gomobile singleton from Mobile.xcframework. This type owns only the generic
// orchestration: the connection state machine, keep-alive, backoff auto-reconnect,
// end-to-end SOCKS verification, and background-audio keep-alive.
//
// Lifecycle:
//   disconnected → connecting → connected | failed(reason)
//
// Why a single-flight manager? The olcrtc runtime is itself a package-level
// singleton (mobile.go: package-scoped `cancel`, `done`, `ready`). Two parallel
// Starts return errAlreadyRunning, so mirroring single-flight here avoids
// surprises. `connect()` dispatches by `record.details` to select the engine.
//
// Concurrency: the `state == .disconnected` guard runs synchronously on
// the main actor. Because we set `state = .connecting` before launching
// the background Task, a second tap on Connect lands on `.connecting`
// and bails. The Task is detached on purpose — MobileStart blocks until
// the Go runtime spins up, and we don't want to freeze the main actor.
//
// IMPORTANT: MobileWaitReady returns success as soon as the SOCKS5
// listener is bound AND the WebRTC ICE state is "connected". But "ICE
// connected" doesn't guarantee data actually flows — the TURN relay can
// reject the client IP (we've seen `403 Forbidden IP` on corporate networks)
// while ICE still reports connected via a direct candidate that doesn't
// carry data. That's why verifyTunnel() does an actual end-to-end probe
// before we report `.connected`.
//
// Background: BackgroundRuntimeKeeper plays a silent AVAudio loop while
// the tunnel is connected so iOS doesn't suspend the app. Requires the
// `audio` UIBackgroundModes entitlement in Info.plist.
//
// #456 (verified health): this type is one of the app's evidence SOURCES. It
// records measured node health into `HealthCoordinator.shared` from exactly
// three chokepoints, and nowhere else:
//   1. `runEngine` — verifyTunnel returned 200 → `.working`; the engine threw →
//      a mapped failure; verifyTunnel found no data path → `.handshake`;
//   2. the keep-alive loop — every OK tick re-stamps `.working` (so the live
//      node never ages), 3 consecutive misses record `.handshake`;
//   3. `computeFailoverCandidates` — READS that evidence to order candidates,
//      so a node just watched fail is no longer tried first.
// Everything else about the state machine (epochs, supersede guards, backoff,
// cancellation) is unchanged: health is recorded alongside, never consulted by,
// the connect path.

enum ConnectionState: Equatable, CustomStringConvertible {
    case disconnected
    case connecting
    case connected
    /// Holding state (#269): the network path went away under a live session.
    /// We tear the dead session down but keep the app alive, waiting for the
    /// path to return rather than burning reconnect attempts with no route.
    case waitingForNetwork
    case failed(String)

    var isConnected: Bool  { self == .connected }
    var isConnecting: Bool { self == .connecting }

    var label: String {
        switch self {
        case .disconnected:      return L10n.stateDisconnected.localized()
        case .connecting:        return L10n.stateConnecting.localized()
        case .connected:         return L10n.stateConnected.localized()
        case .waitingForNetwork: return L10n.stateWaitingForNetwork.localized()
        case .failed(let m):     return L10n.stateErrorPrefix_fmt.formatted(m)
        }
    }

    /// Compact, English-only rendering used by `LogStore` for state-transition
    /// lines (engineering observability, not the user-facing `label`). Keeping
    /// `.failed(reason)` on one line lets you see the cause inline.
    var description: String {
        switch self {
        case .disconnected:      return "disconnected"
        case .connecting:        return "connecting"
        case .connected:         return "connected"
        case .waitingForNetwork: return "waitingForNetwork"
        case .failed(let m):     return "failed(\(m))"
        }
    }
}

/// Result of a per-connection latency probe via `TunnelManager.ping` (#234).
enum PingOutcome: Equatable, Sendable {
    case success(ms: Int)
    case failure(String)
}

/// Outcome of evaluating a network-path change (#269). A pure value so the
/// decision in `TunnelManager.pathDecision` is unit-testable without
/// constructing an `NWPath`, which has no public initializer.
enum NetworkPathAction: Equatable, Sendable {
    case none              // baseline-only / nothing actionable
    case waitForNetwork    // path lost under a live session → hold and wait
    case reconnect(NetworkReconnectReason)
}

/// Why a network-driven reconnect (#269) was requested — selects the log line.
enum NetworkReconnectReason: Equatable, Sendable {
    case restored          // path returned after an `unsatisfied` gap
    case interfaceChanged  // primary interface switched (e.g. Wi-Fi → cellular)
}

/// Drives the connection state machine
/// (disconnected → connecting → connected | failed), manages keep-alive probes,
/// backoff auto-reconnect, and background audio keep-alive. See file header for
/// concurrency and ICE-connected-but-no-data caveats.
@MainActor
final class TunnelManager: ObservableObject {
    /// `nonisolated` so SOCKSSession (called from background tasks) can read
    /// the active port without awaiting MainActor. The value is read from
    /// SettingsStore on every access, so changing the port in Settings
    /// takes effect on the next connect / next URLSession build.
    nonisolated static var socksPort: Int { SettingsStore.shared.socksPort }

    // boc #313
    /// The SOCKS port the live attempt actually bound — the snapshot `preflight`
    /// reserved (#308 guarantees the engine binds exactly it or the attempt
    /// fails). Non-nil while connecting/connected, nil once the session ends.
    /// `socksPort` above re-reads SettingsStore on every access, so after a
    /// live port edit in Settings it no longer answers "which port does the
    /// tunnel hold?" — the Settings port check compares against this instead.
    @Published private(set) var boundPort: Int? {
        // #351: mirror every write into the nonisolated `liveBoundPort` so
        // SOCKSSession (off MainActor) can target the port the live session
        // actually bound rather than the live-editable configured one.
        didSet {
            TunnelManager.liveBoundPort = boundPort
            // #445 (audit fix 1): the credentials mirror lives and dies with the
            // bound-port mirror — no port ⇒ no listener ⇒ no credentials. Clearing
            // here covers every session-end path in one place (`.disconnected`,
            // `.failed` and `.waitingForNetwork` all clear `boundPort`), so a new
            // clearing site can never be forgotten. The SET side happens in
            // `reservePortAndSettings`, just before preflight publishes the port.
            if boundPort == nil { TunnelManager.liveSocksCredentials = nil }
        }
    }
    // eoc #313

    /// #351: nonisolated mirror of `boundPort`. SOCKSSession builds tunnel-mode
    /// URLSessions from a background task and can't await MainActor, so it reads
    /// this instead of the configured `socksPort` while a session is live —
    /// otherwise a live port edit in Settings would point keep-alive's verify
    /// probe (and other in-app SOCKS traffic) at the wrong port and tear down a
    /// healthy tunnel (#313 follow-up). Kept in lockstep by `boundPort.didSet`.
    // boc #382: was `nonisolated(unsafe) private(set) static var liveBoundPort:
    // Int?`. It is written on MainActor (via `boundPort.didSet`) but read off
    // MainActor by `SOCKSSession.make` (called from the detached `verifyTunnel`
    // task), so the unsynchronised shared mutable static was a genuine data race
    // / UB — not merely a benign stale read. Back it with an `OSAllocatedUnfairLock`
    // exactly like #372 did for `lastTunnelActivityDate`; `Int?` is a trivially
    // copyable scalar so the guarded value needs no further wrapping. The
    // get/set surface below preserves the old `static var` call sites verbatim.
    // #382 was: nonisolated(unsafe) private(set) static var liveBoundPort: Int? = nil
    private static let boundPortLock = OSAllocatedUnfairLock<Int?>(initialState: nil)

    /// #382: thread-safe accessor for the live session's bound port. Written on
    /// MainActor (via `boundPort.didSet`), read off MainActor by `SOCKSSession`;
    /// all access is serialized through `boundPortLock`. `private(set)` is kept by
    /// making the setter `private`.
    nonisolated private(set) static var liveBoundPort: Int? {
        get { boundPortLock.withLock { $0 } }
        set { boundPortLock.withLock { $0 = newValue } }
    }
    // eoc #382

    // boc #445 (audit fix 1)
    /// The local-SOCKS credentials the LIVE session's listener demands, mirrored
    /// for off-MainActor readers exactly like `liveBoundPort` above: written on
    /// MainActor (preflight → `reservePortAndSettings`, cleared together with
    /// `boundPort`), read by `SOCKSSession.make` from background tasks. Without
    /// this, enabling local SOCKS auth bricked every connect: master's listener
    /// (internal/client/socks.go) REQUIRES RFC1929 user/pass on every SOCKS
    /// connection once a username is set, but the app's own URLSessions never
    /// presented credentials, so verifyTunnel always failed and connect ended
    /// `.failed` while the tunnel itself was fine.
    private static let socksCredentialsLock =
        OSAllocatedUnfairLock<(user: String, pass: String)?>(initialState: nil)

    /// #445: thread-safe accessor for the live session's SOCKS credentials —
    /// same lock discipline as `liveBoundPort`.
    nonisolated private(set) static var liveSocksCredentials: (user: String, pass: String)? {
        get { socksCredentialsLock.withLock { $0 } }
        set { socksCredentialsLock.withLock { $0 = newValue } }
    }

    /// #445 (audit fix 1): the credentials in-app tunnel sessions must present —
    /// the SAME expression `OlcrtcEngine.start` feeds the Go listener
    /// (`localSocksAuthEnabled ? Settings creds : record creds`), nil when both
    /// halves are empty (master only enforces auth when the user is non-empty).
    /// Pure → tested (Tests/SOCKSVerifyTests.swift).
    nonisolated static func effectiveSocksCredentials(
        localAuthEnabled: Bool,
        settingsUser: String, settingsPass: String,
        recordUser: String, recordPass: String
    ) -> (user: String, pass: String)? {
        let (user, pass) = localAuthEnabled ? (settingsUser, settingsPass)
                                            : (recordUser, recordPass)
        return (user.isEmpty && pass.isEmpty) ? nil : (user, pass)
    }
    // eoc #445

    /// #351: the port in-app SOCKS traffic should target *now* — the live
    /// session's bound port while connected, else the configured port. Tunnel
    /// verify, IP check, and speed test all route through here via SOCKSSession.
    nonisolated static var activeSocksPort: Int { liveBoundPort ?? socksPort }

    @Published var state: ConnectionState = .disconnected {
        didSet {
            guard state != oldValue else { return }
            routeRevision &+= 1 // #483: diagnostics observe committed route transitions, not willSet state.
            // Engineering-level observability for the state machine itself.
            // Side-effects below are already logged through their own helpers;
            // this line captures the bare transition so "what was the
            // connection doing at HH:MM:SS?" is answerable from LogStore alone.
            LogStore.shared.log(.connection, "→ state: \(oldValue) → \(state)")
            switch state {
            case .connected:
                // #vpn: everything in this branch is in-app-proxy machinery —
                // keep-alive probes the local SOCKS port, exit-geo routes
                // through the in-app proxy, and the audio keeper only exists
                // because iOS suspends the app process (the packet-tunnel
                // extension keeps running regardless). In VPN mode there is no
                // in-app SOCKS port/engine and NEVPNStatus is the truth, so a
                // VPN `.connected` must run NONE of it.
                if activeMode == .proxy && runtimeEffectsEnabled { // #483: inert injected tests.
                    startKeepAliveIfEnabled()
                    wedge.reset()       // #440: fresh session — drop any stale failure window
                    logExitGeoAsync()   // #439: record exit IP + country in the log
                    if SettingsStore.shared.backgroundAudio {
                        do {
                            try bgKeeper.start()
                        } catch {
                            // The tunnel itself is up — leave state as .connected.
                            // But warn loudly so a user investigating "why did my
                            // app suspend?" finds the cause in the Logs tab.
                            LogStore.shared.log(.connection,
                                L10n.bgKeeperFailed_fmt.formatted(error.localizedDescription))
                        }
                    }
                }
            case .connecting, .waitingForNetwork:
                // cancel-then-nil-synchronously: Task.cancel() is cooperative,
                // so dropping the handle immediately prevents any later branch
                // (or a re-entrant didSet on rapid oscillation) from observing a
                // stale-but-still-running `keepAliveTask`. NOT `recoveryTask` —
                // the recovery loop itself drives these `.connecting` attempts, so
                // it must survive its own transitions (it's cancelled only by
                // disconnect()/connect(), or a network loss).
                // `.waitingForNetwork` deliberately leaves `bgKeeper` running so
                // a backgrounded app isn't suspended while it waits for the path
                // to return (#269) — it must stay alive to reconnect on its own.
                keepAliveTask?.cancel(); keepAliveTask = nil
                // #313: a network hold releases the listener (`handlePathUpdate`
                // stops the engine before entering this state), so the bound-port
                // snapshot is stale. `.connecting` must NOT clear it — preflight
                // sets the snapshot just before flipping to `.connecting`.
                if state == .waitingForNetwork { boundPort = nil }
            case .disconnected:
                keepAliveTask?.cancel(); keepAliveTask = nil
                bgKeeper.stop()
                boundPort = nil  // #313: session over — the engine no longer holds a port
            case .failed:
                keepAliveTask?.cancel(); keepAliveTask = nil
                // #445 (audit fix 3): stop the silent-audio keeper ONLY when no
                // recovery loop is pending. Keep-alive loss (and every failed
                // recovery attempt) enters `.failed` with `recoveryTask` live —
                // stopping the keeper then let iOS suspend a backgrounded app
                // within seconds, so the backoff `Task.sleep` never resumed and
                // auto-recovery only ever ran on foreground (defeating #270 in
                // exactly the scenario keep-alive exists for). Same reasoning as
                // `.waitingForNetwork` deliberately keeping the keeper (#269).
                // User `disconnect()` stops the keeper itself, and the recovery
                // give-up nils `recoveryTask` BEFORE its `.failed` write, so both
                // terminal paths still release the audio session here.
                if recoveryTask == nil { bgKeeper.stop() }
                boundPort = nil  // #313: session over — the engine no longer holds a port
            }
        }
    }

    // boc #483: nonsecret route history survives a transient up/down cycle.
    // Parent invalidates app-wide IP/speed work from this publisher, not view
    // lifecycle. Publish only after the underlying value has been mutated.
    @Published private(set) var routeRevision: UInt64 = 0
    private var lastRecord: ConnectionRecord? {
        didSet {
            if lastRecord?.id != oldValue?.id || lastRecord?.details != oldValue?.details {
                routeRevision &+= 1
            }
        }
    }
    // eoc #483

    /// #388: the record the live tunnel actually holds — `lastRecord` while the
    /// session is up, else nil. This is the SINGLE source of truth for "which node
    /// am I connected to": `lastRecord` is set by `connect()` and cleared by
    /// `disconnect()`, independent of the UI's `store.primary` selection. The UI
    /// must use THIS (not `store.primary`) wherever it reasons about the live node
    /// — a row tap (`setPrimary`, no reconnect) moves `store.primary` but not the
    /// live session, and that desync made batch-ping skip the wrong node (#388) and
    /// the carrier card read the wrong host (#389). Connecting/failed states return
    /// nil so callers only ever see a node that's genuinely live.
    var connectedRecord: ConnectionRecord? {
        state.isConnected ? lastRecord : nil
    }

    // boc #483: renewal must protect the engaged identity during setup/backoff,
    // but a remembered record from a terminal failure is not a live session.
    var engagedRecord: ConnectionRecord? {
        switch state {
        case .connecting, .connected, .waitingForNetwork: return lastRecord
        case .failed:
            return activeMode == .proxy && recoveryTask?.isCancelled == false ? lastRecord : nil
        case .disconnected: return nil
        }
    }
    // #483: observable ownership, without exposing or allowing mutation of Task handles.
    var hasPendingRecovery: Bool { recoveryTask?.isCancelled == false }
    private var engineTask: Task<Bool, Never>?
    private var proxyStopPending = false // #483: quarantine outlives a timed-out UI waiter.
    private var vpnStartTask: Task<Void, Never>?
    private var vpnStopTask: Task<Void, Error>?
    private let engineOverride: (any TunnelEngine)?
    private let verifyOverride: (@Sendable () async -> Bool)?
    private let runtimeEffectsEnabled: Bool
    private let portIsFree: (UInt16) -> Bool // #483: deterministic lifecycle tests, real default.
    private let teardownWaitSeconds: Double // #483: bounded user wait, injectable clock budget.
    // eoc #483

    private var keepAliveTask: Task<Void, Never>?
    /// #409: the off-MainActor native teardown kicked off by `disconnect()`.
    /// `MobileStop()` blocks until the WebRTC session fully closes, so it runs in
    /// a detached Task to keep the UI responsive; a following `connect()` cancels
    /// it so a stray late Stop can't tear down the freshly-started session.
    private var stopTask: Task<Void, Never>?
    /// #386: the same-port wait Task that `start()` spawns when our own ghost still
    /// holds the configured port (#333). Stored so `disconnect()`/`connect()` can
    /// cancel it — otherwise it was fire-and-forget and, on a disconnect+reconnect
    /// inside its ≤5 s wait, would resume and run `preflight` for the OLD record
    /// (bumping `connectEpoch` last), connecting the wrong exit node.
    private var pendingStartTask: Task<Void, Never>?
    private let bgKeeper = BackgroundRuntimeKeeper()

    // MARK: System-VPN mode state (#vpn)
    //
    // `vpn` drives the NetworkExtension packet tunnel; `activeMode` records
    // which backend the CURRENT session went through. SettingsStore.tunnelMode
    // is only read at connect time, so flipping the setting while disconnected
    // never touches a live session. All in-app proxy machinery (keep-alive,
    // background keeper, exit-geo, path-monitor reconnects) is gated on
    // `.proxy` — in VPN mode there is no in-app SOCKS port or engine, and
    // NEVPNStatus (mirrored via `vpnStatusChanged`) is the truth.
    let vpn: VPNController // #483: injectable control plane; production default is unchanged.
    // boc #487: UI contract for the NEXT attempt; activeMode stays session truth.
    var effectiveModeForNextConnection: TunnelMode {
        let unavailable: Bool
        if case .unavailable = vpn.capability { unavailable = true } else { unavailable = false }
        return SettingsStore.shared.connectionModePreference.effectiveMode(vpnUnavailable: unavailable)
    }

    var automaticModeFallbackReason: String? {
        guard SettingsStore.shared.connectionModePreference == .automatic,
              case .unavailable(let reason) = vpn.capability else { return nil }
        return L10n.vpnAutomaticFallback_fmt.formatted(reason)
    }
    private var attemptModePreference: ConnectionModePreference = .automatic
    // eoc #487

    private(set) var activeMode: TunnelMode = .proxy {
        didSet {
            if activeMode != oldValue { routeRevision &+= 1 } // #483
        }
    }
    private var cancellables = Set<AnyCancellable>()
    private var lastObservedVPNStatus: VPNController.Status? // #483: route history includes suppressed late NE events.

    // MARK: App-lifecycle logging (#432)
    //
    // The user's #1 diagnostic question was "do logs keep being written when the
    // app is backgrounded?". The honest answer depends on whether keep-alive is
    // holding the app up: with `backgroundAudio` OFF (the default) a backgrounded
    // app is suspended within seconds — the Go core stops emitting and the SOCKS
    // proxy stops serving — so logging simply pauses until the app returns. These
    // notes make that transition explicit in the connection log so a gap is never a
    // mystery, and warn loudly when a *connected* app backgrounds without keep-alive.

    private var backgroundedAt: Date?
    /// #432: heartbeat while backgrounded — see `noteBackground`.
    private var backgroundHeartbeat: Task<Void, Never>?
    /// #432: heartbeat cadence. 60 s ≈ one line/minute — negligible cost, plenty to
    /// see whether background execution kept going or the app was suspended.
    static let backgroundHeartbeatSeconds = 60

    /// Log entering the background, stating whether keep-alive should hold the app up,
    /// and — when connected — start a heartbeat that PROVES it. Evenly-spaced
    /// heartbeats through the background window mean the app really stayed alive
    /// (logs were being written); a gap in them is the app being suspended despite
    /// keep-alive. This is what makes "were logs written in the background?"
    /// answerable from the log itself, instead of assuming a cause.
    func noteBackground() {
        let start = Date()
        backgroundedAt = start
        let connected = state.isConnected
        let keeper = bgKeeper.isRunning
        // #470: in VPN mode the core runs in the packet-tunnel extension, which
        // iOS keeps alive on its own — the keeper is (correctly) never started
        // there, so the proxy-mode "keep-alive is OFF, enable Background audio"
        // warning was false, and a heartbeat that stops the moment the app
        // process suspends would read as "the tunnel died".
        let systemVPN = activeMode == .vpn
        LogStore.shared.log(.connection,
                            Self.backgroundEnterMessage(connected: connected, keeperRunning: keeper,
                                                        systemVPN: systemVPN),
                            level: connected && !keeper && !systemVPN ? .warn : .info)   // #470

        backgroundHeartbeat?.cancel()
        guard connected, !systemVPN else { return }   // idle-in-background needs no aliveness proof; #470: nor does a system tunnel
        backgroundHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.backgroundHeartbeatSeconds))
                if Task.isCancelled { break }
                guard let self else { break }
                LogStore.shared.log(.connection,
                    Self.backgroundHeartbeatMessage(elapsedSeconds: Date().timeIntervalSince(start),
                                                    keeperRunning: self.bgKeeper.isRunning))
                // #432: fsync each tick so the newest proof-of-life survives even if
                // iOS suspends/kills the app right after.
                LogStore.shared.flush()
            }
        }
    }

    /// Log returning to the foreground with how long the app was backgrounded, so a
    /// quiet stretch in the log lines up against a visible "was backgrounded Nm" marker.
    func noteForeground() {
        backgroundHeartbeat?.cancel()
        backgroundHeartbeat = nil
        // #445 (audit fix 10): re-arm the keep-alive keeper if it silently died —
        // an audio interruption that ended WITHOUT `.shouldResume` leaves it dead
        // while state stays `.connected`, and nothing else restarts it (it is only
        // started by the `.connected` didSet), so the NEXT backgrounding would
        // suspend the app with keep-alive silently off. Foreground is the safe
        // moment to fix that. Before the `backgroundedAt` guard on purpose: a
        // scene activation without a recorded background entry still re-arms.
        // #470: proxy mode only — the `.connected` didSet never starts the keeper
        // under the system VPN (the extension keeps running by itself), but this
        // re-arm had no such gate, so every foreground under a VPN session
        // activated an AVAudioSession and a silent audio loop for nothing.
        // #470 was: if state.isConnected && SettingsStore.shared.backgroundAudio {
        if state.isConnected && activeMode == .proxy && SettingsStore.shared.backgroundAudio {
            bgKeeper.restartIfNeeded()
        }
        guard let since = backgroundedAt else { return }
        backgroundedAt = nil
        LogStore.shared.log(.connection,
            Self.foregroundEnterMessage(backgroundSeconds: Date().timeIntervalSince(since)))
    }

    /// Pure (unit-tested) — one heartbeat line while backgrounded.
    nonisolated static func backgroundHeartbeatMessage(elapsedSeconds: Double, keeperRunning: Bool) -> String {
        "• still alive in background +\(formatBackgroundDuration(elapsedSeconds)) — keep-alive \(keeperRunning ? "ON" : "OFF")"
    }

    // MARK: Exit geo (#439)

    /// #439: fetch the exit IP + geo through the freshly-verified tunnel and log one
    /// line (`→ exit = <ip> (<city>, <CC> · <org>)`), so the exit's country is
    /// obvious at a glance. Fire-and-forget and best-effort — a failure is silent
    /// (the tunnel is already verified; this is only annotation).
    private func logExitGeoAsync() {
        // #445 (audit fix 9): build the session inside the Task and invalidate it
        // once the geo fetch settles — un-invalidated URLSessions (and their
        // delegate threads) leak until app exit, one per connect otherwise.
        // boc #470: the fetch used to outlive the session. URLSession silently
        // BYPASSES a refusing loopback proxy (see `socksListenerAnswers`), so a
        // disconnect before ipinfo answered let the request complete DIRECT and
        // write the user's REAL IP as "→ exit = …" into the (never IP-masked)
        // connection log, then re-stamp the activity marker `disconnect()` had
        // just cleared. Pin the result to the attempt that asked for it — same
        // epoch, still connected — and let `disconnect()` cancel it outright.
        exitGeoTask?.cancel()
        let epoch = connectEpoch
        exitGeoTask = Task { [weak self] in
            let session = SOCKSSession.make(mode: .tunnel)
            defer { session.finishTasksAndInvalidate() }
            guard let geo = await IPChecker.fetchExitGeo(session: session) else { return }
            guard let self, !Task.isCancelled,
                  self.connectEpoch == epoch, self.state.isConnected else { return }
            LogStore.shared.log(.connection, IPChecker.exitGeoLine(geo))
            SOCKSSession.noteTunnelActivity()
        }
        // eoc #470
    }

    /// #470: the in-flight exit-geo annotation, so a disconnect can cancel it.
    private var exitGeoTask: Task<Void, Never>?

    // MARK: Wedge detection (#440)

    /// #440: sliding-window detector over the core's own log lines. Fed by
    /// `observeCoreLine`.
    /// #445 (audit fix 6) was: threshold 7 — master caps a reconnect burst at 3–5
    /// handshake attempts (internal/client/link.go), so 7-in-10 s could never
    /// trip against a master core. 4-in-10 s catches the burst, and the detector
    /// now also trips IMMEDIATELY on the core's own terminal give-up line
    /// ("… keeping listener up" — see `WedgeDetector.fatalSignatures`).
    private var wedge = WedgeDetector(threshold: 4, window: 10)

    /// Feeds a core log line to the wedge detector, but only when the opt-in setting
    /// is on AND a session is live — so it costs nothing otherwise. A trip restarts
    /// the session early via the shared recovery sink (which is itself idempotent, so
    /// this can't stack on an in-flight reconnect).
    func observeCoreLine(_ line: String) { // #483: internal seam for late-log regression tests.
        // #483 was: state alone also matched an adopted VPN's connected state.
        guard activeMode == .proxy, SettingsStore.shared.earlyRestartOnWedge,
              state.isConnected else { return }
        if wedge.record(line: line, now: ProcessInfo.processInfo.systemUptime) {
            LogStore.shared.log(.connection, L10n.wedgeRestartLog.localized(), level: .warn)
            requestReconnect(reason: L10n.wedgeRestartReason.localized())
        }
    }

    /// Pure (unit-tested) — the background-entry line, keyed on live state.
    /// #470: `systemVPN` — a connected VPN-mode session needs no keeper and no
    /// heartbeat; saying otherwise (the proxy-mode ⚠ line) was simply false.
    /// Defaulted so the pre-#470 call shape (and its tests) still compile.
    nonisolated static func backgroundEnterMessage(connected: Bool, keeperRunning: Bool,
                                                   systemVPN: Bool = false) -> String {
        if connected && systemVPN {   // #470
            return "▶ app entered background — connected through the system VPN; "
                 + "the packet-tunnel extension keeps running on its own, no keep-alive needed"
        }
        switch (connected, keeperRunning) {
        case (true, true):
            return "▶ app entered background — connected, keep-alive ON (heartbeat below confirms whether it stays alive)"
        case (true, false):
            return "⚠ app entered background — connected but keep-alive is OFF; iOS may suspend the app, "
                 + "which stops the SOCKS proxy and pauses logging. Enable Background audio in Settings to stay alive."
        default:
            return "▶ app entered background — not connected"
        }
    }

    /// Pure (unit-tested) — the foreground-return line.
    nonisolated static func foregroundEnterMessage(backgroundSeconds: Double) -> String {
        "▶ app returned to foreground after \(formatBackgroundDuration(backgroundSeconds)) in background"
    }

    /// Pure (unit-tested) — compact human duration: `45s`, `3m`, `3m20s`, `1h5m`.
    nonisolated static func formatBackgroundDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let m = total / 60, s = total % 60
        if m < 60 { return s == 0 ? "\(m)m" : "\(m)m\(s)s" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h)h" : "\(h)h\(mm)m"
    }

    // MARK: Recovery (#270) — capped exponential-backoff auto-reconnect
    //
    // Both keep-alive loss and #269's network events feed `requestReconnect`, the
    // single recovery sink. It retries with capped exponential backoff
    // (base·2^attempt, clamped) and gives up after `maxReconnectAttempts`, then
    // waits for the user — the deliberate battery cap the old one-shot protected.
    // A verified connect ends the loop, so the backoff resets for the next drop.
    private var recoveryTask: Task<Void, Never>?
    /// #470: stamp of the loop that currently owns `recoveryTask`. A cancelled
    /// loop can stay parked for seconds inside an awaited detached stop or a
    /// `connectAndAwait` (neither observes cancellation), and its `defer` used
    /// to nil the handle under a NEWER loop started meanwhile — see
    /// `requestReconnect`. Bumped per loop; the defer clears only its own.
    private var recoveryGeneration = 0
    // `nonisolated` so the pure `backoffDelaySeconds` (also nonisolated, for
    // testing off the MainActor) can read them without a Swift 6 isolation error.
    private nonisolated static let reconnectBaseDelaySeconds: Double = 2
    private nonisolated static let maxReconnectDelaySeconds: Double = 60
    private nonisolated static let maxReconnectAttempts = 6   // 2+4+8+16+32+60 ≈ 122 s, then wait for user
    // #453: with auto-failover on, spend a SHORTER budget per protocol before
    // hopping to the next one on the same VPS — the point is to find a working
    // protocol fast, not to exhaust the full backoff ladder on a blocked one.
    private nonisolated static let failoverAttemptsPerCandidate = 3   // ~2+4+8 ≈ 14 s per protocol

    // MARK: Same-port wait-and-retry (#333)
    //
    // The core's SOCKS listener tears down asynchronously, so right after our own
    // disconnect the configured port can still read busy for a second or two — an
    // immediate reconnect would fail the #308 "port busy" check on our *own* ghost.
    // Mitigation that keeps the #308 contract intact (bind exactly the configured
    // port, typed busy error, NO sliding): if the port is busy *and we disconnected
    // ourselves recently*, poll the SAME port briefly before surfacing the error.
    // The window is gated on a self-disconnect so a genuinely busy port (another
    // app) still fails fast.
    private nonisolated static let selfDisconnectGhostWindow: TimeInterval = 10  // only wait if we let go this recently
    private nonisolated static let portReleasePollInterval: Double = 0.25        // ~250 ms between probes
    private nonisolated static let portReleaseMaxWait: Double = 5                // give up after ~5 s → typed busy error

    /// When we last tore down our own listener (disconnect / keep-alive loss /
    /// recovery teardown). Gates the same-port wait above so we only ever wait on
    /// *our* ghost, never on a port a different app is holding.
    // #382: was `nonisolated(unsafe)`, but every access (write in `disconnect()`,
    // read in `shouldWaitForOwnPortReleaseNow()`) is on the MainActor — the pure
    // verdict takes the elapsed interval as a value, it never reads this static
    // off-actor — so the annotation was merely unnecessary. Let it inherit the
    // type's `@MainActor` isolation; no logic change.
    // #382 was: nonisolated(unsafe) private static var lastSelfDisconnectDate: Date? = nil
    private static var lastSelfDisconnectDate: Date? = nil

    /// #394: the port our last self-disconnect actually released (the `boundPort`
    /// the dying session held). Gates the same-port wait so we only ever wait on a
    /// port WE just let go: if the configured port no longer matches it — the user
    /// changed the SOCKS port in Settings between sessions, or a foreign app is
    /// holding a *different* port — there is no ghost of ours to wait for, so we
    /// fail fast per #308. MainActor-only (written in `disconnect()`, read in
    /// `shouldWaitForOwnPortReleaseNow()`); never read off-actor.
    private static var lastSelfDisconnectPort: Int? = nil

    // boc #483: app-hosted tests restore all shared mirrors after joining their
    // own teardown, rather than polluting the next test/app intent's baseline.
    struct LifecycleSnapshot {
        fileprivate let port: Int?
        fileprivate let credentials: (user: String, pass: String)?
        fileprivate let releasedPort: Int?
        fileprivate let releasedAt: Date?
        fileprivate let activity: Date?
    }
    static func lifecycleSnapshot() -> LifecycleSnapshot {
        LifecycleSnapshot(port: liveBoundPort, credentials: liveSocksCredentials,
                          releasedPort: lastSelfDisconnectPort, releasedAt: lastSelfDisconnectDate,
                          activity: lastTunnelActivityDate)
    }
    static func restoreLifecycleSnapshot(_ snapshot: LifecycleSnapshot) {
        liveBoundPort = snapshot.port
        liveSocksCredentials = snapshot.credentials
        lastSelfDisconnectPort = snapshot.releasedPort
        lastSelfDisconnectDate = snapshot.releasedAt
        lastTunnelActivityDate = snapshot.activity
    }
    // eoc #483

    /// #333: should the connect path wait for the configured port to free up rather
    /// than failing immediately? Only when the port is currently busy, we released
    /// our own listener within `selfDisconnectGhostWindow`, AND the busy port is the
    /// very port we just released (#394). Pure → tested.
    // #394 was: shouldWaitForOwnPortRelease(portFree:selfDisconnectedAgo:) — it
    // classified ANY busy configured port as "our ghost" on timing alone. But
    // `PortAvailability.isFree` is holder-agnostic, so a foreign app (or a
    // now-different configured port) read as busy in the window triggered a 5 s
    // wait instead of the #308 fail-fast. Requiring `configuredPort == releasedPort`
    // attributes the wait to our own just-released session: a foreign holder on any
    // OTHER port, or a port the user re-pointed, now fails fast immediately. (A
    // foreign app grabbing the exact port we just released within the window is not
    // distinguishable at the socket level; that residual case still bounded-waits
    // then fails per #308 — never sliding, never weakening the contract.)
    nonisolated static func shouldWaitForOwnPortRelease(portFree: Bool,
                                                        selfDisconnectedAgo: TimeInterval?,
                                                        configuredPort: Int,
                                                        releasedPort: Int?) -> Bool {
        guard !portFree else { return false }
        guard let ago = selfDisconnectedAgo, ago >= 0, ago <= selfDisconnectGhostWindow else { return false }
        // #394: only our own ghost — the busy port must be the one we just released.
        return releasedPort == configuredPort
    }

    // MARK: Network-path monitoring (#269)
    //
    // The gomobile session is bound to whatever network path it started on, so
    // a Wi-Fi↔cellular handoff (or a drop-then-regain) silently kills it — we'd
    // otherwise only notice ~90 s later when keep-alive gives up. An always-on
    // `NWPathMonitor` (started lazily on the first connect, never torn down —
    // it's cheap) watches for that. The reaction is decided by the pure
    // `pathDecision`; this layer tracks the last-seen path and feeds a regain or
    // interface swap into the shared recovery sink (`requestReconnect`, #270).
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "io.github.hotelk52339.olcrtc.pathmonitor")
    private var pathMonitorStarted = false
    private var lastPathSatisfied: Bool?                  // nil until the first update (baseline)
    private var lastPrimaryInterface: NWInterface.InterfaceType?

    // boc #372: `lastTunnelActivityDate` is written from several concurrent
    // contexts — `noteActivity`, `SOCKSSession.noteTunnelActivity`, and the
    // keep-alive loop — and read by keep-alive. It was a plain
    // `nonisolated(unsafe) static var Date?`, an unsynchronised shared mutable
    // static (a data race / UB). Back it with an `OSAllocatedUnfairLock` (iOS
    // 16+; app targets 17+), storing the time as a `Double`
    // (timeIntervalSinceReferenceDate) so the guarded value is a trivially
    // copyable scalar. The `Date?` get/set/reset surface below is preserved
    // verbatim, so every existing call site — including the #333 reset-on-
    // disconnect (`= nil`) — keeps working with no change.
    // #372 was: nonisolated(unsafe) static var lastTunnelActivityDate: Date? = nil
    private static let activityClock = OSAllocatedUnfairLock<Double?>(initialState: nil)

    /// Timestamp of the last observed tunnel activity (`nil` = none / reset).
    /// `nonisolated` so SOCKSSession / SpeedTest write it from background tasks
    /// and keep-alive reads it on MainActor — all serialized through the lock.
    nonisolated static var lastTunnelActivityDate: Date? {
        get {
            activityClock.withLock { stored in
                stored.map { Date(timeIntervalSinceReferenceDate: $0) }
            }
        }
        set {
            activityClock.withLock { stored in
                stored = newValue?.timeIntervalSinceReferenceDate
            }
        }
    }
    // eoc #372

    /// Call this whenever a successful request through the tunnel is observed.
    /// Pass `forAtLeast` to suppress keep-alive probes for a known busy period
    /// (e.g. speed test duration) — sets the timestamp ahead by that many seconds.
    nonisolated func noteActivity(forAtLeast seconds: TimeInterval = 0) {
        TunnelManager.lastTunnelActivityDate = Date().addingTimeInterval(seconds)
    }

    /// Engine for the current / last connection, selected by `connect(record:)`.
    /// `disconnect()` and the keep-alive failure path stop it. Nil until the first
    /// connect — so a `.connected` state written directly (e.g. in a unit test)
    /// has no engine to stop, which is harmless.
    private var activeEngine: (any TunnelEngine)?

    /// Monotonic connect-attempt counter (#272). `preflight` bumps it at the start
    /// of every attempt; each detached `runEngine` captures the value and only
    /// posts a result while it is still current. Without it, a fast
    /// disconnect→reconnect can alias `state == .connecting` and let a stale
    /// `runEngine` (resuming after `verifyTunnel`) post `.connected` for the wrong
    /// session. `private(set)` so a test can observe that attempts advance it.
    private(set) var connectEpoch = 0

    // No init: engine runtimes initialise lazily on first use via
    // `ConnectionDetails.engine`, so there's nothing protocol-specific to wire
    // up at construction anymore (#243).

    /// #393: "are this device's Keychain secrets currently unreadable?" — supplied
    /// by the owner (MainTabView wires `{ store.secretsLocked }`). When true the
    /// in-memory key is empty and a connect would fail validation with the
    /// misleading "Key must be 64 hex characters (got: 0)"; `connect` short-circuits
    /// to the actionable "unlock the device" message instead. Lives here (not just
    /// in `ConnectionsView.connectGuarded`) so EVERY caller is covered — including
    /// auto-connect-on-launch (App.swift), which bypassed the view guard (#393).
    /// `ConnectionStore` isn't a singleton, so it's injected as a closure rather
    /// than referenced directly. nil (unwired, e.g. in tests) ⇒ never locked.
    /// #412: injected at construction (see `init`) instead of a later `.onAppear`
    /// assignment, so a missed wiring can't silently leave it nil.
    var secretsLocked: (() -> Bool)?

    /// #453: supplies the ordered failover alternatives for a record — the OTHER
    /// protocols running on the SAME VPS (sibling ConnectionRecords, best-first).
    /// Injected by the owner (MainTabView wires it to
    /// `computeFailoverCandidates` over ConnectionStore + ServerHostStore); nil
    /// (tests/previews) ⇒ no failover, the reconnect loop just gives up as before.
    /// Consulted only when `settings.autoFailover` is on and `activeMode == .proxy`.
    var failoverCandidates: (@MainActor (ConnectionRecord) -> [ConnectionRecord])?

    /// #437: the live manager, so an App Intent (Shortcuts / automation) can reach
    /// connect/disconnect without the SwiftUI view tree. Weak — the real instance is
    /// retained by `App`'s `@StateObject`; throwaway test/preview instances just
    /// overwrite it harmlessly (intents never run there). App wiring sets it in
    /// `init`; the last (real) one created wins.
    @MainActor static weak var shared: TunnelManager?

    /// #412: inject the locked-secrets check at construction (default `nil`, so
    /// `TunnelManager()` in tests/previews still means "never locked"). Replaces the
    /// forgettable `.onAppear` wiring that risked a nil ⇒ never-locked bug.
    init(secretsLocked: (() -> Bool)? = nil,
         failoverCandidates: (@MainActor (ConnectionRecord) -> [ConnectionRecord])? = nil,
         vpn: VPNController? = nil,
         engine: (any TunnelEngine)? = nil,
         runtimeEffectsEnabled: Bool = true,
         verify: (@Sendable () async -> Bool)? = nil,
         portIsFree: @escaping (UInt16) -> Bool = { PortAvailability.isFree($0) },
         teardownWaitSeconds: Double = 15) { // #483
        self.secretsLocked = secretsLocked
        self.failoverCandidates = failoverCandidates   // #453
        self.vpn = vpn ?? VPNController()
        self.engineOverride = engine
        self.runtimeEffectsEnabled = runtimeEffectsEnabled
        self.verifyOverride = verify
        self.portIsFree = portIsFree // #483
        self.teardownWaitSeconds = teardownWaitSeconds // #483
        Self.shared = self   // #437: App Intents reach the live manager here
        // #440: observe the core's own log lines for the wedge detector. Cheap and
        // always installed; `observeCoreLine` is a no-op unless the feature is on
        // AND a session is live, so it costs nothing when disabled/disconnected.
        if runtimeEffectsEnabled { // #483: tests must not replace the real app's log observer.
            OlcrtcEngine.coreLineObserver = { [weak self] line in self?.observeCoreLine(line) }
        }
        // #vpn: mirror the system tunnel's status into the connection state
        // machine. VPNController is @MainActor, so every emission arrives on
        // the main actor already — `assumeIsolated` makes that explicit and
        // keeps delivery SYNCHRONOUS (an async hop would let the pre-start
        // status snapshot emitted inside `vpn.start` land after
        // `vpnStartsInFlight` was decremented — see `vpnStatusChanged`).   // #470 was: `vpnStartInFlight` was cleared
        self.vpn.$status.sink { [weak self] status in
            MainActor.assumeIsolated { self?.vpnStatusChanged(status) }
        }.store(in: &cancellables)
        // boc #487: nested ObservableObjects do not forward changes to SwiftUI.
        self.vpn.$capability.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }.store(in: &cancellables)
        SettingsStore.shared.$connectionModePreference
            .receive(on: DispatchQueue.main) // #487: SettingsStore also has nonactor test/legacy callers.
            .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }.store(in: &cancellables)
        // eoc #487
    }

    /// Starts a tunnel for the given record. Dispatches to a protocol-specific
    /// path based on `record.details`. Today only .olcrtc is supported; when
    /// other protocols come online they get their own `start...` method.
    ///
    /// Accepts both `.disconnected` and `.failed` states so the user can
    /// hit "Retry" right on the error banner without first flipping
    /// the global toggle off.
    func connect(record: ConnectionRecord) {
        switch state {
        case .disconnected, .failed: break
        // `.waitingForNetwork` is an active session the path monitor will
        // reconnect on its own once connectivity returns — a manual connect now
        // (no route) would only fail, so treat it like .connecting/.connected.
        case .connecting, .connected, .waitingForNetwork:
            // boc #469: was a bare `return`. Every "switch to this protocol"
            // affordance — the Connections switcher, the host card's "Connect via
            // this protocol" — trusted the comment that connect "disconnects-
            // then-dials". It did not: with a session up, a tap moved
            // `store.primary`, fired a haptic and did nothing else. The SAME
            // record stays idempotent; a DIFFERENT one tears down and dials.
            // boc #477 was: `guard let live = lastRecord, live.id != record.id
            // else { return }` — only the record was compared, and a live state
            // without a known record was left alone. Two gaps followed:
            //   • switching proxy↔VPN on the SAME record did nothing at all, so
            //     the user stayed silently on the old backend;
            //   • an ADOPTED system tunnel (#477) has no `lastRecord`, so
            //     connecting to anything while it ran returned here and the tap
            //     did nothing.
            // Anything that is not "the same record on the same backend" is a
            // switch: tear down, then dial.
            // #487 was: SettingsStore.shared.tunnelMode == activeMode
            let sameBackend = effectiveModeForNextConnection == activeMode
            if let live = lastRecord, live.id == record.id, sameBackend { return }
            disconnect()   // the teardown wait below dials once the engine is down
            // eoc #469 / #477
        }
        // boc #483: claim the attempt before ANY asynchronous teardown/validation.
        // A terminal failed retry must also drain its previous engine.
        connectEpoch &+= 1
        let epoch = connectEpoch
        recoveryTask?.cancel(); recoveryTask = nil
        recoveryGeneration &+= 1
        pendingStartTask?.cancel(); pendingStartTask = nil
        // #483: a failed VPN handshake/stop can still own routes. Switching from
        // .failed must drain it too, not just switches from a visibly live state.
        if activeMode == .vpn { scheduleVPNStop() }
        vpnStartTask?.cancel(); vpnStartTask = nil
        if activeEngine != nil { scheduleEngineStop() }
        // eoc #483
        // #393: if the device was locked before first unlock at launch the saved
        // key couldn't be read (empty in memory) — surface the actionable unlock
        // message rather than the misleading "Key must be 64 hex characters
        // (got: 0)". Guarding here covers auto-connect-on-launch too, which calls
        // `connect` directly and bypassed ConnectionsView.connectGuarded (#393).
        if secretsLocked?() == true {
            lastRecord = nil // #483: a denied attempt does not own yesterday's record.
            state = .failed(L10n.errorSecretsLocked.localized())
            return
        }
        // boc #483
        // #483 was: only proxy starts waited for stopTask, recursively calling
        // connect with idle UI; neither direction awaited the VPN's terminal NE
        // status. Capture the backend once and directly continue this epoch.
        lastRecord = record
        // #487 was: activeMode = SettingsStore.shared.tunnelMode
        attemptModePreference = SettingsStore.shared.connectionModePreference
        activeMode = effectiveModeForNextConnection
        if stopTask != nil || vpnStopTask != nil {
            state = .connecting
            let proxyStop = stopTask
            let vpnStop = vpnStopTask
            pendingStartTask = Task { [weak self] in
                do {
                    guard let self else { return }
                    try await self.waitForProxyStop()
                    await proxyStop?.value
                    try await vpnStop?.value
                    guard !Task.isCancelled, self.connectEpoch == epoch else { return }
                    self.stopTask = nil
                    self.vpnStopTask = nil
                    self.pendingStartTask = nil
                    self.dial(record: record)
                } catch {
                    guard let self, !Task.isCancelled, self.connectEpoch == epoch else { return }
                    self.state = .failed(error.localizedDescription)
                }
            }
            return
        }
        dial(record: record)
        // eoc #483
    }

    // #483: continuation of the current claimed attempt, not a second connect()
    // (which would hit same-record idempotence after the optimistic state flip).
    private func dial(record: ConnectionRecord) {
        if activeMode == .vpn { startVPN(record: record) }
        else { start(record: record) }
    }

    func disconnect() {
        // boc #483: invalidate both backend continuations synchronously.
        connectEpoch &+= 1
        recoveryGeneration &+= 1
        recoveryTask?.cancel(); recoveryTask = nil
        pendingStartTask?.cancel(); pendingStartTask = nil
        vpnStartTask?.cancel(); vpnStartTask = nil
        // eoc #483
        // #vpn: a VPN session runs none of the proxy machinery below — ask the
        // provider to stop and flip state synchronously (mirroring the proxy
        // path's synchronous UI flip). Restoring `activeMode = .proxy` first
        // makes the observer's late `.disconnecting`/`.disconnected` emissions
        // no-ops (`vpnStatusChanged` guards on `.vpn`), so a user-initiated
        // stop never surfaces as `.failed`.
        if activeMode == .vpn {
            LogStore.shared.log(.connection, L10n.disconnectingArrow.localized())
            scheduleVPNStop() // #483: retain the barrier until a subsequent dial consumes it.
            lastRecord = nil
            activeMode = .proxy
            state = .disconnected
            return
        }
        LogStore.shared.log(.connection, L10n.disconnectingArrow.localized())
        // Cancel every background task before mutating state so none can observe
        // an intermediate state and schedule a spurious auto-retry / reconnect.
        // The path monitor itself keeps running, but with `lastRecord == nil`
        // its handler is a no-op (see `pathDecision`), so the next connect starts
        // from a clean baseline.
        recoveryTask?.cancel();  recoveryTask = nil
        keepAliveTask?.cancel(); keepAliveTask = nil
        // #386: a same-port wait may be in flight (state == .connecting while it
        // polls the port). Cancel it so it can't resume past the wait and preflight
        // a now-stale record after the user disconnected.
        pendingStartTask?.cancel(); pendingStartTask = nil
        bgKeeper.stop()
        // #409: MobileStop() blocks until the native WebRTC session fully tears
        // down (leave-presence + peer close) — running it on the MainActor froze
        // the entire UI for seconds. Flip state synchronously (below) so the UI
        // reflects the disconnect at once, then stop the engine OFF the MainActor.
        // A subsequent connect() cancels this task; the Go singleton serialises
        // Stop/Start and #333's port-release wait covers the teardown window.
        // #409 was: activeEngine?.stop() called synchronously on the MainActor.
        // #483 was: cancel and replace a detached stop; an older stop could
        // outlive its handle and hit the replacement session.
        scheduleEngineStop()
        exitGeoTask?.cancel(); exitGeoTask = nil   // #470: never annotate a session that is gone
        lastRecord = nil
        // #333: stopping our own listener opens the async-teardown window during
        // which the port reads busy on our ghost. Record it so the *next* connect
        // can wait-and-retry the same port (gated on this being recent).
        TunnelManager.lastSelfDisconnectDate = Date()
        // #394: record WHICH port this session held (read before the `.disconnected`
        // didSet clears `boundPort`). The next connect waits only if its configured
        // port matches this — so a foreign app on a different port, or a port the
        // user re-pointed, fails fast per #308 instead of waiting on a non-existent
        // ghost of ours.
        TunnelManager.lastSelfDisconnectPort = boundPort
        // #333 fold-in: a future activity reservation (e.g. noteActivity(forAtLeast:)
        // from a speed test) parks `lastTunnelActivityDate` ahead; if it survived
        // teardown it would suppress keep-alive on the NEXT session for one interval.
        // Clear it so each session starts with a clean keep-alive baseline.
        TunnelManager.lastTunnelActivityDate = nil
        state = .disconnected
    }

    // boc #483: teardown owns BOTH the start continuation and the runtime. A
    // detached start can have been queued but not yet entered Go when Stop runs.
    // Join that task and stop once more if it became live while Stop was draining.
    private func scheduleEngineStop() {
        guard let engine = activeEngine else { return }
        activeEngine = nil
        let attempt = engineTask
        engineTask = nil
        let previous = stopTask
        proxyStopPending = true
        stopTask = Task.detached { [weak self] in
            await previous?.value
            engine.stop()
            _ = await attempt?.value
            if engine.isRunning() { engine.stop() }
            // Native Stop is bounded. Do not let its timeout release identity.
            while engine.isRunning() {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await MainActor.run { self?.proxyStopPending = false }
        }
    }

    // #483: only the UI/recovery waiter times out; the real stop remains in
    // quarantine. A retry may proceed later if it finishes, but never overlaps.
    private func waitForProxyStop() async throws {
        let deadline = ContinuousClock.now + .seconds(teardownWaitSeconds)
        while proxyStopPending {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw VPNController.VPNControllerError(L10n.errorRuntimeStillStopping.localized())
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // #483: stop() captures its epoch synchronously, before this waiter is queued.
    private func scheduleVPNStop() {
        vpn.stop()
        let vpn = self.vpn
        vpnStopTask = Task { try await vpn.stopAndWait() }
    }

    // #483: structured shutdown for lifecycle owners/tests; unlike writing state,
    // awaiting this barrier proves no detached attempt can leak into the next test.
    func waitForTeardown() async throws {
        await stopTask?.value
        try await vpnStopTask?.value
    }
    // eoc #483
    // MARK: System-VPN mode (#vpn)

    // #483 was: vpnStartsInFlight counted caller Tasks, whose completion could
    // trail the actual OS handshake and suppress a real terminal notification.
    // VPNController now owns the single serialized isPreparingStart boundary.

    /// VPN-mode counterpart of `start(record:)`: builds a `VPNConfig` from the
    /// (already secret-hydrated, same as the proxy path) record and hands it to
    /// `VPNController`. From here on, NEVPNStatus observation drives the state
    /// machine — this method only reports synchronous validation/start errors.
    private func startVPN(record: ConnectionRecord) {
        guard case .olcrtc(let params) = record.details else {
            // Unreachable today (.olcrtc is the only ConnectionDetails case) —
            // defensive so a future protocol can't silently fall through.
            state = .failed(L10n.stateConnectFailed.localized())
            return
        }
        // boc #470: the VPN branch skipped both halves of the proxy `preflight`.
        // (1) No `startSession`, so a VPN-only user had NO connection log file —
        // every line stayed memory-only and vanished with the process. (2) No
        // structural validation, so a blanked key (subscription re-import, an
        // edited record) reached the appex, failed inside `rt.setKey` and came
        // back as the generic "VPN tunnel disconnected" with no hint at the
        // cause. Same order as the proxy path: session, validate, then dial.
        LogStore.shared.startSession(.connection)
        // videochannel pumps frames through an in-app WKWebView; an appex has
        // no UI process, so the packet-tunnel provider cannot run it.
        guard params.transport != "videochannel" else {
            LogStore.shared.log(.connection, "✗ \(L10n.vpnVideochannelUnsupported.localized())")
            state = .failed(L10n.vpnVideochannelUnsupported.localized())
            return
        }
        if let problem = Self.validate(params: params) {
            LogStore.shared.log(.connection, "✗ \(problem)")
            state = .failed(problem)
            return
        }
        LogStore.shared.log(.connection,
            L10n.connectingOlcrtc_fmt.formatted(params.carrier, params.transport, params.clientID),
            code: .connecting)  // OLC-1002 — the appex logs its own milestones from here on
        // eoc #470
        let s = SettingsStore.shared
        let config = VPNConfig(from: params,
                               dns: s.dnsServer,
                               timeoutMs: s.startTimeoutSeconds * 1000,
                               fallbackVP8FPS: s.vp8FPS,
                               fallbackVP8Batch: s.vp8BatchSize)
        // boc #485: fail closed with an actionable app error before asking NE
        // to launch a packet path that cannot carry UDP to the configured DNS.
        guard config.supportsPacketDNS else {
            state = .failed(L10n.vpnPacketDNSUnsupported.localized())
            return
        }
        // eoc #485
        state = .connecting
        // boc #483: own the entire handshake by epoch, not merely backend mode.
        let epoch = connectEpoch
        vpnStartTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.connectEpoch == epoch else { return }
            // #483: preparation/snapshot suppression belongs to VPNController.
            do {
                try await self.vpn.start(config)
                // #483 was: stale success called vpn.stop(), potentially stopping
                // a newer VPN. VPNController now prevents the stale start itself.
                guard !Task.isCancelled, self.connectEpoch == epoch else { return }
            } catch {
                // Only surface the failure if this VPN attempt is still the
                // current session (not superseded by a disconnect).
                if !Task.isCancelled, self.connectEpoch == epoch, self.activeMode == .vpn {
                    // boc #487: only this attempt's load/save permission failure
                    // authorizes fallback; network, key, carrier and DNS errors do not.
                    if let denied = error as? VPNController.CapabilityUnavailableError,
                       self.attemptModePreference == .automatic,
                       SettingsStore.shared.connectionModePreference == .automatic {
                        await self.fallbackToProxy(record: record, epoch: epoch, reason: denied.reason)
                    } else {
                        self.state = .failed((error as NSError).localizedDescription)
                    }
                    // eoc #487
                }
            }
        }
        // eoc #483
    }

    // boc #487: keep identity and the attempt epoch until NE is terminal AND
    // all setup/secret writes have drained. Never recursively connect(), and
    // never cancel the very task that owns this automatic continuation.
    private func fallbackToProxy(record: ConnectionRecord, epoch: Int, reason: String) async {
        scheduleVPNStop()
        let barrier = vpnStopTask
        do {
            try await barrier?.value
            guard !Task.isCancelled, connectEpoch == epoch, activeMode == .vpn,
                  lastRecord?.id == record.id else { return }
            guard SettingsStore.shared.connectionModePreference == .automatic else {
                state = .failed(reason)
                return
            }
            vpnStopTask = nil
            activeMode = .proxy
            LogStore.shared.log(.connection, L10n.vpnAutomaticFallback_fmt.formatted(reason))
            start(record: record) // proxy preflight claims its own engine epoch after this barrier.
        } catch {
            guard !Task.isCancelled, connectEpoch == epoch, activeMode == .vpn,
                  lastRecord?.id == record.id else { return }
            state = .failed(error.localizedDescription) // fail closed if stop/scrub is unconfirmed.
        }
    }
    // eoc #487

    // boc #477
    /// Hands the session over to the system tunnel that is already up: tears the
    /// proxy machinery down and switches `activeMode`, WITHOUT passing through
    /// `.disconnected` — the device is tunnelled, so the honest next state is
    /// whatever NEVPNStatus reports, which the caller applies immediately after.
    private func adoptSystemTunnel() {
        // #483: stale proxy outcomes (including health verdicts) lose ownership
        // before Stop can make their asynchronous start fail.
        connectEpoch &+= 1
        recoveryGeneration &+= 1
        lastRecord = nil // #483: profile identity is unknown; never inherit a proxy node.
        LogStore.shared.log(.connection,
            "• The system VPN tunnel is up and this app is not the one that started it. "
            + "Running the in-app proxy as well would put a second client with the same id "
            + "into the carrier room, and two clients sharing an id break each other — "
            + "so the proxy is standing down and the tunnel takes over.",
            level: .info)
        recoveryTask?.cancel();     recoveryTask = nil
        keepAliveTask?.cancel();    keepAliveTask = nil
        pendingStartTask?.cancel(); pendingStartTask = nil
        exitGeoTask?.cancel();      exitGeoTask = nil
        bgKeeper.stop()
        // Same off-actor teardown as `disconnect()` — MobileStop blocks up to 5 s.
        // #483 was: cancel/replace an unjoined detached stop.
        scheduleEngineStop()
        // The listener is going away with the engine; clearing the snapshot also
        // clears the mirrored credentials (`boundPort.didSet`).
        TunnelManager.lastSelfDisconnectPort = boundPort
        TunnelManager.lastSelfDisconnectDate = Date()
        TunnelManager.lastTunnelActivityDate = nil
        boundPort = nil
        activeMode = .vpn
    }

    /// #477: is a system tunnel carrying the device right now? True whether this
    /// app started it or the user did. Everything that measures a path — probes,
    /// exit-IP checks — has to ask this rather than `activeMode`, which only says
    /// what the app *believes* it is doing.
    var systemTunnelIsUp: Bool {
        Self.systemTunnelIsUp(activeMode: activeMode, state: state, vpnStatus: vpn.status,
                              foreignTunnel: SystemVPNPresence.isActive)   // #479
    }

    /// Pure half of the above, so every combination is unit-tested rather than
    /// reasoned about — the #472 mistake was getting exactly this table wrong.
    ///
    /// In VPN mode the state machine mirrors NEVPNStatus already, and iOS
    /// installs the routes when the provider answers `startTunnel` — BEFORE
    /// `.connected` — so only `.disconnected`/`.failed` are provably route-free
    /// (#472). In proxy mode the app's own state says nothing about a tunnel it
    /// did not start, so the observed NEVPNStatus is the only evidence.
    nonisolated static func systemTunnelIsUp(activeMode: TunnelMode,
                                             state: ConnectionState,
                                             vpnStatus: VPNController.Status,
                                             foreignTunnel: Bool = false) -> Bool {   // #479
        // #483: OS route evidence takes precedence over a stale app failure,
        // including routes still draining after the user pressed Disconnect.
        // Preserve #479's foreign-VPN guard in BOTH backend modes.
        if foreignTunnel || VPNController.mayHoldRoutes(vpnStatus) { return true }
        if activeMode == .vpn {
            switch state {
            case .disconnected, .failed:                        return false
            case .connecting, .connected, .waitingForNetwork:   return true
            }
        }
        // boc #479: a tunnel this app did not create carries the device just the
        // same. #477 could only see our OWN extension (NETunnelProviderManager
        // shows an app its own configurations and nobody else's), so the pairing
        // this app is most often used in — our SOCKS listener under a
        // third-party VPN client, the only arrangement available without a paid
        // signature — was invisible, and every side-channel probe went out
        // through it.
        if foreignTunnel { return true }
        // eoc #479
        switch vpnStatus {
        case .connected, .connecting, .reasserting, .disconnecting: return true // #483
        case .invalid, .disconnected: return false
        }
    }
    // eoc #477

    /// Bridge: NEVPNStatus (via VPNController) → the connection state machine.
    /// Only live in VPN mode — user `disconnect()` restores `activeMode` to
    /// `.proxy` BEFORE the observer's late emissions arrive, so an expected
    /// stop is skipped here and only an UNEXPECTED drop reaches `.failed`.
    private func vpnStatusChanged(_ status: VPNController.Status) {
        // #483: even a suppressed/transition-only status can change the routes
        // (notably disconnecting). Do not lose a brief up/down cycle to equality
        // of the eventual app state. Skip only the publisher's initial replay.
        if lastObservedVPNStatus != status {
            if lastObservedVPNStatus != nil { routeRevision &+= 1 }
            lastObservedVPNStatus = status
        }
        // #483: locally stopped profiles must reach terminal status before
        // queued connected/reasserting signals can be treated as adoption.
        if vpn.stopRequested { return }
        if vpnStopTask != nil, pendingStartTask != nil { return }
        // boc #477: the system tunnel is THIS app's packet-tunnel extension, and
        // it can come up without `connect()` ever running — the user flips the
        // profile on in iOS Settings or Control Centre, or it was left running
        // when the app relaunched. `activeMode` is still `.proxy` then, and the
        // guard below dropped the notification: the in-app proxy kept its own
        // session open, so the SAME clientID sat in the carrier room twice.
        //
        // Two peers sharing one identity break each other — the rule
        // `shouldSkipBatchPing` already encodes for probes, unenforced for the
        // proxy/VPN pair. Observed on the server as
        // `Current peers count: 2, Devices: [default, default]`, followed by the
        // proxy session going silent (`control missed pong` → `reason=liveness`).
        // Recovery then re-entered a room whose identity was taken, spent its
        // budget and landed in `.failed` — "Connection failed", for as long as
        // the VPN stayed on, which is exactly what was reported from the field.
        //
        // There is only one consistent answer: the system tunnel wins. It IS
        // this app's tunnel, it holds the identity, and it already carries the
        // whole device. The proxy stands down instead of fighting it.
        if activeMode == .proxy || (vpn.externallyStarted && lastRecord != nil),
           status == .connected || status == .connecting || status == .reasserting { // #483
            adoptSystemTunnel()
        }
        // eoc #477
        guard activeMode == .vpn else { return }
        // Pre-start snapshot emitted inside `vpn.start` — not a drop.
        // #483 was: vpnStartsInFlight > 0 also swallowed actual terminal events
        // delivered after NE returned but before the caller task resumed.
        if vpn.isPreparingStart, status == .disconnected { return }
        // boc #470: a `.disconnected` that arrives with NO provider error is, by
        // iOS's own definition (`fetchLastDisconnectError` → nil), not a failure:
        // the user toggled the tunnel off in Settings > VPN, or another VPN took
        // the slot. It used to become red "Connection failed · VPN tunnel
        // disconnected" plus the error haptic. A genuine drop still lands as
        // `.failed(reason)`: VPNController re-emits `.disconnected` once the
        // provider's error has been fetched (#469), and that second pass carries
        // the reason. `lastRecord`/`activeMode` are deliberately kept so that
        // second pass is not filtered out by the guard above.
        if status == .disconnected, vpn.lastDisconnectReason == nil {
            if lastRecord != nil {
                // Explicit level: the keyword classifier would file a line
                // containing "error" / "failure" as red, which is the point missed.
                LogStore.shared.log(.connection,
                    "• VPN tunnel stopped — no provider error reported (Settings > VPN toggle, or another VPN took over): "
                    + "treated as idle, not a failure; a provider error fetched later still lands as one",
                    level: .info)
            }
            state = .disconnected
            return
        }
        // eoc #470
        if let next = Self.connectionState(forVPNStatus: status,
                                           hasRecord: lastRecord != nil || vpn.lastDisconnectReason != nil, // #483: adopted failures still have a cause.
                                           reason: vpn.lastDisconnectReason) {
            state = next
        }
    }

    /// Pure NEVPNStatus → ConnectionState mapping for VPN mode (nil = leave
    /// the state unchanged). Factored out of `vpnStatusChanged` so it's
    /// unit-testable without NetworkExtension (Tests/VPNStatusMappingTests).
    ///
    /// - `.reasserting` (the system tunnel reconnecting after a path change)
    ///   maps to `.connecting` — closest in-app notion; the system brings the
    ///   tunnel back on its own, no in-app machinery involved.
    /// - `.disconnecting` and `.invalid` are transitional/no-information —
    ///   hold the current state until a terminal status arrives.
    /// - `.disconnected` with a record still held means the tunnel dropped
    ///   under us → `.failed` with the provider's reason when available;
    ///   without a record it's an ordinary idle `.disconnected`.
    /// #470: `vpnStatusChanged` no longer routes a reason-less `.disconnected`
    ///   through here (a stop without a provider error is idle, not failed), so
    ///   the generic `vpnDisconnected` fallback below is only reachable when a
    ///   caller passes `reason: nil` explicitly — it stays for the pinned
    ///   contract in `VPNStatusMappingTests` and as the safety net.
    nonisolated static func connectionState(forVPNStatus status: VPNController.Status,
                                            hasRecord: Bool,
                                            reason: String?) -> ConnectionState? {
        switch status {
        case .connecting:    return .connecting
        case .connected:     return .connected
        case .reasserting:   return .connecting
        case .disconnecting: return nil
        case .invalid:       return nil
        case .disconnected:
            return hasRecord ? .failed(reason ?? L10n.vpnDisconnected.localized())
                             : .disconnected
        }
    }

    // MARK: Keep-alive + auto-reconnect
    //
    // While the tunnel is .connected and the user has set
    // `keepAliveSeconds > 0`, fire `verifyTunnel()` periodically and
    // downgrade the state if it fails. iOS suspends the whole app when
    // backgrounded, so this Task naturally pauses then — no special
    // background handling needed.
    //
    // On sustained failure (3 consecutive misses ≈ 90 s) the keep-alive loop
    // hands off to the shared recovery sink (`requestReconnect`, #270) rather
    // than just dropping — see the Recovery section for the backoff policy.

    /// #470: how often the keep-alive loop re-checks the setting while it is 0.
    private nonisolated static let keepAliveIdlePollSeconds = 5

    private func startKeepAliveIfEnabled() {
        keepAliveTask?.cancel(); keepAliveTask = nil
        // #470 was: `let interval = SettingsStore.shared.keepAliveSeconds` +
        // `guard interval > 0 else { return }` — one snapshot at `.connected`, so
        // turning keep-alive on (or changing it) in Settings mid-session did
        // nothing until the next connect while Settings showed it as on. The
        // loop now re-reads the setting every tick and idles while it is 0
        // instead of returning (a returned loop never restarts — the same rule
        // the per-view `.task` loops follow).

        keepAliveTask = Task { @MainActor [weak self] in
            var failCount = 0  // consecutive failures; resets on any success or recent activity
            while !Task.isCancelled {
                // boc #470
                let interval = SettingsStore.shared.keepAliveSeconds
                guard interval > 0 else {
                    try? await Task.sleep(for: .seconds(Self.keepAliveIdlePollSeconds))
                    continue
                }
                // eoc #470
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                guard self.state.isConnected else { return }

                // #445 (audit fix 2): engine liveness is authoritative — checked
                // BEFORE the recent-activity skip and the HTTP probe. A dead Go
                // runtime means the SOCKS listener is gone, and neither signal
                // can be trusted then: URLSession silently BYPASSES a refusing
                // loopback proxy and completes probes DIRECT (Apple-confirmed
                // design), which also refreshes the activity marker via
                // `noteTunnelActivity` on what is actually direct traffic. Skip
                // the 3-strike budget entirely — the core is gone, not flaky.
                if self.activeEngine?.isRunning() == false {
                    LogStore.shared.log(.connection,
                        "✗ Keep-alive: engine is no longer running — connection lost",
                        code: .keepAliveLost)  // OLC-1012
                    self.failKeepAliveAndRecover()
                    return
                }

                // If data flowed through the tunnel recently (e.g. speed test, IP check),
                // the tunnel is clearly alive — skip the HTTP probe this round.
                // "Recently" = within the last keep-alive interval, same logic as WireGuard's
                // "if we received a packet, no need to send a handshake" heuristic.
                if let last = TunnelManager.lastTunnelActivityDate,
                   Date().timeIntervalSince(last) < Double(interval) {
                    failCount = 0
                    // #287: `noteActivity(forAtLeast:)` parks the marker in the
                    // *future* to reserve a known-busy window (e.g. a speed test),
                    // which made the "ago" math go negative ("active −N s ago").
                    let age = Date().timeIntervalSince(last)
                    LogStore.shared.log(.connection, Self.keepAliveSkipNote(ageSeconds: age))
                    continue
                }

                let ok = await Self.verifyTunnel()
                guard !Task.isCancelled, self.state.isConnected else { return }

                if ok {
                    failCount = 0
                    TunnelManager.lastTunnelActivityDate = Date()
                    LogStore.shared.log(.connection, L10n.keepAliveOK.localized(), code: .keepAliveOK)  // OLC-1010
                    // #456: free end-to-end evidence — verifyTunnel just returned
                    // HTTP 200 through the live node's own SOCKS port. Re-stamped
                    // every tick, so the live node never goes stale while up.
                    if let id = self.lastRecord?.id {
                        // #470: carry the live rtt forward. `noteLiveVerified`
                        // replaces the whole NodeHealth, and the Diagnostics card
                        // publishes a real sample every 8 s (HealthCard
                        // .publishLiveLatency) — a nil here wiped it on every
                        // tick, so the chip flipped "48 ms · now" ↔ "now".
                        // Only a `.working` entry can hold this session's sample.
                        // #470 was: HealthCoordinator.shared.noteLiveVerified(recordID: id, rttMs: nil)
                        let live = HealthCoordinator.shared.health(for: id)
                        let rtt = live?.resolvedKind == .working ? live?.rttMs : nil
                        HealthCoordinator.shared.noteLiveVerified(recordID: id, rttMs: rtt)
                    }
                } else {
                    failCount += 1
                    if failCount < 3 {
                        // Failures may be transient — heavy traffic, brief blip.
                        // Warn but keep the connection alive; next interval decides.
                        // 3 consecutive failures = 90s of sustained failure before disconnect.
                        LogStore.shared.log(.connection,
                            "⚠ Keep-alive failed (\(failCount)/3) — retrying next interval",
                            code: .keepAliveRetry)  // OLC-1011
                    } else if SystemVPNPresence.isActive, self.activeEngine?.isRunning() == true {
                        // boc #479: our verification goes out through our OWN SOCKS
                        // port, so under a third-party VPN that has not excluded
                        // this app it is captured and handed back to that port —
                        // a loop that hangs until the probe's own timeout. Three
                        // of those is 90 s, and this branch then tore down a
                        // session that was carrying traffic perfectly well, after
                        // which the reconnect failed on a port thick with
                        // TIME_WAIT. The engine is the evidence that survives: it
                        // is still running, so the session stands.
                        failCount = 0
                        LogStore.shared.log(.connection,
                            "• Keep-alive cannot verify through our own SOCKS port while another VPN "
                            + "carries this device — the core is still running, so the session stands. "
                            + "Exclude this app from that VPN to restore verification.",
                            level: .info)
                        // eoc #479
                    } else {
                        LogStore.shared.log(.connection, L10n.keepAliveLost.localized(), code: .keepAliveLost)  // OLC-1012
                        // #456: 3 consecutive verify misses with the engine still
                        // running and the path still satisfied = the link is up but
                        // no data passes. Recorded as `.handshake` ("connects but no
                        // data"), NOT as a grey "couldn't check" — we did check.
                        if let id = self.lastRecord?.id {
                            HealthCoordinator.shared.noteHandshakeOnly(
                                recordID: id,
                                detail: "keep-alive: no response through the tunnel",
                                source: "live")
                        }
                        // #445 was: engine.stop() ON the MainActor (froze the UI up
                        // to 5 s), then `.failed` BEFORE requestReconnect (whose
                        // didSet stopped the bg keeper before a recovery was
                        // pending, suspending a backgrounded app mid-backoff).
                        self.failKeepAliveAndRecover()
                        return
                    }
                }
            }
        }
    }

    /// Shared keep-alive-loss teardown (#445, audit fixes 2+3+5). Order matters:
    ///   1. stop the engine OFF the MainActor — master's Stop(ms) blocks until the
    ///      generation's goroutine exits (up to 5 s), which used to freeze the UI
    ///      right when the network died (#409 fixed only `disconnect()`); the
    ///      `stopTask` bookkeeping lets a following `connect()` cancel a late stop;
    ///   2. request the recovery loop BEFORE entering `.failed`, so the didSet
    ///      sees a pending recovery and keeps the background keeper alive through
    ///      the backoff sleeps (fix 3);
    ///   3. flip state — synchronously, so the UI reflects the loss at once.
    private func failKeepAliveAndRecover() {
        guard activeMode == .proxy else { return } // #483: never stop/recover beneath VPN.
        // #479: record the ghost BEFORE the state flip clears `boundPort`. The
        // bookkeeping that lets the next attempt wait for our own listener to
        // let go was written only by `disconnect()`, so a session that died on
        // its own — keep-alive loss here, a network drop in `handlePathUpdate` —
        // left none, and the reconnect two seconds later hit its own residue
        // and reported the port busy.
        noteOwnPortReleased()
        // #483 was: unjoined detached stop.
        connectEpoch &+= 1
        scheduleEngineStop()
        requestReconnect(reason: lastRecord?.displayName ?? "")
        state = .failed(L10n.serverConnectionLost.localized())
    }

    /// Single recovery sink (#270). Both keep-alive loss and #269's network
    /// events call this. Runs capped exponential-backoff reconnects until one
    /// connects *and* verifies (loop ends → backoff resets), or the attempt
    /// budget is spent (→ `.failed`, wait for the user). Idempotent: while a loop
    /// is live, further requests are no-ops so triggers can't stack.
    func requestReconnect(reason: String) { // #483: test the guarded recovery sink directly.
        // #483: gate both entry and every post-await continuation by backend.
        guard activeMode == .proxy, lastRecord != nil, recoveryTask == nil else { return }
        LogStore.shared.log(.connection, L10n.reconnecting_fmt.formatted(reason), code: .reconnecting)  // OLC-1013
        // #470: this loop's own stamp — see `recoveryGeneration`.
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // #470 was: defer { self.recoveryTask = nil } — ran when a CANCELLED
            // loop finally exited (it can sit for seconds in the awaited detached
            // stop or in `connectAndAwait`, neither of which observes
            // cancellation) and nilled the handle of the loop `handlePathUpdate`
            // + `requestReconnect` had started meanwhile. From then on that live
            // loop was invisible: its `.failed` stopped the background keeper
            // (the #445 fix-3 defect), a further path event stacked a third
            // loop beside it, and a user connect could not cancel it.
            defer { if self.recoveryGeneration == generation { self.recoveryTask = nil } }
            var attempt = 0
            // #453: protocols already tried this recovery run (seeded with the
            // starting record) so a failover hop never re-picks one.
            var tried: Set<UUID> = self.lastRecord.map { [$0.id] } ?? []
            while !Task.isCancelled {
                // #453/#455: a failover hop earns a SHORTENED budget only when
                // there is actually somewhere to hop TO. Compute the next untried
                // sibling up front (auto-failover on + proxy mode): when one
                // exists we spend a short budget so a blocked protocol is
                // abandoned fast; otherwise we keep the FULL backoff ladder, so a
                // single-protocol setup is never cut short just because
                // auto-failover is enabled (it defaults on now — #455). Recomputed
                // each iteration: the setting is live and `tried` grows per hop.
                let hop: ConnectionRecord? = (SettingsStore.shared.autoFailover && self.activeMode == .proxy)
                    ? self.lastRecord.flatMap { cur in
                        Self.nextFailoverCandidate(current: cur,
                                                   candidates: self.failoverCandidates?(cur) ?? [],
                                                   tried: tried)
                      }
                    : nil
                let budget = hop != nil ? Self.failoverAttemptsPerCandidate : Self.maxReconnectAttempts
                // #438: jittered so simultaneously-dropped clients don't rejoin the
                // carrier room in lockstep.
                let delay = Self.jitteredBackoffSeconds(attempt: attempt, random: .random(in: 0..<1))
                // #470: coded like the sink-entry line above — the catalog files
                // the per-attempt progression under OLC-1013 too, and a search
                // for the code used to show one line per recovery episode.
                LogStore.shared.log(.connection,
                    L10n.reconnectAttempt_fmt.formatted(attempt + 1, budget, Int(delay)),
                    code: .reconnecting)  // OLC-1013
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, self.activeMode == .proxy,
                      self.recoveryGeneration == generation,
                      let record = self.lastRecord else { return } // #483
                // Tear down whatever is bound to the old/dead path, then attempt a
                // fresh connect and await its verified outcome.
                // #445 (audit fix 5): Stop(ms) blocks until the generation's
                // goroutine exits (up to 5 s) — run it OFF the MainActor so every
                // backoff iteration doesn't freeze the UI. Ordering matters here
                // (the next attempt must not race the teardown), so AWAIT the
                // detached stop rather than fire-and-forget.
                // #445 was: self.activeEngine?.stop() on the MainActor.
                // #483 was: untracked detached stop that could outlive a switch.
                self.connectEpoch &+= 1
                self.scheduleEngineStop()
                // #483: a wedged native Stop must not leave recovery spinning
                // forever; report failure while the engine stays quarantined.
                do {
                    try await self.waitForProxyStop()
                    await self.stopTask?.value
                } catch {
                    guard !Task.isCancelled, self.recoveryGeneration == generation else { return }
                    self.recoveryTask = nil
                    self.state = .failed(error.localizedDescription)
                    return
                }
                // The awaited stop is a real suspension point — a user connect()/
                // disconnect() may have superseded this loop while it waited.
                // Re-check before preflighting a stale attempt (#386-style guard;
                // with the old synchronous stop no interleaving was possible here).
                guard !Task.isCancelled, self.activeMode == .proxy,
                      self.recoveryGeneration == generation else { return } // #483
                self.stopTask = nil
                let ok = await self.connectAndAwait(record)
                if Task.isCancelled || ok { return }   // superseded, or connected → done
                attempt += 1
                if attempt >= budget {
                    // #453: before giving up on this protocol, hop to another
                    // one on the SAME VPS (opt-in, proxy mode only — VPN-mode
                    // recovery is the appex/NEVPNStatus's job). A hop resets the
                    // attempt budget and continues the same recovery loop, so a
                    // blocked carrier fails over in ~14 s instead of dead-ending.
                    // #453/#455: hop to the sibling picked up front (nil when
                    // there is nowhere to fail over to → fall through to give up).
                    if let next = hop {
                        tried.insert(next.id)
                        LogStore.shared.log(.connection,
                            L10n.failoverSwitching_fmt.formatted(Self.carrierLabelForLog(record),
                                                                 Self.carrierLabelForLog(next)),
                            code: .failoverSwitch)   // OLC-1027
                        self.lastRecord = next
                        attempt = 0
                        continue
                    }
                    // #453: no untried alternative → give up. Distinct message
                    // when failover was on and actually hopped (tried > the seed).
                    let msg = (SettingsStore.shared.autoFailover && tried.count > 1)
                        ? L10n.failoverAllFailed.localized()
                        : L10n.reconnectGaveUp.localized()
                    LogStore.shared.log(.connection, msg, code: .reconnectFailed)  // OLC-1014
                    // #445 (audit fix 3): nil the handle BEFORE the `.failed`
                    // write — the didSet stops the background keeper only when no
                    // recovery is pending, and the `defer` above runs AFTER this
                    // assignment (too late for the didSet's guard). This is the
                    // final give-up: the keeper MUST stop so a backgrounded app
                    // doesn't burn battery waiting for a user who isn't looking.
                    self.recoveryTask = nil
                    self.state = .failed(msg)
                    return
                }
            }
        }
    }

    /// Capped exponential backoff before reconnect attempt `n` (#270):
    /// base·2^n clamped to `maxReconnectDelaySeconds`. n=0 → base. Pure → tested.
    nonisolated static func backoffDelaySeconds(attempt: Int) -> Double {
        let shift = min(max(attempt, 0), 20)            // clamp so 1<<shift can't overflow
        let delay = reconnectBaseDelaySeconds * Double(1 << shift)
        return min(delay, maxReconnectDelaySeconds)
    }

    /// #438: the same capped backoff with de-correlating jitter. When many clients
    /// drop together (a shared carrier-room or network outage), an identical
    /// deterministic backoff makes them all rejoin in lockstep and stampede the
    /// room; subtracting up to 25% spreads the attempts across a window without ever
    /// exceeding the cap or collapsing to ~0. `random` in [0,1) is injected so the
    /// spread is unit-testable (the caller passes `.random(in: 0..<1)`).
    nonisolated static func jitteredBackoffSeconds(attempt: Int, random: Double) -> Double {
        let base = backoffDelaySeconds(attempt: attempt)
        let r = min(max(random, 0), 1)
        return base * (1 - 0.25 * r)                    // in [0.75·base, base]
    }

    // MARK: Auto-failover (#453) — pure helpers
    //
    // On repeated reconnect failure for the active protocol, hop to another
    // protocol on the SAME VPS instead of giving up. The candidate list comes
    // from `failoverCandidates` (wired to `computeFailoverCandidates` below);
    // the loop in `requestReconnect` picks the next untried one.

    /// First candidate not yet tried this recovery run and not the current
    /// record. nil ⇒ every alternative has been tried → give up.
    nonisolated static func nextFailoverCandidate(current: ConnectionRecord,
                                                  candidates: [ConnectionRecord],
                                                  tried: Set<UUID>) -> ConnectionRecord? {
        candidates.first { $0.id != current.id && !tried.contains($0.id) }
    }

    /// Failover priority for a (carrier, transport): lower is tried first, so a
    /// known-good combo is preferred over an intermittent one. Maps the
    /// CarrierTransportMatrix verdict — recommended(0) < ok(1) < question(2) <
    /// fail/unknown(3).
    nonisolated static func failoverRank(carrier: String, transport: String) -> Int {
        switch CarrierTransportMatrix.compat(carrier: carrier, transport: transport) {
        case .recommended: return 0
        case .ok:          return 1
        case .question:    return 2
        case .fail, .unknown: return 3
        }
    }

    // boc #456: observed evidence outranks the static matrix
    /// #456: observed-evidence rank — MEASURED proof beats the compile-time
    /// compatibility table. A node the user just watched fail must stop being
    /// tried first (the exact defect: a field-dead but `.recommended`
    /// telemost/vp8 burned its whole budget ahead of a probe-verified sibling).
    /// 0 fresh verified · 1 aging verified · 2 unknown/inconclusive · 3 recently broken.
    nonisolated static func observedRank(_ display: HealthDisplay) -> Int {
        switch display {
        case .verified:                     return 0
        case .fading:                       return 1
        case .never, .checking, .stale, .inconclusive, .handshakeOnly: return 2
        case .broken:                       return 3
        }
    }
    // eoc #456

    /// Ordered failover alternatives for `current`: the OTHER `.olcrtc` records
    /// on the SAME VPS (the ServerHost whose primary/extra connection ids
    /// include `current.id`), best-first by `failoverRank`. Empty when the
    /// record isn't tied to a known host or the stores are gone. @MainActor —
    /// it reads the two stores; the wiring closure is invoked on the main actor.
    @MainActor
    static func computeFailoverCandidates(_ current: ConnectionRecord,
                                          store: ConnectionStore?,
                                          serverStore: ServerHostStore?) -> [ConnectionRecord] {
        guard let store, let serverStore else { return [] }
        guard let host = serverStore.hosts.first(where: {
            $0.lastConnectionID == current.id || ($0.extraConnectionIDs?.contains(current.id) ?? false)
        }) else { return [] }
        let ids = [host.lastConnectionID].compactMap { $0 } + (host.extraConnectionIDs ?? [])
        let records = ids.compactMap { id in store.connections.first(where: { $0.id == id }) }
        let siblings = records
            .filter { $0.id != current.id }
            .filter { if case .olcrtc = $0.details { return true } else { return false } }
        // boc #456: (observed, matrix, name) lexicographic — ordering ONLY.
        // The reconnect loop, its budget, its epochs and its cancellation guards
        // are untouched; only WHICH sibling is tried first changes.
        // The observed ranks are snapshotted against ONE `now` before sorting:
        // re-reading the clock inside the comparator could flip a node across the
        // fresh/stale boundary mid-sort and yield an inconsistent ordering.
        // #456 was: .sorted by `rank(of:)` (the static matrix) then displayName.
        let now = Date()
        // `uniquingKeysWith`, never `uniqueKeysWithValues`: a host whose
        // extraConnectionIDs happen to repeat an id would trap the app otherwise.
        let observed: [UUID: Int] = Dictionary(
            siblings.map {
                ($0.id, observedRank(HealthCoordinator.shared.display(for: $0.id, now: now)))
            },
            uniquingKeysWith: { first, _ in first })
        return siblings.sorted { a, b in
            let oa = observed[a.id] ?? 2, ob = observed[b.id] ?? 2
            if oa != ob { return oa < ob }
            let ra = rank(of: a), rb = rank(of: b)
            if ra != rb { return ra < rb }
            return a.displayName < b.displayName   // stable, deterministic
        }
        // eoc #456
    }

    /// #453: failoverRank for a record's olcrtc params (worst rank for a
    /// non-olcrtc record, which computeFailoverCandidates has already filtered).
    private nonisolated static func rank(of record: ConnectionRecord) -> Int {
        guard case .olcrtc(let p) = record.details else { return Int.max }
        return failoverRank(carrier: p.carrier, transport: p.transport)
    }

    /// #453: carrier label for the failover log line (falls back to the record's
    /// display name for a non-olcrtc record, which shouldn't reach failover).
    private nonisolated static func carrierLabelForLog(_ record: ConnectionRecord) -> String {
        if case .olcrtc(let p) = record.details {
            return CarrierTransportMatrix.carrierLabel(p.carrier)
        }
        return record.displayName
    }

    // MARK: Network-path reconnect (#269)
    //
    // While we hold an active session, react to the network path changing:
    //   • path lost     → cancel recovery, hold `.waitingForNetwork` (don't burn
    //                     retries with no route), wait for the path to return;
    //   • path regained → reconnect;
    //   • interface swap while still satisfied (Wi-Fi↔cellular) → reconnect onto
    //                     the new path.
    // Regain/swap feed the shared backoff sink (`requestReconnect`, #270), so a
    // network round-trip resets the backoff. Follow-ups: #271 adds a room-settle
    // delay, #272 a generation guard for the in-flight-reconnect race.

    private func startPathMonitorIfNeeded() {
        guard runtimeEffectsEnabled, !pathMonitorStarted else { return } // #483
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // Snapshot the two facts we need off the monitor's queue, then hop
            // to MainActor for every state decision.
            let satisfied = path.status == .satisfied
            let primary   = Self.primaryInterface(of: path)
            Task { @MainActor in self?.handlePathUpdate(satisfied: satisfied, primary: primary) }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// Translates a path update into a side-effect via the pure `pathDecision`,
    /// then refreshes the last-seen baseline.
    private func handlePathUpdate(satisfied: Bool, primary: NWInterface.InterfaceType?) {
        // #vpn: path-driven reconnects are in-app-proxy machinery. In VPN mode
        // `lastRecord` is non-nil, so without this gate a Wi-Fi drop would put
        // a live SYSTEM tunnel into `.waitingForNetwork` and the path's return
        // would start the in-app proxy engine underneath it. The system tunnel
        // handles path changes itself (NEVPNStatus `.reasserting`, bridged via
        // `vpnStatusChanged`). Keep the last-seen baseline fresh either way so
        // a later proxy session starts from current facts.
        guard activeMode == .proxy else {
            lastPathSatisfied    = satisfied
            lastPrimaryInterface = primary
            return
        }
        let action = Self.pathDecision(
            satisfied: satisfied, primary: primary,
            wasSatisfied: lastPathSatisfied, lastPrimary: lastPrimaryInterface,
            state: state, hasActiveRecord: lastRecord != nil)
        // Update the baseline regardless of what we do with this transition.
        lastPathSatisfied    = satisfied
        lastPrimaryInterface = primary

        switch action {
        case .none:
            break
        case .waitForNetwork:
            // Stop spending reconnect attempts with no route; cancel any live
            // recovery loop — a fresh one starts (below) when the path returns.
            recoveryTask?.cancel(); recoveryTask = nil
            LogStore.shared.log(.connection, L10n.netPathLost.localized(), code: .waitingNetwork)  // OLC-1015
            // #445 (audit fix 5): Stop(ms) blocks until the goroutine exits (up
            // to 5 s) — running it here ON the MainActor froze the UI exactly
            // when Wi-Fi dropped. Same detached fire-and-forget as disconnect()
            // (#409), incl. the stopTask bookkeeping so a following connect()
            // can cancel a stray late stop; the state flip stays synchronous.
            // #445 was: activeEngine?.stop()
            noteOwnPortReleased()   // #479 — see failKeepAliveAndRecover
            // #483 was: unjoined stop and live epoch after a network hold.
            connectEpoch &+= 1
            scheduleEngineStop()
            state = .waitingForNetwork
        case .reconnect(let reason):
            let text = reason == .restored
                ? L10n.netPathRestored.localized()
                : L10n.netPathChanged.localized()
            requestReconnect(reason: text)
        }
    }

    /// The primary interface a path routes over, by priority; nil for an
    /// unsatisfied path. `nonisolated` because it runs on the monitor queue.
    nonisolated private static func primaryInterface(of path: NWPath) -> NWInterface.InterfaceType? {
        for type in [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other]
            where path.usesInterfaceType(type) {
            return type
        }
        return nil
    }

    /// Pure decision for a network-path update (#269) — factored out of
    /// `handlePathUpdate` so it's unit-testable without an `NWPath`.
    ///
    /// - `wasSatisfied == nil` means no baseline yet (first update) → `.none`.
    /// - Only an active session reacts; `.disconnected` and `.failed` (a down
    ///   server isn't a path problem) are ignored.
    /// - `.connecting` reacts only to a *loss* (→ wait); a mid-connect interface
    ///   wobble is left for the in-flight attempt to resolve, avoiding thrash.
    nonisolated static func pathDecision(satisfied: Bool,
                                         primary: NWInterface.InterfaceType?,
                                         wasSatisfied: Bool?,
                                         lastPrimary: NWInterface.InterfaceType?,
                                         state: ConnectionState,
                                         hasActiveRecord: Bool) -> NetworkPathAction {
        guard wasSatisfied != nil, hasActiveRecord else { return .none }
        switch state {
        case .disconnected, .failed: return .none
        case .connected, .connecting, .waitingForNetwork: break
        }
        guard satisfied else {
            // Already holding → nothing new to do.
            return state == .waitingForNetwork ? .none : .waitForNetwork
        }
        if wasSatisfied == false || state == .waitingForNetwork {
            return .reconnect(.restored)
        }
        if state == .connected, primary != lastPrimary {
            return .reconnect(.interfaceChanged)
        }
        return .none
    }

    // MARK: Generic engine start (#243)

    /// Synchronous preflight on MainActor: select the engine, run structural
    /// validation, reserve a free SOCKS port + snapshot settings, and flip to
    /// `.connecting`. Returns the launch params, or nil if it already set
    /// `.failed` (validation) / couldn't reserve a port. Shared by the
    /// fire-and-forget `start` (`isReconnect: false`) and the awaitable
    /// `connectAndAwait` (`isReconnect: true`, #270) — the flag rides into
    /// `EngineStartSettings` to drive the engine's room-settle delay (#271).
    private func preflight(_ record: ConnectionRecord, isReconnect: Bool)
        -> (engine: any TunnelEngine, details: ConnectionDetails, port: Int, settings: EngineStartSettings, epoch: Int)? {
        guard activeMode == .proxy, !Task.isCancelled else { return nil } // #483
        startPathMonitorIfNeeded()
        let engine = engineOverride ?? record.details.engine // #483: no native runtime in unit tests.
        LogStore.shared.startSession(.connection)
        if let problem = engine.validate(record.details) {
            LogStore.shared.log(.connection, "✗ \(problem)")
            state = .failed(problem)
            return nil
        }
        guard let (port, settings) = reservePortAndSettings(details: record.details,
                                                            isReconnect: isReconnect) else { return nil }
        activeEngine = engine // #483: invalid/preflight-only attempts own no runtime.
        // #313: record the port this attempt binds (#308: exactly the reserved
        // snapshot, never slid) — set before `.connecting` so the didSet for
        // that state can't observe a stale value.
        boundPort = port
        // New attempt → new epoch (bumped before `.connecting` so the value
        // `runEngine` captures is the one live for this attempt, #272).
        connectEpoch &+= 1
        state = .connecting
        return (engine, record.details, port, settings, connectEpoch)
    }

    /// True iff `epoch` is still the current attempt *and* we're mid-connect — the
    /// guard every `runEngine` MainActor hop uses before mutating state (#272).
    /// The `state == .connecting` half catches user-disconnect / network-loss
    /// supersession; the epoch half catches a disconnect→reconnect that returns
    /// to `.connecting` under a *different* attempt.
    private func isLiveAttempt(_ epoch: Int) -> Bool {
        // #483 was: epoch/state only, accepting the adopted VPN's connecting.
        activeMode == .proxy && connectEpoch == epoch && state == .connecting
    }

    // boc #477: stop the engine only while THIS attempt still owns it.
    // `OlcrtcEngine` is a process-wide singleton — `stop()` ends whatever
    // generation is running, not "mine". #469 moved `runEngine`'s two superseded
    // -branch stops off the MainActor (`Task.detached { engine.stop() }`) to
    // unfreeze the UI, and in doing so removed the serialisation that had made
    // them safe: a stop scheduled by an attempt that LOST the race could now
    // land after the winner had already connected, tearing a healthy session
    // down. Whoever superseded us — `disconnect()`, or a newer attempt — owns
    // the teardown and does it themselves; we clean up only when the epoch is
    // still ours.
    /// Tears the engine down off-actor, but only if no newer attempt has claimed it.
    private func stopEngineIfStillOurs(_ engine: any TunnelEngine, epoch: Int) {
        // #483 was: unjoined detached Stop; superseding sessions own teardown.
        guard activeMode == .proxy, connectEpoch == epoch else { return }
        scheduleEngineStop()
    }
    // eoc #477

    /// User-initiated connect: preflight, then hand the blocking native work to a
    /// detached task (fire-and-forget — a failure lands in `.failed` and waits
    /// for the user, it does NOT enter the recovery loop, so a bad manual connect
    /// can't spin a backoff).
    private func start(record: ConnectionRecord) {
        // #333: in the common case the configured port is free, so preflight runs
        // synchronously here and flips to `.connecting` in the same turn (the
        // responsive, test-observable fast path). Only when the port is busy on
        // *our own* recent ghost do we detour through an async same-port wait,
        // then preflight once it frees up.
        if shouldWaitForOwnPortReleaseNow() {
            // #386: snapshot the epoch BEFORE the wait. A disconnect+reconnect
            // inside the ≤5 s wait runs its own preflight (bumping connectEpoch)
            // and lands back on `.connecting` for a DIFFERENT record — the old
            // `state == .connecting` guard couldn't tell the two apart and would
            // preflight the stale record last, connecting the wrong exit node.
            // #469: bump BEFORE flipping to .connecting. `isLiveAttempt(epoch)` is
            // `connectEpoch == epoch && state == .connecting`; without the bump a
            // superseded attempt's continuation — its epoch still equal to the
            // unchanged counter — saw .connecting and published ITS result, so a
            // failed verify from record A landed in record B's pending connect.
            connectEpoch &+= 1
            let epochAtWaitStart = connectEpoch
            state = .connecting   // optimistic: hold the toggle ON while we wait
            // #386: store the Task so disconnect()/connect() can cancel it; was a
            // fire-and-forget Task that nothing could stop.
            pendingStartTask = Task { [weak self] in
                guard let self else { return }
                await self.waitForOwnPortRelease()
                // The wait may have been superseded — either the user flipped off
                // (→ .disconnected) or a newer connect() ran its own preflight and
                // bumped the epoch. Proceed only if we're still the SAME pending
                // attempt: state held at .connecting AND no newer connect intervened.
                guard !Task.isCancelled,
                      self.state == .connecting,
                      self.connectEpoch == epochAtWaitStart else { return }
                guard let (engine, details, port, settings, epoch) = self.preflight(record, isReconnect: false) else { return }
                self.engineTask = Task.detached { [weak self] in // #483: join before releasing identity.
                    await Self.runEngine(engine: engine, details: details,
                                         port: port, settings: settings, epoch: epoch, manager: self)
                }
            }
            return
        }
        guard let (engine, details, port, settings, epoch) = preflight(record, isReconnect: false) else { return }
        engineTask = Task.detached { [weak self] in // #483
            await Self.runEngine(engine: engine, details: details,
                                 port: port, settings: settings, epoch: epoch, manager: self)
        }
    }

    /// Awaitable single connect attempt for the recovery loop (#270): the same
    /// preflight + engine path as `start`, but returns whether it connected *and*
    /// verified, so the loop can stop (success) or back off (failure).
    @discardableResult
    private func connectAndAwait(_ record: ConnectionRecord) async -> Bool {
        let generation = recoveryGeneration // #483: the port wait can be superseded.
        if shouldWaitForOwnPortReleaseNow() { await waitForOwnPortRelease() }   // #333
        guard !Task.isCancelled, activeMode == .proxy,
              recoveryGeneration == generation else { return false } // #483
        guard let (engine, details, port, settings, epoch) = preflight(record, isReconnect: true) else { return false }
        let task = Task.detached { // #483: keep the same teardown ownership as manual starts.
            await Self.runEngine(engine: engine, details: details,
                                 port: port, settings: settings, epoch: epoch, manager: self)
        }
        engineTask = task
        return await task.value
    }

    // boc #479
    /// Records that OUR listener is letting go of `boundPort` right now, so the
    /// next attempt knows the residue on that port is ours and waits for it
    /// instead of failing fast (#333/#394). Must run while `boundPort` still
    /// holds the value — the `.failed`/`.waitingForNetwork` didSet clears it.
    private func noteOwnPortReleased() {
        guard let held = boundPort else { return }
        TunnelManager.lastSelfDisconnectPort = held
        TunnelManager.lastSelfDisconnectDate = Date()
    }
    // eoc #479

    /// #333: is the configured SOCKS port busy *because* we just tore down our own
    /// listener (within `selfDisconnectGhostWindow`)? Reads live state on MainActor
    /// and delegates the verdict to the pure `shouldWaitForOwnPortRelease`.
    private func shouldWaitForOwnPortReleaseNow() -> Bool {
        let configuredPort = SettingsStore.shared.socksPort
        let ago = TunnelManager.lastSelfDisconnectDate.map { Date().timeIntervalSince($0) }
        return Self.shouldWaitForOwnPortRelease(
            portFree: portIsFree(UInt16(configuredPort)), // #483
            selfDisconnectedAgo: ago,
            // #394: the busy port must be the one our last session released, else
            // there's no ghost of ours to wait for → fail fast (#308).
            configuredPort: configuredPort,
            releasedPort: TunnelManager.lastSelfDisconnectPort)
    }

    /// #333: poll the SAME configured port until it frees up — up to
    /// `portReleaseMaxWait`, every `portReleasePollInterval` — before the
    /// preflight's #308 check runs. Keeps the #308 contract: we never slide to
    /// another port; on timeout the preflight surfaces the typed busy error as
    /// usual. Only called when `shouldWaitForOwnPortReleaseNow()` is true, so a
    /// foreign-held port is never waited on (it still fails fast).
    private func waitForOwnPortRelease() async {
        let port = UInt16(SettingsStore.shared.socksPort)
        LogStore.shared.log(.connection, L10n.waitingForPortRelease.localized())
        let deadline = Date().addingTimeInterval(Self.portReleaseMaxWait)
        while !Task.isCancelled, Date() < deadline { // #483: cancelled waits must yield immediately.
            if portIsFree(port) { return } // #483
            try? await Task.sleep(for: .seconds(Self.portReleasePollInterval))
        }
        // Fell through → still busy; preflight's isFree() check fails fast with the
        // typed busy error (no special handling needed here).
    }

    /// Checks the configured SOCKS port is free and snapshots the `SettingsStore`
    /// values the engine needs — both on MainActor. Returns nil (and sets
    /// `.failed`) if the configured port is busy. #445 (audit fix 1): also
    /// snapshots the effective SOCKS credentials into `liveSocksCredentials` so
    /// off-MainActor URLSessions (`SOCKSSession.make`) can authenticate against
    /// the listener this attempt is about to configure.
    private func reservePortAndSettings(details: ConnectionDetails,
                                        isReconnect: Bool) -> (port: Int, settings: EngineStartSettings)? {
        let s = SettingsStore.shared
        let configuredPort = UInt16(s.socksPort)
        // #308: always bind the *configured* port — never auto-slide to another.
        // The port is the contract with external SOCKS clients (Shadowrocket,
        // browsers) pointed at exactly it, so a single isFree() check that fails
        // fast on a busy port is correct; the user frees it or changes the setting.
        // #308 was: PortAvailability.nextFreePort auto-slide + portChangedAuto log.
        guard portIsFree(configuredPort) else { // #483
            let msg = L10n.errorPortBusy_fmt.formatted(Int(configuredPort))
            LogStore.shared.log(.connection, "✗ \(msg)", code: .portBusy)  // OLC-1026 (docs/diagnostic-messages.md)
            // #479 was: `state = .failed(msg)` on every path. Inside the recovery
            // loop that painted a terminal red error while the loop was still
            // backing off and about to try again — and the usual cause is our own
            // listener still letting go, which the next attempt resolves. A manual
            // connect still ends here, where the user is waiting for an answer.
            if !isReconnect { state = .failed(msg) }
            return nil
        }
        // #445 (audit fix 1): mirror the credentials the engine will feed the Go
        // listener (the same expression as OlcrtcEngine.start: Settings creds
        // when local auth is ON, else the record's own). Set only after the port
        // check succeeds, cleared with `boundPort` (its didSet).
        let recordCreds: (user: String, pass: String) = {
            if case .olcrtc(let p) = details { return (p.socksUser, p.socksPass) }
            return ("", "")
        }()
        TunnelManager.liveSocksCredentials = Self.effectiveSocksCredentials(
            localAuthEnabled: s.localSocksAuthEnabled,
            settingsUser: s.localSocksUser, settingsPass: s.localSocksPass,
            recordUser: recordCreds.user, recordPass: recordCreds.pass)
        let settings = EngineStartSettings(
            dns:                   s.dnsServer,
            debugEnabled:          s.debugLogging,
            timeoutMs:             s.startTimeoutSeconds * 1000,
            vp8FPS:                s.vp8FPS,
            vp8Batch:              s.vp8BatchSize,
            localSocksAuthEnabled: s.localSocksAuthEnabled,
            localSocksUser:        s.localSocksUser,
            localSocksPass:        s.localSocksPass,
            isReconnect:           isReconnect)
        return (Int(configuredPort), settings)
    }

    /// Off-MainActor: start the engine (blocking native work), then verify
    /// end-to-end connectivity and post the final state. State reads/writes hop
    /// to MainActor via `manager`. The engine logs its own protocol-specific
    /// milestones and failures and tears down its runtime on failure; this layer
    /// owns only the generic state machine + SOCKS verification.
    @discardableResult
    private static func runEngine(engine: any TunnelEngine,
                                  details: ConnectionDetails,
                                  port: Int,
                                  settings: EngineStartSettings,
                                  epoch: Int,
                                  manager: TunnelManager?) async -> Bool {
        // #483: a queued detached task must not start a runtime after Disconnect
        // already completed its first Stop. Teardown also joins this task.
        guard await MainActor.run(body: { manager?.isLiveAttempt(epoch) == true }) else { return false }
        do {
            try await engine.start(details, port: port, settings: settings)
        } catch let e as TunnelEngineError {
            await MainActor.run {
                guard manager?.isLiveAttempt(epoch) == true else { return }
                // #456: a real connect attempt failed — record it as measured
                // evidence for this node (mapped to a human reason at display time).
                if let id = manager?.lastRecord?.id {
                    // #456: `e.message` is already localized — pass the engine's
                    // own stable classification so a Russian UI still resolves
                    // "the key no longer matches" instead of "couldn't check".
                    HealthCoordinator.shared.noteFailure(recordID: id, raw: e.message,
                                                         source: "connect", classified: e.reason)
                }
                manager?.state = .failed(e.message)
            }
            return false
        } catch {
            await MainActor.run {
                guard manager?.isLiveAttempt(epoch) == true else { return }
                // #456: same as above for a non-typed engine error.
                if let id = manager?.lastRecord?.id {
                    HealthCoordinator.shared.noteFailure(recordID: id,
                                                         raw: error.localizedDescription,
                                                         source: "connect")
                }
                manager?.state = .failed(error.localizedDescription)
            }
            return false
        }
        // Guard: a disconnect or a newer attempt (#272) may have superseded us
        // while the engine was starting.
        let stillLive = await MainActor.run { manager?.isLiveAttempt(epoch) == true }
        // #477 was: a bare `engine.stop()` — the same unowned teardown as the two
        // branches below. This one runs off-actor, so the ownership check has to
        // hop; the stop it schedules is detached either way.
        guard stillLive else {
            await MainActor.run { manager?.stopEngineIfStillOurs(engine, epoch: epoch) }
            return false
        }

        // #483: injected verification makes state tests fully network-independent.
        let injectedVerify = await MainActor.run { manager?.verifyOverride }
        let tunnelOK: Bool
        if let injectedVerify { tunnelOK = await injectedVerify() }
        else { tunnelOK = await verifyTunnel() }
        return await MainActor.run {
            // Guard again: disconnect() / a newer attempt may have intervened
            // during verifyTunnel() — only the still-current attempt posts a result.
            guard manager?.isLiveAttempt(epoch) == true else {
                // #469 was: `engine.stop()` inside MainActor.run — MobileStop
                // blocks up to 5 s while the WebRTC session closes and froze the
                // UI for exactly that long (#445 moved every OTHER stop off the
                // actor; these two were missed).
                // #477 was: `Task.detached { engine.stop() }` — unowned, so this
                // superseded attempt could stop the winner's live session.
                manager?.stopEngineIfStillOurs(engine, epoch: epoch)
                return false
            }
            if tunnelOK {
                LogStore.shared.log(.connection, L10n.tunnelOK.localized(), code: .tunnelWorks)  // OLC-1007
                manager?.state = .connected
                // #456: verifyTunnel just proved HTTP 200 through this node's own
                // SOCKS port — the strongest evidence there is, and free. No rtt:
                // verifyTunnel races several URLs and reports a boolean only.
                if let id = manager?.lastRecord?.id {
                    HealthCoordinator.shared.noteLiveVerified(recordID: id, rttMs: nil)
                }
                return true
            } else {
                LogStore.shared.log(.connection, L10n.tunnelFailed.localized(), code: .tunnelDown)  // OLC-1009
                // #469: off the actor — see above. #477: and only while ours.
                manager?.stopEngineIfStillOurs(engine, epoch: epoch)
                // #456: the transport came up (start + waitReady succeeded) but
                // verifyTunnel got no HTTP 200 — this is EXACTLY "connects but no
                // data", the user's telemost incident, so it is recorded as
                // `.handshake` (amber) rather than routed through `noteFailure`.
                // A localized reason string would also map to `.unknown` (grey
                // "couldn't check"), which would be dishonest: we DID check.
                if let id = manager?.lastRecord?.id {
                    HealthCoordinator.shared.noteHandshakeOnly(
                        recordID: id,
                        detail: "connect: tunnel came up but verifyTunnel got no response",
                        source: "connect")
                }
                manager?.state = .failed(L10n.serverNotResponding.localized())
                return false
            }
        }
    }

    // MARK: Validation
    //
    // Cheap structural checks that surface friendlier errors than the Go
    // runtime would. Anything expensive to verify (network reachability,
    // room existence) is left to MobileStart/WaitReady.
    nonisolated static func validate(params: OlcrtcConnection) -> String? {
        let clientID = params.clientID.trimmingCharacters(in: .whitespaces)
        if clientID.isEmpty            { return L10n.validateClientIDEmpty.localized() }
        if clientID.contains(where: \.isWhitespace) { return L10n.validateClientIDWhitespace.localized() }

        let key = params.key
        if key.count != 64             { return L10n.validateKeyLength_fmt.formatted(key.count) }
        if key.contains(where: { !$0.isHexDigit }) { return L10n.validateKeyNonHex.localized() }

        if params.roomID.trimmingCharacters(in: .whitespaces).isEmpty {
            return L10n.validateRoomIDEmpty.localized()
        }
        return nil
    }

    // End-to-end tunnel probe: HTTPS request(s) through the local SOCKS5
    // listener. Iterates through `AppConstants.tunnelVerifyURLs` until one
    // returns 200 — fallbacks matter because individual probe hosts have
    // been observed to be blocked from some carriers.
    //
    // Without this, ICE-connected-but-TURN-rejected states would be reported
    // as .connected to the UI.
    /// #287: wording for the "keep-alive skipped" line. `noteActivity(forAtLeast:)`
    /// can park the activity marker in the future, so a naive "ago" goes negative —
    /// report the reserved window instead of "active −N s ago".
    nonisolated static func keepAliveSkipNote(ageSeconds: Double) -> String {
        ageSeconds < 0
            ? "♡ Keep-alive skipped — tunnel busy (\(Int(-ageSeconds))s reserved)"
            : "♡ Keep-alive skipped — tunnel active \(Int(ageSeconds))s ago"
    }

    /// #287: a valid verify URL only reports "bad URL" when the SOCKS session
    /// itself can't be built (e.g. the proxy is gone mid-teardown). Translate that
    /// to a truthful reason; pass everything else through unchanged.
    nonisolated static func verifyFailureReason(_ error: Error) -> String {
        if let u = error as? URLError, u.code == .badURL || u.code == .unsupportedURL {
            return "proxy not ready"
        }
        return error.localizedDescription
    }

    /// #445 (audit fix 2): does a 2-byte SOCKS5 method-selection reply indicate a
    /// live listener? Byte 0 must be the SOCKS version (0x05); byte 1 is the
    /// server's chosen method (0x00 no-auth or 0x02 user/pass — both mean the
    /// listener is alive, and master answers before any credentials are needed,
    /// so this works regardless of auth config). Pure → tested
    /// (Tests/SOCKSVerifyTests.swift).
    nonisolated static func isSocksGreetingReply(_ data: Data) -> Bool {
        data.count >= 2 && data.first == 0x05
    }

    /// #445 (audit fix 2): raw SOCKS5 greeting against the local listener.
    /// URLSession's `connectionProxyDictionary` silently BYPASSES a proxy that
    /// REFUSES the connection and completes the request DIRECT (Apple-confirmed:
    /// "the proxy system is designed to make requests work"), so an HTTP 200
    /// through the "tunnel" session proves nothing once the Go listener is dead —
    /// on loopback a dead listener is an instant ECONNREFUSED, i.e. exactly the
    /// bypass case. This NWConnection probe cannot be bypassed: connect to
    /// 127.0.0.1:port, send the method-selection greeting [0x05, 0x01, 0x00],
    /// require a 2-byte version-0x05 reply. `.waiting` (Network framework's state
    /// for a refused loopback connect, which it would otherwise retry) counts as
    /// dead — nothing transient explains it on loopback.
    nonisolated static func socksListenerAnswers(port: Int, timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { continuation in
            let conn = NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any,
                using: .tcp)
            let gate = ContinuationGate()   // resume-at-most-once (#400)

            func finish(_ answered: Bool) {
                guard gate.fire() else { return }
                conn.cancel()
                continuation.resume(returning: answered)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data([0x05, 0x01, 0x00]),
                              completion: .contentProcessed { sendErr in
                        if sendErr != nil { finish(false) }
                    })
                    conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, error in
                        finish(error == nil && Self.isSocksGreetingReply(data ?? Data()))
                    }
                case .waiting, .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            conn.start(queue: .global())
            // Timeout backstop; the closure retains `conn` until it fires, and the
            // gate makes a late fire a no-op.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private static func verifyTunnel() async -> Bool {
        // #445 (audit fix 2): fail-closed pre-check. Gate the HTTP probes on the
        // raw greeting so a refused loopback connect can never be masked by
        // URLSession's direct-bypass into a false "tunnel OK" — which previously
        // kept a dead session "Connected" indefinitely, showed the user's REAL IP
        // as the exit, and sent in-app "tunnel" traffic direct.
        let activePort = TunnelManager.activeSocksPort
        guard await socksListenerAnswers(port: activePort) else {
            LogStore.shared.log(.connection,
                "✗ tunnel verify: SOCKS5 listener on 127.0.0.1:\(activePort) is not answering",
                code: .verifyFailed)  // OLC-1006
            return false
        }
        let session = SOCKSSession.make(mode: .tunnel, timeout: 20)
        // #333 fold-in: tear the session down once we have a verdict so the losing /
        // cancelled probe tasks don't linger in flight against the (about-to-close)
        // SOCKS listener. `finishTasksAndInvalidate` lets the winner's transfer
        // complete, then releases the session and any sockets it held.
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: (String, Bool).self) { group in
            for urlString in AppConstants.tunnelVerifyURLs {
                guard let url = URL(string: urlString) else { continue }
                group.addTask {
                    do {
                        let (_, response) = try await session.data(from: url)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        if status == 200 {
                            await MainActor.run {
                                LogStore.shared.log(.connection, "✓ tunnel verify via \(urlString)",
                                                    code: .verifyOK)  // OLC-1005
                            }
                            return (urlString, true)
                        }
                        await MainActor.run {
                            LogStore.shared.log(.connection,
                                "✗ tunnel verify via \(urlString): HTTP \(status)",
                                code: .verifyFailed)  // OLC-1006
                        }
                        return (urlString, false)
                    } catch {
                        let reason = Self.verifyFailureReason(error)
                        await MainActor.run {
                            LogStore.shared.log(.connection,
                                "✗ tunnel verify via \(urlString): \(reason)",
                                code: .verifyFailed)  // OLC-1006
                        }
                        return (urlString, false)
                    }
                }
            }
            for await (_, success) in group {
                if success {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
    }

    // MARK: Per-connection probes (#234 latency, #242 time-to-ready)
    //
    // Both spin up an isolated, non-singleton client (separate from the tunnel
    // this manager drives), so they are safe to run while connected. The engine
    // owns the native probe + ephemeral-port reservation; this layer just
    // snapshots the relevant settings on MainActor and routes to the record's
    // engine. `.success(ms:)` is HTTP latency for ping, time-to-ready for check.

    /// Measures HTTP latency for one connection via an isolated client (#234).
    func ping(_ details: ConnectionDetails) async -> PingOutcome {
        let engine = details.engine
        if let problem = engine.validate(details) { return .failure(problem) }
        return await engine.ping(details, settings: probeSettings())
    }

    /// Measures WebRTC time-to-ready for one connection via an isolated client (#242).
    func checkReady(_ details: ConnectionDetails) async -> PingOutcome {
        let engine = details.engine
        if let problem = engine.validate(details) { return .failure(problem) }
        return await engine.checkReady(details, settings: probeSettings())
    }

    // boc #456: budgeted probe overloads for the auto-verifier
    /// #456: one-shot probe with an EXPLICIT budget. The auto-verifier
    /// (`HealthCoordinator`) must not ride the user's 60 s start timeout — a hung
    /// carrier would otherwise cost a full minute per node, sequentially.
    func ping(_ details: ConnectionDetails, timeoutMs: Int) async -> PingOutcome {
        let engine = details.engine
        if let problem = engine.validate(details) { return .failure(problem) }
        return await engine.ping(details, settings: probeSettings(timeoutMs: timeoutMs))
    }

    /// #456: budgeted `checkReady` — same reasoning as the budgeted `ping` above.
    func checkReady(_ details: ConnectionDetails, timeoutMs: Int) async -> PingOutcome {
        let engine = details.engine
        if let problem = engine.validate(details) { return .failure(problem) }
        return await engine.checkReady(details, settings: probeSettings(timeoutMs: timeoutMs))
    }
    // eoc #456

    // MARK: Batch ping a group (#364)
    //
    // Health-check every connection in a group at once. The single-node `ping`
    // already runs an isolated, non-singleton client that leases an EPHEMERAL
    // port per probe (OlcrtcEngine.ping → PortAvailability.freeEphemeralPort) — it
    // never touches the configured SOCKS port (#308). The batch only adds
    // orchestration: it runs the probes SEQUENTIALLY (one room at a time, no
    // parallel native clients fighting over the gomobile primitives), gives each
    // probe a UNIQUE clientID so two pings — or a ping racing the live tunnel — in
    // the same room don't collide on identity, and SKIPS the node the live tunnel
    // currently holds (pinging it would join its own room as a second client).

    /// Per-probe clientID for a batch ping (#364): the record's own id keeps it
    /// stable across re-runs while still being unique per node, so a probe never
    /// rendezvouses under the same clientID as a live tunnel (which uses the
    /// connection's configured clientID, e.g. "default"). Pure → tested.
    nonisolated static func batchPingClientID(recordID: UUID) -> String {
        "olc-ping-\(recordID.uuidString.prefix(8))"
    }

    /// Whether a batch ping should SKIP this record: true only when the live
    /// tunnel is connected to *this same node*. Pinging it would join the node's
    /// room a second time; the live RTT is already known. Other nodes (and the
    /// disconnected case) are always probed. Pure → tested.
    nonisolated static func shouldSkipBatchPing(record: ConnectionRecord,
                                                connectedNode: ConnectionRecord?,
                                                state: ConnectionState) -> Bool {
        guard state.isConnected, let live = connectedNode else { return false }
        return live.id == record.id
    }

    /// Rewrites a record's olcrtc clientID to `clientID` for an isolated probe,
    /// leaving every other field untouched. Non-olcrtc records pass through.
    nonisolated static func recordForBatchPing(_ record: ConnectionRecord,
                                               clientID: String) -> ConnectionRecord {
        guard case .olcrtc(var p) = record.details else { return record }
        p.clientID = clientID
        var r = record
        r.details = .olcrtc(p)
        return r
    }

    /// Sequentially pings every record in `group`, returning id → outcome. Skips
    /// the node the live tunnel currently holds (#308: never a second client into
    /// the live room; the engine already leases an ephemeral port per probe).
    /// `onResult` fires on MainActor after each probe so the UI can badge rows as
    /// they complete rather than waiting for the whole group.
    // #388/#390 was: pingGroup(_:connectedNode:onResult:) — the caller passed a
    // snapshot of the connected node (`store.primary`, a UI selection that desyncs
    // from the live node on a no-reconnect row tap, #388) and the loop snapshotted
    // `state`/`connectedNode` ONCE before iterating (#390). Both let the skip miss
    // the genuinely-live node and ping it as a 2nd client in its room. Now the live
    // node is read from `connectedRecord` (the single source of truth) and re-read
    // EACH iteration — across the `await ping` suspension points the live session
    // can change, so a node that connects mid-batch is now correctly skipped.
    @discardableResult
    func pingGroup(_ group: [ConnectionRecord],
                   // No `@escaping`: `onResult` is called inline (never stored), and
                   // since `pingGroup` is `@MainActor`-isolated each callback already
                   // runs on the main actor — the UI can mutate @State directly.
                   onResult: (UUID, PingOutcome) -> Void) async -> [UUID: PingOutcome] {
        var results: [UUID: PingOutcome] = [:]
        for record in group {
            // #390: re-read live state EACH iteration — a node that connects mid-
            // batch (the user hits Connect while a group ping runs) must be skipped.
            guard !Self.shouldSkipBatchPing(record: record,
                                            connectedNode: connectedRecord,
                                            state: state) else {
                continue
            }
            let probeRecord = Self.recordForBatchPing(
                record, clientID: Self.batchPingClientID(recordID: record.id))
            let outcome = await ping(probeRecord.details)
            results[record.id] = outcome
            onResult(record.id, outcome)
        }
        return results
    }

    /// Snapshots the `SettingsStore` values the probes need, on MainActor.
    /// #456: `timeoutMs` is now overridable — nil keeps the historical behaviour
    /// (ride the user's start timeout) for the manual per-row probes, while the
    /// auto-verifier passes its own short budget (`HealthPolicy.probeTimeoutMs`).
    // #456 was: private func probeSettings() -> EngineProbeSettings
    private func probeSettings(timeoutMs: Int? = nil) -> EngineProbeSettings {
        let s = SettingsStore.shared
        return EngineProbeSettings(
            timeoutMs: timeoutMs ?? (s.startTimeoutSeconds * 1000),   // #456
            pingURL:   AppConstants.pingProbeURL,
            vp8FPS:    s.vp8FPS,
            vp8Batch:  s.vp8BatchSize)
    }
}
