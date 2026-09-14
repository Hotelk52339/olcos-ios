import Foundation
import XCTest
@testable import olcrtc_ios

// boc #486
// Pure decisions only: no device, UIKit generator, microphone, carrier,
// Keychain, UserDefaults, NetworkExtension or network request is touched.
final class SignalInteractionPolicyTests: XCTestCase {
    func testOnlyVisibleActiveConnectedWithoutReduceMotionMoves() {
        for connected in [false, true] {
            for active in [false, true] {
                for reduced in [false, true] {
                    for visible in [false, true] {
                        XCTAssertEqual(
                            SignalMotionPolicy.allowsMotion(
                                isConnected: connected, sceneIsActive: active,
                                reduceMotion: reduced, isVisible: visible),
                            connected && active && !reduced && visible)
                    }
                }
            }
        }
    }

    func testDrawWorkHasAFiniteBudget() {
        XCTAssertEqual(SignalMotionPolicy.framesPerSecond, 30)
        XCTAssertLessThanOrEqual(SignalMotionPolicy.lineCount, 8)
        XCTAssertLessThanOrEqual(SignalMotionPolicy.sampleCount, 128)
        XCTAssertGreaterThan(SignalMotionPolicy.sampleCount, 0)
    }

    func testLineEndsStayAtRestAndInteriorFlows() {
        for line in 0..<SignalMotionPolicy.lineCount {
            for phase in [0.0, 0.8, 2.4, 4.0] {
                for x in [0.0, 1.0] {
                    XCTAssertEqual(SignalMotionPolicy.displacement(
                        x: x, line: line, phase: phase, touchX: 0.5, touchY: 0),
                                   0, accuracy: 0.000001)
                }
            }
        }
        let first = SignalMotionPolicy.displacement(x: 0.4, line: 3, phase: 0,
                                                    touchX: nil, touchY: nil)
        let later = SignalMotionPolicy.displacement(x: 0.4, line: 3, phase: 1,
                                                    touchX: nil, touchY: nil)
        XCTAssertNotEqual(first, later)
    }

    func testTouchReshapesTheLineAndClampsOutsideTheView() {
        let rest = SignalMotionPolicy.displacement(x: 0.5, line: 3, phase: 0.5,
                                                   touchX: nil, touchY: nil)
        let touched = SignalMotionPolicy.displacement(x: 0.5, line: 3, phase: 0.5,
                                                      touchX: 0.5, touchY: 0.1)
        XCTAssertGreaterThan(touched, rest)
        XCTAssertEqual(
            SignalMotionPolicy.displacement(x: 0.5, line: 3, phase: 0.5, touchX: -20, touchY: 40),
            SignalMotionPolicy.displacement(x: 0.5, line: 3, phase: 0.5, touchX: 0, touchY: 1))
    }

    func testDisplacementIsFiniteAndBounded() {
        for line in 0..<SignalMotionPolicy.lineCount {
            for sample in 0...SignalMotionPolicy.sampleCount {
                let x = Double(sample) / Double(SignalMotionPolicy.sampleCount)
                for phase in [0.0, 1.0, 4.0, 10.0] {
                    let value = SignalMotionPolicy.displacement(
                        x: x, line: line, phase: phase, touchX: 0.5, touchY: 0)
                    XCTAssertTrue(value.isFinite)
                    XCTAssertLessThanOrEqual(abs(value), 1.3)
                }
            }
        }
    }

    func testAutomaticAndAdoptedStatesHaveNoOutcomeHaptic() {
        var policy = SignalHapticPolicy()
        for phase in [SignalConnectionPhase.idle, .connecting, .connected, .waiting, .failed] {
            XCTAssertNil(policy.outcome(phase: phase, connectedRecordID: UUID(),
                                        isVisible: true, sceneIsActive: true,
                                        isAutomaticRecovery: false))
        }
    }

    func testAUserConnectionSucceedsExactlyOnceForTheExpectedRecord() {
        var policy = SignalHapticPolicy()
        let record = UUID()
        policy.beginConnection(id: record)
        XCTAssertNil(policy.outcome(phase: .connecting, connectedRecordID: nil,
                                    isVisible: true, sceneIsActive: true, isAutomaticRecovery: false))
        XCTAssertEqual(policy.outcome(phase: .connected, connectedRecordID: record,
                                      isVisible: true, sceneIsActive: true, isAutomaticRecovery: false),
                       .success)
        XCTAssertNil(policy.outcome(phase: .connected, connectedRecordID: record,
                                    isVisible: true, sceneIsActive: true, isAutomaticRecovery: false))
    }

