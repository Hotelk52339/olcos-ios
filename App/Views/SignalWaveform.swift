import Foundation

// Pure policy stays independent of SwiftUI/UIKit so motion decisions can be
// tested without a device, a tunnel, or feedback generators.
//
// Motion policy: the hero's beam and traffic particles follow REAL tunnel
// throughput (`TunnelThroughputMonitor`, bytes/s in+out, smoothed). The
// continuous frame clock runs only while connected (traffic flows) or
// connecting (the beam pulses into the wall), and only visible, foreground and
// without Reduce Motion. Idle and error settle on a short, finite schedule
// (wall reassembles / impact flash) and then hold a static frame.
// The picture is never a health verdict and never shows a number itself —
// measured figures are spoken to VoiceOver by the hero, nothing is printed.
enum SignalMotionPolicy {
    static let framesPerSecond = 30.0
    /// Strands in the beam bundle and samples along each strand.
    static let lineCount = 7
    static let sampleCount = 96

    /// Relative amplitude (fraction of the canvas height) of the strand
    /// waver at intensity 0 / 1.
    static let calmAmplitude = 0.13
    static let peakAmplitude = 0.31
    /// Relative amplitude of the faint, static, disconnected beam.
    static let staticAmplitude = 0.055
    /// Phase advance in rad/s at intensity 0 / 1 (idle breath vs. busy flow).
    static let calmSpeed = Double.pi / 5
    static let peakSpeed = Double.pi * 0.85
    /// Per-frame easing rate (1/s) of the displayed intensity toward the target:
    /// the 1 Hz samples arrive as steps; the picture must breathe, not jump.
    static let intensityEasing = 2.5

    /// Throughput that maps to full intensity. Above it the flow is as busy
    /// as it gets.
    static let fullIntensityBytesPerSecond = 8_000_000.0
    /// Below this the connection is treated as idle (keep-alive noise only).
    static let idleBytesPerSecond = 512.0

    static func allowsMotion(isConnected: Bool, sceneIsActive: Bool,
                             reduceMotion: Bool, isVisible: Bool) -> Bool {
        isConnected && sceneIsActive && !reduceMotion && isVisible
    }

    /// Which hero states keep a CONTINUOUS clock: connected (particles flow
    /// with traffic) and connecting (the beam pulses and cracks grow). Idle
    /// and error run a finite settle schedule and then hold a static frame.
    static func keepsClock(_ state: FirewallBeamState) -> Bool {
        state == .connected || state == .connecting
    }

    static func allowsMotion(state: FirewallBeamState, sceneIsActive: Bool,
                             reduceMotion: Bool, isVisible: Bool) -> Bool {
        allowsMotion(isConnected: keepsClock(state), sceneIsActive: sceneIsActive,
                     reduceMotion: reduceMotion, isVisible: isVisible)
    }

    /// 0…1 from a smoothed byte rate, log-scaled so both 20 KB/s and 2 MB/s
    /// read as visibly different flows. Non-finite or negative input is idle.
    static func intensity(bytesPerSecond: Double) -> Double {
        guard bytesPerSecond.isFinite, bytesPerSecond > idleBytesPerSecond else { return 0 }
        let top = log10(1 + fullIntensityBytesPerSecond / idleBytesPerSecond)
        let value = log10(1 + bytesPerSecond / idleBytesPerSecond) / top
        return min(1, max(0, value))
    }

    static func amplitude(intensity: Double, isConnected: Bool) -> Double {
        guard isConnected else { return staticAmplitude }
        let t = min(1, max(0, intensity))
        return calmAmplitude + (peakAmplitude - calmAmplitude) * t
    }

    static func speed(intensity: Double) -> Double {
        let t = min(1, max(0, intensity))
        return calmSpeed + (peakSpeed - calmSpeed) * t
    }

