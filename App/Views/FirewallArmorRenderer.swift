#if canImport(SwiftUI)
import SwiftUI

/// A small, deterministic software scene, painted by the hero's existing Canvas.
/// The entering beam and the fused core are behind the stone wall; the crack
/// web is clipped to the front skins so a nearer stone still hides it, and the
/// seeping rays leave real mortar joints on the lit front face.
enum FirewallArmorRenderer {
    static func draw(in context: GraphicsContext, size: CGSize, model: FirewallBeamModel,
                     phase: Double, amplitude: CGFloat, touchX: Double?, touchY: Double?,
                     dark: Bool) {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        let frame = Frame(size: size, model: model, phase: phase, amplitude: amplitude,
                          touchX: touchX, touchY: touchY, dark: dark)
        let scene = makeScene(frame)
        var canvas = context
        canvas.clip(to: Path(CGRect(origin: .zero, size: size)))
        canvas.translateBy(x: size.width * 0.52, y: size.height * 0.51)
        canvas.scaleBy(x: CGFloat(frame.scale), y: CGFloat(frame.scale))

        // No independent time source: even the wave envelope translates using
        // integrated model.flow, rather than time × the latest traffic speed.
        drawIncoming(in: canvas, frame: frame)
        drawPressure(in: canvas, frame: frame)
        drawFused(in: canvas, frame: frame)
        drawArmor(in: canvas, frame: frame, scene: scene)
        drawCracks(in: canvas, frame: frame, scene: scene)
        drawSeep(in: canvas, frame: frame, scene: scene)
        drawDebris(in: canvas, frame: frame)
    }

    // MARK: Scene coordinates

    private typealias Point = FirewallArmorGeometry.Point
    private typealias Vector = FirewallArmorGeometry.Vector
    private typealias Pose = FirewallArmorGeometry.Pose
    private typealias Face = FirewallArmorGeometry.Face
    private typealias Scene = FirewallArmorGeometry.Scene
    private typealias Stage = FirewallBeamModel.Stage

    private static let wallScale = FirewallArmorGeometry.wallScale
    private static let depth = FirewallArmorGeometry.depth
    private static let strandCount = 7

    private struct Frame {
        let model: FirewallBeamModel
        let dark: Bool
        let scale: Double
        let left: Double
        let right: Double
        let height: Double
        let amplitude: Double
        /// Continuous strand phase of the settled traffic line (rad).
        let phase: Double
        let touch: Point?
        let touchX: Double?
        let touchY: Double?

        var span: Double { right - left }
        var pressure: Double { clamp(model.pressure) }
        var destruction: Double { clamp(model.destruction) }
        var failure: Double { clamp(model.failureTint) }
        var success: Bool { model.state == .connected }
        var fusion: Double { success ? clamp(model.fusion) : 0 }
        var seep: Double { success ? clamp(model.seep) : 0 }
        /// 0 = thin released beam, 1 = braided traffic line.
        var settle: Double { success ? clamp(model.lineSettle) : 0 }
        var intensity: Double { clamp(model.intensity) }
        var inboundShare: Double { clamp(model.inboundShare) }
        var burstAge: Double {
            clamp((model.breach - Stage.burst) / (Stage.destructionEnd - Stage.burst)) * 2.6
        }
        var broken: Bool { success && destruction > 0 }
        var mergeX: Double { min(167, right - 24) }
        var emissionFade: Double { 1 - smooth(destruction / 0.48) }
        var flow: Double { model.flow.isFinite ? model.flow : 0 }
        var crack: Double {
            clamp(model.crack) * (1 - smooth(destruction / 0.16))
        }
        var brightness: Double {
            switch model.state {
            case .idle: return 0.19
            case .error: return 0.62 + pressure * 0.24
            case .connecting: return 0.62 + pressure * 0.3
            case .connected: return 0.96
            }
        }
        var highlight: Color {
            dark ? rgb(237, 254, 255) : rgb(241, 255, 255)
        }
        /// Amplitude of the braided line's axis: the old volumetric Signal
        /// line, breathing with measured intensity.
        var braidAmplitude: Double { height * (0.059 + 0.082 * intensity) }
        var braidRadius: Double { (7 + 9 * intensity) * settle }

