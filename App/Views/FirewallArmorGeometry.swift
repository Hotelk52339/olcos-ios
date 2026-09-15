import Foundation

/// Pure scene geometry shared by the Canvas and platform-independent tests.
/// Units match the 440-point reference stage; layout only scales the projection.
///
/// The wall is a stone stretcher-bond masonry: eleven courses of blocks with
/// half-block closers on the odd courses and three merlons on top. Every block
/// is a full box (front, rear and four sides) so a flying stone never reveals
/// a missing face.
enum FirewallArmorGeometry {
    struct Point: Equatable, Sendable {
        var x: Double
        var y: Double
        var cg: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
    }

    struct Vector: Equatable, Sendable {
        var x: Double
        var y: Double
        var z: Double

        var projected: Point { Point(x: x * 0.78 + z * 0.82, y: y + x * 0.22 - z * 0.25) }
        var depth: Double { z * 0.78 - x * 0.6 - y * 0.08 }

        func rotated(_ angles: Vector) -> Vector {
            let yy = y * cos(angles.x) - z * sin(angles.x)
            let zz = y * sin(angles.x) + z * cos(angles.x)
            let xx = x * cos(angles.y) + zz * sin(angles.y)
            let zzz = -x * sin(angles.y) + zz * cos(angles.y)
            return Vector(x: xx * cos(angles.z) - yy * sin(angles.z),
                          y: xx * sin(angles.z) + yy * cos(angles.z), z: zzz)
        }
    }

    struct Cell: Equatable, Sendable {
        let id: Int
        /// Course index, -5…5; merlons sit on the virtual course 6.
        let row: Int
        let u: Double
        let v: Double
        let width: Double
        let height: Double
        let isMerlon: Bool
        let radius: Double
        let seed: Double

        /// Mortar joint midpoints on the front skin: right, left, top, bottom.
        var seams: [Point] {
            [Point(x: width / 2, y: 0), Point(x: -width / 2, y: 0),
             Point(x: 0, y: height / 2), Point(x: 0, y: -height / 2)]
        }
    }

    /// Nominal block size and the half depth of every stone.
    static let blockWidth = 40.0
    static let blockHeight = 21.0
    static let depth = 22.0
    /// The whole wall (and only the wall) is drawn this much larger than the
    /// stage units, so the beam keeps its reference proportions.
    static let wallScale = 1.15
    /// Crack length that reaches beyond the farthest block.
    static let crackReach = 205.0
    static let seamCount = 11

    /// Stretcher bond: even courses hold seven blocks, odd courses six plus two
    /// closers; three merlons crown the top. 35 + 48 + 3 = 86 stones.
    static let cells: [Cell] = {
        var result: [Cell] = []
        func add(row: Int, u: Double, v: Double, width: Double, height: Double, merlon: Bool) {
            result.append(Cell(id: result.count, row: row, u: u, v: v, width: width, height: height,
                               isMerlon: merlon, radius: hypot(u * 0.82, v),
                               seed: random(result.count + 1)))
        }
        for row in -5...5 {
            let v = Double(row) * blockHeight
            if abs(row) % 2 == 0 {
                for column in -3...3 {
                    add(row: row, u: Double(column) * blockWidth, v: v,
                        width: blockWidth, height: blockHeight, merlon: false)
                }
            } else {
                for column in -3...2 {
                    add(row: row, u: Double(column) * blockWidth + blockWidth / 2, v: v,
                        width: blockWidth, height: blockHeight, merlon: false)
                }
                let closer = 3 * blockWidth + blockWidth / 4
                add(row: row, u: -closer, v: v, width: blockWidth / 2, height: blockHeight, merlon: false)
                add(row: row, u: closer, v: v, width: blockWidth / 2, height: blockHeight, merlon: false)
            }
        }
        let merlonHeight = blockHeight * 1.15
        let merlonV = -6 * blockHeight + (blockHeight - merlonHeight) / 2
        for column in [-2, 0, 2] {
            add(row: 6, u: Double(column) * blockWidth, v: merlonV,
                width: blockWidth * 0.8, height: merlonHeight, merlon: true)
        }
        return result
    }()

    /// The eight corners of a stone: rear ring 0…3, front ring 4…7, inset by
    /// 0.6 so mortar joints separate neighbours.
    static func vertices(of cell: Cell) -> [Vector] {
        let w = cell.width / 2 - 0.6
        let h = cell.height / 2 - 0.6
        return [-depth, depth].flatMap { z in
            [Vector(x: -w, y: -h, z: z), Vector(x: w, y: -h, z: z),
             Vector(x: w, y: h, z: z), Vector(x: -w, y: h, z: z)]
        }
    }

    /// Face 0 = rear, 1 = front skin, 2…5 = sides (bottom, right, top, left).
    static let faceIndices: [[Int]] = {
        var result = [[3, 2, 1, 0], [4, 5, 6, 7]]
        for index in 0..<4 {
            result.append([index, (index + 1) % 4, (index + 1) % 4 + 4, index + 4])
        }
        return result
    }()

    struct Pose: Equatable, Sendable {
        let cell: Cell
        let center: Vector
        let angles: Vector
        let scale: Double
        let hot: Double

