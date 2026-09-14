import XCTest
@testable import olcrtc_ios

// #259: pure-logic tests for the single-source VPS display reducer introduced in
// #258 (HostBase / HostOp / HostDisplay + their transitions). These lock in the
// invariants that stop the Manage-VPS status from "jumping":
//   • a probe result is the ONLY thing that sets the base (terminalBase),
//   • while an op runs the card shows the PREVIOUS base, never the target,
//   • phases advance forward only (and cap at the last milestone),
//   • a failure carries previousBase so Retry restores it.
// The reducer is a pure value type — no SwiftUI host or provisioner needed.

final class HostDisplayTests: XCTestCase {

    // MARK: HostBase(VPSReadinessState) mapping

    func testReadinessMapsToBase() {
        XCTAssertEqual(HostBase(.noPodman), .noPodman)
        XCTAssertEqual(HostBase(.noImage), .noImage)
        XCTAssertEqual(HostBase(.imageReady), .imageReady)
        XCTAssertEqual(HostBase(.containerStopped("x")), .stopped)
        XCTAssertEqual(HostBase(.containerRunning("x")), .running)
    }

    func testHasContainerOnlyForStoppedOrRunning() {
        XCTAssertTrue(HostBase.running.hasContainer)
        XCTAssertTrue(HostBase.stopped.hasContainer)
        for b in [HostBase.unknown, .noPodman, .noImage, .imageReady] {
            XCTAssertFalse(b.hasContainer, "\(b) must not report a container")
        }
    }

    func testToneVocabulary() {
        XCTAssertEqual(HostBase.unknown.tone, .unknown)
        XCTAssertEqual(HostBase.noPodman.tone, .unknown)
        XCTAssertEqual(HostBase.noImage.tone, .progress)   // amber: podman ok, image pending
        // #456 was: .ok for both. Green is now reserved for an end-to-end VERIFIED
        // result; podman "Up" only proves the process exists, and "image cached"
        // is not a success at all.
        XCTAssertEqual(HostBase.imageReady.tone, .unknown)
        XCTAssertEqual(HostBase.running.tone, .unknown)
        XCTAssertEqual(HostBase.stopped.tone, .warn)
    }

    /// #456: the honesty invariant behind the change above — NO podman-derived
    /// base may be green. Green must be earned by a probe.
    func testNoContainerStateEverClaimsGreen() {
        for b in [HostBase.unknown, .noPodman, .noImage, .imageReady, .stopped, .running] {
            XCTAssertNotEqual(b.tone, .ok, "\(b): podman status must never render as verified green")
        }
    }

    // MARK: HostBase.seed (pre-probe — never asserts running)

    func testSeedNeverAssertsRunning() {
        XCTAssertEqual(HostBase.seed(lastContainerName: nil), .unknown)
        XCTAssertEqual(HostBase.seed(lastContainerName: "olcrtc-server-abc"), .stopped)
    }

    // MARK: HostOp.target / phases

    func testOpTargets() {
        XCTAssertNil(HostOp.check.target)        // status probe → keep base
        XCTAssertNil(HostOp.reboot.target)       // host going down → keep base
        XCTAssertEqual(HostOp.install.target, .running)
        XCTAssertEqual(HostOp.start.target, .running)
        XCTAssertEqual(HostOp.reconfigure.target, .running)
        XCTAssertEqual(HostOp.update.target, .running)
        XCTAssertEqual(HostOp.stop.target, .stopped)
        XCTAssertEqual(HostOp.uninstall.target, .imageReady)
        XCTAssertEqual(HostOp.deepUninstall.target, .noPodman)
    }

    func testEveryOpHasPhasesAndVerb() {
        let ops: [HostOp] = [.check, .install, .start, .stop, .reconfigure,
                             .update, .uninstall, .deepUninstall, .reboot]
        for op in ops {
            XCTAssertGreaterThanOrEqual(op.stepCount, 2, "\(op) needs ≥2 steps to size the bar")
            XCTAssertFalse(op.verb.isEmpty, "\(op) needs a verb")
        }
    }

    // MARK: start — shows the PREVIOUS base, never the optimistic target

