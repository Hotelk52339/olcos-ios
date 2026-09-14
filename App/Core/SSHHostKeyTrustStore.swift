import Foundation
import Darwin

/// A dial/rekey cannot outlive an explicit trust reset and relearn an old key.
struct SSHHostKeyTrustContext: Sendable {
    let endpoint: String
    fileprivate let generation: UUID
}

/// Public host-key digests only; SSH credentials remain in Keychain.
/// A transaction covers read, compare and atomic replacement. NSLock serializes
/// threads/instances; flock also serializes processes using this same file.
/// No in-memory trust cache and no MainActor/model-store callbacks on NIO.
final class SSHHostKeyTrustStore: @unchecked Sendable {
    static let statusDidChange = Notification.Name("SSHHostKeyTrustStore.statusDidChange")
    static let shared = SSHHostKeyTrustStore(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory,
                                         in: .userDomainMask)[0]
            .appendingPathComponent("SSHHostKeys", isDirectory: true)
            .appendingPathComponent("trust.json"),
        legacyPins: {
            // Migrate ALL saved explicit pins before any endpoint can use TOFU,
            // including a duplicate row with a different UUID and no pin.
            return try SavedListRecovery.load([ServerHost].self, key: "olcrtc_server_hosts")
                .compactMap(\.sshHostKeyPin)
        })

    private struct Entry: Codable, Equatable {
        var fingerprints: [String] = []
        var generation = UUID()
        // A durable explicit-reset marker prevents stale models/backups from
        // silently reinstating an old pin. It contains no secret material.
        var ignoresLegacy = false
    }

    private struct Document: Codable, Equatable {
        var version = 1
        var entries: [String: Entry] = [:]
    }

    private static let lock = NSLock()
    // UI recovery status only, never an input to acceptance. Guarded by lock,
    // keyed by store path so isolated tests cannot affect production status.
    private static var mismatchEndpoints: [String: Set<String>] = [:]
    private let fileURL: URL
    private let legacyPins: @Sendable () throws -> [SSHHostKeyPin]

    /// Injectable path/provider keep tests entirely outside real user storage.
    init(fileURL: URL, legacyPins: @escaping @Sendable () throws -> [SSHHostKeyPin] = { [] }) {
        self.fileURL = fileURL
        self.legacyPins = legacyPins
    }

    /// Called BEFORE choosing a relay/dial endpoint or sending authentication.
    /// Import an edited model's old pin under its old endpoint, never its new one.
    func prepare(host: String, port: Int, legacyPin: SSHHostKeyPin? = nil) throws -> SSHHostKeyTrustContext {
        guard let endpoint = SSHHostKeyVerification.endpoint(host: host, port: port) else {
            throw SSHHostKeyError.verificationRequired
        }
        return try transaction { document in
            var pins = try legacyPins()
            if let legacyPin { pins.append(legacyPin) }
            for pin in pins {
                var entry = document.entries[pin.endpoint] ?? Entry()
                guard !entry.ignoresLegacy else { continue }
                do { try SSHHostKeyVerification.validateLegacyPin(pin) }
                catch {
                    // Unrelated broken metadata must not produce a false
                    // changed-key warning for the endpoint being connected.
                    if pin.endpoint == endpoint || pin == legacyPin { throw error }
                    continue
                }
                if !entry.fingerprints.isEmpty {
                    // A legacy multi-algorithm set may retain its verified keys.
                    // Conflicting known identities never overwrite one another.
                    if Set(entry.fingerprints).isDisjoint(with: pin.fingerprints) {
                        setMismatchLocked(endpoint: pin.endpoint, present: true)
                        if pin.endpoint == endpoint { throw SSHHostKeyError.mismatch }
                        // Preserve existing unrelated trust, never replace it.
                        // Its conflict is terminal when THAT endpoint is dialed.
                        continue
                    }
                }
                entry.fingerprints = Set(entry.fingerprints + pin.fingerprints).sorted()
                document.entries[pin.endpoint] = entry
            }
            let entry = document.entries[endpoint] ?? Entry()
            document.entries[endpoint] = entry
            return SSHHostKeyTrustContext(endpoint: endpoint, generation: entry.generation)
        }
    }

    /// Commit first use before fulfilling NIOSSH's promise. Concurrent different
    /// keys cannot both win. Rekey/algorithm changes must match known trust too.
    func validate(presented: String, for context: SSHHostKeyTrustContext) throws {
        guard SSHHostKeyVerification.normalizedFingerprint(presented) == presented else {
            throw SSHHostKeyError.mismatch
        }
        try transaction { document in
            guard var entry = document.entries[context.endpoint],
                  entry.generation == context.generation else {
                throw SSHHostKeyError.mismatch
            }
            if entry.fingerprints.isEmpty {
                entry.fingerprints = [presented]
                document.entries[context.endpoint] = entry
            } else if !entry.fingerprints.contains(presented) {
                setMismatchLocked(endpoint: context.endpoint, present: true)
                throw SSHHostKeyError.mismatch
            }
        }
    }

    /// Status only: never expose fingerprint values to the UI. A storage error
    /// cannot produce a "trusted" status or permit validation.
    func hasTrust(host: String, port: Int) -> Bool {
        guard let endpoint = SSHHostKeyVerification.endpoint(host: host, port: port) else { return false }
        return (try? transaction { !($0.entries[endpoint]?.fingerprints.isEmpty ?? true) }) ?? false
    }

    /// Covers all SSH callers, including Logs/Bots/renewal. A stale generation
    /// rejection is NOT a changed-key observation and must not reopen recovery.
    func hasMismatch(host: String, port: Int) -> Bool {
        guard let endpoint = SSHHostKeyVerification.endpoint(host: host, port: port) else { return false }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Self.mismatchEndpoints[fileURL.standardizedFileURL.path]?.contains(endpoint) ?? false
    }

    /// Caller holds the transaction lock. Post asynchronously so observers
    /// never reenter the store while it is locked, and NIO never needs MainActor.
    private func setMismatchLocked(endpoint: String, present: Bool) {
        let path = fileURL.standardizedFileURL.path
        var endpoints = Self.mismatchEndpoints[path] ?? []
        let changed: Bool
        if present { changed = endpoints.insert(endpoint).inserted }
        else { changed = endpoints.remove(endpoint) != nil }
        guard changed else { return }
        Self.mismatchEndpoints[path] = endpoints
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
    }

    /// UI MUST obtain explicit confirmation first. Ordinary edits, removal,
    /// retry and mismatch handling must never call this. Endpoint-wide, not UUID.
    /// The next NEW dial learns automatically; existing dial contexts fail.
    func resetTrust(host: String, port: Int) throws {
        guard let endpoint = SSHHostKeyVerification.endpoint(host: host, port: port) else {
            throw SSHHostKeyError.verificationRequired
        }
        try transaction(onCommit: { self.setMismatchLocked(endpoint: endpoint, present: false) }) { document in
            var fresh = Entry()
            fresh.ignoresLegacy = true
            document.entries[endpoint] = fresh
        }
    }

    private func transaction<T>(onCommit: (() -> Void)? = nil,
                                _ body: (inout Document) throws -> T) throws -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let lockPath = fileURL.appendingPathExtension("lock").path
            let descriptor = lockPath.withCString { Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR) }
            guard descriptor >= 0 else { throw SSHHostKeyError.trustStoreUnavailable }
            defer { Darwin.close(descriptor) }
            // Never wait on another process from an NIO event-loop thread.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw SSHHostKeyError.trustStoreUnavailable
            }
            defer { flock(descriptor, LOCK_UN) }
            let original = try readDocument()
            var document = original
            let value = try body(&document)
            if document != original {
                let data = try JSONEncoder().encode(document)
                try data.write(to: fileURL, options: .atomic)
            }
            onCommit?()
            return value
        } catch let error as SSHHostKeyError {
            throw error
        } catch {
            // Never interpret damaged/inaccessible storage as a first connection.
            throw SSHHostKeyError.trustStoreUnavailable
        }
    }

    private func readDocument() throws -> Document {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Document()
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw SSHHostKeyError.trustStoreUnavailable }
        for (endpoint, entry) in document.entries {
            // Empty entries are preparation/reset markers, not trusted keys.
            guard SSHHostKeyVerification.isCanonicalEndpoint(endpoint),
                  entry.fingerprints.allSatisfy({
                      SSHHostKeyVerification.normalizedFingerprint($0) == $0
                  }) else { throw SSHHostKeyError.trustStoreUnavailable }
        }
        return document
    }
}
