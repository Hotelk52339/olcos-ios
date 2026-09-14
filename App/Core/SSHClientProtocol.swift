import Foundation
@preconcurrency import Citadel

// MARK: - SSHSecret (#451)
//
// The SSH credential for a ServerHost — a password (the historical default)
// or an OpenSSH private key pasted by the user. Threaded through
// SSHRunner.connect / Provisioner so every VPS operation works with either.
//
// Key material handling mirrors the password: it lives ONLY in the Keychain
// (ServerHostStore services `olcrtc.serverhost.privatekey` /
// `olcrtc.serverhost.keypassphrase`) and in transient call arguments — never
// in UserDefaults, never in logs, never in a share payload (full-access
// sharing is disabled for key hosts — see ServersView.fullAccessRequest).

enum SSHSecret: Sendable, Equatable {
    case password(String)
    /// `text` is the full OpenSSH private-key file contents
    /// ("-----BEGIN OPENSSH PRIVATE KEY-----…"). `passphrase` decrypts an
    /// encrypted key; nil/empty for unencrypted keys.
    case privateKey(text: String, passphrase: String?)
}

// MARK: - SSHKeyAnalyzer (#451)
//
// Pure, dependency-free classification of a pasted private key. Used by
// AddServerHostView for immediate validation (detect type, reject ECDSA,
// reveal the passphrase field for encrypted keys) and by
// SSHRunner.authenticationMethod to pick the Citadel parser.
//
// Why our own detector instead of Citadel's SSHKeyDetection? (a) it keeps the
// UI validation logic unit-testable with synthetic fixtures and independent of
// which Citadel 0.x CI resolves; (b) Citadel ships a type of that exact name,
// so a same-named app type would collide in files importing Citadel.
//
// The openssh-key-v1 container stores cipher/kdf names and the PUBLIC key blob
// (whose first field is the key-type string) unencrypted — so type + encrypted
// detection works on passphrase-protected keys too, without the passphrase.

enum SSHKeyAnalyzer {

    enum Detection: Equatable, Sendable {
        case ed25519(encrypted: Bool)
        case rsa(encrypted: Bool)
        /// Citadel has no ECDSA private-key text parser — reject with guidance.
        case ecdsa
        /// A recognisable private key Citadel cannot parse: legacy PEM
        /// (PKCS#1/PKCS#8/SEC1), DSA, PuTTY .ppk, FIDO `sk-` keys.
        case unsupportedFormat
        /// Doesn't look like a private key at all (e.g. a `.pub` line, garbage,
        /// or a corrupt/truncated paste).
        case notAKey

        /// True for the two key kinds SSHRunner can actually authenticate with.
        var isSupported: Bool {
            switch self {
            case .ed25519, .rsa:                        return true
            case .ecdsa, .unsupportedFormat, .notAKey:  return false
            }
        }

        /// True when the key material is passphrase-protected.
        var isEncrypted: Bool {
            switch self {
            case .ed25519(let enc), .rsa(let enc): return enc
            default:                               return false
            }
        }
    }

    static let openSSHHeader = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let openSSHFooter = "-----END OPENSSH PRIVATE KEY-----"

