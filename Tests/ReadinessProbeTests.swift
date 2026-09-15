import XCTest
@testable import olcrtc_ios

/// The readiness probe must never turn "podman ps failed" or "output cut
/// short" into "nothing installed": a running server used to flash
/// "Ready to install" with an empty protocol list until the next refresh.
final class ReadinessProbeTests: XCTestCase {
    private let container = "olcrtc-server-abc"

    private func output(container: String, rc: Int, end: Bool = true) -> String {
        var s = "PODMAN=yes\nIMAGE=yes\nCONTAINER=\(container)\nCONTAINER_RC=\(rc)\nDISK=3.3G/8.0G\nRAM=400M/1900M\nUPTIME=18:47\n"
        if end { s += "READINESS_END\n" }
        return s
    }

    func testRunningContainerIsRunning() throws {
        let state = try SSHRunner.parseReadiness(from: output(container: "Up 3 hours", rc: 0), containerName: container)
        guard case .containerRunning = state else { return XCTFail("\(state)") }
    }

    func testEmptyListWithExitZeroIsImageReady() throws {
        let state = try SSHRunner.parseReadiness(from: output(container: "", rc: 0), containerName: container)
        XCTAssertEqual(state, .imageReady)
    }

    func testPodmanFailureIsInconclusiveNotImageReady() {
        XCTAssertThrowsError(try SSHRunner.parseReadiness(from: output(container: "", rc: 125), containerName: container))
    }

    func testTruncatedOutputIsInconclusive() {
        XCTAssertThrowsError(try SSHRunner.parseReadiness(from: output(container: "", rc: 0, end: false), containerName: container))
        XCTAssertThrowsError(try SSHRunner.parseReadiness(from: "", containerName: container))
    }

    func testNoContainerOnRecordIsImageReady() throws {
        let state = try SSHRunner.parseReadiness(from: output(container: "", rc: 0), containerName: nil)
        XCTAssertEqual(state, .imageReady)
    }

    func testNoPodmanAndNoImageStillReported() throws {
        XCTAssertEqual(try SSHRunner.parseReadiness(from: "PODMAN=no\nIMAGE=no\nCONTAINER=\nCONTAINER_RC=0\nREADINESS_END\n", containerName: container), .noPodman)
        XCTAssertEqual(try SSHRunner.parseReadiness(from: "PODMAN=yes\nIMAGE=no\nCONTAINER=\nCONTAINER_RC=0\nREADINESS_END\n", containerName: container), .noImage)
    }

    func testScriptEmitsExitCodeAndSentinel() {
        let script = SSHRunner.readinessScript(containerName: container)
        XCTAssertTrue(script.contains("CONTAINER_RC="))
        XCTAssertTrue(script.contains("READINESS_END"))
        XCTAssertTrue(SSHRunner.readinessScript(containerName: nil).contains("READINESS_END"))
    }
}