    /// One easing step of the displayed intensity toward `target` over `dt`
    /// seconds. Monotone and bounded: it never overshoots the target.
    static func eased(current: Double, target: Double, dt: Double) -> Double {
        guard dt.isFinite, dt > 0 else { return current }
        let k = min(1, dt * intensityEasing)
        return current + (target - current) * k
    }

    /// The strand waver along the beam, NOT a microphone envelope. Normalized
    /// inputs keep touch displacement and draw cost strictly bounded; both
    /// ends are at rest so the bundle leaves the edge and meets the wall as
    /// one beam.
    static func displacement(x: Double, line: Int, phase: Double,
                             touchX: Double?, touchY: Double?) -> Double {
        let x = min(1, max(0, x))
        let strand = Double(min(lineCount - 1, max(0, line)))
        let envelope = pow(sin(.pi * x), 1.6)
        let carrier = sin(x * .pi * 3.4 - phase + strand * 0.24)
        let overtone = sin(x * .pi * 6.0 - phase * 0.65 + strand * 0.38) * 0.24
        var touch = 0.0
        if let touchX, let touchY {
            let dx = x - min(1, max(0, touchX))
            let strength = (0.5 - min(1, max(0, touchY))) * 0.8
            touch = exp(-dx * dx * 24) * strength
        }
        return (carrier * 0.65 + overtone + touch) * envelope
    }
}

/// Integrates phase over wall-clock time at a speed that may change every
/// frame, so a throughput change alters the pace of the strands without a
/// visible jump. Also eases the displayed intensity toward the target.
final class SignalPhaseClock {
    private(set) var phase = 0.0
    private(set) var intensity = 0.0
    private var last: Date?

    func advance(to date: Date, target: Double) {
        defer { last = date }
        guard let last else {
            intensity = target.isFinite ? min(1, max(0, target)) : 0
            return
        }
        let dt = min(0.25, max(0, date.timeIntervalSince(last)))
        intensity = SignalMotionPolicy.eased(current: intensity, target: target, dt: dt)
        phase += SignalMotionPolicy.speed(intensity: intensity) * dt
        if phase > 2 * .pi * 1_000 { phase -= 2 * .pi * 1_000 }
    }

    func reset() {
        last = nil
    }
}

// MARK: - FirewallBeamModel
//
// The hero picture: an incoming beam meets a stone masonry firewall wall.
//   • idle        — wall intact, beam faint and ends at the wall;
//   • connecting  — sustained local pressure without outgoing light;
//   • connected   — pressure, seep through the joints, outgoing-strand fusion,
//                   then the whole wall cracks and breaks (one-shot,
//                   `breakDuration` = 3.6 s); steady traffic flows at a pace
//                   set by measured intensity, without replay;
//   • error       — pressure stretches, failure tint arrives after a delay,
//                   then intact armor recoils (~1.8 s); no outgoing light;
//   • disconnect  — dispersed armor reassembles (~0.5 s) back to idle.
// An interrupted success cancels outgoing light immediately; any dispersed
// fragments may reverse into place before the new state's resting picture.
// This struct is the whole state machine; the Canvas only reads it. Nothing
// here draws, times or randomises: per-cell and per-particle variation comes
// from `noise(_:_:)`, a deterministic hash of the index.

/// What the hero asks the picture to show; ConnectHero maps `ConnectionState`.
enum FirewallBeamState: Equatable {
    case idle, connecting, connected, error
}

struct FirewallBeamModel: Equatable {
    enum Phase: Equatable {
        /// Wall whole, beam faint (idle).
        case intact
        /// Beam pushes into the wall, cracks grow (connecting).
        case charging
        /// One-shot: pressure, seep, fusion, then armor destruction (→ open).
        case breaking
        /// Armor dispersed, outgoing beam and measured traffic (connected).
        case open
        /// Pressure stretch, delayed failure tint, intact-armor recoil (error).
        case rejected
        /// Reverse of the break (→ the resting phase of the current state).
        case reassembling
    }

