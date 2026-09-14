import XCTest
@testable import olcrtc_ios

// boc #483: caller cancellation is separate from an explicit user stop. This
// fixture needs no app/settings globals and joins both controller task tails.
@MainActor
final class VPNControllerCancellationTests: XCTestCase {
    func testCancellingCallerDuringSaveCannotLaunchAnOrphan() async {
        let gate = LifecycleGate()
        let profile = LifecycleProfile()
        profile.onSave = { await gate.wait() }
        let vpn = VPNController(loadProfiles: { [profile] }, makeProfile: { profile })
        let params = OlcrtcConnection(carrier: "jitsi", transport: "datachannel", roomID: "test",
                                      key: String(repeating: "a", count: 64), clientID: "test")
        let config = VPNConfig(from: params, dns: "1.1.1.1", timeoutMs: 1_000,
                               fallbackVP8FPS: 10, fallbackVP8Batch: 1)
        let attempt = Task { try await vpn.start(config) }
        await lifecycleEventually { gate.entered }
        attempt.cancel()
        gate.release()
        let outcome = await attempt.result
        switch outcome {
        case .success: XCTFail("cancelled caller must not succeed")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        await lifecycleEventually { vpn.stopRequested }
        try? await vpn.stopAndWait()
        XCTAssertEqual(profile.startCount, 0)
        XCTAssertFalse(VPNController.mayHoldRoutes(vpn.status))
    }
}
// eoc #483
