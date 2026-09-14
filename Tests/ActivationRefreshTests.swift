import XCTest
@testable import olcrtc_ios

// boc #485
@MainActor
final class ActivationRefreshTests: XCTestCase {
    func testAdoptionCompletesBeforeChecksAndRenewal() async {
        var events: [String] = []
        await ActivationRefresh.run(
            adopt: {
                events.append("adopt started")
                await Task.yield()
                events.append("adopt completed")
            },
            isCurrent: { true },
            refresh: { events.append("refresh") },
            renew: { events.append("renew") })
        XCTAssertEqual(events, ["adopt started", "adopt completed", "refresh", "renew"])
    }

    func testSupersededActivationDoesNotRunChecks() async {
        var current = true
        var checks = 0
        await ActivationRefresh.run(
            adopt: { current = false },
            isCurrent: { current },
            refresh: { checks += 1 },
            renew: { checks += 1 })
        XCTAssertEqual(checks, 0)
    }

    func testCancellationDuringAdoptionDoesNotRunChecks() async {
        var checks = 0
        let task = Task {
            await ActivationRefresh.run(
                adopt: {
                    while !Task.isCancelled { await Task.yield() }
                },
                isCurrent: { true },
                refresh: { checks += 1 },
                renew: { checks += 1 })
        }
        task.cancel()
        await task.value
        XCTAssertEqual(checks, 0)
    }
}
// eoc #485