    /// The traffic particle the renderer draws; positions are unit-square.
    struct Particle: Equatable {
        /// 0…1 across the full canvas width.
        var x: Double
        /// -1…1 across the beam's thickness.
        var lane: Double
        /// 0…1 relative size.
        var size: Double
        /// 0…1 brightness.
        var alpha: Double
    }

    /// Ordered success sequence: pressure, seep, merge, destruction, then the
    /// released beam settles into its braided traffic line.
    static let breakDuration: TimeInterval = 3.6

    /// Stage boundaries as fractions of `breakDuration` (`breach`).
    enum Stage {
        /// Pressure reaches its peak.
        static let pressureEnd = 0.2
        /// Light starts to seep through the seams.
        static let seepStart = 0.2
        static let seepEnd = 0.42
        /// Seeping strands merge into one core.
        static let fusionStart = 0.42
        static let fusionEnd = 0.6
        /// Stones start to fly; the wall is completely gone at `destructionEnd`.
        static let burst = 0.62
        static let destructionEnd = 0.88
        /// The thin beam thickens into the braided line.
        static let settleStart = 0.8
        static let settleEnd = 1.0
    }
    static let reassembleDuration: TimeInterval = 0.5
    /// Time for the cracks to reach full length while connecting.
    static let crackDuration: TimeInterval = 1.8
    static let flashDuration: TimeInterval = 1.8
    static let pulseHertz = 1.4

    static let maxParticles = 40
    static let minParticles = 6

    private(set) var state: FirewallBeamState = .idle
    private(set) var phase: Phase = .intact
    /// 0…1 inside the current phase (1 = settled for intact/open).
    private(set) var progress: Double = 1
    private(set) var phaseStart: TimeInterval = 0
    /// The last time seen by `advance(to:)`; never decreases.
    private(set) var time: TimeInterval = 0
    /// Displayed throughput intensity 0…1 (already eased by the caller).
    private(set) var intensity: Double = 0
    /// Integrated particle travel in canvas widths: speed may change every
    /// frame without the particles jumping.
    private(set) var flow: Double = 0
    /// 0…1 share of measured throughput that flows toward the device (↓).
    private(set) var inboundShare: Double = 0.5
    private var entryPressure: Double = 0

    init() {}

    /// The frame everything settles into for `state` — Reduce Motion, a first
    /// appearance, and the static branch render this instead of animating.
    static func settled(state: FirewallBeamState, intensity: Double = 0) -> FirewallBeamModel {
        var model = FirewallBeamModel()
        model.state = state
        model.setIntensity(intensity)
        model.enter(model.restingPhase(for: state))
        model.progress = 1
        return model
    }

    // MARK: Derived picture

    /// 0 = wall whole, 1 = gap fully open. Linear in time; the renderer eases.
    var breach: Double {
        switch phase {
        case .intact, .charging, .rejected: return 0
        case .open:                          return 1
        case .breaking:                      return progress
        case .reassembling:                  return 1 - progress
        }
    }

    /// 0…1 crack growth on the wall face.
    var crack: Double {
        switch phase {
        case .charging:     return progress
        case .breaking:     return pressure
        case .reassembling: return 1 - progress
        case .rejected:     return pressure
        case .intact, .open: return 0
        }
    }

    static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    /// Local deformation, not proof that the connection succeeded.
    var pressure: Double {
        switch phase {
        case .charging: return Self.smooth(progress)
        case .breaking:
            return (entryPressure + (1 - entryPressure) * Self.smooth(progress / Stage.pressureEnd))
                * (1 - destruction)
        case .rejected:
            let rise = entryPressure + (1 - entryPressure) * Self.smooth(progress / 0.32)
            return rise * (1 - Self.smooth((progress - 0.55) / 0.45))
        case .reassembling: return breach * (1 - destruction)
        case .intact, .open: return 0
        }
    }

    /// No outgoing light until the authoritative state is connected.
    var seep: Double {
        guard state == .connected else { return 0 }
        return Self.smooth((breach - Stage.seepStart) / (Stage.seepEnd - Stage.seepStart))
    }

