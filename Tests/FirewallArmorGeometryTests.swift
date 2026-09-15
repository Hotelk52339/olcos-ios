import Foundation
import XCTest
@testable import olcrtc_ios

final class FirewallArmorGeometryTests: XCTestCase {
    func testWallHasEightySixCompleteStonesWithMerlons() {
        let scene = FirewallArmorGeometry.scene(pressure: 0, breach: 0)
        XCTAssertEqual(scene.poses.count, 86)
        XCTAssertEqual(scene.faces.count, 86 * 6)
        XCTAssertEqual(Set(scene.poses.map { $0.cell.id }).count, 86)
        XCTAssertEqual(Set(scene.poses.map { $0.cell.row }), Set(-5...6))
        XCTAssertEqual(scene.poses.filter { $0.cell.isMerlon }.count, 3)
        XCTAssertEqual(scene.poses.filter { $0.cell.width < FirewallArmorGeometry.blockWidth * 0.75 }.count, 12,
                       "Odd courses end in half-width closers")
        for pose in scene.poses {
            XCTAssertEqual(pose.scale, 1)
            XCTAssertEqual(pose.center.x, pose.cell.u)
            XCTAssertEqual(pose.center.y, pose.cell.v)
            XCTAssertEqual(pose.center.z, 0)
            let corners = FirewallArmorGeometry.vertices(of: pose.cell)
            XCTAssertEqual(corners.count, 8)
            XCTAssertEqual(Set(corners.map(\.z)),
                           Set([-FirewallArmorGeometry.depth, FirewallArmorGeometry.depth]))
            XCTAssertLessThan(pose.cell.radius, 260)
        }
    }

    func testFacesAreGloballyDepthSortedAndDeterministic() {
        for progress in [0.0, 0.5, 0.7, 0.82, 0.95] {
            let scene = FirewallArmorGeometry.scene(pressure: 0.6, breach: progress)
            XCTAssertEqual(scene, FirewallArmorGeometry.scene(pressure: 0.6, breach: progress))
            for (a, b) in zip(scene.faces, scene.faces.dropFirst()) {
                XCTAssertLessThanOrEqual(a.depth, b.depth)
                if a.depth == b.depth { XCTAssertLessThan(a.order, b.order) }
            }
            for face in scene.faces {
                XCTAssertTrue(scene.poses.indices.contains(face.pose))
                XCTAssertEqual(face.points.count, 4)
            }
        }
    }

    func testNoFragmentDispersesBeforeMergedBeamAndEveryRowDisappears() {
        var model = FirewallBeamModel()
        model.apply(state: .connected)
        var lastCount = 86
        for frame in 0...144 {
            model.advance(to: Double(frame) / 30)
            let scene = FirewallArmorGeometry.scene(pressure: model.pressure, breach: model.breach)
            if model.breach <= FirewallBeamModel.Stage.burst {
                XCTAssertEqual(scene.poses.count, 86)
                for pose in scene.poses {
                    XCTAssertEqual(pose.scale, 1)
                    XCTAssertEqual(pose.angles, .init(x: 0, y: 0, z: 0))
                }
            } else {
                XCTAssertEqual(model.fusion, 1)
            }
            XCTAssertLessThanOrEqual(scene.poses.count, lastCount)
            lastCount = scene.poses.count
        }
        XCTAssertEqual(model.phase, .open)
        let gone = FirewallArmorGeometry.scene(pressure: model.pressure, breach: model.breach)
        XCTAssertTrue(gone.poses.isEmpty, "No upper or lower row remains")
        XCTAssertTrue(gone.faces.isEmpty)
        XCTAssertTrue(FirewallArmorGeometry.seams(scene: gone).isEmpty)
    }

    func testErrorStretchesSolidArmorThenReturnsExactlyToItsRestShape() {
        let rest = FirewallArmorGeometry.scene(pressure: 0, breach: 0)
        let charged = FirewallArmorGeometry.scene(pressure: 1, breach: 0)
        let failed = FirewallArmorGeometry.scene(pressure: 1, breach: 0, rejection: 1)
        XCTAssertEqual(failed.poses.count, rest.poses.count)
        for (normal, strained) in zip(charged.poses, failed.poses) {
            XCTAssertGreaterThan(strained.center.z, normal.center.z)
            XCTAssertGreaterThanOrEqual(abs(strained.center.x), abs(normal.center.x))
            XCTAssertEqual(strained.scale, 1, "Failure cannot erode the armor")
        }
        var model = FirewallBeamModel()
        model.apply(state: .error)
        for frame in 0...60 {
            model.advance(to: Double(frame) / 30)
            let scene = FirewallArmorGeometry.scene(pressure: model.pressure,
                                                    breach: model.breach, rejection: model.rejectionStrain)
            XCTAssertEqual(scene.poses.count, 86)
        }
        let recoiled = FirewallArmorGeometry.scene(pressure: model.pressure,
                                                   breach: model.breach, rejection: model.rejectionStrain)
        XCTAssertEqual(recoiled, rest)
    }