    func testStartShowsPreviousBaseNotTarget() {
        // "Start" resolves to .running, but while running from a .stopped base the
        // card must still report .stopped — the optimistic target is never shown.
        let d = HostDisplay.start(.start, from: .stopped)
        XCTAssertTrue(d.isRunning)
        XCTAssertEqual(d.base, .stopped)
        guard case .running(let op, let phase, let note, let prev) = d else {
            return XCTFail("start() must produce .running")
        }
        XCTAssertEqual(op, .start)
        XCTAssertEqual(phase, 0)
        XCTAssertEqual(note, L10n.vpsConnecting.localized())
        XCTAssertEqual(prev, .stopped)
    }

    // MARK: advanced — monotonic, capped, preserves previousBase

    func testAdvanceIsMonotonicAndCapped() {
        var d = HostDisplay.start(.install, from: .imageReady)
        let total = HostOp.install.stepCount
        for i in 1...(total + 5) {            // advance well past the milestone count
            d = d.advanced(note: "step \(i)")
        }
        guard case .running(_, let phase, let note, let prev) = d else {
            return XCTFail("still running")
        }
        XCTAssertEqual(phase, total - 1, "phase caps at the last milestone")
        XCTAssertEqual(note, "step \(total + 5)", "note tracks the latest message")
        XCTAssertEqual(prev, .imageReady, "previous base preserved across phases")
    }

    func testAdvanceNeverGoesBackward() {
        var d = HostDisplay.start(.update, from: .running)
        var last = -1
        for i in 1...10 {
            d = d.advanced(note: "m\(i)")
            guard case .running(_, let phase, _, _) = d else { return XCTFail("not running") }
            XCTAssertGreaterThanOrEqual(phase, last, "phase must never decrease")
            last = phase
        }
    }

    func testAdvanceOnNonRunningIsNoOp() {
        let base = HostDisplay.base(.running)
        XCTAssertEqual(base.advanced(note: "x"), base)
    }

    // MARK: terminalBase — the probe is authoritative (single terminal assignment)

    func testTerminalBaseProbeWins() {
        // Optimistic target was .running, but the probe came back .stopped → the
        // probe wins. This is the exact "no jump" guarantee.
        XCTAssertEqual(HostDisplay.terminalBase(op: .start, probed: .stopped, previous: .running),
                       .stopped)
    }

    func testTerminalBaseFallsBackToTargetThenPrevious() {
        // No probe (op didn't probe) → nominal target.
        XCTAssertEqual(HostDisplay.terminalBase(op: .stop, probed: nil, previous: .running), .stopped)
        // No probe and no target (reboot) → keep the previous base.
        XCTAssertEqual(HostDisplay.terminalBase(op: .reboot, probed: nil, previous: .running), .running)
    }

    // MARK: failure carries previousBase; Retry restores it

    func testFailureCarriesPreviousBaseAndNote() {
        let running = HostDisplay.start(.start, from: .running).advanced(note: "Verifying")
        let failed = running.failed(message: "container exited")
        guard case .failed(let op, let phase, let message, let prev) = failed else {
            return XCTFail("failed() must produce .failed")
        }
        XCTAssertEqual(op, .start)
        XCTAssertEqual(phase, "Verifying")          // the note where it failed
        XCTAssertEqual(message, "container exited")
        XCTAssertEqual(prev, .running)
        XCTAssertEqual(failed.base, .running)       // base under a failure = the previous base
    }

    func testRetryRestoresPreviousBase() {
        let failed = HostDisplay.start(.install, from: .imageReady).failed(message: "ssh timeout")
        guard let restored = failed.retryBase() else {
            return XCTFail("retryBase() must restore the previous base from a failure")
        }
        XCTAssertEqual(restored, .base(.imageReady))
    }

    func testRetryBaseNilWhenNotFailed() {
        XCTAssertNil(HostDisplay.base(.running).retryBase())
        XCTAssertNil(HostDisplay.start(.check, from: .unknown).retryBase())
    }

    func testFailedOnNonRunningIsNoOp() {
        let base = HostDisplay.base(.stopped)
        XCTAssertEqual(base.failed(message: "x"), base)
    }

    // MARK: HostHeadline (#456) — the ONE VPS-card verdict

    private func busyDisplay(_ op: HostOp, from base: HostBase) -> HostDisplay {
        HostDisplay.start(op, from: base)
    }