    var fusion: Double {
        guard state == .connected else { return 0 }
        return Self.smooth((breach - Stage.fusionStart) / (Stage.fusionEnd - Stage.fusionStart))
    }

    /// Every stone disperses, including the top and bottom rows.
    var destruction: Double {
        Self.smooth((breach - Stage.burst) / (Stage.destructionEnd - Stage.burst))
    }

    /// 0 = thin released beam, 1 = the full braided traffic line. Like the
    /// other outputs it exists only while the authoritative state is connected.
    var lineSettle: Double {
        guard state == .connected else { return 0 }
        return Self.smooth((breach - Stage.settleStart) / (Stage.settleEnd - Stage.settleStart))
    }

    var failureTint: Double {
        guard isRed else { return 0 }
        return phase == .rejected ? Self.smooth((progress - 0.32) / 0.16) : 1
    }

    /// Increase the rejection strain continuously, without a gain jump at entry.
    var rejectionStrain: Double {
        phase == .rejected ? Self.smooth(progress / 0.32) : 0
    }

    /// 0…1 red impact flash (error only), fading over `flashDuration`.
    var flash: Double {
        phase == .rejected ? max(0, 1 - progress) : 0
    }

    /// 0…1 beam push into the wall while connecting (a slow pulse).
    var pulse: Double {
        guard phase == .charging || phase == .breaking else { return 0 }
        return 0.5 + 0.5 * sin(2 * .pi * Self.pulseHertz * time)
    }

    /// How green the beam is: exactly how open the wall is.
    var greenMix: Double { breach }
    var isRed: Bool { state == .error }
    var isSignal: Bool { state == .connecting }

    /// True while something changes on its own: transitions, the connecting
    /// pulse, the error flash, and particle flow through an open gap.
    var isAnimating: Bool {
        switch phase {
        case .intact:       return false
        case .charging:     return true
        case .breaking:     return true
        case .open:         return true
        case .rejected:     return progress < 1
        case .reassembling: return true
        }
    }

    /// Seconds until the current one-shot transition (and the flash that may
    /// follow it) has settled; 0 when nothing finite is pending.
    var transientRemaining: TimeInterval {
        switch phase {
        case .breaking:
            return (1 - progress) * Self.breakDuration
        case .reassembling:
            let rest = (1 - progress) * Self.reassembleDuration
            return rest + (state == .error ? Self.flashDuration : 0)
        case .rejected:
            return (1 - progress) * Self.flashDuration
        case .intact, .open, .charging:
            return 0
        }
    }

    /// How many particles to draw through the gap, from intensity.
    var particleCount: Int {
        guard breach > 0 else { return 0 }
        let extra = Double(Self.maxParticles - Self.minParticles) * intensity
        return min(Self.maxParticles, Self.minParticles + Int(extra.rounded()))
    }

    // MARK: Mutation

    mutating func setIntensity(_ value: Double) {
        intensity = value.isFinite ? min(1, max(0, value)) : 0
    }

    /// Which part of the traffic line's packet trains run back toward the
    /// device. Undirected measurements (or none) keep the even 0.5 split.
    mutating func setInboundShare(_ value: Double) {
        inboundShare = value.isFinite ? min(1, max(0, value)) : 0.5
    }

