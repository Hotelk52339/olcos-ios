import SwiftUI

// boc #490
// #490 was: default Form headers and surfaces. Signal uses shared sentence-case
// section headers, readable native rows and consistent sage action chrome.
// All fields, bindings, validation, secrets and submit/lifecycle methods remain.
// eoc #490

// MARK: - AddServerHostView
//
// Sheet for creating/editing a ServerHost. Credentials are loaded from
// Keychain on open (edit mode) and saved there on submit. We pre-fill port 22
// and username root since that's the Timeweb default.
//
// #451: SSH auth is either a password (the default, unchanged) or an OpenSSH
// private key. The segmented picker swaps the password SecureField for a
// monospaced paste field + paste-from-clipboard button; the pasted key is
// validated immediately (SSHKeyAnalyzer) — ed25519/RSA accepted, ECDSA and
// non-OpenSSH formats rejected with guidance, and an encrypted key reveals
// the passphrase field. onSave now hands back an SSHSecret instead of a
// password string.

struct AddServerHostView: View {
    var existing: ServerHost? = nil
    var existingPassword: String? = nil          // pre-fill on edit; nil for add-new flow
    /// Edit mode: the stored key + passphrase. The key TEXT is never shown or
    /// placed in an editable field — it is only classified (type / encrypted)
    /// and re-saved unchanged unless the user replaces it.
    var existingKey: String? = nil
    var existingPassphrase: String? = nil
    // #295: every other host's label, for uniqueness validation. The label
    // (sanitised via `ServerHost.logFilePrefix`) prefixes the per-server
    // container-log file, so two hosts must not collapse to the same prefix.
    var otherLabels: [String] = []
    // #451 was: (ServerHost, String) — password only.
    var onSave: (ServerHost, SSHSecret) -> Void   // (host, credential)

    @Environment(\.dismiss) private var dismiss

    @State private var label    = ""
    @State private var host     = ""
    @State private var port     = "22"
    @State private var username = "root"
    @State private var password = ""
    // #451: key-auth state.
    @State private var authMethod: SSHAuthMethod = .password
    @State private var privateKey = ""
    @State private var keyPassphrase = ""
    @State private var keyDetection: SSHKeyAnalyzer.Detection? = nil
    /// Edit mode: the Keychain key is kept as-is; the editor is hidden until
    /// "Replace key" is tapped.
    @State private var storedKeyKept = false

    @FocusState private var portFocused: Bool

    @State private var isTesting: Bool = false
    @State private var testResult: String? = nil
    @State private var testTask: Task<Void, Never>? = nil

