// boc #481: automatic first-use trust, bound to the original SSH endpoint.
import Foundation
import CryptoKit
import NIO
import NIOSSH

/// Legacy explicitly verified public metadata, retained for safe migration.
/// New trust is recorded by SSHHostKeyTrustStore, never entered in the editor.
struct SSHHostKeyPin: Codable, Hashable, Sendable {
    let endpoint: String
    let fingerprints: [String]
}

enum SSHHostKeyError: LocalizedError, Equatable, Sendable {
    case verificationRequired
    case mismatch
    case trustStoreUnavailable

    var errorDescription: String? {
        switch self {
        case .verificationRequired: return L10n.sshHostKeyVerificationRequired.localized()
        case .mismatch: return L10n.sshHostKeyMismatch.localized()
        case .trustStoreUnavailable: return L10n.sshHostKeyTrustStoreUnavailable.localized()
        }
    }
}

enum SSHHostKeyVerification {
    /// Uses the original VPS endpoint, NEVER a transient localhost relay port.
    /// DNS case/trailing dot and IPv6 bracket/compression aliases share a pin.
    /// No DNS lookup: a network answer must not redefine the trusted identity.
    static func endpoint(host: String, port: Int) -> String? {
        guard (1...65535).contains(port) else { return nil }
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let bracketed = name.hasPrefix("[") && name.hasSuffix("]")
        if bracketed {
            name = String(name.dropFirst().dropLast())
        }
        if let bytes = SSHSocks5.ipv6Bytes(name) {
            let groups = stride(from: 0, to: bytes.count, by: 2).map {
                String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16)
            }
            return "[\(groups.joined(separator: ":"))]:\(port)"
        }
        guard !bracketed else { return nil }  // Brackets denote IPv6, not DNS.
        if let bytes = SSHSocks5.ipv4Bytes(name) {
            return "\(bytes.map { String($0) }.joined(separator: ".")):\(port)"
        }
        name = name.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard !name.isEmpty, name.utf8.count <= 253,
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-"
              }) else { return nil }
        return "\(name):\(port)"
    }

    /// OpenSSH SHA256 uses unpadded Base64 of the 32-byte digest. Accept the
    /// equivalent single-padding spelling, but never arbitrary text/MD5.
    static func normalizedFingerprint(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("SHA256:") else { return nil }
        let payload = String(value.dropFirst(7))
        let unpadded = payload.hasSuffix("=") ? String(payload.dropLast()) : payload
        guard unpadded.count == 43,
              let bytes = Data(base64Encoded: unpadded + "="), bytes.count == 32,
              bytes.base64EncodedString() == unpadded + "=" else { return nil }
        return "SHA256:" + unpadded
    }

    /// Legacy pins are already canonical. Validate before migration, including
    /// their OWN endpoint when the model has since been edited.
    static func isCanonicalEndpoint(_ value: String) -> Bool {
        guard let separator = value.lastIndex(of: ":"),
              let port = Int(value[value.index(after: separator)...]) else { return false }
        return endpoint(host: String(value[..<separator]), port: port) == value
    }

    static func validateLegacyPin(_ pin: SSHHostKeyPin) throws {
        guard isCanonicalEndpoint(pin.endpoint), !pin.fingerprints.isEmpty,
              pin.fingerprints.allSatisfy({ normalizedFingerprint($0) == $0 }) else {
            throw SSHHostKeyError.verificationRequired
        }
    }

    /// Hash the SSH wire public-key blob, not its textual armor or only the
    /// curve bytes. NIOSSH's PUBLIC String initializer serializes the full blob.
    /// API checked at Wellz26/swift-nio-ssh 0.3.4, NIOSSHPublicKey.swift:605.
    static func fingerprint(of key: NIOSSHPublicKey) throws -> String {
        let fields = String(openSSHPublicKey: key).split(separator: " ")
        guard fields.count == 2, let blob = Data(base64Encoded: String(fields[1])) else {
            throw SSHHostKeyError.mismatch
        }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Citadel 0.12.1's real extension point is `.custom(delegate)` (ClientSession
/// lines 283–320). NIOSSH waits for this promise before completing key exchange.
/// No MainActor dependency: NIOSSH can invoke this on any event-loop thread.
/// The immutable context always identifies the original host and port.
final class SSHAutomaticHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let context: SSHHostKeyTrustContext
    let store: SSHHostKeyTrustStore
    private let lock = NSLock()
    private var recordedRejection: SSHHostKeyError?

    init(context: SSHHostKeyTrustContext, store: SSHHostKeyTrustStore) {
        self.context = context
        self.store = store
    }

    /// Citadel/channel shutdown may surface a transport error instead of the
    /// delegate error. Retain the precise reason BEFORE failing its promise.
    /// One validator per attempt keeps this latch independent of later dials.
    var rejection: SSHHostKeyError? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRejection
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let presented = try SSHHostKeyVerification.fingerprint(of: hostKey)
            try store.validate(presented: presented, for: context)
            validationCompletePromise.succeed(())
        } catch {
            let reason = error as? SSHHostKeyError ?? .trustStoreUnavailable
            lock.lock()
            if recordedRejection == nil { recordedRejection = reason }
            lock.unlock()
            validationCompletePromise.fail(reason)
        }
    }
}
// eoc #481
