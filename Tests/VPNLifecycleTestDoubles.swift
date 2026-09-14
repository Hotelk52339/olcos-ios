import Foundation
import XCTest
@testable import olcrtc_ios

// boc #483: no NetworkExtension calls, Go runtime, HTTP probes, path monitor,
// background audio or sockets. Each test owns and drains its suspended work.
final class LifecycleEngine: TunnelEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Void, Error>?
    private var running = false
    private var starts = 0
    private var stops = 0
    private var rooms: [String] = []
    var stopBarrier: DispatchSemaphore?

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var startedRooms: [String] { lock.withLock { rooms } }

    func start(_ details: ConnectionDetails, port: Int, settings: EngineStartSettings) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                starts += 1
                if case .olcrtc(let p) = details { rooms.append(p.roomID) }
                running = true
                pending = continuation
            }
        }
    }

    func completeStart(error: Error? = nil) {
        let continuation = lock.withLock {
            let value = pending
            pending = nil
            return value
        }
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }

    func stop() {
        lock.withLock { stops += 1 }
        stopBarrier?.wait()
        lock.withLock { running = false }
        completeStart(error: CancellationError())
    }

    func isRunning() -> Bool { lock.withLock { running } }
    func validate(_ details: ConnectionDetails) -> String? {
        guard case .olcrtc(let p) = details else { return nil }
        return TunnelManager.validate(params: p)
    }
    func ping(_ details: ConnectionDetails, settings: EngineProbeSettings) async -> PingOutcome {
        fatalError("#483: lifecycle tests must never probe")
    }
    func checkReady(_ details: ConnectionDetails, settings: EngineProbeSettings) async -> PingOutcome {
        fatalError("#483: lifecycle tests must never probe")
    }
}

@MainActor
final class LifecycleProfile: VPNProfile {
    var providerIdentifier: String? = VPNController.providerBundleIdentifier
    var status: VPNController.Status = .disconnected
    var configuration: [String: Any] = [:]
    var startCount = 0
    var stopCount = 0
    var saveCount = 0
    var reloadCount = 0
    var configuredRooms: [String] = []
    var onSave: (() async throws -> Void)?
    var onReload: (() async throws -> Void)?
    var onError: (() async -> String?)?
    var startError: Error?
    var startStatus: VPNController.Status = .connecting
    var stopImmediately = true
    private var changed: (@MainActor () -> Void)?

    func configure(_ config: VPNConfig) {
        configuredRooms.append(config.roomID)
        configuration = config.providerConfiguration()
    }
    func save() async throws {
        saveCount += 1
        try await onSave?()
    }
    func reload() async throws {
        reloadCount += 1
        try await onReload?()
    }
    func start() throws {
        startCount += 1
        if let startError { throw startError }
        emit(startStatus)
    }
    func stop() {
        stopCount += 1
        emit(stopImmediately ? .disconnected : .disconnecting)
    }
    func emit(_ value: VPNController.Status) {
        status = value
        changed?()
    }
    func observe(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }
    func disconnectError() async -> String? { await onError?() }
    func message(_ data: Data) async -> Data? { nil }
}

@MainActor
final class LifecycleGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
func lifecycleEventually(_ predicate: @escaping @MainActor () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<1_000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Lifecycle event did not arrive", file: file, line: line)
}
// eoc #483