    /// Moves the clock to `now` (never backwards) and completes one-shot
    /// transitions. Safe to call from any phase, at any cadence.
    mutating func advance(to now: TimeInterval) {
        guard now.isFinite else { return }
        let dt = min(0.25, max(0, now - time))
        time = max(time, now)
        flow += Self.flowSpeed(intensity: intensity) * dt
        if flow > 1_000 { flow -= 1_000 }
        let elapsed = max(0, time - phaseStart)
        switch phase {
        case .intact, .open:
            progress = 1
        case .charging:
            progress = min(1, elapsed / Self.crackDuration)
        case .rejected:
            progress = min(1, elapsed / Self.flashDuration)
        case .breaking:
            progress = min(1, elapsed / Self.breakDuration)
            if progress >= 1 { enter(.open) }
        case .reassembling:
            progress = min(1, elapsed / Self.reassembleDuration)
            if progress >= 1 {
                let completedAt = phaseStart + Self.reassembleDuration
                enter(restingPhase(for: state))
                // Keep the original deadline when a frame arrives late. The
                // finite TimelineView cannot supply additional recovery frames.
                phaseStart = completedAt
                let carried = max(0, time - completedAt)
                if phase == .rejected {
                    progress = min(1, carried / Self.flashDuration)
                } else if phase == .charging {
                    progress = min(1, carried / Self.crackDuration)
                }
            }
        }
    }

    /// Switches the target state. A change into `.connected` breaks the wall
    /// from however open it already is; any other change first reassembles
    /// whatever is open, then settles into that state's resting phase.
    mutating func apply(state new: FirewallBeamState) {
        guard new != state else { return }
        let previousPressure = pressure
        state = new
        entryPressure = previousPressure
        let openness = breach
        switch new {
        case .connected:
            if phase == .open { return }
            if openness >= 1 {
                enter(.open)
            } else {
                phase = .breaking
                progress = openness
                phaseStart = time - openness * Self.breakDuration
            }
        case .idle, .connecting, .error:
            if openness > 0 {
                phase = .reassembling
                progress = 1 - openness
                phaseStart = time - progress * Self.reassembleDuration
            } else {
                enter(restingPhase(for: new))
            }
        }
    }

    // MARK: Pure helpers

    func restingPhase(for state: FirewallBeamState) -> Phase {
        switch state {
        case .idle:       return .intact
        case .connecting: return .charging
        case .connected:  return .open
        case .error:      return .rejected
        }
    }

    private mutating func enter(_ next: Phase) {
        phase = next
        phaseStart = time
        switch next {
        case .intact, .open: progress = 1
        case .charging, .breaking, .rejected, .reassembling: progress = 0
        }
    }

    /// Particle travel in canvas widths per second at a given intensity: a
    /// slow drift at zero traffic, about one width per second when busy.
    static func flowSpeed(intensity: Double) -> Double {
        let t = intensity.isFinite ? min(1, max(0, intensity)) : 0
        return 0.14 + 0.76 * t
    }

    /// Deterministic 0…1 hash of (index, salt): the same cell or particle
    /// always gets the same "random" speed, angle and offset — no `Random`
    /// per frame, identical pictures in tests and on device.
    static func noise(_ index: Int, _ salt: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
        h = h &+ UInt64(truncatingIfNeeded: salt) &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 31
        h = h &* 0x94D0_49BB_1331_11EB
        h ^= h >> 29
        return Double(h >> 11) / Double(UInt64(1) << 53)
    }

    /// The i-th traffic particle. `x` wraps across the width from the
    /// integrated `flow`, so a pace change never teleports a particle.
    func particle(_ index: Int) -> Particle {
        let n0 = Self.noise(index, 11), n1 = Self.noise(index, 12)
        let n2 = Self.noise(index, 13), n3 = Self.noise(index, 14)
        let speedFactor = 0.75 + 0.6 * n0
        let travel = flow * speedFactor + n1
        let x = travel - travel.rounded(.down)
        return Particle(x: x,
                        lane: (n2 - 0.5) * 2,
                        size: 0.35 + 0.65 * n3,
                        alpha: min(1, breach) * (0.55 + 0.45 * n0))
    }
}

enum SignalConnectionPhase: Equatable {
    case idle, connecting, connected, waiting, failed
}

struct SignalHapticPolicy {
    enum Outcome: Equatable { case success, error }
    private(set) var pendingConnectionID: UUID?

    mutating func beginConnection(id: UUID) {
        pendingConnectionID = id
    }