    static func detect(_ text: String) -> Detection {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .notAKey }
        if t.contains("PuTTY-User-Key-File") { return .unsupportedFormat }
        guard let headerRange = t.range(of: openSSHHeader) else {
            // Non-OpenSSH armors. Citadel's parsers accept ONLY the OpenSSH
            // format, so even a PEM RSA key must be converted first
            // (`ssh-keygen -p -o -f <keyfile>` re-saves in OpenSSH format).
            if t.contains("BEGIN EC PRIVATE KEY") { return .ecdsa }          // SEC1 PEM — ECDSA by definition
            if t.contains("PRIVATE KEY-----")     { return .unsupportedFormat } // PKCS#1 / PKCS#8 / DSA / encrypted PKCS#8
            return .notAKey
        }
        let afterHeader = t[headerRange.upperBound...]
        // Tolerate a truncated/missing footer — the base64 decode below decides.
        let body = afterHeader.range(of: openSSHFooter).map { afterHeader[..<$0.lowerBound] } ?? afterHeader
        let b64 = body.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let blob = Data(base64Encoded: b64) else { return .notAKey }
        return classify(blob: Data(blob))   // re-wrap so indices start at 0
    }

    /// openssh-key-v1 binary layout (all outside the encrypted section):
    ///   "openssh-key-v1\0" magic · string cipher · string kdf ·
    ///   string kdfoptions · uint32 numkeys · string publickey-blob
    /// and the publickey blob's first field is the key-type string
    /// ("ssh-ed25519" / "ssh-rsa" / "ecdsa-sha2-nistp256" / …).
    private static func classify(blob: Data) -> Detection {
        let magic = Data("openssh-key-v1\0".utf8)
        guard blob.count > magic.count, blob.prefix(magic.count) == magic else { return .notAKey }
        var offset = magic.count

        func readUInt32() -> Int? {
            guard offset + 4 <= blob.count else { return nil }
            let v = (UInt32(blob[offset])     << 24) | (UInt32(blob[offset + 1]) << 16) |
                    (UInt32(blob[offset + 2]) <<  8) |  UInt32(blob[offset + 3])
            offset += 4
            return Int(v)
        }
        func readString() -> Data? {
            guard let len = readUInt32(), len >= 0, offset + len <= blob.count else { return nil }
            defer { offset += len }
            return blob.subdata(in: offset ..< offset + len)
        }

        guard let cipherData = readString(),
              readString() != nil,          // kdf name ("none" | "bcrypt")
              readString() != nil,          // kdf options
              readUInt32() != nil,          // number of keys (1 for ssh-keygen output)
              let pubBlob = readString(),   // subdata → fresh 0-based indices
              !pubBlob.isEmpty
        else { return .notAKey }

        // First field of the public-key blob is its key-type string.
        guard pubBlob.count >= 4 else { return .notAKey }
        let typeLen = (Int(pubBlob[0]) << 24) | (Int(pubBlob[1]) << 16) | (Int(pubBlob[2]) << 8) | Int(pubBlob[3])
        guard typeLen > 0, 4 + typeLen <= pubBlob.count else { return .notAKey }
        let keyType = String(decoding: pubBlob.subdata(in: 4 ..< 4 + typeLen), as: UTF8.self)

        let encrypted = String(decoding: cipherData, as: UTF8.self) != "none"
        switch keyType {
        case "ssh-ed25519":                       return .ed25519(encrypted: encrypted)
        case "ssh-rsa":                           return .rsa(encrypted: encrypted)
        case let t where t.hasPrefix("ecdsa-"):   return .ecdsa
        default:                                  return .unsupportedFormat   // ssh-dss, sk-* FIDO keys, …
        }
    }
}

// MARK: - SSHClientProtocol
//
// Single-method SSH abstraction injected into pollLoop() so the poll logic
// can be tested without a live Citadel connection.
//
// Each call to execute(command:) is intentionally a complete round-trip
// (connect → run → disconnect), matching what _withConnection() does in
// production. Tests substitute a MockSSHClient that returns canned responses.

protocol SSHClientProtocol: Sendable {
    /// Runs a shell command and returns its combined stdout+stderr output.
    /// Throws on connection failure or non-zero exit, matching SSHRunner.execute() semantics.
    func execute(command: String) async throws -> String
}

// MARK: - CitadelSSHClient

/// Production adapter: wraps SSHRunner._withConnection + _execute into the protocol.
/// Kept internal so tests can see it but callers outside the module use the protocol.
/// #451 was: `let password: String` — now carries the full SSHSecret so the
/// install poll loop works over key auth too.
struct CitadelSSHClient: SSHClientProtocol {
    let host: ServerHost
    let secret: SSHSecret

    func execute(command: String) async throws -> String {
        try await SSHRunner._withConnection(host: host, secret: secret) { client in
            try await SSHRunner._execute(client: client, label: "pollLoop", command: command)
        }
    }
}
