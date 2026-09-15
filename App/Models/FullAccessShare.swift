import Foundation

// MARK: - FullAccessShare
//
// Wire format for the opt-in "full access" share — the co-admin variant that
// conveys BOTH the connection URI and the VPS SSH credentials so the recipient
// can MANAGE the server (install / reconfigure / reboot / uninstall), not
// merely connect through it.
//
// FORMAT
// ------
//   olcrtc://host/v1/<base64url(JSON)>
//
// JSON is this struct, Codable-encoded. Base64url (no padding) keeps the blob
// URL-safe for the system share sheet / clipboard. It reuses the registered
// `olcrtc://` scheme with a distinguishing `host/` authority+path, so a
// recipient's handler can tell it apart from a plain connection URI (which is
// `olcrtc://<carrier>?<transport>@…` — always a `?`, never a `/v1/` path). The
// `v1` segment mirrors `formatVersion` so a parser can reject an unknown
// version before decoding.
//
// The payload carries the connection `uri` PLUS the SSH host/port/username and
// ONE credential: `sshPassword` for password hosts, or `sshPrivateKey`
// (+ optional `sshKeyPassphrase`) for key hosts. The key fields are optional
// and absent from the JSON of a password host, so a v1 link produced before
// key hosts could be shared decodes unchanged, and an old reader that ignores
// unknown fields still gets a valid password payload.
//
// SECURITY
// --------
//   • Opt-in only, behind an explicit confirmation that names the secret the
//     link contains (password or the full private key).
//   • The credential is read live from the Keychain (ServerHostStore /
//     KeychainHelper) at share time — never persisted into UserDefaults.
//   • This blob MUST NOT be logged: callers log the *action*, never the payload.
//   • A private key is a bigger blast radius than a per-host password and is
//     often reused across hosts; the confirmation copy says so. A key payload
//     is also usually too large for a QR code — the share sheet offers Copy /
//     Share for it, not QR.

struct FullAccessShare: Codable, Equatable {
    /// Bumped if the JSON shape changes; also encoded in the URL authority so a
    /// parser can reject an unknown version before attempting to decode.
    var formatVersion: Int = 1

    /// The same `olcrtc://…` connection string the URI-only share produces —
    /// lets the recipient connect immediately, not just manage the VPS.
    var uri: String

    // SSH access to the VPS (ServerHost fields + ONE Keychain credential).
    var label: String
    var sshHost: String
    var sshPort: Int
    var sshUsername: String
    /// Password hosts: the password. Key hosts: "" (the key fields carry the secret).
    var sshPassword: String
    /// Key hosts only: the full OpenSSH private-key text. nil for password hosts.
    var sshPrivateKey: String? = nil
    /// Key hosts only: the passphrase of an encrypted key. nil when unencrypted.
    var sshKeyPassphrase: String? = nil

    /// True when the payload authenticates with a private key.
    var isKeyAuth: Bool { !(sshPrivateKey ?? "").isEmpty }

    /// The stored credential as the SSHSecret the recipient should save.
    var secret: SSHSecret {
        if let key = sshPrivateKey, !key.isEmpty {
            return .privateKey(text: key, passphrase: (sshKeyPassphrase?.isEmpty == false) ? sshKeyPassphrase : nil)
        }
        return .password(sshPassword)
    }

    // #366 was: scheme = "olcrtc-host". Reuse the registered `olcrtc://` scheme
    // with a `host/` authority so no new URL scheme must be registered; the
    // `host/` prefix is what distinguishes a full-access link from a plain
    // connection URI (`olcrtc://<carrier>?…`).
    static let scheme = "olcrtc"
    static let hostToken = "host"
    static let versionToken = "v1"

    /// The prefix that marks a full-access link: `olcrtc://host/`. A plain
    /// connection URI never starts with this (its authority is a carrier and is
    /// followed by `?`), so the importer uses it to route the link (#366).
    static var linkPrefix: String { "\(scheme)://\(hostToken)/" }

    /// True iff `raw` looks like a full-access link (vs a plain connection URI).
    static func isFullAccessLink(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(linkPrefix)
    }

    /// Encodes to `olcrtc://host/v1/<base64url(JSON)>`. Returns nil only if JSON
    /// encoding fails (it can't for these plain fields), so callers can treat a
    /// nil result as a programmer error rather than a user-facing one.
    func encoded() -> String? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        return "\(Self.linkPrefix)\(Self.versionToken)/\(Self.base64urlEncode(json))"
    }

    /// Parses an `olcrtc-host://v1/…` link back into a payload. Throws on a bad
    /// scheme, an unknown version, or undecodable JSON so an importer can show a
    /// precise reason instead of silently dropping a malformed link.
    enum ParseError: Error, Equatable {
        case invalidScheme
        case unsupportedVersion(String)
        case malformedPayload
    }

    static func parse(_ raw: String) throws -> FullAccessShare {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // #366: a full-access link is `olcrtc://host/v1/<blob>`; a plain
        // connection URI (`olcrtc://<carrier>?…`) lacks the `host/` prefix.
        guard s.hasPrefix(linkPrefix) else { throw ParseError.invalidScheme }
        let afterPrefix = String(s.dropFirst(linkPrefix.count))   // "v1/<blob>"
        guard let slash = afterPrefix.firstIndex(of: "/") else {
            throw ParseError.malformedPayload
        }
        let version = String(afterPrefix[afterPrefix.startIndex..<slash])
        guard version == versionToken else { throw ParseError.unsupportedVersion(version) }
        let blob = String(afterPrefix[afterPrefix.index(after: slash)...])
        guard let data = base64urlDecode(blob),
              let decoded = try? JSONDecoder().decode(FullAccessShare.self, from: data) else {
            throw ParseError.malformedPayload
        }
        return decoded
    }

    // MARK: base64url (no padding) — URL-safe so the blob survives share sheets.

    static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4 for the stdlib decoder.
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        return Data(base64Encoded: b64)
    }
}
