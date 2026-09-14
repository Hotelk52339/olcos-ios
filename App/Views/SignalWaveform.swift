import Foundation

// boc #486
// #486: Pure policy stays independent of SwiftUI/UIKit so intent and motion
// decisions can be tested without a device, a tunnel, or feedback generators.
enum SignalMotionPolicy {
    static let framesPerSecond = 30.0
    static let lineCount = 7
    static let sampleCount = 96

    static func allowsMotion(isConnected: Bool, sceneIsActive: Bool,
                             reduceMotion: Bool, isVisible: Bool) -> Bool {
        isConnected && sceneIsActive && !reduceMotion && isVisible
    }

    /// An expressive shape, NOT a microphone envelope or a network measurement.
    /// Normalized inputs keep touch displacement and draw cost strictly bounded.
    static func displacement(x: Double, line: Int, phase: Double,
                             touchX: Double?, touchY: Double?) -> Double {
        let x = min(1, max(0, x))
        let strand = Double(min(lineCount - 1, max(0, line)))
        let envelope = pow(sin(.pi * x), 1.6)
        let carrier = sin(x * .pi * 3.4 - phase + strand * 0.24)
        let overtone = sin(x * .pi * 6.0 + phase * 0.65 + strand * 0.38) * 0.24
        var touch = 0.0
        if let touchX, let touchY {
            let dx = x - min(1, max(0, touchX))
            let strength = (0.5 - min(1, max(0, touchY))) * 0.8
            touch = exp(-dx * dx * 24) * strength
        }
        return (carrier * 0.65 + overtone + touch) * envelope
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

    static func selectionChanged<Value: Equatable>(from old: Value, to new: Value) -> Bool {
        old != new
    }
}
// eoc #486

#if canImport(SwiftUI)
import SwiftUI

// boc #486
/// Signal's central mark is only flowing lines — no app icon or centre image.
/// Connection state drives expression, never invented audio/packet counters.
struct SignalWaveform: View {
    let isConnected: Bool
    let isFailed: Bool
    var isPresented = true

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @GestureState private var touch: CGPoint?

    private var moves: Bool {
        SignalMotionPolicy.allowsMotion(isConnected: isConnected,
                                        sceneIsActive: scenePhase == .active,
                                        reduceMotion: reduceMotion,
                                        isVisible: isVisible && isPresented)
    }

    var body: some View {
        GeometryReader { geometry in
            // Removing the TimelineView (not just freezing phase) means idle,
            // connecting/error, Reduce Motion and background have no draw clock.
            Group {
                if moves {
                    TimelineView(.animation(minimumInterval: 1 / SignalMotionPolicy.framesPerSecond)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 120) * .pi / 3
                        canvas(phase: phase, size: geometry.size, touch: touch)
                    }
                } else {
                    canvas(phase: 0, size: geometry.size, touch: nil)
                }
            }
            .contentShape(Rectangle())
            // Simultaneous rather than exclusive: the list must still scroll
            // when a vertical swipe begins on these lines. No frame haptics.
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
        .onDisappear { isVisible = false }
        .transaction { $0.animation = nil }
    }

    private func canvas(phase: Double, size: CGSize, touch: CGPoint?) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
            let width = canvasSize.width
            let height = canvasSize.height
            guard width > 0, height > 0 else { return }
            let touchX = touch.map { Double($0.x / max(1, size.width)) }
            let touchY = touch.map { Double($0.y / max(1, size.height)) }
            let amplitude = height * (isConnected ? 0.29 : 0.055)
            let color = isFailed ? Theme.Palette.red
                : (isConnected ? Theme.Signal.stroke : Theme.Palette.textSecondary)

            for line in 0..<SignalMotionPolicy.lineCount {
                var path = Path()
                let strandOffset = CGFloat(line - SignalMotionPolicy.lineCount / 2) * 3
                for sample in 0...SignalMotionPolicy.sampleCount {
                    let x = Double(sample) / Double(SignalMotionPolicy.sampleCount)
                    let displacement = SignalMotionPolicy.displacement(
                        x: x, line: line, phase: phase, touchX: touchX, touchY: touchY)
                    let point = CGPoint(x: width * x,
                                        y: height / 2 + strandOffset + amplitude * displacement)
                    if sample == 0 { path.move(to: point) }
                    else { path.addLine(to: point) }
                }
                let prominence = 1 - abs(Double(line - SignalMotionPolicy.lineCount / 2)) * 0.18
                context.stroke(path,
                               with: .linearGradient(
                                Gradient(stops: [
                                    .init(color: color.opacity(0), location: 0),
                                    .init(color: color.opacity(prominence), location: 0.22),
                                    .init(color: color.opacity(prominence), location: 0.78),
                                    .init(color: color.opacity(0), location: 1)
                                ]), startPoint: .zero, endPoint: CGPoint(x: width, y: 0)),
                               style: StrokeStyle(lineWidth: line == 3 ? 2 : 1.2, lineCap: .round))
            }
        }
    }
}
// eoc #486
#endif