        init(size: CGSize, model: FirewallBeamModel, phase: Double, amplitude: CGFloat,
             touchX: Double?, touchY: Double?, dark: Bool) {
            self.model = model
            self.dark = dark
            self.phase = phase.isFinite ? phase : 0
            scale = min(Double(size.height) / 440, Double(size.width) / 700)
            left = -Double(size.width) * 0.52 / scale
            right = Double(size.width) * 0.48 / scale
            height = Double(size.height) / scale
            let value = amplitude.isFinite ? Double(amplitude) / scale : 8
            self.amplitude = min(14, max(4, value))
            if let x = touchX, let y = touchY, x.isFinite, y.isFinite {
                self.touchX = clamp(x)
                self.touchY = clamp(y)
                touch = Point(x: left + clamp(x) * (right - left),
                              y: (clamp(y) - 0.51) * height)
            } else {
                touch = nil
                self.touchX = nil
                self.touchY = nil
            }
        }

        func wave(_ x: Double, lane: Double = 0) -> Double {
            let travel = x - flow * span
            let primary = sin(travel * 0.025 + lane * 0.23) * amplitude
            let secondary = sin(travel * 0.012 + lane * 0.15) * amplitude * 0.375
            var y = primary + secondary + lane * 1.45
            if let touch {
                let distance = (x - touch.x) / 75
                // Touch bends light, never the wall or the direction of travel.
                y += min(28, max(-28, touch.y)) * exp(-distance * distance)
            }
            return y
        }

        func incomingY(_ x: Double, lane: Double) -> Double {
            let focus = broken ? 1 : 1 - (1 - destruction) * 0.78 * exp(-x * x / 2200)
            return wave(x, lane: lane) * focus
        }

        /// The braided line's axis: the pre-armor volumetric strand shape.
        func axis(_ x: Double, strand: Int = 3) -> Double {
            braidAmplitude * SignalMotionPolicy.displacement(
                x: (x - left) / span, line: strand, phase: phase, touchX: touchX, touchY: touchY)
        }

        /// Thin lane while the wall stands, blended into the wide line as it settles.
        func laneY(_ x: Double, lane: Int) -> Double {
            let narrow = incomingY(x, lane: Double(lane))
            guard settle > 0 else { return narrow }
            let wide = Double(lane) * 3 + axis(x, strand: min(6, max(0, lane + 3)))
            return narrow * (1 - settle) + wide * settle
        }

        /// Both ends of the line rest at the viewport edges.
        func edgeFade(_ x: Double) -> Double {
            let q = (x - left) / span
            return smooth(q / 0.2) * smooth((1 - q) / 0.2)
        }
    }

    private static func makeScene(_ frame: Frame) -> Scene {
        FirewallArmorGeometry.scene(pressure: frame.pressure, breach: frame.model.breach,
                                    rejection: frame.model.rejectionStrain, crack: clamp(frame.model.crack))
    }

    // MARK: Light (always behind the solid geometry)