    func testSynchronousFailureIsConsumedOnceAndRetryCanFailAgain() {
        var policy = SignalHapticPolicy()
        let record = UUID()
        for _ in 0..<2 {
            policy.beginConnection(id: record)
            XCTAssertEqual(policy.outcome(phase: .failed, connectedRecordID: nil,
                                          isVisible: true, sceneIsActive: true, isAutomaticRecovery: false),
                           .error)
            XCTAssertNil(policy.outcome(phase: .failed, connectedRecordID: nil,
                                        isVisible: true, sceneIsActive: true, isAutomaticRecovery: false))
        }
    }

    func testHidingOrBackgroundingConsumesIntentWithoutReplay() {
        for visibility in [(false, true), (true, false), (false, false)] {
            var policy = SignalHapticPolicy()
            let record = UUID()
            policy.beginConnection(id: record)
            XCTAssertNil(policy.outcome(phase: .connected, connectedRecordID: record,
                                        isVisible: visibility.0, sceneIsActive: visibility.1,
                                        isAutomaticRecovery: false))
            XCTAssertNil(policy.outcome(phase: .connected, connectedRecordID: record,
                                        isVisible: true, sceneIsActive: true, isAutomaticRecovery: false))
        }
    }

    func testAutomaticRecoveryAndNetworkWaitDiscardUserIntent() {
        let record = UUID()
        for phase in [SignalConnectionPhase.connecting, .connected, .failed] {
            var policy = SignalHapticPolicy()
            policy.beginConnection(id: record)
            XCTAssertNil(policy.outcome(phase: phase, connectedRecordID: record,
                                        isVisible: true, sceneIsActive: true, isAutomaticRecovery: true))
            XCTAssertNil(policy.pendingConnectionID)
        }
        var waiting = SignalHapticPolicy()
        waiting.beginConnection(id: record)
        XCTAssertNil(waiting.outcome(phase: .waiting, connectedRecordID: nil,
                                     isVisible: true, sceneIsActive: true, isAutomaticRecovery: false))
        XCTAssertNil(waiting.outcome(phase: .connected, connectedRecordID: record,
                                     isVisible: true, sceneIsActive: true, isAutomaticRecovery: false))
    }

    func testDisconnectAndExplicitCancellationNeverProduceSuccess() {
        var policy = SignalHapticPolicy()
        let record = UUID()
        policy.beginConnection(id: record)
        XCTAssertNil(policy.outcome(phase: .idle, connectedRecordID: nil,
                                    isVisible: true, sceneIsActive: true, isAutomaticRecovery: false))
        policy.beginConnection(id: record)
        policy.cancel()
        XCTAssertNil(policy.outcome(phase: .failed, connectedRecordID: nil,
                                    isVisible: true, sceneIsActive: true, isAutomaticRecovery: false))
    }

    func testAReplacementOrUnknownSystemRecordCannotClaimSuccess() {
        for record in [UUID(), nil] {
            var policy = SignalHapticPolicy()
            policy.beginConnection(id: UUID())
            XCTAssertNil(policy.outcome(phase: .connected, connectedRecordID: record,
                                        isVisible: true, sceneIsActive: true, isAutomaticRecovery: false))
            XCTAssertNil(policy.pendingConnectionID)
        }
    }

    func testRealSelectionChangesOnly() {
        XCTAssertTrue(SignalHapticPolicy.selectionChanged(from: false, to: true))
        XCTAssertTrue(SignalHapticPolicy.selectionChanged(from: true, to: false))
        XCTAssertFalse(SignalHapticPolicy.selectionChanged(from: true, to: true))
        XCTAssertFalse(SignalHapticPolicy.selectionChanged(from: "server-a", to: "server-a"))
        XCTAssertTrue(SignalHapticPolicy.selectionChanged(from: "server-a", to: "server-b"))
    }
}
// eoc #486