    // #295: case-insensitive duplicate check on the raw label AND on the
    // sanitised log-file prefix — two visually distinct labels (e.g. "TW
    // Moscow #1" vs "TW Moscow-1") could still collapse to the same prefix.
    private var isDuplicateLabel: Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        let prefix = ServerHost.sanitizeLogFilePrefix(trimmed).lowercased()
        return otherLabels.contains { other in
            other.lowercased() == lowered
                || ServerHost.sanitizeLogFilePrefix(other).lowercased() == prefix
        }
    }

    /// #451: the pasted key is usable — a supported type, and if encrypted the
    /// passphrase has been entered (an encrypted key without one would only
    /// fail later at connect time).
    private var keyOK: Bool {
        if storedKeyKept { return true }
        guard let d = keyDetection, d.isSupported else { return false }
        return !d.isEncrypted || !keyPassphrase.isEmpty
    }

    private var credentialOK: Bool {
        authMethod == .privateKey ? keyOK : !password.isEmpty
    }

    /// #469: a port outside 1…65535 passed `isValid` (`Int(port) != nil`), was
    /// stored as typed, and crashed the Servers tab in `UInt16(host.port)` on the
    /// very next auto-ping — on every launch, until the host was deleted.
    static func validPort(_ text: String) -> Int? {
        guard let p = Int(text.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(p) else { return nil }
        return p
    }

    // boc #470: whitespace never reaches a stored host. `isValid` accepted a
    // label of spaces and a host pasted as "1.2.3.4 " from a chat (the duplicate
    // check trimmed, the validity check did not), and `save()` stored both
    // verbatim — every later op then failed to resolve a correct address, and a
    // blank label produced a nameless card and records named " · Telemost".
    private var trimmedLabel: String    { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHost: String     { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isValid: Bool {
        // #470 was: !label.isEmpty && !host.isEmpty … && !username.isEmpty
        !trimmedLabel.isEmpty && !trimmedHost.isEmpty && Self.validPort(port) != nil   // #469
            && !trimmedUsername.isEmpty && credentialOK && !isDuplicateLabel
    }

    /// #470: the test below is a TCP probe of host:port — it needs no
    /// credentials, and gating it on them read as "my password works".
    /// #470 was: !host.isEmpty && Self.validPort(port) != nil && !username.isEmpty && credentialOK
    private var canTest: Bool {
        !trimmedHost.isEmpty && Self.validPort(port) != nil   // #469
    }
    // eoc #470

    var body: some View {
        NavigationStack {
            Form {
                descriptionSection // #490: small independent form expression.
                sshSection
                testSection // #490: preserves the original TCP task closure.
            }
            .signalFormChrome() // #490 was: default grouped-form chrome.
            .navigationTitle(existing == nil
                             ? L10n.newServerTitle.localized()
                             : L10n.editServerTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            // #262: keep the numeric-field keyboard toolbar; ✕ close + footer
            // come from the shared `.olcSheet` chrome below.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.actionDone.localized()) { portFocused = false }
                }
            }
            .olcSheet(confirm: L10n.save.localized(), disabled: !isValid) { save() }
            .onAppear { prefill() }
            .onDisappear {
                testTask?.cancel()
                testTask = nil
            }
        }
    }

    // boc #490
    // #490 was: description and TCP test controls were nested inside body.
    private var descriptionSection: some View {
        Section {
            FormField(label: L10n.nameField.localized(), placeholder: "TW Moscow", text: $label)
            // #295: server names must be unique — they prefix the
            // per-server container-log file (`<name>_container.log`).
            if isDuplicateLabel {
                Text(L10n.duplicateServerNameError.localized())
                    .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption)
                    .foregroundStyle(Theme.Palette.red) // #317 was: .foregroundStyle(.red) — status colors via Theme.Palette (#258 invariant)
            }
        } header: {
            SignalSectionHeader(L10n.sectionDescription.localized())
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }

    @ViewBuilder private var testSection: some View {
        if canTest {
            Section {
                VStack(spacing: Theme.Metrics.s2) {   // #471: B9 — 6 → s2
                    Button {
                        testResult = nil
                        isTesting = true
                        testTask = Task { await testSSH() }
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            // #470 was: Text(L10n.testSSHAction.localized()) — "Test SSH"
                            // over a bare TCP connect: a wrong password still
                            // earned a green "Reachable". It is the same TCP ping
                            // the VPS card runs, so it is named like it.
                            Text(L10n.vpsStatPing.localized())
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isTesting)
                    if let result = testResult {
                        Text(result)
                            .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption)
                            // #317 was: result.hasPrefix("✓") ? .green : .red
                            .foregroundStyle(result.hasPrefix("✓") ? Theme.Palette.green : Theme.Palette.red)
                    }
                }
            }
            .signalFormRows() // #490: retain native rows on Signal surfaces.
        }
    }
    // eoc #490

    // MARK: SSH access section (#451: password OR private key)

    private var sshSection: some View {
        Section {
            FormField(label: L10n.hostField.localized(),  placeholder: "1.2.3.4", text: $host)
            FormField(label: L10n.portField.localized(),  placeholder: "22",      text: $port, keyboard: .numberPad, focusBinding: $portFocused)
            FormField(label: L10n.loginField.localized(), placeholder: "root",    text: $username)
            Picker(L10n.authMethodPickerLabel.localized(), selection: $authMethod) {
                Text(L10n.authMethodPassword.localized()).tag(SSHAuthMethod.password)
                Text(L10n.authMethodKey.localized()).tag(SSHAuthMethod.privateKey)
            }
            .pickerStyle(.segmented)
            if authMethod == .password {
                FormField(label: L10n.passwordField.localized(), placeholder: "•••", text: $password, secure: true)
            } else {
                keyEditor
            }
        } header: {
            SignalSectionHeader(L10n.sshAccessHeader.localized())
        } footer: {
            if authMethod == .privateKey {
                // #471: B9 — a Form footer is already a caption; `.caption2` only
                // pushed it below the scale. was: .font(.caption2)
                Text(L10n.sshKeyFooter.localized())
            }
        }
        .signalFormRows() // #490: retain native rows on Signal surfaces.
    }

    @ViewBuilder
    private var keyEditor: some View {
        if storedKeyKept {
            storedKeyRow
        } else {
            // Paste target for the OpenSSH key file contents. TextEditor (not
            // SecureField): the armor is multi-line, and seeing the BEGIN/END
            // lines is how users verify they pasted the right thing. It is
            // only ever filled by the user — never prefilled from the Keychain.
            TextEditor(text: $privateKey)
                .font(Theme.Typography.mono)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: Theme.Metrics.s8 * 3)
                .accessibilityLabel(L10n.authMethodKey.localized())
                .onChange(of: privateKey) { _, newValue in
                    revalidateKey(newValue)
                }
            Button {
                if let s = UIPasteboard.general.string {
                    privateKey = s   // onChange revalidates
                }
            } label: {
                Label(L10n.sshKeyPasteButton.localized(), systemImage: "doc.on.clipboard")
            }
            if let status = keyStatus {
                Text(status.text)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(status.ok ? Theme.Palette.textSecondary : Theme.Palette.red)
            }
            // Passphrase — revealed only when the pasted key is encrypted.
            if keyDetection?.isEncrypted == true {
                FormField(label: L10n.sshKeyPassphraseField.localized(), placeholder: "•••",
                          text: $keyPassphrase, secure: true)
            }
        }
    }

    /// Edit mode: "ed25519 key stored in Keychain" + Replace. The stored text
    /// stays in the Keychain; only its type is shown.
    private var storedKeyRow: some View {
        HStack(alignment: .center, spacing: Theme.Metrics.s3) {
            Image(systemName: "key.fill")
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityHidden(true)
            Text(L10n.sshKeyStored_fmt.formatted(Self.keyTypeName(keyDetection)))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Metrics.s2)
            Button(L10n.sshKeyReplaceAction.localized()) {
                storedKeyKept = false
                privateKey = ""
                keyPassphrase = ""
                keyDetection = nil
            }
            .font(Theme.Typography.label)
        }
        .frame(minHeight: Theme.Metrics.controlHeight)
    }

    /// Display name of a stored key's type ("ed25519" / "RSA" / "SSH").
    static func keyTypeName(_ detection: SSHKeyAnalyzer.Detection?) -> String {
        switch detection {
        case .ed25519: return "ed25519"
        case .rsa:     return "RSA"
        default:       return "SSH"
        }
    }

    /// #451: immediate validation feedback under the key editor.
    private var keyStatus: (text: String, ok: Bool)? {
        guard let d = keyDetection else { return nil }
        switch d {
        case .ed25519(let enc):
            return (enc ? L10n.sshKeyDetectedEncrypted_fmt.formatted("ed25519")
                        : L10n.sshKeyDetected_fmt.formatted("ed25519"), true)
        case .rsa(let enc):
            return (enc ? L10n.sshKeyDetectedEncrypted_fmt.formatted("RSA")
                        : L10n.sshKeyDetected_fmt.formatted("RSA"), true)
        case .ecdsa:             return (L10n.sshKeyErrorECDSA.localized(), false)
        case .unsupportedFormat: return (L10n.sshKeyErrorUnsupportedFormat.localized(), false)
        case .notAKey:           return (L10n.sshKeyErrorNotAKey.localized(), false)
        }
    }

    private func revalidateKey(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        keyDetection = trimmed.isEmpty ? nil : SSHKeyAnalyzer.detect(text)
    }

    /// A TCP connect to host:port — reachability only. It proves the address
    /// and port answer, NOT that the credentials work; SSH auth is exercised by
    /// the first real server action. #470: the result says exactly that.
    @MainActor
    private func testSSH() async {
        guard !Task.isCancelled else { return }
        // #470 was: `Int(port), portInt > 0, portInt <= 65535` — the #469 helper.
        guard let portInt = Self.validPort(port) else {
            // #455 (editorial) was: hardcoded English "✗ Invalid port" — a
            // Russian user saw mixed languages. Localised; the ✓/✗ prefix is
            // kept because `testResult.hasPrefix("✓")` drives the result colour.
            testResult = "✗ " + L10n.sshTestInvalidPort.localized()
            isTesting = false
            return
        }
        let result = await NetPing.tcp(host: trimmedHost, port: UInt16(portInt))   // #470: trimmed
        if result.success, let ms = result.ms {
            // #470 was: L10n.sshTestReachable_fmt ("Reachable (%@)") — read as
            // "SSH works". The VPS card's own TCP-ping wording names the port.
            testResult = "✓ " + L10n.pingTCPOK_fmt.formatted(portInt, String(format: "%.0f", ms))
        } else {
            testResult = "✗ " + L10n.pingTCPFail_fmt.formatted(portInt)   // #470 was: L10n.sshTestUnreachable
        }
        isTesting = false
    }

    private func save() {
        var h = existing ?? ServerHost(label: "", host: "")
        h.label    = trimmedLabel      // #470 was: label
        h.host     = trimmedHost       // #470 was: host
        h.port     = Self.validPort(port) ?? 22   // #469: never store an unroutable port
        h.username = trimmedUsername   // #470 was: username
        h.authMethod = authMethod   // #451: nil only for pre-#451 stored hosts
        // Trust belongs to the SSH backend. Editing credentials or a label
        // must never clear or replace the remembered server key.
        let secret: SSHSecret
        switch authMethod {
        case .privateKey where storedKeyKept:
            // Unchanged key: re-save exactly what the Keychain holds.
            secret = .privateKey(text: existingKey ?? "",
                                 passphrase: (existingPassphrase?.isEmpty == false) ? existingPassphrase : nil)
        case .privateKey:
            secret = .privateKey(text: privateKey,
                                 passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase)
        case .password:
            secret = .password(password)
        }
        onSave(h, secret)
        dismiss()
    }

    private func prefill() {
        guard let h = existing else { return }
        label    = h.label
        host     = h.host
        port     = String(h.port)
        username = h.username
        authMethod = h.authMethod ?? .password
        // Credentials are fetched from the Keychain by the caller. The password
        // prefills its secure field; the private key is NEVER put into a text
        // field — it is classified for the "stored in Keychain" row and kept.
        if let pw = existingPassword { password = pw }
        if let key = existingKey, !key.isEmpty {
            keyDetection = SSHKeyAnalyzer.detect(key)
            storedKeyKept = true
        }
    }
}
