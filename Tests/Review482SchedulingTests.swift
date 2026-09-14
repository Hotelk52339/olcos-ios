import XCTest
@testable import olcrtc_ios

// boc #482: C3/C5/C6/C7/C8/C9. Continuations deliberately ignore cancellation,
// exactly like a native probe finishing later. No network/native/VPS work.
@MainActor
final class Review482SchedulingTests: XCTestCase {
    // Nested types do not inherit the test case's global-actor isolation.
    // Keep the entered flag, release flag and continuation on the same actor.
    @MainActor
    private final class Gate {
        private(set) var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    // Poll actor-confined state against a monotonic deadline, yielding the
    // actor each time. A timeout fails and returns to the test's defer cleanup;
    // a task-group race would still await a stuck continuation on group exit.
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                XCTFail("Cancelled while waiting for \(description)", file: file, line: line)
                return false
            }
        }
        return true
    }

    private func waitForCompletion(
        of task: Task<Void, Never>?,
        named description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        guard let task else {
            XCTFail("Missing task: \(description)", file: file, line: line)
            return false
        }
        var completed = false
        // Observe the task's actual completion, including scheduler defer
        // cleanup, rather than merely the work closure returning.
        let observer = Task { @MainActor in
            await task.value
            completed = true
        }
        defer { observer.cancel() }
        return await waitUntil(description, file: file, line: line) { completed }
    }

    func testSupersededForcedSweepCannotClearItsSuccessor() async {
        let health = HealthCoordinator(loadPersisted: false)
        let old = Gate(), newer = Gate()
        defer {
            old.release()
            newer.release()
            health.cancelAll()
        }
        let oldTask = health.startSweep(force: true) { await old.wait() }
        defer { oldTask?.cancel() }
        guard await waitUntil("old sweep entry", condition: { old.entered }) else { return }
        let newerTask = health.startSweep(force: true) { await newer.wait() }
        defer { newerTask?.cancel() }
        guard await waitUntil("successor sweep entry", condition: { newer.entered }) else { return }
        old.release()
        guard await waitForCompletion(of: oldTask, named: "old sweep completion") else { return }
        XCTAssertTrue(health.forcedSweepRunning)
        var automaticRan = false
        let automatic = health.startSweep(force: false) { automaticRan = true }
        defer { automatic?.cancel() }
        XCTAssertNil(automatic)
        XCTAssertFalse(automaticRan)
        XCTAssertTrue(health.forcedSweepRunning)
        newer.release()
        guard await waitForCompletion(of: newerTask, named: "successor sweep completion") else { return }
        XCTAssertFalse(health.forcedSweepRunning)
    }

    func testCancelledSweepCleanupCannotClearNewForcedOwner() async {
        let health = HealthCoordinator(loadPersisted: false)
        let old = Gate(), newer = Gate()
        defer {
            old.release()
            newer.release()
            health.cancelAll()
        }
        let oldTask = health.startSweep(force: true) { await old.wait() }
        defer { oldTask?.cancel() }
        guard await waitUntil("old sweep entry", condition: { old.entered }) else { return }
        health.cancelAll()
        let newerTask = health.startSweep(force: true) { await newer.wait() }
        defer { newerTask?.cancel() }
        guard await waitUntil("new forced owner entry", condition: { newer.entered }) else { return }
        old.release()
        guard await waitForCompletion(of: oldTask, named: "cancelled sweep completion") else { return }
        XCTAssertTrue(health.forcedSweepRunning)
        newer.release()
        guard await waitForCompletion(of: newerTask, named: "new forced owner completion") else { return }
        XCTAssertFalse(health.forcedSweepRunning)
    }

    func testGateReleaseBeforeEntryIsRememberedAndIdempotent() async {
        let gate = Gate()
        defer { gate.release() }
        gate.release()
        gate.release()
        let task = Task { @MainActor in await gate.wait() }
        defer { task.cancel() }
        guard await waitForCompletion(of: task, named: "already released gate") else { return }
        XCTAssertTrue(gate.entered)
    }

    func testForegroundClaimsRearmOnlyOnExplicitReopenNotification() {
        let health = HealthCoordinator(loadPersisted: false)
        XCTAssertTrue(health.claimAutomaticSweep())
        XCTAssertTrue(health.claimServerPass())
        // An inactive round-trip sends no reopen notification (App.swift).
        XCTAssertFalse(health.claimAutomaticSweep())
        XCTAssertFalse(health.claimServerPass())
        health.noteForegrounded()
        XCTAssertTrue(health.claimAutomaticSweep())
        XCTAssertTrue(health.claimServerPass())
        XCTAssertFalse(health.claimAutomaticSweep())
        XCTAssertFalse(health.claimServerPass())
    }

    func testHostLaneIsExclusiveAcrossCallersAndReusableAfterRelease() {
        let host = UUID(), other = UUID()
        defer { Provisioner.leaveHost(host); Provisioner.leaveHost(other) }
        XCTAssertTrue(Provisioner.tryEnterHost(host))
        XCTAssertFalse(Provisioner.tryEnterHost(host))
        XCTAssertTrue(Provisioner.busyHostIDs.contains(host))
        XCTAssertTrue(Provisioner.tryEnterHost(other))
        Provisioner.leaveHost(host)
        XCTAssertTrue(Provisioner.tryEnterHost(host))
        XCTAssertFalse(Provisioner.tryEnterHost(host))
    }

    func testNewHostNeedsFirstProbeWithoutRecheckingExistingHosts() {
        let existing = ServerHost(label: "Existing", host: "example.invalid")
        let added = ServerHost(label: "Added", host: "example.invalid")
        let attempts = [existing.id: Date()]
        XCTAssertEqual(ServersView.neverProbedHosts([existing, added], lastProbe: attempts).map(\.id), [added.id])
        XCTAssertTrue(ServersView.neverProbedHosts([existing], lastProbe: attempts).isEmpty)
        XCTAssertTrue(ServersView.neverProbedHosts([added], lastProbe: [added.id: Date()]).isEmpty)
    }

    func testCopyableAddressUsesBoundPortUntilDisconnect() {
        XCTAssertEqual(SettingsAdvancedView.proxyAddress(boundPort: 1080, configuredPort: 1081),
                       "127.0.0.1:1080")
        XCTAssertEqual(SettingsAdvancedView.proxyAddress(boundPort: nil, configuredPort: 1081),
                       "127.0.0.1:1081")
    }
}
// eoc #482