    mutating func cancel() {
        pendingConnectionID = nil
    }

    /// Consume once, and never replay after foregrounding, uncovering a sheet,
    /// adopting a system tunnel or recovering automatically from a lost route.
    mutating func outcome(phase: SignalConnectionPhase, connectedRecordID: UUID?,
                          isVisible: Bool, sceneIsActive: Bool,
                          isAutomaticRecovery: Bool) -> Outcome? {
        guard let expected = pendingConnectionID else { return nil }
        guard isVisible, sceneIsActive, !isAutomaticRecovery else {
            cancel()
            return nil
        }
        switch phase {
        case .connecting:
            return nil
        case .connected:
            cancel()
            return connectedRecordID == expected ? .success : nil
        case .failed:
            cancel()
            return .error
        case .idle, .waiting:
            cancel()
            return nil
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// Holds the model across frames. A class so
/// the TimelineView body can mutate it without touching SwiftUI state.
final class FirewallBeamHolder {
    var model = FirewallBeamModel()
    var primed = false
}

/// Signal's central mark: a beam meeting a stone firewall wall — no app
/// icon or centre image. `intensity` (0…1, from
/// `SignalMotionPolicy.intensity(bytesPerSecond:)`) sets how dense and fast
/// the traffic particles flow; it comes from measured tunnel counters, never
/// from an invented signal. The view owns no timer or task: its only clocks
/// are TimelineViews, mounted solely while motion is allowed.
struct SignalWaveform: View {
    let state: FirewallBeamState
    var isPresented = true
    /// Smoothed throughput intensity, 0 = idle. Ignored while disconnected.
    var intensity = 0.0
    /// 0…1 share of the measured throughput flowing toward the device; it
    /// splits the traffic line's packet trains between the two directions.
    /// 0.5 when the measurement cannot be split (SOCKS5 estimate) or is absent.
    var inboundShare = 0.5

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var clock = SignalPhaseClock()
    @State private var holder = FirewallBeamHolder()
    /// Finite frame dates for the idle/error settle (reassemble, flash).
    @State private var settleDates: [Date] = []
    @State private var settleToken = 0
    @GestureState private var touch: CGPoint?

    private var isConnected: Bool { state == .connected }

    /// The finite idle/error settle clock is mounted.
    private var settling: Bool {
        !settleDates.isEmpty && !reduceMotion && scenePhase == .active && isVisible && isPresented
    }

    private var motionPermitted: Bool {
        !reduceMotion && scenePhase == .active && isVisible && isPresented
    }

    /// The continuous clock: connected traffic or the connecting pulse.
    private var moves: Bool {
        SignalMotionPolicy.allowsMotion(isConnected: SignalMotionPolicy.keepsClock(state),
                                        sceneIsActive: scenePhase == .active,
                                        reduceMotion: reduceMotion,
                                        isVisible: isVisible && isPresented)
    }

    var body: some View {
        GeometryReader { geometry in
            // Removing the TimelineView (not just freezing phase) means idle,
            // settled error, Reduce Motion and background have no draw clock.
            Group {
                if moves {
                    TimelineView(.animation(minimumInterval: 1 / SignalMotionPolicy.framesPerSecond)) { context in
                        let _ = clock.advance(to: context.date, target: intensity)
                        let _ = advanceModel(to: context.date)
                        canvas(phase: clock.phase, amplitude: connectedAmplitude(clock.intensity),
                               size: geometry.size, touch: touch)
                    }
                } else if settling {
                    // A finite schedule: it fires once per frame until the wall
                    // has reassembled / the impact flash has faded, then stops.
                    TimelineView(.explicit(settleDates)) { context in
                        let _ = advanceModel(to: context.date)
                        canvas(phase: 0, amplitude: staticAmplitude, size: geometry.size, touch: nil)
                    }
                    .id(settleToken)
                } else {
                    // Static: Reduce Motion, off-screen and idle show the settled
                    // frame for the state; the hero speaks the measured figures.
                    canvas(phase: 0, amplitude: staticAmplitude, size: geometry.size, touch: nil)
                }
            }
            .contentShape(Rectangle())
            // Simultaneous rather than exclusive: the list must still scroll
            // when a vertical swipe begins on the beam. No frame haptics.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($touch) { value, location, _ in
                        guard moves else { return }
                        location = value.location
                    }
            )
        }
        .frame(height: Theme.Signal.waveHeight)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; clock.reset() }
        .onChange(of: moves) { _, _ in clock.reset() }
        .onChange(of: motionPermitted) { _, permitted in
            guard !permitted else { return }
            // Never replay an interrupted transition on returning to the screen.
            holder.model = FirewallBeamModel.settled(state: state, intensity: intensity)
            settleDates = []
            clock.reset()
        }
        .onChange(of: state, initial: true) { _, new in applyState(new) }
        .transaction { $0.animation = nil }
    }

