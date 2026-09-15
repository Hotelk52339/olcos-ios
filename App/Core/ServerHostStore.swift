import Foundation

// MARK: - ServerHostStore
//
// Saves the list of SSH-reachable VPS hosts. Non-secret fields go to
// UserDefaults as JSON; the password lives in iOS Keychain under a
// per-host UUID key. See KeychainHelper for the underlying primitives.

@MainActor
final class ServerHostStore: ObservableObject {
    @Published var hosts: [ServerHost] = [] {
        didSet { save() }
    }
    private var isLoading = false // #482: decoding is not an explicit edit.
    private let defaults: UserDefaults // #482: isolated persistence tests.

    // MARK: Resolved-secret cache (round 2, D)
    //
    // `secret(for:)` is what every SSH pass on the Servers tab resolves first,
    // and it was ALSO reached from the card's render path (ServersView
    // `menuItems` → `shareRequest` → `fullAccessPayload`), which meant one or
    // two synchronous `SecItemCopyMatching` calls per host per body
    // evaluation. The render path no longer asks for the secret at all; the
    // async paths still do, once per host per pass, so the resolved value is
    // kept HERE, in memory only, after the first successful read:
    //  • memory-only — never encoded, never logged, never in UserDefaults;
    //  • keyed by host id AND auth method, so a method switch is a miss;
    //  • only a HIT is cached — a miss (Keychain still locked right after a
    //    reboot, entry wiped) is re-asked next time, so nothing is ever
    //    remembered as "absent";
    //  • dropped on every write or removal below, and on `invalidateSecrets()`
    //    (once per foreground, from the tab that owns the store).
    private struct SecretCacheKey: Hashable {
        let id: UUID
        let method: SSHAuthMethod? // `ServerHost.authMethod` is optional (nil = legacy password host)
    }
    private var secretCache: [SecretCacheKey: SSHSecret] = [:]

    /// Forget every resolved credential; the next `secret(for:)` re-reads the
    /// Keychain. Called once per foreground so a credential changed by another
    /// process (or a Keychain that became readable after first unlock) is
    /// picked up without a per-render read.
    func invalidateSecrets() {
        secretCache.removeAll()
    }

    private func forgetSecret(for host: ServerHost) {
        secretCache = secretCache.filter { $0.key.id != host.id }
    }

    private let storeKey = "olcrtc_server_hosts"
    private static let keychainService = "olcrtc.serverhost.password"
    // #451: SSH private-key auth. Same per-host account key (id.uuidString) as
    // the password; separate services so a host can hold both (e.g. after
    // switching methods) without clobbering. `nonisolated` — immutable names,
    // read by the nonisolated `resolveSecret` bridge below.
    nonisolated private static let privateKeyService    = "olcrtc.serverhost.privatekey"
    nonisolated private static let keyPassphraseService = "olcrtc.serverhost.keypassphrase"

    // #482 was: init() { load() }, always touching real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Legacy password-only add — kept verbatim for pre-#451 call sites
    /// (the full-access import in App.swift). Adds a password-auth host.
    func add(_ host: ServerHost, password: String) {
        add(host, secret: .password(password))
    }

    /// #451: adds a host with either credential kind.
    func add(_ host: ServerHost, secret: SSHSecret) {
        hosts.append(host)
        writeSecret(secret, for: host)
        LogStore.shared.log(.provisioning,
            "+ added VPS: \(host.label) [\(host.username)@\(host.host):\(host.port)]" +
            (host.authMethod == .privateKey ? " (SSH key)" : ""))
    }

    /// Legacy update — `password` nil/empty leaves the stored credentials
    /// untouched (the "(password changed)" contract every pre-#451 caller
    /// relies on). #451: a NON-empty password through this API also flips a
    /// key-auth host back to password auth — the only such caller is the
    /// full-access re-import (App.swift), where the link explicitly carries a
    /// password the sender intends to be used.
    func update(_ host: ServerHost, password: String?) {
        var h = host
        if let pw = password, !pw.isEmpty, h.authMethod == .privateKey {
            h.authMethod = .password
        }
        if let i = hosts.firstIndex(where: { $0.id == h.id }) {
            hosts[i] = h
            LogStore.shared.log(.provisioning,
                "✎ updated VPS: \(h.label) [\(h.username)@\(h.host):\(h.port)]" +
                ((password ?? "").isEmpty ? "" : " (password changed)"))
        }
        if let pw = password, !pw.isEmpty {
            forgetSecret(for: host)
            KeychainHelper.set(pw, service: Self.keychainService, account: host.id.uuidString)
        }
    }