    func testErrorEntryPreservesLoadedShapeBeforeAdditionalStretch() {
        var model = FirewallBeamModel()
        model.apply(state: .connecting)
        model.advance(to: FirewallBeamModel.crackDuration)
        let before = FirewallArmorGeometry.scene(pressure: model.pressure, breach: model.breach)
        model.apply(state: .error)
        let entering = FirewallArmorGeometry.scene(pressure: model.pressure, breach: model.breach,
                                                   rejection: model.rejectionStrain)
        XCTAssertEqual(entering, before, "Changing state cannot instantly double the displacement gain")
        model.advance(to: model.time + FirewallBeamModel.flashDuration * 0.32)
        let stretched = FirewallArmorGeometry.scene(pressure: model.pressure, breach: model.breach,
                                                    rejection: model.rejectionStrain)
        for (old, new) in zip(before.poses, stretched.poses) {
            XCTAssertGreaterThan(new.center.z, old.center.z)
        }
    }

    func testSeamsLieOnStandingFrontFacesRightOfTheImpact() {
        for pressure in [0.0, 0.5, 1.0] {
            let scene = FirewallArmorGeometry.scene(pressure: pressure, breach: 0)
            let seams = FirewallArmorGeometry.seams(scene: scene)
            XCTAssertEqual(seams.count, FirewallArmorGeometry.seamCount)
            XCTAssertEqual(Set(seams.map(\.index)), Set(0..<FirewallArmorGeometry.seamCount))
            for seam in seams {
                let pose = scene.poses[seam.cell]
                XCTAssertFalse(pose.cell.isMerlon)
                XCTAssertGreaterThan(pose.cell.u, 0)
                let front = scene.faces.first { $0.pose == seam.cell && $0.kind == 1 }
                let polygon = front?.points ?? []
                // Joints lie in the 0.6-unit mortar gap just outside the inset front skin.
                XCTAssertTrue(contains(polygon, seam.point) || distance(polygon, seam.point) <= 1.0,
                              "Seam \(seam.index) must sit on the mortar joint of its stone's front skin")
                XCTAssertLessThan(seam.point.x, 160, "There is room to merge on the right")
            }
        }
    }

    func testCrackFrontHeatsStonesOutwardFromTheImpact() {
        let cold = FirewallArmorGeometry.scene(pressure: 0, breach: 0, crack: 0)
        XCTAssertTrue(cold.poses.allSatisfy { $0.hot == 0 })
        let half = FirewallArmorGeometry.scene(pressure: 0, breach: 0, crack: 0.5)
        let full = FirewallArmorGeometry.scene(pressure: 0, breach: 0, crack: 1)
        XCTAssertEqual(FirewallArmorGeometry.crackFront(1), FirewallArmorGeometry.crackReach)
        XCTAssertEqual(FirewallArmorGeometry.crackFront(0), 0)
        for (near, far) in zip(half.poses, full.poses) {
            XCTAssertLessThanOrEqual(near.hot, far.hot + 0.000001)
        }
        XCTAssertTrue(full.poses.allSatisfy { $0.hot > 0.4 }, "A full crack web lights the whole wall")
        let center = half.poses.min { $0.cell.radius < $1.cell.radius }!
        let edge = half.poses.max { $0.cell.radius < $1.cell.radius }!
        XCTAssertGreaterThan(center.hot, 0.4)
        XCTAssertEqual(edge.hot, 0, "Half-grown cracks have not reached the outer stones")
        XCTAssertEqual(FirewallArmorGeometry.scene(pressure: 0, breach: 0, crack: .nan), cold)
    }

    private func distance(_ polygon: [FirewallArmorGeometry.Point], _ point: FirewallArmorGeometry.Point) -> Double {
        guard polygon.count >= 2 else { return .infinity }
        var best = Double.infinity
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
            best = min(best, hypot(point.x - (a.x + dx * t), point.y - (a.y + dy * t)))
        }
        return best
    }

    private func contains(_ polygon: [FirewallArmorGeometry.Point], _ point: FirewallArmorGeometry.Point) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    func testProjectedFacesStayFiniteAndGeometryReversesWithoutRandomJumps() {
        var forward: [FirewallArmorGeometry.Scene] = []
        for frame in 0...60 {
            let progress = Double(frame) / 60
            let scene = FirewallArmorGeometry.scene(pressure: 0, breach: progress)
            forward.append(scene)
            for face in scene.faces {
                XCTAssertTrue(face.depth.isFinite)
                for point in face.points {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                    XCTAssertLessThan(abs(point.x), 2_000)
                    XCTAssertLessThan(abs(point.y), 2_000)
                }
            }
        }
        for frame in stride(from: 60, through: 0, by: -1) {
            XCTAssertEqual(FirewallArmorGeometry.scene(pressure: 0, breach: Double(frame) / 60),
                           forward[frame])
        }
        let rest = FirewallArmorGeometry.scene(pressure: 0, breach: 0)
        XCTAssertEqual(FirewallArmorGeometry.scene(pressure: .nan, breach: .infinity), rest)
    }
}