    private static func beamShading(_ frame: Frame, from: Point, to: Point) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: [
            .init(color: Theme.Palette.signalCyan, location: 0),
            .init(color: Theme.Palette.signalViolet, location: 0.35),
            .init(color: Theme.Palette.signalMid, location: 0.55),
            .init(color: frame.success ? Theme.Palette.green : Theme.Palette.signalCyan, location: 1)
        ]), startPoint: from.cg, endPoint: to.cg)
    }

    private static func drawIncoming(in context: GraphicsContext, frame: Frame) {
        // While the wall stands the beam presses into its front skin.
        let end = frame.broken
            ? frame.right
            : (-38 + frame.pressure * (12 + depth) - frame.failure * 4) * wallScale
        let settle = frame.settle
        let shading = beamShading(frame, from: Point(x: frame.left, y: 0),
                                  to: Point(x: frame.right, y: 0))
        if settle < 1 {
            for lane in -5...5 {
                let trace = sampled(from: frame.left, to: end) { x in
                    Point(x: x, y: frame.laneY(x, lane: lane))
                }
                let alpha = frame.brightness * (lane == 0 ? 0.96 : 0.38) * (1 - settle)
                stroke(trace, in: context, shading: shading,
                       width: lane == 0 ? 2 : 1, alpha: alpha * (1 - frame.failure))
                stroke(trace, in: context, color: Theme.Palette.red,
                       width: lane == 0 ? 2 : 1, alpha: alpha * frame.failure)
            }
        }
        if settle > 0 {
            drawBraid(in: context, frame: frame)
        }
        let count = frame.success ? max(6, frame.model.particleCount) : 12
        let particleAlpha = frame.brightness * 0.8 * (1 - settle * 0.55)
        for index in 0..<count {
            let x = frame.left + fraction(frame.flow + random(index + 121)) * frame.span
            guard x <= end else { continue }
            let lane = index % 9 - 4
            let y = frame.laneY(x, lane: lane)
            let color = frame.failure > 0.5 ? Theme.Palette.red
                : (frame.success && x > 25 ? Theme.Palette.green : frame.highlight)
            let tail = sampled(from: max(frame.left, x - 4.8), to: x) { position in
                Point(x: position, y: frame.laneY(position, lane: lane))
            }
            stroke(tail, in: context, color: color, width: 1.8, alpha: particleAlpha)
            dot(in: context, at: Point(x: x, y: y), radius: 1.1, color: color, alpha: particleAlpha)
        }
    }

    // MARK: The braided traffic line

    private struct StrandPoint {
        let x: Double
        let y: Double
        /// -1 far … 1 near.
        let z: Double
        var point: Point { Point(x: x, y: y) }
        var nearness: Double { (z + 1) / 2 }
    }

    /// Strand `k` of a real three-dimensional braid: seven strands twist around
    /// the wavy axis; depth drives brightness, width and paint order, so near
    /// strands pass in front of far ones and the line reads as a tube.
    private static func strand(_ k: Int, at x: Double, frame: Frame) -> StrandPoint {
        let radius = frame.braidRadius
        let twist = (x - frame.left) * 0.028 + frame.phase * 1.35
        let angle = twist + Double(k) * .pi * 2 / Double(strandCount)
        let z = sin(angle)
        // Slight perspective: nearer strands drift right/up as in the projection.
        return StrandPoint(x: x + z * radius * 0.35,
                           y: frame.axis(x) + cos(angle) * radius - z * radius * 0.12, z: z)
    }

    private static func strandColor(_ k: Int, nearness d: Double, dark: Bool) -> Color {
        let background: (Double, Double, Double) = dark ? (11, 12, 16) : (242, 242, 247)
        let hue: (Double, Double, Double) = dark
            ? (k % 2 == 1 ? (160, 230, 255) : (150, 255, 215))
            : (k % 2 == 1 ? (11, 122, 153) : (27, 122, 52))
        let bright = 0.18 + 0.66 * d
        return rgb(background.0 + (hue.0 - background.0) * bright,
                   background.1 + (hue.1 - background.1) * bright,
                   background.2 + (hue.2 - background.2) * bright)
    }

    private static func drawBraid(in context: GraphicsContext, frame: Frame) {
        let settle = frame.settle
        let charge = frame.brightness
        let radius = frame.braidRadius
        let step = 4.0
        // Soft body glow first, behind every strand.
        let glowPath = sampled(from: frame.left, to: frame.right, step: 6) { x in
            Point(x: x, y: frame.axis(x))
        }
        let glow = GraphicsContext.Shading.linearGradient(Gradient(stops: [
            .init(color: Theme.Palette.signalMid.opacity(0), location: 0),
            .init(color: Theme.Palette.signalMid.opacity(0.16), location: 0.3),
            .init(color: Theme.Palette.green.opacity(0.16), location: 0.7),
            .init(color: Theme.Palette.green.opacity(0), location: 1)
        ]), startPoint: Point(x: frame.left, y: 0).cg, endPoint: Point(x: frame.right, y: 0).cg)
        stroke(glowPath, in: context, shading: glow, width: radius * 3.2 + 8, alpha: settle * charge)

        var previous = (0..<strandCount).map { strand($0, at: frame.left, frame: frame) }
        var x = frame.left + step
        while x <= frame.right + step / 2 {
            let current = (0..<strandCount).map { strand($0, at: min(x, frame.right), frame: frame) }
            let edge = frame.edgeFade((current[0].x + previous[0].x) / 2)
            // Segments sorted back-to-front for each slice.
            for k in (0..<strandCount).sorted(by: { current[$0].z < current[$1].z }) {
                let d = current[k].nearness
                stroke(polyline([previous[k].point, current[k].point]), in: context,
                       color: strandColor(k, nearness: d, dark: frame.dark),
                       width: (1.1 + 2.1 * d) * (0.6 + 0.4 * settle),
                       alpha: charge * settle * edge)
            }
            previous = current
            x += step
        }
        drawPackets(in: context, frame: frame)
    }

    /// Internet traffic, not a decoration: bursty packet trains ride the
    /// strands. Uploads run outward (left→right), downloads come back the other
    /// way in a second tint; the split follows the measured ↓/↑ share, the
    /// count and length follow throughput, and the pace is the integrated flow.
    private static func drawPackets(in context: GraphicsContext, frame: Frame) {
        let settle = frame.settle
        let charge = frame.brightness
        let intensity = frame.intensity
        let trains = 6 + Int((intensity * 10).rounded())
        let inbound = Int((Double(trains) * frame.inboundShare).rounded())
        let outward = frame.dark ? Color.white : rgb(6, 44, 62)
        let back = frame.dark ? rgb(255, 207, 147) : rgb(176, 84, 0)
        for m in 0..<trains {
            let isBack = m < inbound
            let k = min(strandCount - 1, Int(random(m + 211) * Double(strandCount)))
            let pace = (0.55 + random(m + 401) * 0.45) * (isBack ? 0.8 : 1)
            let length = 30 + random(m + 501) * 70
            let period = frame.span + 220 + random(m + 601) * 300
            let head = fraction(frame.flow * frame.span * pace / period + random(m + 701)) * period
            let x0 = isBack ? frame.right - head : frame.left + head
            let direction = isBack ? 1.0 : -1.0
            var q = 0.0
            while q < length {
                let x = x0 + direction * q
                let fadeTail = 1 - q / length
                q += 3
                guard x >= frame.left, x <= frame.right else { continue }
                let a = strand(k, at: x, frame: frame)
                let b = strand(k, at: min(frame.right, max(frame.left, x + direction * 3)), frame: frame)
                let d = a.nearness
                stroke(polyline([a.point, b.point]), in: context, color: isBack ? back : outward,
                       width: 2 + 3.2 * d,
                       alpha: charge * settle * frame.edgeFade(x) * (0.3 + 0.7 * d) * pow(fadeTail, 0.6))
            }
            if x0 > frame.left, x0 < frame.right {
                let h = strand(k, at: x0, frame: frame)
                radial(in: context, at: h.point, radius: 16,
                       color: isBack ? back : (frame.dark ? rgb(200, 255, 235) : rgb(6, 44, 62)),
                       alpha: charge * settle * frame.edgeFade(x0) * 0.7 * h.nearness)
            }
        }
    }

    private static func drawPressure(in context: GraphicsContext, frame: Frame) {
        let power = frame.pressure * (1 - smooth(frame.destruction / 0.4))
        guard power > 0 else { return }
        let s = wallScale
        let color = frame.failure > 0.5 ? Theme.Palette.red : Theme.Palette.signalCyan
        radial(in: context, at: Point(x: 7 * s, y: -2 * s), radius: (35 + power * 84) * s,
               color: color, alpha: power * (frame.dark ? 0.31 : 0.18))
        radial(in: context, at: Point(x: 7 * s, y: -2 * s), radius: (8 + power * 17) * s,
               color: frame.highlight, alpha: power * 0.72)
        var path = Path()
        for index in 0..<9 {
            let angle = Double(index) * .pi * 2 / 9 + 0.15
            let radius = power * (36 + random(index + 3) * 55) * s
            path.move(to: Point(x: 7 * s, y: 0).cg)
            for (fraction, offset) in [(0.38, 0.2), (0.72, -0.13), (1.0, 0.0)] {
                let x = 7 * s + cos(angle + offset) * radius * fraction
                let y = sin(angle + offset) * radius * fraction
                path.addLine(to: Point(x: x, y: y).cg)
            }
        }
        stroke(path, in: context, color: color, width: 1.25, alpha: power * 0.83)
        if frame.failure > 0 {
            radial(in: context, at: Point(x: -100 * s, y: 0), radius: 30 * s,
                   color: Theme.Palette.red, alpha: frame.failure * power * 0.4)
        }
    }

    /// Eleven rays leave real mortar joints on the lit front face at their own
    /// moments and paces, wander, and gather into one beam on the right.
    private static func drawSeep(in context: GraphicsContext, frame: Frame, scene: Scene) {
        guard frame.seep > 0, frame.emissionFade > 0 else { return }
        // Stragglers keep arriving while the core is already fusing.
        let clock = frame.seep * 0.7 + frame.fusion * 0.3
        let end = Point(x: frame.mergeX, y: frame.wave(frame.mergeX) * 0.25)
        for seam in FirewallArmorGeometry.seams(scene: scene) {
            let k = seam.index
            let origin = seam.point
            guard origin.x < end.x - 4 else { continue }
            let delay = random(k + 77) * 0.42
            let pace = 0.3 + random(k + 91) * 0.28
            let progress = smooth((clock - delay) / pace)
            guard progress > 0 else { continue }
            let jitter = sin(frame.flow * 14 * (1.7 + random(k) * 2.5) + Double(k)) * 9 * (1 - progress * 0.6)
            let c1 = Point(x: origin.x + 40 + random(k + 3) * 60,
                           y: origin.y + (random(k + 9) - 0.5) * 120 + jitter)
            let c2 = Point(x: end.x - 20 - random(k + 13) * 70,
                           y: end.y + (random(k + 17) - 0.5) * 90 - jitter)
            var points: [Point] = []
            points.reserveCapacity(61)
            for index in 0...60 {
                points.append(cubic(origin, c1, c2, end, Double(index) / 60 * progress))
            }
            let path = polyline(points)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [k % 2 == 0 ? Theme.Palette.signalCyan : Theme.Palette.signalViolet,
                                  Theme.Palette.green]), startPoint: origin.cg, endPoint: end.cg)
            stroke(path, in: context, shading: shading, width: 4.5, alpha: frame.emissionFade * 0.13)
            stroke(path, in: context, shading: shading, width: 1.1, alpha: frame.emissionFade * 0.85)
            radial(in: context, at: origin, radius: 7, color: Theme.Palette.signalCyan,
                   alpha: 0.4 * progress * frame.emissionFade)
            for index in 0..<3 {
                let q = fraction(frame.flow * 6 * (0.5 + random(k + index) * 0.5)
                                 + Double(index) * 0.31 + Double(k) * 0.05)
                guard q <= progress else { continue }
                let position = q / max(progress, 0.0001) * 60
                let lower = min(59, Int(position))
                let point = interpolate(points[lower], points[lower + 1], position - Double(lower))
                dot(in: context, at: point, radius: 1.25,
                    color: frame.highlight, alpha: frame.emissionFade)
            }
        }
    }

    private static func drawFused(in context: GraphicsContext, frame: Frame) {
        // The fused core hands over to the braided line as it settles.
        let joined = frame.fusion * (1 - frame.settle)
        guard joined > 0 else { return }
        // Once the explosion starts, the same uninterrupted core spans the
        // entire viewport; flying solids, not a fake central hole, occlude it.
        let left = frame.model.breach >= Stage.burst ? frame.left : frame.mergeX
        let path = sampled(from: left, to: frame.right) { x in
            Point(x: x, y: frame.wave(x) * 0.25)
        }
        let shading = beamShading(frame, from: Point(x: frame.left, y: 0),
                                  to: Point(x: frame.right, y: 0))
        for (width, alpha) in [(17.0, 0.07), (9.0, 0.16), (4.2, 0.88)] {
            stroke(path, in: context, shading: shading,
                   width: width * joined, alpha: alpha * joined)
        }
        stroke(path, in: context, color: frame.dark ? rgb(225, 255, 244) : Theme.Palette.green,
               width: 1.4 * joined, alpha: 0.95 * joined)
        let count = max(6, frame.model.particleCount / 2)
        for index in 0..<count {
            let x = frame.left + fraction(frame.flow + random(index + 251)) * frame.span
            guard x >= left else { continue }
            let tail = sampled(from: max(left, x - 11), to: x) { position in
                Point(x: position, y: frame.wave(position) * 0.25)
            }
            stroke(tail, in: context,
                   color: frame.dark ? rgb(239, 255, 248) : Theme.Palette.green,
                   width: 2.5, alpha: joined * 0.95)
        }
        radial(in: context, at: Point(x: frame.mergeX, y: frame.wave(frame.mergeX) * 0.25),
               radius: 18, color: Theme.Palette.green,
               alpha: joined * 0.4 * (1 - frame.destruction))
    }

    private static func drawDebris(in context: GraphicsContext, frame: Frame) {
        let age = frame.burstAge
        guard age > 0, age < 2, frame.model.breach < 1 else { return }
        let s = wallScale
        radial(in: context, at: Point(x: 15 * s, y: -3 * s), radius: (80 + age * 70) * s,
               color: Theme.Palette.signalCyan, alpha: max(0, 0.45 - age * 0.8))
        for index in 0..<85 {
            let angle = random(index + 345) * .pi * 2
            let speed = 40 + random(index + 84) * 155
            let point = Point(x: (cos(angle) * age * speed * 0.8 + age * 45) * s,
                              y: sin(angle) * age * speed * s)
            let tail = Point(x: point.x - cos(angle) * 7, y: point.y - sin(angle) * 7)
            let alpha = (1 - smooth(age / 2)) * (0.25 + random(index + 71) * 0.6)
            stroke(polyline([tail, point]), in: context,
                   color: index % 3 == 0 ? Theme.Palette.signalViolet : Theme.Palette.signalCyan,
                   width: index % 4 == 0 ? 1.8 : 0.7, alpha: alpha)
        }
        let ring = Path(ellipseIn: CGRect(x: CGFloat((4 - age * 51) * s), y: CGFloat((-15 - age * 133) * s),
                                         width: CGFloat((16 + age * 150) * s),
                                         height: CGFloat((30 + age * 266) * s)))
        stroke(ring, in: context, color: Theme.Palette.signalCyan,
               width: 1, alpha: (1 - smooth(age / 1.25)) * 0.6)
    }

    // MARK: Opaque stone and its mortar

    /// Weathered granite: a per-stone tone, a warmer lit front, cooler shadowed
    /// sides. Heat (pressure, the crack front, flight) tints toward the beam.
    private static func material(_ face: Face, pose: Pose, frame: Frame) -> Color {
        let hot = pose.hot
        let red = frame.failure * hot
        let side = Double(face.kind)
        if frame.dark {
            let tone = 84 + pose.cell.seed * 30 - (pose.cell.isMerlon ? 6 : 0)
            switch face.kind {
            case 1: return rgb(tone * 1.04 + hot * 70 + red * 80, tone * 1.0 + hot * 85 - red * 40,
                               tone * 0.92 + hot * 95 - red * 55)
            case 0: return rgb(tone * 0.34, tone * 0.35, tone * 0.38)
            default: return rgb(tone * (0.58 + side * 0.04) + hot * 25 + red * 45,
                                tone * (0.58 + side * 0.04) + hot * 35 - red * 15,
                                tone * (0.6 + side * 0.04) + hot * 45 - red * 20)
            }
        }
        // Light theme: pale sandstone on the grouped background; heat deepens
        // toward the dark cyan of the light-theme beam.
        let tone = 150 + pose.cell.seed * 35 - (pose.cell.isMerlon ? 6 : 0)
        switch face.kind {
        case 1: return rgb(tone * 1.02 - hot * 60 + red * 30, tone * 1.0 - hot * 15 - red * 55,
                           tone * 0.95 + hot * 5 - red * 65)
        case 0: return rgb(tone * 0.5, tone * 0.5, tone * 0.52)
        default: return rgb(tone * (0.66 + side * 0.04) - hot * 30 + red * 30,
                            tone * (0.66 + side * 0.04) - hot * 5 - red * 30,
                            tone * (0.68 + side * 0.04) + hot * 10 - red * 40)
        }
    }

    private static func drawArmor(in context: GraphicsContext, frame: Frame, scene: Scene) {
        let mortarFront = frame.dark ? rgb(38, 34, 30) : rgb(70, 64, 58)
        let mortarSide = frame.dark ? rgb(30, 28, 26) : rgb(60, 56, 52)
        let heat = frame.dark ? rgb(135, 225, 255) : rgb(11, 122, 153)
        let ember = frame.dark ? rgb(255, 125, 150) : rgb(192, 48, 42)
        let grain = frame.dark ? Color.black : rgb(40, 32, 24)
        let chip = frame.dark ? rgb(255, 250, 240) : Color.white
        for face in scene.faces {
            let pose = scene.poses[face.pose]
            let surface = polygon(face.points)
            // Never inherit an effect layer's opacity or blend mode here.
            var solid = context
            solid.opacity = 1
            solid.blendMode = .normal
            solid.fill(surface, with: .color(material(face, pose: pose, frame: frame)))
            let hot = pose.hot
            let red = frame.failure * hot
            let front = face.kind == 1
            let width = front ? 1.6 + hot * 0.7 : 0.65
            if red > 0.1 {
                stroke(surface, in: solid, color: ember, width: width, alpha: 0.24 + red * 0.66)
            } else if hot > 0.2 {
                stroke(surface, in: solid, color: heat, width: width, alpha: 0.24 + hot * 0.66)
            } else {
                stroke(surface, in: solid, color: front ? mortarFront : mortarSide,
                       width: width, alpha: front ? 0.9 : 0.8)
            }
            guard front, face.points.count == 4 else { continue }
            // Stone grain: deterministic speckles and a chipped highlight edge.
            let p = face.points
            let center = Point(x: p.reduce(0) { $0 + $1.x } / 4, y: p.reduce(0) { $0 + $1.y } / 4)
            let w = abs(p[1].x - p[0].x)
            let h = abs(p[2].y - p[1].y)
            let seed = pose.cell.id * 31
            for g in 0..<6 {
                let gx = center.x + (random(seed * 997 + g) - 0.5) * w * 0.8
                let gy = center.y + (random(seed * 613 + g) - 0.5) * h * 0.7
                let rx = 1.2 + random(g + seed * 31) * 2.4
                let ry = 0.8 + random(g * 3 + seed) * 1.3
                var speck = solid
                speck.opacity = 0.10 + random(seed * 77 + g) * 0.12
                speck.fill(Path(ellipseIn: CGRect(x: gx - rx, y: gy - ry, width: rx * 2, height: ry * 2)),
                           with: .color(grain))
            }
            stroke(polyline([p[0], p[1]]), in: solid, color: chip, width: 0.9, alpha: 0.14 + hot * 0.2)
            stroke(polyline([p[3], p[0]]), in: solid, color: chip, width: 0.7, alpha: 0.08 + hot * 0.1)
        }
    }

    // MARK: The crack web across the whole front skin

    /// A jagged polyline: heading wobbles and step length varies per segment.
    private static func jagged(from start: Point, angle: Double, length: Double, seed: Int,
                               segments: Int, wobble: Double) -> [Point] {
        var points = [start]
        var heading = angle
        var x = start.x
        var y = start.y
        for j in 1...segments {
            heading += (random(seed + j * 7) - 0.5) * wobble
            let r = length / Double(segments) * (0.7 + random(seed + j * 3) * 0.6)
            x += cos(heading) * r * 0.78
            y += sin(heading) * r
            points.append(Point(x: x, y: y))
        }
        return points
    }

    /// Nine trunk cracks run from the impact to the wall edges; each spawns
    /// jagged branches and hairline twigs as the front passes, so the whole
    /// wall is webbed. Clipped to the standing front skins, so a crack never
    /// hangs in the air where a stone has already left.
    private static func drawCracks(in context: GraphicsContext, frame: Frame, scene: Scene) {
        let growth = frame.crack
        guard growth > 0 else { return }
        var mask = Path()
        for face in scene.faces where face.kind == 1 && scene.poses[face.pose].scale > 0.5 {
            mask.addPath(polygon(face.points))
        }
        guard !mask.isEmpty else { return }
        var skin = context
        skin.clip(to: mask)
        let s = wallScale
        let front = FirewallArmorGeometry.crackFront(clamp(frame.model.crack))
        let lift = depth + frame.pressure * (30 + 44 * frame.model.rejectionStrain)
        let centerVector = Vector(x: 0, y: 0, z: lift).projected
        let center = Point(x: centerVector.x * s, y: centerVector.y * s)
        let red = frame.failure > 0.5
        let layers: [(Double, Double, Color)] = red
            ? [(3.2, 0.16, rgb(255, 148, 165)), (1, 0.88, rgb(255, 148, 165)), (0.42, 1, rgb(255, 220, 226))]
            : frame.dark
                ? [(3.2, 0.16, rgb(80, 194, 255)), (1, 0.88, rgb(119, 224, 255)), (0.42, 1, rgb(237, 254, 255))]
                : [(3.2, 0.16, rgb(11, 122, 153)), (1, 0.88, rgb(20, 140, 180)), (0.42, 1, rgb(240, 252, 255))]
        func draw(_ points: [Point], alphaScale: Double, width: Double) {
            let path = polyline(points.map { Point(x: center.x + $0.x * s, y: center.y + $0.y * s) })
            for (line, alpha, color) in layers {
                stroke(path, in: skin, color: color, width: width * line,
                       alpha: min(1, growth * alpha * alphaScale))
            }
        }
        let origin = Point(x: 0, y: 0)
        for k in 0..<9 {
            let angle = Double(k) * .pi * 2 / 9 + 0.26 + (random(k + 61) - 0.5) * 0.3
            let full = 170 + random(k + 22) * 50
            let length = min(full, front * (0.85 + random(k + 5) * 0.3))
            guard length > 0 else { continue }
            let trunk = jagged(from: origin, angle: angle, length: length, seed: k * 97, segments: 10, wobble: 0.85)
            draw(trunk, alphaScale: 1, width: 1.5)
            for branch in 1...4 {
                let at = min(trunk.count - 1, 1 + branch)
                let grown = smooth((length / full * 7 - Double(at)) / 1.5)
                guard grown > 0 else { continue }
                let a = angle + (branch % 2 == 1 ? 0.75 : -0.8) + (random(k * 13 + branch) - 0.5) * 0.5
                let twig = jagged(from: trunk[at], angle: a, length: (26 + random(k + branch * 31) * 38) * grown,
                                  seed: k * 131 + branch * 17, segments: 3, wobble: 0.7)
                draw(twig, alphaScale: 0.9, width: 0.85)
                if grown > 0.6 {
                    let leaf = jagged(from: twig[2], angle: a + (branch % 2 == 1 ? -0.9 : 0.95),
                                      length: (10 + random(k + branch * 7) * 14) * (grown - 0.6) / 0.4,
                                      seed: k * 7 + branch * 53, segments: 2, wobble: 0.6)
                    draw(leaf, alphaScale: 0.7, width: 0.5)
                }
            }
        }
    }

    // MARK: Drawing primitives

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func smooth(_ value: Double) -> Double {
        let t = clamp(value)
        return t * t * (3 - 2 * t)
    }
    private static func fraction(_ value: Double) -> Double { value - floor(value) }
    private static func random(_ index: Int) -> Double {
        fraction(sin(Double(index) * 127.1 + 311.7) * 43758.5453)
    }
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: clamp(r / 255), green: clamp(g / 255), blue: clamp(b / 255))
    }
    private static func interpolate(_ a: Point, _ b: Point, _ t: Double) -> Point {
        Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    private static func cubic(_ a: Point, _ b: Point, _ c: Point, _ d: Point, _ t: Double) -> Point {
        let m = 1 - t
        let aa = m * m * m, bb = 3 * m * m * t, cc = 3 * m * t * t, dd = t * t * t
        return Point(x: a.x * aa + b.x * bb + c.x * cc + d.x * dd,
                     y: a.y * aa + b.y * bb + c.y * cc + d.y * dd)
    }
    private static func polyline(_ points: [Point]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first.cg)
        for point in points.dropFirst() { path.addLine(to: point.cg) }
        return path
    }
    private static func polygon(_ points: [Point]) -> Path {
        var path = polyline(points)
        path.closeSubpath()
        return path
    }
    private static func sampled(from start: Double, to end: Double, step: Double = 2,
                                at point: (Double) -> Point) -> Path {
        guard end > start else { return Path() }
        let count = min(600, max(1, Int(ceil((end - start) / step))))
        var path = Path()
        for index in 0...count {
            // Includes the exact viewport edge, even if width is not divisible by the step.
            let x = start + (end - start) * Double(index) / Double(count)
            if index == 0 { path.move(to: point(x).cg) } else { path.addLine(to: point(x).cg) }
        }
        return path
    }
    private static func stroke(_ path: Path, in context: GraphicsContext, color: Color,
                               width: Double, alpha: Double) {
        stroke(path, in: context, shading: .color(color), width: width, alpha: alpha)
    }
    private static func stroke(_ path: Path, in context: GraphicsContext,
                               shading: GraphicsContext.Shading, width: Double, alpha: Double) {
        guard alpha > 0, width > 0 else { return }
        var layer = context
        layer.opacity = clamp(alpha)
        layer.stroke(path, with: shading,
                     style: StrokeStyle(lineWidth: CGFloat(width), lineCap: .round, lineJoin: .round))
    }
    private static func dot(in context: GraphicsContext, at point: Point, radius: Double,
                            color: Color, alpha: Double) {
        var layer = context
        layer.opacity = clamp(alpha)
        let rect = CGRect(x: CGFloat(point.x - radius), y: CGFloat(point.y - radius),
                          width: CGFloat(radius * 2), height: CGFloat(radius * 2))
        layer.fill(Path(ellipseIn: rect), with: .color(color))
    }
    private static func radial(in context: GraphicsContext, at point: Point, radius: Double,
                               color: Color, alpha: Double) {
        guard alpha > 0, radius > 0 else { return }
        let gradient = Gradient(stops: [
            .init(color: color.opacity(alpha), location: 0),
            .init(color: color.opacity(alpha * 0.5), location: 0.25),
            .init(color: color.opacity(0), location: 1)
        ])
        let rect = CGRect(x: CGFloat(point.x - radius), y: CGFloat(point.y - radius),
                          width: CGFloat(radius * 2), height: CGFloat(radius * 2))
        context.fill(Path(ellipseIn: rect), with: .radialGradient(
            gradient, center: point.cg, startRadius: 0, endRadius: CGFloat(radius)))
    }
}
#endif