    /// #451: update with either credential kind; `secret` nil leaves the
    /// stored credentials untouched.
    func update(_ host: ServerHost, secret: SSHSecret?) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
            LogStore.shared.log(.provisioning,
                "✎ updated VPS: \(host.label) [\(host.username)@\(host.host):\(host.port)]" +
                (secret == nil ? "" : " (credentials changed)"))
        }
        if let secret { writeSecret(secret, for: host) }
    }

    private func writeSecret(_ secret: SSHSecret, for host: ServerHost) {
        forgetSecret(for: host)
        let account = host.id.uuidString
        switch secret {
        case .password(let pw):
            KeychainHelper.set(pw, service: Self.keychainService, account: account)
        case .privateKey(let text, let passphrase):
            KeychainHelper.set(text, service: Self.privateKeyService, account: account)
            if let pp = passphrase, !pp.isEmpty {
                KeychainHelper.set(pp, service: Self.keyPassphraseService, account: account)
            } else {
                // Unencrypted key — make sure no stale passphrase survives a
                // key swap (a wrong passphrase would fail the decrypt).
                KeychainHelper.delete(service: Self.keyPassphraseService, account: account)
            }
        }
    }

    func remove(at idx: IndexSet) {
        let removed = idx.compactMap { hosts.indices.contains($0) ? hosts[$0] : nil }
        for h in removed {
            forgetSecret(for: h)
            // #451: sweep every credential service, whatever authMethod says —
            // a method switch may have left entries under the other services.
            KeychainHelper.delete(service: Self.keychainService,     account: h.id.uuidString)
            KeychainHelper.delete(service: Self.privateKeyService,   account: h.id.uuidString)
            KeychainHelper.delete(service: Self.keyPassphraseService, account: h.id.uuidString)
        }
        hosts.remove(atOffsets: idx)
        for h in removed {
            LogStore.shared.log(.provisioning, "− removed VPS: \(h.label) [\(h.host)]")
        }
    }

    /// The host's stored credential MATERIAL — the password for password
    /// hosts, and (#451) the private-key TEXT for key hosts. The key-host
    /// case exists so legacy `guard let pw = password(for:)` call sites that
    /// cannot be updated in lock-step (LogsView's container-log fetch) still
    /// see a non-nil credential; those sites hand the string to Provisioner's
    /// `password:`-labelled compatibility overloads, which re-resolve the full
    /// SSHSecret (key + passphrase) via `resolveSecret(for:credential:)`.
    /// Sites that need strictly the password (edit-sheet prefill, full-access
    /// share) must gate on `host.authMethod` first.
    func password(for host: ServerHost) -> String? {
        if host.authMethod == .privateKey {
            return KeychainHelper.get(service: Self.privateKeyService, account: host.id.uuidString)
        }
        return KeychainHelper.get(service: Self.keychainService, account: host.id.uuidString)
    }

    /// #451: the stored private-key text for a host (any auth method) — used
    /// by the edit sheet to prefill the key editor. nil when never stored.
    func privateKey(for host: ServerHost) -> String? {
        KeychainHelper.get(service: Self.privateKeyService, account: host.id.uuidString)
    }

    /// #451: the stored key passphrase, nil for unencrypted keys.
    func keyPassphrase(for host: ServerHost) -> String? {
        KeychainHelper.get(service: Self.keyPassphraseService, account: host.id.uuidString)
    }

    /// #451: the host's full SSHSecret, resolved per `authMethod`. nil when
    /// the Keychain has no entry (never saved / wiped) — callers surface the
    /// method-appropriate "credential missing" message.
    /// Served from the in-memory cache after the first successful read (see
    /// the cache notes at the top of the class); a miss is never cached.
    func secret(for host: ServerHost) -> SSHSecret? {
        let key = SecretCacheKey(id: host.id, method: host.authMethod)
        if let cached = secretCache[key] { return cached }
        guard let resolved = readSecret(for: host) else { return nil }
        secretCache[key] = resolved
        return resolved
    }

    /// The uncached Keychain read behind `secret(for:)`.
    private func readSecret(for host: ServerHost) -> SSHSecret? {
        if host.authMethod == .privateKey {
            guard let key = KeychainHelper.get(service: Self.privateKeyService,
                                               account: host.id.uuidString) else { return nil }
            return .privateKey(text: key,
                               passphrase: KeychainHelper.get(service: Self.keyPassphraseService,
                                                              account: host.id.uuidString))
        }
        guard let pw = KeychainHelper.get(service: Self.keychainService,
                                          account: host.id.uuidString) else { return nil }
        return .password(pw)
    }

    /// #451: bridge for the String-credential compatibility overloads on
    /// Provisioner (see `password(for:)` above): `credential` is whatever
    /// `password(for:)` returned — the password for password hosts, the key
    /// text for key hosts (the passphrase is re-read from the Keychain).
    /// nonisolated + static so the @MainActor Provisioner can call it without
    /// holding a store reference.
    nonisolated static func resolveSecret(for host: ServerHost, credential: String) -> SSHSecret {
        guard host.authMethod == .privateKey else { return .password(credential) }
        return .privateKey(text: credential,
                           passphrase: KeychainHelper.get(service: keyPassphraseService,
                                                          account: host.id.uuidString))
    }

    // MARK: Full-access import (#384)

    /// How a full-access-imported host folds into the current list.
    enum ImportOutcome: Equatable {
        case addNew(ServerHost)          // new VPS — label disambiguated if it clashed
        case updateExisting(ServerHost)  // same SSH coordinates → refresh in place (dedup)
    }

    /// #384: decide how a full-access-imported `candidate` folds into `hosts`,
    /// applying the same rules `AddServerHostView` enforces but WITHOUT mutating
    /// the store or Keychain — pure, so it's unit-testable. The caller applies
    /// the outcome (`add` / `update`).
    ///
    /// • Dedup — a host with the SAME SSH coordinates (host/port/username) is the
    ///   same VPS re-imported, so refresh it in place (the caller re-writes the
    ///   password) instead of adding a 2nd card + Keychain entry. The existing
    ///   label is kept (renaming on re-import could itself create a clash).
    /// • #323 — otherwise, if the label (or its sanitised `logFilePrefix`) clashes
    ///   with a *different* host, append " (n)" until both are unique, so the two
    ///   hosts never share a `<prefix>_container.log`.
    nonisolated static func resolveImport(_ candidate: ServerHost,
                                          into hosts: [ServerHost]) -> ImportOutcome {
        if let existing = hosts.first(where: { sameCoordinates($0, candidate) }) {
            return .updateExisting(existing)
        }
        guard labelCollides(candidate.label, with: hosts) else { return .addNew(candidate) }
        var disambiguated = candidate
        var n = 2
        while labelCollides("\(candidate.label) (\(n))", with: hosts) { n += 1 }
        disambiguated.label = "\(candidate.label) (\(n))"
        return .addNew(disambiguated)
    }

    /// Two hosts are the same VPS iff host (case-insensitive), port and username
    /// match — the SSH coordinates a full-access link carries.
    nonisolated private static func sameCoordinates(_ a: ServerHost, _ b: ServerHost) -> Bool {
        a.host.lowercased() == b.host.lowercased()
            && a.port == b.port
            && a.username == b.username
    }

    /// Mirrors `AddServerHostView.isDuplicateLabel`: a label clashes if it equals
    /// another host's label case-insensitively OR sanitises to the same
    /// `logFilePrefix` (the shared-container-log case #323 guards against).
    nonisolated private static func labelCollides(_ label: String, with hosts: [ServerHost]) -> Bool {
        let lowered = label.lowercased()
        let prefix = ServerHost.sanitizeLogFilePrefix(label).lowercased()
        return hosts.contains {
            $0.label.lowercased() == lowered
                || ServerHost.sanitizeLogFilePrefix($0.label).lowercased() == prefix
        }
    }

    // MARK: Persistence

    private func save() {
        guard !isLoading else { return } // #482: preserve the exact loaded bytes.
        if let data = try? JSONEncoder().encode(hosts) {
            // #482 was: set(data, forKey: storeKey), bypassing recovery protection.
            SavedListRecovery.save(data, as: [ServerHost].self, key: storeKey, defaults: defaults) // #482
        }
    }
    // #482 was: backupKey = "olcrtc_server_hosts.unreadable", a write-only
    // parking place. SavedListRecovery now reads and protects it.

    // #470 was: `if let data = …, let list = try? JSONDecoder().decode(…) { hosts = list }`
    private func load() {
        // boc #482: hosts had the same parked-but-never-read backup defect.
        isLoading = true
        defer { isLoading = false }
        do {
            hosts = try SavedListRecovery.load([ServerHost].self, key: storeKey, defaults: defaults) // #482
        } catch {
            // #482 was: park once without ever attempting recovery.
            LogStore.shared.log(.provisioning,
                "⚠ ServerHostStore: saved VPS list could not be read; original bytes retained for recovery: \(error.localizedDescription)")
        }
        // eoc #482
    }
}
