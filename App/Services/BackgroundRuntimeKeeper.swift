import AVFoundation
import Foundation

// MARK: - BackgroundRuntimeKeeper
//
// Keeps the app alive in the iOS background by playing a silent looping
// audio buffer through AVAudioEngine.
//
// Why this approach?
// iOS suspends apps within a few seconds of backgrounding unless they hold
// an active background task (audio, location, VoIP, …). Playing silent audio
// with the `mixWithOthers` option is the lightest way to stay alive without
// interfering with the user's music or podcasts. The alternative is
// NEPacketTunnelProvider (VPN), deferred until we have a paid dev account.
//
// Requires `UIBackgroundModes: [audio]` in Info.plist (set via project.yml).
//
// Usage: call start() when the tunnel connects; stop() when it disconnects.
// start() is idempotent — calling it twice is safe.
//
// #432: resilience. A silent-audio keep-alive dies on two events the OS raises
// routinely — an AVAudioSession *interruption* (a phone call, Siri, another app
// grabbing audio) and a *media-services reset* — and nothing here used to bring it
// back, so after the first phone call the app silently became suspendable again
// (the tunnel/SOCKS then died in the background and logging stopped, with no trace
// of why). The keeper now observes both, re-arms the engine when it can, and logs
// every transition to the connection log so "why did my app suspend?" is
// answerable from the Logs tab alone.

@MainActor
final class BackgroundRuntimeKeeper {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var silentBuffer: AVAudioPCMBuffer?
    private var running = false
    private var observers: [NSObjectProtocol] = []
    /// #445 (audit fix 4): set while `rebuildAndRestart()` runs from the
    /// configuration-change handler. A rebuild can itself post another
    /// AVAudioEngineConfigurationChange (delivered synchronously when posted on
    /// the main thread, since the observer queue is `.main`), which would
    /// re-enter the handler mid-rebuild — ignore those.
    private var rebuildingAfterRouteChange = false
    /// #445 (audit fix 4): time-based debounce companion to the flag above —
    /// a change posted asynchronously DURING the rebuild is delivered after the
    /// flag resets; one rebuild per second is plenty and breaks any
    /// rebuild→notification→rebuild loop.
    private var lastRouteRebuild: Date = .distantPast

    /// #432: exposed so the app-lifecycle logging can report whether keep-alive is
    /// actually holding the app up when it backgrounds.
    var isRunning: Bool { running }

    func start() throws {
        guard !running else { return }
        try armSession()
        try buildAndPlay()
        running = true
        installObservers()   // #432: only while running; removed in stop()
    }