        /// Model space → stage space (the wall scale is applied here).
        func transform(_ point: Vector) -> Vector {
            let rotated = point.rotated(angles)
            return Vector(x: (center.x + rotated.x * scale) * wallScale,
                          y: (center.y + rotated.y * scale) * wallScale,
                          z: (center.z + rotated.z * scale) * wallScale)
        }
    }

    struct Face: Equatable, Sendable {
        let points: [Point]
        let depth: Double
        /// 0 = rear, 1 = front skin, 2…5 = sides.
        let kind: Int
        let pose: Int
        let order: Int
    }

    struct Scene: Equatable, Sendable {
        var poses: [Pose] = []
        var faces: [Face] = []
    }

    /// Passing the same breach backwards exactly reverses every flight pose.
    /// Rejection changes elastic strain only; breach remains zero on failure.
    /// `crack` lights the stones the crack front has already reached.
    static func scene(pressure: Double, breach: Double, rejection: Double = 0,
                      crack: Double = 0) -> Scene {
        let pressure = clamp(pressure)
        let breach = clamp(breach)
        let rejection = clamp(rejection)
        let burstAge = clamp((breach - FirewallBeamModel.Stage.burst)
                             / (FirewallBeamModel.Stage.destructionEnd - FirewallBeamModel.Stage.burst)) * 2.6
        let front = crackFront(crack)
        // The crack glow lets go as soon as the stones start to fly.
        let calm = 1 - smooth((burstAge - 0.25) / 1)
        var scene = Scene()
        guard breach < 1 else { return scene }
        scene.poses.reserveCapacity(cells.count)
        scene.faces.reserveCapacity(cells.count * 6)
        for cell in cells {
            let weight = exp(-cell.radius * cell.radius / 8000)
            let age = max(0, burstAge - cell.radius / 480 - cell.seed * 0.08)
            let fading = 1 - smooth((age - 0.9) / 1.2)
            guard fading > 0.002 else { continue }
            // Erode flying solids instead of blending individual faces, which
            // would reveal rear edges and light through still-present stones.
            let stretch = 1 + pressure * weight * (0.055 + 0.105 * rejection)
            let displacement = pressure * weight * (30 + 44 * rejection)
            let flight = 1 - exp(-age * 1.9)
            let velocity = 80 + random(cell.id + 52) * 75
            let center = Vector(x: cell.u * stretch + flight * cell.u * 0.9,
                                y: cell.v * stretch + flight * cell.v * 0.72 + age * age * 12,
                                z: displacement + flight * velocity + age * 33)
            let angles = Vector(x: age * (random(cell.id + 23) - 0.5) * 3,
                                y: age * (random(cell.id + 32) - 0.5) * 3,
                                z: age * (random(cell.id + 44) - 0.5) * 2.6)
            let reach = smooth((front - cell.radius) / 34) * calm
            let hot = max(pressure * weight * calm, reach * 0.42,
                          age > 0 ? max(0, 1 - age) * 0.75 : 0)
            let pose = Pose(cell: cell, center: center, angles: angles, scale: fading, hot: hot)
            let poseIndex = scene.poses.count
            scene.poses.append(pose)
            let transformed = vertices(of: cell).map { pose.transform($0) }
            for (kind, indices) in faceIndices.enumerated() {
                let points = indices.map { transformed[$0] }
                scene.faces.append(Face(points: points.map(\.projected),
                                        depth: points.reduce(0) { $0 + $1.depth } / Double(points.count),
                                        kind: kind, pose: poseIndex, order: cell.id * 6 + kind))
            }
        }
        // One painter's list for ALL faces, not one sort per block.
        scene.faces.sort {
            $0.depth == $1.depth ? $0.order < $1.order : $0.depth < $1.depth
        }
        return scene
    }

    /// Radius (model units) the crack web has reached for a 0…1 crack growth.
    static func crackFront(_ crack: Double) -> Double {
        smooth(crack) * crackReach
    }

    /// Eleven mortar joints on the front skin of the right half of the wall
    /// where light seeps through. Chosen deterministically but scattered, so
    /// the leaks look accidental; every anchor lies on an existing stone.
    struct Seam: Equatable, Sendable {
        let index: Int
        let cell: Int
        let point: Point
    }

    static func seams(scene: Scene) -> [Seam] {
        let candidates = scene.poses.indices.filter { index in
            let cell = scene.poses[index].cell
            return cell.u > 0 && abs(cell.v) <= 120 && !cell.isMerlon
        }
        guard !candidates.isEmpty else { return [] }
        return (0..<seamCount).map { index in
            let pick = candidates[min(candidates.count - 1,
                                      Int(random(index * 7 + 3) * Double(candidates.count)))]
            let pose = scene.poses[pick]
            let seam = pose.cell.seams[min(3, Int(random(index + 41) * 4))]
            let point = pose.transform(Vector(x: seam.x, y: seam.y, z: depth)).projected
            return Seam(index: index, cell: pick, point: point)
        }
    }

    static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
    static func smooth(_ value: Double) -> Double {
        let t = clamp(value)
        return t * t * (3 - 2 * t)
    }
    static func random(_ index: Int) -> Double {
        let value = sin(Double(index) * 127.1 + 311.7) * 43758.5453
        return value - floor(value)
    }
}
