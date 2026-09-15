import Foundation
import XCTest
@testable import olcrtc_ios

/// The armor choreography is a pure model contract. In particular, local
/// pressure is not success, and reversing fragments is not outgoing light.
final class FirewallArmorSequenceTests: XCTestCase {
    private let fps = 30.0

    private func assertNoOutput(
        _ model: FirewallBeamModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(model.seep, 0, "No light may seep through without success", file: file, line: line)
        XCTAssertEqual(model.fusion, 0, "No outgoing beam may merge without success", file: file, line: line)
        XCTAssertEqual(model.lineSettle, 0, "The traffic line only settles after success", file: file, line: line)
    }

    private func assertBounded(
        _ model: FirewallBeamModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let unitValues: [(String, Double)] = [
            ("pressure", model.pressure), ("seep", model.seep),
            ("fusion", model.fusion), ("destruction", model.destruction),
            ("failureTint", model.failureTint), ("rejectionStrain", model.rejectionStrain),
            ("progress", model.progress),
            ("breach", model.breach), ("crack", model.crack),
            ("flash", model.flash), ("pulse", model.pulse),
            ("greenMix", model.greenMix), ("intensity", model.intensity),
            ("lineSettle", model.lineSettle), ("inboundShare", model.inboundShare)
        ]
        for (name, value) in unitValues {
            XCTAssertTrue(value.isFinite, "\(name) must be finite", file: file, line: line)
            XCTAssertGreaterThanOrEqual(value, 0, name, file: file, line: line)
            XCTAssertLessThanOrEqual(value, 1, name, file: file, line: line)
        }
        XCTAssertTrue(model.flow.isFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(model.flow, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(model.flow, 1_000, file: file, line: line)
        XCTAssertTrue(model.transientRemaining.isFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(model.transientRemaining, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(
            model.transientRemaining,
            max(FirewallBeamModel.breakDuration,
                FirewallBeamModel.reassembleDuration + FirewallBeamModel.flashDuration),
            file: file, line: line
        )
    }

    func testSuccessHasDistinctPressureSeepFusionAndDestructionStages() {
        var model = FirewallBeamModel()
        model.apply(state: .connected)
        let duration = FirewallBeamModel.breakDuration

        model.advance(to: duration * 0.12)
        XCTAssertGreaterThan(model.pressure, 0, "First the incoming beam stretches intact armor")
        assertNoOutput(model)
        XCTAssertEqual(model.destruction, 0)

        model.advance(to: duration * 0.33)
        XCTAssertEqual(model.pressure, 1, accuracy: 0.000001)
        XCTAssertGreaterThan(model.seep, 0)
        XCTAssertLessThan(model.seep, 1, "Light begins as a partial seep, not a complete beam")
        XCTAssertEqual(model.fusion, 0)
        XCTAssertEqual(model.destruction, 0, "Seeping must not scatter armor")

        model.advance(to: duration * 0.53)
        XCTAssertEqual(model.seep, 1, accuracy: 0.000001)
        XCTAssertGreaterThan(model.fusion, 0)
        XCTAssertLessThan(model.fusion, 1, "The outgoing strands merge before armor disperses")
        XCTAssertEqual(model.destruction, 0)

        model.advance(to: duration * 0.80)
        XCTAssertEqual(model.seep, 1)
        XCTAssertEqual(model.fusion, 1)
        XCTAssertGreaterThan(model.destruction, 0)
        XCTAssertLessThan(model.destruction, 1)
        XCTAssertLessThan(model.pressure, 1, "Pressure releases as the armor disperses")
        XCTAssertEqual(model.lineSettle, 0, accuracy: 0.000001,
                       "The released beam is still thin while the stones fly")

        model.advance(to: duration * 0.9)
        XCTAssertGreaterThan(model.lineSettle, 0)
        XCTAssertLessThan(model.lineSettle, 1, "The braid widens gradually, not in one frame")

        model.advance(to: duration)
        XCTAssertEqual(model.phase, .open)
        XCTAssertEqual(model.pressure, 0)
        XCTAssertEqual(model.seep, 1)
        XCTAssertEqual(model.fusion, 1)
        XCTAssertEqual(model.destruction, 1)
        XCTAssertEqual(model.lineSettle, 1)
        XCTAssertEqual(model.failureTint, 0)
        XCTAssertEqual(FirewallBeamModel.settled(state: .connected).lineSettle, 1,
                       "A settled connected hero shows the full braided line")
        XCTAssertEqual(FirewallBeamModel.settled(state: .connecting).lineSettle, 0)
        XCTAssertEqual(FirewallBeamModel.settled(state: .error).lineSettle, 0)
    }

    func testInboundShareIsClampedAndFiniteAndDefaultsToHalf() {
        var model = FirewallBeamModel()
        XCTAssertEqual(model.inboundShare, 0.5)
        model.setInboundShare(0.8)
        XCTAssertEqual(model.inboundShare, 0.8)
        model.setInboundShare(3)
        XCTAssertEqual(model.inboundShare, 1)
        model.setInboundShare(-1)
        XCTAssertEqual(model.inboundShare, 0)
        model.setInboundShare(.nan)
        XCTAssertEqual(model.inboundShare, 0.5, "A missing measurement means an even split")
    }

    func testThirtyFPSIncludesEverySuccessStageInOrder() throws {
        // Both an immediate success and success after a long connection attempt
        // must preserve the intermediate pictures, not jump straight to debris.
        for charged in [false, true] {
            var model = charged
                ? FirewallBeamModel.settled(state: .connecting)
                : FirewallBeamModel()
            model.apply(state: .connected)
            var firstPressure: Int?
            var firstSeep: Int?
            var firstFusion: Int?
            var firstDestruction: Int?
            let frames = Int(ceil(FirewallBeamModel.breakDuration * fps))
            for frame in 0...frames {
                model.advance(to: Double(frame) / fps)
                if model.pressure > 0, firstPressure == nil { firstPressure = frame }
                if model.seep > 0, firstSeep == nil { firstSeep = frame }
                if model.fusion > 0, firstFusion == nil { firstFusion = frame }
                if model.destruction > 0, firstDestruction == nil { firstDestruction = frame }
                if model.fusion > 0 {
                    XCTAssertEqual(model.seep, 1, accuracy: 0.000001)
                }
                if model.destruction > 0 {
                    XCTAssertEqual(model.fusion, 1, accuracy: 0.000001)
                }
                XCTAssertEqual(model.failureTint, 0)
                assertBounded(model)
            }
            let pressure = try XCTUnwrap(firstPressure)
            let seep = try XCTUnwrap(firstSeep)
            let fusion = try XCTUnwrap(firstFusion)
            let destruction = try XCTUnwrap(firstDestruction)
            XCTAssertLessThan(pressure, seep)
            XCTAssertLessThan(seep, fusion)
            XCTAssertLessThan(fusion, destruction)
        }
    }

    func testLongConnectingNeverLeaksOrDestroysArmor() {
        var model = FirewallBeamModel()
        model.apply(state: .connecting)
        for frame in 0...3_600 {
            model.advance(to: Double(frame) / fps)
            assertNoOutput(model)
            XCTAssertEqual(model.destruction, 0)
            XCTAssertEqual(model.failureTint, 0)
            assertBounded(model)
        }
        model.advance(to: 86_400)
        XCTAssertEqual(model.pressure, 1, "Waiting may sustain pressure indefinitely")
        assertNoOutput(model)
        XCTAssertEqual(model.destruction, 0, "Elapsed time alone never authorizes success")
        XCTAssertEqual(model.phase, .charging)
    }

    func testErrorStretchesThenRecoilsWithoutOutputAndDelaysItsTint() {
        // Test both a cold rejection and a rejection of an already loaded wall.
        for connectingTime in [0.0, FirewallBeamModel.crackDuration * 0.25] {
            var model = FirewallBeamModel()
            if connectingTime > 0 {
                model.apply(state: .connecting)
                model.advance(to: connectingTime)
            }
            let incomingPressure = model.pressure
            model.apply(state: .error)
            XCTAssertEqual(model.pressure, incomingPressure, accuracy: 0.000001,
                           "An error should retain the pressure already applied")
            XCTAssertEqual(model.failureTint, 0, "Rejection starts with pressure, not instant red")
            let start = model.time
            let duration = FirewallBeamModel.flashDuration

            model.advance(to: start + duration * 0.20)
            XCTAssertGreaterThan(model.pressure, incomingPressure)
            XCTAssertEqual(model.failureTint, 0, "The early pressure stretch is not tinted")

            model.advance(to: start + duration * 0.50)
            let peak = model.pressure
            XCTAssertEqual(peak, 1, accuracy: 0.000001)
            XCTAssertGreaterThan(model.failureTint, 0, "The failure tint follows the stretch")

            model.advance(to: start + duration * 0.80)
            XCTAssertGreaterThan(model.pressure, 0)
            XCTAssertLessThan(model.pressure, peak, "The intact armor visibly recoils")

            model.advance(to: start + duration + 1 / fps)
            XCTAssertEqual(model.pressure, 0)
            XCTAssertEqual(model.failureTint, 1)
            XCTAssertEqual(model.transientRemaining, 0)
            XCTAssertFalse(model.isAnimating, "Error must finish its finite recoil")

            // Independently sample the whole rejection at the actual cadence.
            var sampled = FirewallBeamModel()
            sampled.apply(state: .connecting)
            sampled.advance(to: connectingTime)
            sampled.apply(state: .error)
            for frame in 0...Int(ceil((duration + 1) * fps)) {
                sampled.advance(to: connectingTime + Double(frame) / fps)
                assertNoOutput(sampled)
                XCTAssertEqual(sampled.breach, 0)
                XCTAssertEqual(sampled.destruction, 0)
                assertBounded(sampled)
            }
        }
    }

    func testConnectedToErrorCancelsOutgoingLightInTheSameFrame() {
        for fraction in [0.05, 0.33, 0.53, 0.85, 1.0] {
            var model = FirewallBeamModel()
            model.apply(state: .connected)
            model.advance(to: FirewallBeamModel.breakDuration * fraction)
            if fraction > FirewallBeamModel.Stage.seepStart { XCTAssertGreaterThan(model.seep, 0) }
            if fraction > FirewallBeamModel.Stage.fusionStart { XCTAssertGreaterThan(model.fusion, 0) }
            let start = model.time
            let priorDestruction = model.destruction
            model.apply(state: .error)
            assertNoOutput(model) // No advance: cancellation is synchronous.

            // Scattered fragments may reverse back into position. They are
            // geometry, not permission to keep displaying a success output.
            XCTAssertEqual(model.destruction, priorDestruction, accuracy: 0.000001)
            var lastDestruction = model.destruction
            let settle = FirewallBeamModel.reassembleDuration + FirewallBeamModel.flashDuration + 1
            for frame in 0...Int(ceil(settle * fps)) {
                model.advance(to: start + Double(frame) / fps)
                assertNoOutput(model)
                XCTAssertNotEqual(model.phase, .open, "A cancelled success must never complete later")
                XCTAssertLessThanOrEqual(model.destruction, lastDestruction + 0.000001)
                lastDestruction = model.destruction
                assertBounded(model)
            }
            XCTAssertEqual(model.phase, .rejected)
            XCTAssertEqual(model.destruction, 0)
            XCTAssertEqual(model.pressure, 0)
            XCTAssertEqual(model.failureTint, 1)
        }
    }

    func testInterruptionAtExactStageBoundariesCannotLeaveAnOrphanSuccess() {
        let duration = FirewallBeamModel.breakDuration
        for fraction in [0.0, FirewallBeamModel.Stage.seepStart, FirewallBeamModel.Stage.fusionStart,
                         FirewallBeamModel.Stage.fusionEnd, FirewallBeamModel.Stage.burst,
                         FirewallBeamModel.Stage.settleStart, 1.0] {
            for target in [FirewallBeamState.idle, .connecting, .error] {
                // Cover both orderings when a frame and a state notification
                // coincide: notify just before the frame, or render it first.
                for renderBoundaryFirst in [false, true] {
                    var model = FirewallBeamModel()
                    model.apply(state: .connected)
                    let boundary = duration * fraction
                    model.advance(to: max(0, boundary - 1 / fps))
                    if renderBoundaryFirst { model.advance(to: boundary) }
                    model.apply(state: target)
                    assertNoOutput(model)
                    model.advance(to: boundary)
                    assertNoOutput(model)
                    for frame in 1...Int(ceil((duration + 3) * fps)) {
                        model.advance(to: boundary + Double(frame) / fps)
                        XCTAssertEqual(model.state, target)
                        XCTAssertNotEqual(model.phase, .breaking)
                        XCTAssertNotEqual(model.phase, .open)
                        assertNoOutput(model)
                        assertBounded(model)
                    }
                    XCTAssertEqual(model.destruction, 0)
                    let expectedPhase: FirewallBeamModel.Phase
                    switch target {
                    case .idle: expectedPhase = .intact
                    case .connecting: expectedPhase = .charging
                    case .error: expectedPhase = .rejected
                    case .connected: XCTFail("Not an interruption target"); continue
                    }
                    XCTAssertEqual(model.phase, expectedPhase)
                }
            }
        }
    }

    func testAdoptedConnectedStateKeepsMeasuredFlowWithoutReplayingArmorSequence() {
        let measured = SignalMotionPolicy.intensity(bytesPerSecond: 200_000)
        var model = FirewallBeamModel.settled(state: .connected, intensity: measured)
        model.advance(to: 100)
        let initialFlow = model.flow
        let initialParticle = model.particle(0).x
        for frame in 1...60 {
            // Repeated observations of the adopted tunnel are not new success.
            model.apply(state: .connected)
            model.advance(to: 100 + Double(frame) / fps)
            XCTAssertEqual(model.phase, .open)
            XCTAssertEqual(model.pressure, 0)
            XCTAssertEqual(model.seep, 1)
            XCTAssertEqual(model.fusion, 1)
            XCTAssertEqual(model.destruction, 1)
            XCTAssertEqual(model.failureTint, 0)
            XCTAssertEqual(model.transientRemaining, 0)
            XCTAssertEqual(model.intensity, measured)
            assertBounded(model)
        }
        XCTAssertGreaterThan(model.flow, initialFlow)
        XCTAssertEqual(model.flow - initialFlow,
                       2 * FirewallBeamModel.flowSpeed(intensity: measured),
                       accuracy: 0.000001)
        XCTAssertNotEqual(model.particle(0).x, initialParticle)

        let flowBeforeMeasurement = model.flow
        let busier = SignalMotionPolicy.intensity(bytesPerSecond: 2_000_000)
        model.setIntensity(busier)
        XCTAssertEqual(model.flow, flowBeforeMeasurement,
                       "A throughput sample changes pace, not accumulated travel")
        model.advance(to: 102 + 1 / fps)
        XCTAssertEqual(model.flow - flowBeforeMeasurement,
                       FirewallBeamModel.flowSpeed(intensity: busier) / fps,
                       accuracy: 0.000001)
        XCTAssertEqual(model.phase, .open)
        XCTAssertEqual(model.pressure, 0)
        XCTAssertEqual(model.fusion, 1)
        XCTAssertEqual(model.destruction, 1)
    }

    func testDroppedReassemblyFramesStillFinishErrorWithinTheOriginalSchedule() {
        for openness in [0.25, 0.85, 1.0] {
            var initial = FirewallBeamModel()
            initial.advance(to: 100)
            initial.apply(state: .connected)
            initial.advance(to: 100 + FirewallBeamModel.breakDuration * openness)
            initial.apply(state: .error)
            let start = initial.time
            let deadline = initial.transientRemaining
            let closingTime = deadline - FirewallBeamModel.flashDuration
            let lastScheduledFrame = deadline + 1 / fps
            let schedules: [[TimeInterval]] = [
                // A dropped completion frame must not restart the error clock.
                [closingTime + 0.2, lastScheduledFrame],
                // Several missed dates, including a late reassembly completion.
                [closingTime * 0.5, closingTime + 0.25,
                 deadline - 0.1, lastScheduledFrame],
                // One frame arrives after BOTH reassembly and recoil deadlines.
                [deadline + 2]
            ]
            for schedule in schedules {
                var model = initial
                for offset in schedule {
                    model.advance(to: start + offset)
                    XCTAssertEqual(model.transientRemaining, max(0, deadline - offset),
                                   accuracy: 0.000001,
                                   "Dropped frames cannot extend a finite error schedule")
                    assertNoOutput(model)
                    assertBounded(model)
                }
                XCTAssertEqual(model.phase, .rejected)
                XCTAssertEqual(model.progress, 1)
                XCTAssertEqual(model.pressure, 0, "The final scheduled picture must finish recoiling")
                XCTAssertEqual(model.destruction, 0)
                XCTAssertEqual(model.failureTint, 1)
                XCTAssertEqual(model.transientRemaining, 0)
                XCTAssertFalse(model.isAnimating, "No extra timeline dates should be needed")
            }
        }
    }

    func testFirstClockFramePreservesTheAdoptedMeasuredIntensity() {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        for measured in [0.0, 0.25,
                         SignalMotionPolicy.intensity(bytesPerSecond: 2_000_000), 1.0] {
            let clock = SignalPhaseClock()
            var model = FirewallBeamModel.settled(state: .connected, intensity: measured)

            // Mirror the first live frame: the clock feeds the adopted model.
            clock.advance(to: date, target: measured)
            model.setIntensity(clock.intensity)
            model.advance(to: date.timeIntervalSinceReferenceDate)
            XCTAssertEqual(clock.intensity, measured,
                           "Adoption must not briefly replace measured traffic with zero")
            XCTAssertEqual(model.intensity, measured)
            XCTAssertEqual(clock.phase, 0, "The first date seeds time without invented travel")
            XCTAssertEqual(model.phase, .open)
            XCTAssertEqual(model.fusion, 1)
            XCTAssertEqual(model.pressure, 0)

            let flow = model.flow
            clock.advance(to: date.addingTimeInterval(1 / fps), target: measured)
            model.setIntensity(clock.intensity)
            model.advance(to: date.timeIntervalSinceReferenceDate + 1 / fps)
            XCTAssertEqual(model.flow - flow,
                           FirewallBeamModel.flowSpeed(intensity: measured) / fps,
                           accuracy: 0.000001)
        }
    }

    func testResetClockSeedsTheCurrentMeasurementWithoutIntegratingTheHiddenInterval() {
        let clock = SignalPhaseClock()
        let initialDate = Date(timeIntervalSinceReferenceDate: 100)
        clock.advance(to: initialDate, target: 0.7)
        clock.advance(to: initialDate.addingTimeInterval(1 / fps), target: 0.7)
        XCTAssertGreaterThan(clock.phase, 0)

        for (index, currentTarget) in [0.15, 0.9, 0.0].enumerated() {
            let phaseBeforeReset = clock.phase
            clock.reset()
            let resumed = initialDate.addingTimeInterval(Double(index + 1) * 3_600)
            clock.advance(to: resumed, target: currentTarget)
            XCTAssertEqual(clock.intensity, currentTarget,
                           "Returning to the hero uses the current sample, not stale traffic")
            XCTAssertEqual(clock.phase, phaseBeforeReset,
                           "Reset must not integrate time while the hero was hidden")

            clock.advance(to: resumed.addingTimeInterval(1 / fps), target: currentTarget)
            XCTAssertEqual(clock.intensity, currentTarget)
            XCTAssertEqual(clock.phase - phaseBeforeReset,
                           SignalMotionPolicy.speed(intensity: currentTarget) / fps,
                           accuracy: 0.000001,
                           "The next frame resumes ordinary measured-speed motion")
        }
    }
}
