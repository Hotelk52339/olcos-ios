import XCTest
@testable import olcrtc_ios

// #442: pins the master-migration behaviour that moved bind/readiness failures
// from MobileStart to WaitReady. `OlcrtcEngine.isNoPeerWaitError` decides whether
// a WaitReady failure means "no peer rendezvoused in the room" (→ the #275
// user-facing diagnostic) or a real start failure (bind race / provider error)
// that should surface verbatim. The two "no peer" sentinels are master's
// mobile/runtime.go ErrReadyTimeout / ErrStoppedBeforeReady texts.
final class TunnelEngineWaitErrorTests: XCTestCase {

    func testReadinessTimeoutIsNoPeer() {
        XCTAssertTrue(OlcrtcEngine.isNoPeerWaitError("olcRTC runtime readiness timed out"))
    }

    func testStoppedBeforeReadyIsNoPeer() {
        XCTAssertTrue(OlcrtcEngine.isNoPeerWaitError("olcRTC runtime stopped before becoming ready"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(OlcrtcEngine.isNoPeerWaitError("OLCRTC RUNTIME READINESS TIMED OUT"))
    }

    func testBindFailureIsNotNoPeer() {
        XCTAssertFalse(OlcrtcEngine.isNoPeerWaitError(
            "run public client: client: failed to listen on 127.0.0.1:8808: bind: address already in use"))
    }

    func testProviderErrorIsNotNoPeer() {
        XCTAssertFalse(OlcrtcEngine.isNoPeerWaitError(
            "open engine session: auth provider rejected the request: get connection info: telemost api: status 404"))
    }

    // startErrorReason still maps a port-busy string to the localized OLC-1026
    // message regardless of which stage surfaced it (now WaitReady, not Start).
    func testStartErrorReasonMapsPortBusy() {
        let prev = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
        defer { SettingsStore.shared.language = prev }
        let mapped = OlcrtcEngine.startErrorReason(
            "listen tcp4 127.0.0.1:8808: bind: address already in use", port: 8808)
        XCTAssertEqual(mapped, L10n.errorPortBusy_fmt.formatted(8808))
    }

    func testStartErrorReasonPassesThroughOtherErrors() {
        let raw = "some unrelated go error"
        XCTAssertEqual(OlcrtcEngine.startErrorReason(raw, port: 8808), raw)
    }

    func testRejoinSettleCarrierAware() {
        XCTAssertEqual(OlcrtcEngine.rejoinSettleMs(carrier: "jitsi"), 3000)
        XCTAssertEqual(OlcrtcEngine.rejoinSettleMs(carrier: "TELEMOST"), 3000)
        XCTAssertEqual(OlcrtcEngine.rejoinSettleMs(carrier: "wbstream"), 1500)
    }

    // MARK: #445 (audit fix 7) — stop-timeout ghost classification

    // Start throwing master's ErrAlreadyRunning ("olcRTC runtime is already
    // active", mobile/runtime.go) means the PREVIOUS generation is still tearing
    // down — the engine retries once after a longer bounded stop, then surfaces
    // the friendly errorRuntimeStillStopping message instead of the raw text.
    func testAlreadyActiveMatchesMasterErrText() {
        XCTAssertTrue(OlcrtcEngine.isAlreadyActiveError("olcRTC runtime is already active"))
        XCTAssertTrue(OlcrtcEngine.isAlreadyActiveError("OLCRTC RUNTIME IS ALREADY ACTIVE"))
    }

    // Deliberately narrow: the bind race ("address already in use") contains
    // "already" too but has its own OLC-1026 mapping in startErrorReason — it
    // must NOT be treated as a still-stopping ghost.
    func testAlreadyActiveIgnoresOtherStartFailures() {
        XCTAssertFalse(OlcrtcEngine.isAlreadyActiveError(
            "listen tcp4 127.0.0.1:8808: bind: address already in use"))
        XCTAssertFalse(OlcrtcEngine.isAlreadyActiveError(
            "invalid config: key must be 64 hex characters"))
    }
}
