import SwiftUI

/// Step 1 — host, port, login and either a password or a pasted private key.
/// The key text goes straight into the draft from the clipboard and is never
/// rendered; the user only sees the detected type and can replace it.
struct AddServerAccessStep: View {
    @ObservedObject var flow: AddServerFlowController
    @FocusState private var focused: Field?

    private enum Field: Hashable { case label, host, port, user, password, passphrase }

    private var errors: [AddServerAccessDraft.FieldError] {
        flow.showAccessErrors ? flow.accessErrors : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            AddServerLead(text: .addFlowAccessLead)

            OlcCard {
                VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                    field(L10n.nameField.localized(), text: $flow.access.label,
                          placeholder: "VPS-1", field: .label,
                          error: firstError { $0 == .labelMissing || $0 == .labelDuplicate })
                        .textInputAutocapitalization(.words)

                    HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                        field(L10n.hostField.localized(), text: $flow.access.host,
                              placeholder: "203.0.113.10", field: .host,
                              error: firstError { $0 == .hostMissing }, mono: true)
                            .keyboardType(.URL)
                        field(L10n.portField.localized(), text: $flow.access.port,
                              placeholder: "22", field: .port,
                              error: firstError { $0 == .portInvalid }, mono: true)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: 110)
                    }

                    field(L10n.loginField.localized(), text: $flow.access.username,
                          placeholder: "root", field: .user,
                          error: firstError { $0 == .userMissing }, mono: true)
                }
            }

            OlcCard {
                VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                    OlcSectionHeader(L10n.authMethodPickerLabel.localized())
                    OlcSegmented(selection: $flow.access.authMethod, options: [
                        (SSHAuthMethod.password, L10n.authMethodPassword.localized()),
                        (SSHAuthMethod.privateKey, L10n.authMethodKey.localized()),
                    ])
                    switch flow.access.authMethod {
                    case .password: passwordSection
                    case .privateKey: keySection
                    }
                }
            }
        }
        .onChange(of: flow.access) { _, _ in flow.invalidateCheck() }
    }

    // MARK: Password

    @ViewBuilder private var passwordSection: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            FormField(label: L10n.passwordField.localized(), placeholder: "••••••••",
                      text: $flow.access.password, secure: true)
                .focused($focused, equals: .password)
                .submitLabel(.done)
            if let e = firstError({ $0 == .passwordMissing }) { AddServerInlineError(message: e) }
        }
    }

    // MARK: Key

    @ViewBuilder private var keySection: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
            if let detection = flow.access.keyDetection {
                keyStatus(detection)
                HStack(spacing: Theme.Metrics.s3) {
                    OlcButton(L10n.addFlowKeyReplace.localized(), systemImage: "arrow.triangle.2.circlepath",
                              role: .secondary, compact: true) { pasteKey() }
                    Spacer(minLength: 0)
                }
                if detection.isEncrypted {
                    VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                        FormField(label: L10n.sshKeyPassphraseField.localized(), placeholder: "••••••••",
                                  text: $flow.access.passphrase, secure: true)
                            .focused($focused, equals: .passphrase)
                        if let e = firstError({ $0 == .passphraseMissing }) { AddServerInlineError(message: e) }
                    }
                }
            } else {
                OlcButton(L10n.sshKeyPasteButton.localized(), systemImage: "doc.on.clipboard",
                          role: .secondary, fillWidth: true) { pasteKey() }
                Text(L10n.sshKeyFooter.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let e = firstError({ $0 == .keyMissing }) { AddServerInlineError(message: e) }
            }
            if clipboardWasEmpty {
                AddServerInlineError(message: L10n.addFlowClipboardEmpty.localized())
            }
        }
    }

    @State private var clipboardWasEmpty = false

    private func pasteKey() {
        let text = UIPasteboard.general.string ?? ""
        clipboardWasEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !clipboardWasEmpty else { return }
        flow.access.keyText = text
        flow.access.passphrase = ""
        Haptics.tap()
    }

    @ViewBuilder private func keyStatus(_ detection: SSHKeyAnalyzer.Detection) -> some View {
        let name: String? = {
            switch detection {
            case .ed25519: return "ed25519"
            case .rsa:     return "RSA"
            default:       return nil
            }
        }()
        if let name {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                OlcStatusPill(tone: .ok,
                              title: L10n.addFlowKeyPasted_fmt.formatted(name),
                              subtitle: detection.isEncrypted
                                ? L10n.sshKeyPassphraseField.localized()
                                : L10n.addFlowKeyNotShownNote.localized())
            }
        } else if let e = firstError({ if case .keyUnsupported = $0 { return true }; return false }) {
            OlcStatusPill(tone: .error, title: e)
        } else {
            let message = AddServerAccessDraft.FieldError.keyUnsupported(detection).message
            OlcStatusPill(tone: .error, title: message)
        }
    }

    // MARK: Helpers

    private func firstError(_ match: (AddServerAccessDraft.FieldError) -> Bool) -> String? {
        errors.first(where: match)?.message
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String,
                       field: Field, error: String?, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            TextField(placeholder, text: text)
                .font(mono ? Theme.Typography.metricValue : Theme.Typography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: field)
                .frame(minHeight: Theme.Metrics.chipHeight)
                .padding(.horizontal, Theme.Metrics.s3)
                .background(Theme.Palette.fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius)
                        .stroke(error == nil ? Theme.Palette.fillBorder : Theme.Palette.red, lineWidth: 1)
                )
            if let error { AddServerInlineError(message: error) }
        }
    }
}