    /// #432: activate the audio session (idempotent — also used on interruption
    /// recovery, where the engine is rebuilt separately).
    private func armSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setActive(true)
    }

    /// #432: (re)build the engine graph and start the silent loop. Split out of
    /// `start()` so interruption/reset recovery can rebuild from scratch — a reset
    /// invalidates the old engine and player entirely.
    private func buildAndPlay() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            throw BackgroundError.invalidFormat
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        // 1-second silent buffer, looped forever.
        let frameCount = AVAudioFrameCount(44_100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            engine.detach(player)
            throw BackgroundError.bufferAllocationFailed
        }
        buffer.frameLength = frameCount
        // PCM data is zero-initialised = digital silence.

        silentBuffer = buffer
        do {
            try engine.start()
        } catch {
            engine.detach(player)
            silentBuffer = nil
            throw error
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    /// #441: tear down and rebuild the whole audio stack (fresh engine + player),
    /// then re-arm the session and restart the silent loop. Shared by
    /// interruption-resume and media-reset recovery: a full rebuild is the one path
    /// that guarantees the engine starts before the player plays AND the looped
    /// buffer is scheduled — resuming a stopped engine in place can leave the
    /// player with an empty queue (keep-alive alive on paper, silently doing nothing).
    private func rebuildAndRestart() throws {
        player.stop(); engine.stop(); engine.detach(player)
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        silentBuffer = nil
        try armSession()
        try buildAndPlay()
    }

    // MARK: Interruption / reset resilience (#432)

    /// What to do for an AVAudioSession interruption notification. Pure so the
    /// decision is unit-testable without a live audio session.
    enum InterruptionAction: Equatable { case pause, resume, ignore }
    nonisolated static func interruptionAction(began: Bool, shouldResume: Bool) -> InterruptionAction {
        began ? .pause : (shouldResume ? .resume : .ignore)
    }

    private func installObservers() {
        // #445 (audit fix 10) defensive: `restartIfNeeded()` makes "start() after
        // a failed media-reset rebuild" reachable — that failure path left
        // `running = false` with the observers still installed, so a fresh
        // start() would double-install and every notification would be handled
        // twice. Removing first makes installation idempotent.
        removeObservers()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaReset() }
        })
        // #445 (audit fix 4): AVAudioEngine stops (and uninitialises) itself when
        // the output hardware's channel count / sample rate changes — headphones
        // unplugged, AirPods connect/disconnect, CarPlay — and announces it ONLY
        // via AVAudioEngineConfigurationChange. That is neither an AVAudioSession
        // interruption nor a media-services reset, so the two observers above
        // never fire and the keeper was left `running == true` with a dead
        // engine: the app silently became suspendable in background with no log
        // trace (the exact failure mode #432 was written to eliminate).
        // `object: nil` on purpose — `rebuildAndRestart()` replaces `self.engine`
        // with a fresh AVAudioEngine, so an engine-scoped observer would go
        // stale after the first rebuild.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        })
    }

    /// #445 (audit fix 4): the engine stopped itself because the audio route /
    /// hardware format changed — rebuild the whole stack (same recovery as an
    /// interruption resume or a media reset), with re-entrancy + rate debounce.
    private func handleConfigurationChange() {
        guard running, !rebuildingAfterRouteChange,
              Date().timeIntervalSince(lastRouteRebuild) > 1 else { return }
        rebuildingAfterRouteChange = true
        defer { rebuildingAfterRouteChange = false }
        lastRouteRebuild = Date()
        LogStore.shared.log(.connection,
            "⚠ keep-alive: audio route changed — rebuilding", level: .warn)
        do {
            try rebuildAndRestart()
            LogStore.shared.log(.connection, "✓ keep-alive: audio rebuilt after route change")
        } catch {
            LogStore.shared.log(.connection,
                "⚠ keep-alive: audio rebuild failed after route change (\(error.localizedDescription)) — app may suspend",
                level: .warn)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard running,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let began = type == .began
        let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optsRaw).contains(.shouldResume)

        switch Self.interruptionAction(began: began, shouldResume: shouldResume) {
        case .pause:
            LogStore.shared.log(.connection,
                "⚠ keep-alive: audio interrupted — app may suspend until it resumes", level: .warn)
        case .resume:
            do {
                // #441 was: `try armSession(); if !engine.isRunning { player.play();
                // try engine.start() }` — play() on a stopped engine raises an
                // uncatchable ObjC exception, and even in the right order the looped
                // buffer may have been dropped by the interruption, leaving keep-alive
                // silently dead. Rebuild from scratch instead, like a media reset.
                try rebuildAndRestart()
                LogStore.shared.log(.connection, "✓ keep-alive: audio resumed after interruption")
            } catch {
                LogStore.shared.log(.connection,
                    "⚠ keep-alive: could not resume audio after interruption (\(error.localizedDescription))",
                    level: .warn)
            }
        case .ignore:
            // Interruption ended without a resume hint — leave the engine as-is; a
            // later background/foreground cycle re-arms it.
            break
        }
    }

    private func handleMediaReset() {
        guard running else { return }
        LogStore.shared.log(.connection, "⚠ keep-alive: media services reset — rebuilding audio", level: .warn)
        // A reset invalidates the whole audio stack; start over with fresh objects.
        do {
            // #441 was: the teardown + fresh-objects + armSession + buildAndPlay
            // sequence inlined here — now shared with interruption resume.
            try rebuildAndRestart()
            LogStore.shared.log(.connection, "✓ keep-alive: audio rebuilt after media reset")
        } catch {
            // #470: a real teardown, not just the flag. With `running = false`
            // alone, `stop()`'s guard returned early on the next disconnect, so
            // the three observers stayed registered for the process lifetime and
            // the playback session was never deactivated (other apps' audio kept
            // ducking under `.mixWithOthers`). `stop()` removes them, deactivates,
            // and clears `running` itself; `restartIfNeeded()` re-arms via `start()`.
            // #470 was: running = false
            stop()
            LogStore.shared.log(.connection,
                "⚠ keep-alive: audio rebuild failed after media reset (\(error.localizedDescription)) — app may suspend",
                level: .warn)
        }
    }

    enum BackgroundError: LocalizedError {
        case invalidFormat
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .invalidFormat:          return "AVAudioFormat creation failed"
            case .bufferAllocationFailed: return "AVAudioPCMBuffer allocation failed"
            }
        }
    }

    /// #445 (audit fix 10): re-arm the keeper after a silent death. Two gaps this
    /// closes: (a) an interruption that ended WITHOUT `.shouldResume` takes the
    /// `.ignore` branch above, whose comment promised "a later background/
    /// foreground cycle re-arms it" — nothing implemented that, so after e.g. a
    /// declined call the keeper stayed dead while the state stayed `.connected`;
    /// (b) the keeper was stopped entirely (`running == false`) while the tunnel
    /// is still up and the setting is on. TunnelManager.noteForeground() calls
    /// this when `state.isConnected && backgroundAudio` — the caller owns that
    /// "should be running" decision. Idempotent and silent when all is well.
    func restartIfNeeded() {
        if running {
            guard !engine.isRunning else { return }   // healthy — the common case
            LogStore.shared.log(.connection,
                "⚠ keep-alive: audio engine found dead on foreground — rebuilding", level: .warn)
            do {
                try rebuildAndRestart()
                LogStore.shared.log(.connection, "✓ keep-alive: audio rebuilt on foreground")
            } catch {
                LogStore.shared.log(.connection,
                    "⚠ keep-alive: audio rebuild on foreground failed (\(error.localizedDescription)) — app may suspend",
                    level: .warn)
            }
        } else {
            do {
                try start()
                LogStore.shared.log(.connection, "✓ keep-alive: restarted on foreground")
            } catch {
                LogStore.shared.log(.connection,
                    "⚠ keep-alive: restart on foreground failed (\(error.localizedDescription)) — app may suspend",
                    level: .warn)
            }
        }
    }

    /// #445: shared by `stop()` and the idempotence guard in `installObservers()`.
    private func removeObservers() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    func stop() {
        guard running else { return }
        removeObservers()
        player.stop()
        engine.stop()
        engine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        silentBuffer = nil
        running = false
    }
}
