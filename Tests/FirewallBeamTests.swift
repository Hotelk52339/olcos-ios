import Foundation
import XCTest
@testable import olcrtc_ios

// The hero's firewall picture as a pure state machine: no SwiftUI, no clock,
// no randomness. The Canvas only reads `FirewallBeamModel`; everything the
// user sees as "the wall breaks / the beam is rejected / the wall closes" is
// decided here and pinned by these tests.
final class FirewallBeamTests: XCTestCase {

    private func make(_ state: FirewallBeamState, at time: TimeInterval = 100) -> FirewallBeamModel {
        var model = FirewallBeamModel()
        model.advance(to: time)
        model.apply(state: state)
        return model
    }

    // MARK: Resting frames

    func testFreshModelIsAnIntactWallWithAFaintBeam() {
        let model = FirewallBeamModel()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.phase, .intact)
        XCTAssertEqual(model.breach, 0)
        XCTAssertEqual(model.crack, 0)
        XCTAssertEqual(model.flash, 0)
        XCTAssertEqual(model.greenMix, 0)
        XCTAssertFalse(model.isRed)
        XCTAssertFalse(model.isAnimating)
        XCTAssertEqual(model.particleCount, 0)
    }

    func testSettledFramesMatchTheirStates() {
        let idle = FirewallBeamModel.settled(state: .idle)
        XCTAssertEqual(idle.phase, .intact)
        XCTAssertEqual(idle.breach, 0)
        XCTAssertFalse(idle.isAnimating)

        let connecting = FirewallBeamModel.settled(state: .connecting)
        XCTAssertEqual(connecting.phase, .charging)
        XCTAssertEqual(connecting.crack, 1, "settled connecting shows fully grown cracks")
        XCTAssertEqual(connecting.breach, 0, "connecting never opens the wall")

        let connected = FirewallBeamModel.settled(state: .connected, intensity: 0.5)
        XCTAssertEqual(connected.phase, .open)
        XCTAssertEqual(connected.breach, 1)
        XCTAssertEqual(connected.greenMix, 1)
        XCTAssertEqual(connected.intensity, 0.5)
        XCTAssertGreaterThan(connected.particleCount, 0)

        let error = FirewallBeamModel.settled(state: .error)
        XCTAssertEqual(error.phase, .rejected)
        XCTAssertTrue(error.isRed)
        XCTAssertEqual(error.flash, 0, "the flash has faded; the red tint remains via isRed")
        XCTAssertEqual(error.breach, 0, "an error never breaks the wall")
        XCTAssertFalse(error.isAnimating)
        XCTAssertEqual(error.transientRemaining, 0)
    }

    // MARK: Connecting

    func testConnectingPushesAndCracksButNeverOpens() {
        var model = make(.connecting)
        XCTAssertEqual(model.phase, .charging)
        XCTAssertTrue(model.isAnimating)
        XCTAssertTrue(model.isSignal)
        var lastCrack = -1.0
        for step in 0...40 {
            model.advance(to: 100 + Double(step) * 0.1)
            XCTAssertEqual(model.breach, 0)
            XCTAssertGreaterThanOrEqual(model.crack, lastCrack)
            XCTAssertLessThanOrEqual(model.crack, 1)
            XCTAssertGreaterThanOrEqual(model.pulse, 0)
            XCTAssertLessThanOrEqual(model.pulse, 1)
            lastCrack = model.crack
        }
        XCTAssertEqual(model.crack, 1, accuracy: 0.000001)
        XCTAssertEqual(model.particleCount, 0)
    }

    // MARK: Connected — the break

    func testConnectingToConnectedBreaksTheWallOnceThenStaysOpen() {
        var model = make(.connecting)
        model.advance(to: 101)
        model.apply(state: .connected)
        XCTAssertEqual(model.phase, .breaking)
        XCTAssertEqual(model.breach, 0, accuracy: 0.000001)
        XCTAssertEqual(model.transientRemaining, FirewallBeamModel.breakDuration, accuracy: 0.000001)

        var lastBreach = -1.0
        var time = 101.0
        while time < 101 + FirewallBeamModel.breakDuration {
            time += 1 / 30
            model.advance(to: time)
            XCTAssertGreaterThanOrEqual(model.breach, lastBreach, "the break never runs backwards")
            XCTAssertLessThanOrEqual(model.breach, 1)
            XCTAssertEqual(model.greenMix, model.breach, "the beam turns green exactly as the wall opens")
            lastBreach = model.breach
        }
        model.advance(to: time + 0.1)
        XCTAssertEqual(model.phase, .open)
        XCTAssertEqual(model.breach, 1)
        XCTAssertEqual(model.progress, 1)
        XCTAssertTrue(model.isAnimating, "particles keep flowing while connected")
        XCTAssertEqual(model.transientRemaining, 0)

        // Re-applying the same state is a no-op: no second break.
        let before = model
        model.apply(state: .connected)
        XCTAssertEqual(model, before)
    }

    func testBreakProgressClampsAcrossALongGapBetweenFrames() {
        var model = make(.connected)
        XCTAssertEqual(model.phase, .breaking)
        model.advance(to: 1_000)  // the app was in the background for a while
        XCTAssertEqual(model.phase, .open)
        XCTAssertEqual(model.breach, 1)
        XCTAssertEqual(model.progress, 1)
    }

    func testTimeNeverRunsBackwards() {
        var model = make(.connected)
        model.advance(to: 100.5)
        let midway = model
        model.advance(to: 50)
        XCTAssertEqual(model.time, midway.time)
        XCTAssertEqual(model.progress, midway.progress, accuracy: 0.000001)
        model.advance(to: .nan)
        XCTAssertEqual(model.time, midway.time)
    }

    // MARK: Disconnect — the wall reassembles

    func testDisconnectReassemblesTheWallAndSettlesIdle() {
        var model = make(.connected)
        model.advance(to: 200)
        XCTAssertEqual(model.phase, .open)
        model.apply(state: .idle)
        XCTAssertEqual(model.phase, .reassembling)
        XCTAssertEqual(model.breach, 1, accuracy: 0.000001, "starts from fully open")
        XCTAssertEqual(model.transientRemaining, FirewallBeamModel.reassembleDuration, accuracy: 0.000001)

        var lastBreach = 2.0
        var time = 200.0
        while time < 200 + FirewallBeamModel.reassembleDuration {
            time += 1 / 30
            model.advance(to: time)
            XCTAssertLessThanOrEqual(model.breach, lastBreach, "the wall only closes")
            XCTAssertEqual(model.crack, model.breach, accuracy: 0.000001, "cracks heal with the wall")
            lastBreach = model.breach
        }
        model.advance(to: time + 0.1)
        XCTAssertEqual(model.phase, .intact)
        XCTAssertEqual(model.breach, 0)
        XCTAssertFalse(model.isAnimating)
        XCTAssertEqual(model.particleCount, 0)
    }

    func testReconnectMidwayThroughReassemblyContinuesFromTheCurrentOpenness() {
        var model = make(.connected)
        model.advance(to: 200)
        model.apply(state: .idle)
        model.advance(to: 200 + FirewallBeamModel.reassembleDuration / 2)
        let openness = model.breach
        XCTAssertEqual(openness, 0.5, accuracy: 0.01)
        model.apply(state: .connected)
        XCTAssertEqual(model.phase, .breaking)
        XCTAssertEqual(model.breach, openness, accuracy: 0.000001, "no jump when the direction flips")
        model.advance(to: 200.25 + FirewallBeamModel.breakDuration)
        XCTAssertEqual(model.phase, .open)
    }

    func testDisconnectMidBreakClosesFromTheCurrentOpenness() {
        var model = make(.connected)
        model.advance(to: 100 + FirewallBeamModel.breakDuration * 0.4)
        let openness = model.breach
        XCTAssertEqual(openness, 0.4, accuracy: 0.01)
        model.apply(state: .idle)
        XCTAssertEqual(model.phase, .reassembling)
        XCTAssertEqual(model.breach, openness, accuracy: 0.000001)
    }

    // MARK: Error — rejected, wall intact

    func testErrorFromConnectingTurnsRedFlashesAndKeepsTheWallIntact() {
        var model = make(.connecting)
        model.advance(to: 101)
        model.apply(state: .error)
        XCTAssertEqual(model.phase, .rejected)
        XCTAssertTrue(model.isRed)
        XCTAssertEqual(model.flash, 1, accuracy: 0.000001)
        XCTAssertTrue(model.isAnimating)
        XCTAssertEqual(model.transientRemaining, FirewallBeamModel.flashDuration, accuracy: 0.000001)

        var lastFlash = 2.0
        var time = 101.0
        while time < 101 + FirewallBeamModel.flashDuration + 0.1 {
            time += 1 / 30
            model.advance(to: time)
            XCTAssertEqual(model.breach, 0, "an error never opens the wall")
            XCTAssertEqual(model.greenMix, 0)
            XCTAssertLessThanOrEqual(model.flash, lastFlash)
            lastFlash = model.flash
        }
        XCTAssertEqual(model.flash, 0)
        XCTAssertFalse(model.isAnimating, "a settled error holds a static red-tinted frame")
        XCTAssertTrue(model.isRed)
        XCTAssertEqual(model.transientRemaining, 0)
    }

    func testErrorWhileConnectedFirstClosesTheWallThenFlashes() {
        var model = make(.connected)
        model.advance(to: 200)
        model.apply(state: .error)
        XCTAssertEqual(model.phase, .reassembling)
        XCTAssertTrue(model.isRed)
        XCTAssertEqual(model.transientRemaining,
                       FirewallBeamModel.reassembleDuration + FirewallBeamModel.flashDuration,
                       accuracy: 0.000001)
        model.advance(to: 200 + FirewallBeamModel.reassembleDuration + 0.01)
        XCTAssertEqual(model.phase, .rejected)
        XCTAssertEqual(model.breach, 0)
        XCTAssertGreaterThan(model.flash, 0.9)
        model.advance(to: 300)
        XCTAssertEqual(model.flash, 0)
        XCTAssertFalse(model.isAnimating)
    }

    func testRetryFromErrorChargesAgainAndIdleFromErrorIsInstant() {
        var retry = make(.error)
        retry.advance(to: 150)
        retry.apply(state: .connecting)
        XCTAssertEqual(retry.phase, .charging)
        XCTAssertEqual(retry.progress, 0)
        XCTAssertFalse(retry.isRed)

        var idle = make(.error)
        idle.advance(to: 150)
        idle.apply(state: .idle)
        XCTAssertEqual(idle.phase, .intact)
        XCTAssertEqual(idle.transientRemaining, 0)
    }

    // MARK: Intensity, flow and particles

    func testIntensityIsClampedAndNonFiniteIsIdle() {
        var model = FirewallBeamModel()
        model.setIntensity(7)
        XCTAssertEqual(model.intensity, 1)
        model.setIntensity(-3)
        XCTAssertEqual(model.intensity, 0)
        model.setIntensity(.nan)
        XCTAssertEqual(model.intensity, 0)
        model.setIntensity(0.25)
        XCTAssertEqual(model.intensity, 0.25)
    }

    func testFlowIntegratesFasterWithMoreTraffic() {
        var calm = FirewallBeamModel.settled(state: .connected, intensity: 0)
        var busy = FirewallBeamModel.settled(state: .connected, intensity: 1)
        var lastCalm = calm.flow
        for step in 1...30 {
            let time = Double(step) / 30
            calm.advance(to: time)
            busy.advance(to: time)
            XCTAssertGreaterThan(calm.flow, lastCalm, "even idle traffic drifts")
            lastCalm = calm.flow
        }
        XCTAssertGreaterThan(busy.flow, calm.flow)
        XCTAssertEqual(calm.flow, FirewallBeamModel.flowSpeed(intensity: 0), accuracy: 0.001)
        XCTAssertEqual(busy.flow, FirewallBeamModel.flowSpeed(intensity: 1), accuracy: 0.001)
    }

    func testParticleCountFollowsIntensityWithinTheBudget() {
        XCTAssertEqual(FirewallBeamModel.settled(state: .connected, intensity: 0).particleCount,
                       FirewallBeamModel.minParticles)
        XCTAssertEqual(FirewallBeamModel.settled(state: .connected, intensity: 1).particleCount,
                       FirewallBeamModel.maxParticles)
        XCTAssertLessThanOrEqual(FirewallBeamModel.maxParticles, 40)
        var last = -1
        for step in 0...20 {
            let count = FirewallBeamModel.settled(state: .connected, intensity: Double(step) / 20).particleCount
            XCTAssertGreaterThanOrEqual(count, last)
            last = count
        }
        XCTAssertEqual(FirewallBeamModel.settled(state: .connecting, intensity: 1).particleCount, 0,
                       "no traffic through an intact wall")
    }

    func testParticlesAreDeterministicBoundedAndWrapAcrossTheWidth() {
        var model = FirewallBeamModel.settled(state: .connected, intensity: 0.7)
        let first = (0..<model.particleCount).map { model.particle($0) }
        let again = (0..<model.particleCount).map { model.particle($0) }
        XCTAssertEqual(first, again)
        for particle in first {
            XCTAssertGreaterThanOrEqual(particle.x, 0)
            XCTAssertLessThan(particle.x, 1)
            XCTAssertGreaterThanOrEqual(particle.lane, -1)
            XCTAssertLessThanOrEqual(particle.lane, 1)
            XCTAssertGreaterThan(particle.size, 0)
            XCTAssertLessThanOrEqual(particle.size, 1)
            XCTAssertGreaterThan(particle.alpha, 0)
            XCTAssertLessThanOrEqual(particle.alpha, 1)
        }
        for step in 1...200 {
            model.advance(to: Double(step) * 0.05)
            let particle = model.particle(0)
            XCTAssertGreaterThanOrEqual(particle.x, 0)
            XCTAssertLessThan(particle.x, 1)
        }
    }

    // MARK: Deterministic variation

    func testNoiseIsDeterministicInUnitRangeAndVariesWithSalt() {
        var seen = Set<Double>()
        for index in 0..<200 {
            let value = FirewallBeamModel.noise(index, 1)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
            XCTAssertEqual(value, FirewallBeamModel.noise(index, 1))
            XCTAssertNotEqual(value, FirewallBeamModel.noise(index, 2))
            seen.insert(value)
        }
        XCTAssertGreaterThan(seen.count, 190, "the hash must not collapse to a few values")
    }

    // MARK: Motion policy for the picture

    func testOnlyConnectedAndConnectingKeepAContinuousClock() {
        XCTAssertTrue(SignalMotionPolicy.keepsClock(.connected))
        XCTAssertTrue(SignalMotionPolicy.keepsClock(.connecting))
        XCTAssertFalse(SignalMotionPolicy.keepsClock(.idle))
        XCTAssertFalse(SignalMotionPolicy.keepsClock(.error))
        for state in [FirewallBeamState.idle, .connecting, .connected, .error] {
            XCTAssertFalse(SignalMotionPolicy.allowsMotion(state: state, sceneIsActive: true,
                                                           reduceMotion: true, isVisible: true),
                           "Reduce Motion is always static")
            XCTAssertFalse(SignalMotionPolicy.allowsMotion(state: state, sceneIsActive: false,
                                                           reduceMotion: false, isVisible: true))
            XCTAssertEqual(SignalMotionPolicy.allowsMotion(state: state, sceneIsActive: true,
                                                           reduceMotion: false, isVisible: true),
                           SignalMotionPolicy.keepsClock(state))
        }
    }
}