    // MARK: Model driving

    /// The first state is adopted settled (opening the app while connected
    /// must not replay the break); every later change animates.
    private func applyState(_ new: FirewallBeamState) {
        let now = Date()
        if !holder.primed {
            holder.primed = true
            holder.model = FirewallBeamModel.settled(state: new, intensity: intensity)
            settleDates = []
            return
        }
        holder.model.advance(to: now.timeIntervalSinceReferenceDate)
        holder.model.apply(state: new)
        let remaining = holder.model.transientRemaining
        if !motionPermitted {
            holder.model = FirewallBeamModel.settled(state: new, intensity: intensity)
            settleDates = []
        } else if SignalMotionPolicy.keepsClock(new) {
            settleDates = []
        } else if remaining <= 0 || reduceMotion || !isPresented || scenePhase != .active {
            // Nothing to animate (or not allowed to): hold the settled frame.
            holder.model = FirewallBeamModel.settled(state: new, intensity: intensity)
            settleDates = []
        } else {
            let step = 1 / SignalMotionPolicy.framesPerSecond
            var dates: [Date] = []
            var offset = 0.0
            while offset <= remaining + step {
                dates.append(now.addingTimeInterval(offset))
                offset += step
            }
            settleDates = dates
            settleToken += 1
        }
    }

    private func advanceModel(to date: Date) {
        holder.model.setIntensity(clock.intensity)
        holder.model.setInboundShare(inboundShare)
        holder.model.advance(to: date.timeIntervalSinceReferenceDate)
    }

    /// The model to draw: the live one while any clock runs, otherwise the
    /// settled frame for the current state (Reduce Motion, off-screen, idle).
    private func frameModel(live: Bool) -> FirewallBeamModel {
        if live { return holder.model }
        var model = FirewallBeamModel.settled(state: state, intensity: intensity)
        model.setInboundShare(inboundShare)
        return model
    }

    private func connectedAmplitude(_ intensity: Double) -> Double {
        SignalMotionPolicy.amplitude(intensity: intensity, isConnected: true)
    }

    private var staticAmplitude: Double {
        SignalMotionPolicy.amplitude(intensity: 0, isConnected: isConnected)
    }

    // MARK: Rendering

    private func canvas(phase: Double, amplitude relative: Double,
                        size: CGSize, touch: CGPoint?) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
            let width = canvasSize.width
            let height = canvasSize.height
            guard width > 0, height > 0 else { return }
            let model = frameModel(live: moves || settling)
            let touchX = touch.map { Double($0.x / max(1, size.width)) }
            let touchY = touch.map { Double($0.y / max(1, size.height)) }
            // Strands waver at a quarter of the wave amplitude: a beam, not a wave.
            let amplitude = height * CGFloat(relative) * 0.28

            FirewallArmorRenderer.draw(in: context, size: canvasSize, model: model,
                                       phase: phase, amplitude: amplitude,
                                       touchX: touchX, touchY: touchY,
                                       dark: colorScheme == .dark)
        }
    }

}
#endif