    func testHeadlineBusyWinsOverEverything() {
        let h = HostHeadline.reduce(display: busyDisplay(.install, from: .running),
                                    reachable: false,
                                    lastProbeAge: nil,
                                    health: .broken(.keyMismatch, age: 1))
        // #456: `.busy` now carries the live note + step so the pill can show
        // progress instead of repeating its own title. `HostDisplay.start` seeds
        // phase 0 with the "connecting" note.
        XCTAssertEqual(h, .busy(verb: HostOp.install.verb,
                                note: L10n.vpsConnecting.localized(),
                                step: 0, of: HostOp.install.stepCount))
        XCTAssertEqual(h.tone, .progress)
    }

    func testHeadlineOpFailureBeatsEveryStateReading() {
        let failed = busyDisplay(.start, from: .stopped).failed(message: "container exited")
        let h = HostHeadline.reduce(display: failed, reachable: true,
                                    lastProbeAge: 10, health: .verified(ms: 20, age: 5))
        // #456: `.opFailed` now names the operation, so the headline can say
        // WHICH action failed rather than a generic "last action failed".
        XCTAssertEqual(h, .opFailed(verb: HostOp.start.verb, message: "container exited"))
        XCTAssertEqual(h.tone, .error)
        XCTAssertEqual(h.subtitle, "container exited")
    }

    // The requirement-2 test: an unreachable VPS must NEVER be reported as
    // stopped or failed, however old the last container reading is.
    func testUnreachableNeverReadsAsStopped() {
        let h = HostHeadline.reduce(display: .base(.stopped), reachable: false,
                                    lastProbeAge: 900, health: .never)
        XCTAssertEqual(h, .unreachable(age: 900))
        XCTAssertEqual(h.tone, .unknown, "couldn't check is GREY, never red/amber")
        XCTAssertNotEqual(h, .containerStopped(age: 900))   // #471
        XCTAssertEqual(h.title, L10n.vpsHeadlineUnreachable.localized())
    }

    func testUnreachableWithNoProbeAgeStillSaysCannotReach() {
        let h = HostHeadline.reduce(display: .base(.running), reachable: false,
                                    lastProbeAge: nil, health: .verified(ms: 10, age: 1))
        XCTAssertEqual(h, .unreachable(age: nil))
        XCTAssertEqual(h.subtitle, L10n.vpsHeadlineUnreachableHintNever.localized())
    }

    func testNeverProbedIsNotCheckedNotAVerdict() {
        // A persisted/seeded base must not be presented as present-tense fact
        // before anything has probed this launch (the stale-"stopped" bug).
        let h = HostHeadline.reduce(display: .base(.stopped), reachable: nil,
                                    lastProbeAge: nil, health: .never)
        XCTAssertEqual(h, .notChecked)
        XCTAssertEqual(h.tone, .unknown)
    }

    func testStoppedContainerIsAmberOnceActuallyProbed() {
        let h = HostHeadline.reduce(display: .base(.stopped), reachable: true,
                                    lastProbeAge: 5, health: .never)
        XCTAssertEqual(h, .containerStopped(age: 5))   // #471
        XCTAssertEqual(h.tone, .warn)
    }

    func testNothingInstalledDefersToTheBase() {
        for b in [HostBase.unknown, .noPodman, .noImage, .imageReady] {
            let h = HostHeadline.reduce(display: .base(b), reachable: true,
                                        lastProbeAge: 5, health: .verified(ms: 1, age: 1))
            XCTAssertEqual(h, .noContainer(b, age: 5))   // #471
            XCTAssertEqual(h.tone, b.tone)
            XCTAssertEqual(h.title, b.title)
        }
    }

    func testHealthIsTheHeadlineWhenNothingElseIsInTheWay() {
        let verified = HealthDisplay.verified(ms: 42, age: 30)
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: 5, health: verified)
        XCTAssertEqual(h, .health(verified, verified: 0, total: 0, age: nil))   // #471
        XCTAssertEqual(h.tone, .ok)          // the ONLY route to green on the card
        XCTAssertEqual(h.title, verified.title)
    }

    func testRunningContainerWithNoProbeEvidenceIsNotGreen() {
        // The exact fake-green: podman says Up, nothing has verified anything.
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: 5, health: .never)
        XCTAssertEqual(h, .health(.never, verified: 0, total: 0, age: nil))   // #471
        XCTAssertNotEqual(h.tone, .ok)
    }

    func testRunningContainerWithABrokenProtocolIsRed() {
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: 5, health: .broken(.keyMismatch, age: 60))
        XCTAssertEqual(h.tone, .error)
        XCTAssertEqual(h.title, HealthReason.keyMismatch.headline)
    }
}
