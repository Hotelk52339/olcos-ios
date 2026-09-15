import SwiftUI

// MARK: - Sharing
//
// Two sheets share one page:
//  • `ShareConnectionView` — one connection: explanation + the mono `olcrtc://`
//    URI + Copy / Share / QR. Used by the Connect tab.
//  • `ServerShareSheet` — the server card's "Share": pick WHICH protocol
//    connection to share (each as its own `olcrtc://` URI / QR), or hand over
//    "Full access (SSH)". Full access is behind an explicit confirmation that
//    names the secret the link carries (password or the full private key), and
//    the link is never logged — only the action is.
// The QR is a NavigationLink push inside the sheet's own NavigationStack.

/// One protocol connection a server card can share.
struct ServerShareOption: Identifiable, Hashable {
    let conn: ConnectionRecord
    var id: UUID { conn.id }
    /// "Yandex Telemost · VP8" — the same naming the protocol rows use.
    var title: String { ConnectionNaming.protocolLine(conn.details) }

    // `ConnectionRecord` is not Hashable (it carries the secret-bearing
    // details); identity by record id is what the navigation path needs.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ShareConnectionView: View {
    let conn: ConnectionRecord
    /// Present only when the caller supplies full-access credentials.
    let fullAccess: FullAccessShare?
    @Environment(\.dismiss) private var dismiss

    init(conn: ConnectionRecord, fullAccess: FullAccessShare? = nil) {
        self.conn = conn
        self.fullAccess = fullAccess
    }

    var body: some View {
        NavigationStack {
            ShareConnectionPage(conn: conn, fullAccess: fullAccess)
                .navigationTitle(L10n.shareConnectionTitle.localized())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { closeItem }
        }
        .presentationDetents([.medium, .large])
    }

    private var closeItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(L10n.closeAction.localized())
        }
    }
}

// MARK: - Server share picker

struct ServerShareSheet: View {
    let hostLabel: String
    /// Every protocol connection this server owns, in row order.
    let options: [ServerShareOption]
    /// Full-access payload, or nil when no SSH credential is stored.
    let fullAccess: FullAccessShare?
    /// Open straight onto the full-access confirmation (Manage screen entry).
    var startWithFullAccess = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmFullAccess = false
    @State private var showFullAccess = false

    var body: some View {
        NavigationStack {
            List {
                protocolSection
                fullAccessSection
            }
            .signalFormChrome()
            .navigationTitle(L10n.shareServerTitle_fmt.formatted(hostLabel))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.closeAction.localized())
                }
            }
            .navigationDestination(isPresented: $showFullAccess) {
                if let fa = fullAccess, let conn = options.first?.conn {
                    FullAccessSharePage(conn: conn, payload: fa)
                        .navigationTitle(L10n.shareFullAccessHeader.localized())
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .onAppear {
                if startWithFullAccess, fullAccess != nil { confirmFullAccess = true }
            }
            .alert(L10n.shareFullAccessConfirmTitle.localized(), isPresented: $confirmFullAccess) {
                Button(L10n.shareFullAccessConfirmAction.localized(), role: .destructive) {
                    showFullAccess = true
                }
                Button(L10n.cancel.localized(), role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var protocolSection: some View {
        Section {
            if options.isEmpty {
                Text(L10n.shareServerNoProtocols.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            ForEach(options) { option in
                NavigationLink {
                    ShareConnectionPage(conn: option.conn, fullAccess: nil)
                        .navigationTitle(option.title)
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    SignalSettingsLabel(option.title, systemImage: "link")
                }
            }
        } header: {
            SignalSectionHeader(L10n.shareServerProtocolsHeader.localized())
        } footer: {
            Text(L10n.shareConnectionOnlySub.localized())
        }
        .signalFormRows()
    }

    @ViewBuilder
    private var fullAccessSection: some View {
        if fullAccess != nil, !options.isEmpty {
            Section {
                Button { confirmFullAccess = true } label: {
                    SignalSettingsLabel(L10n.shareFullAccessHeader.localized(), systemImage: "key.horizontal")
                        .foregroundStyle(Theme.Palette.red)
                }
            } footer: {
                Text(fullAccess?.isKeyAuth == true
                     ? L10n.shareFullAccessKeySub.localized()
                     : L10n.shareFullAccessPasswordSub.localized())
            }
            .signalFormRows()
        }
    }

    private var confirmMessage: String {
        fullAccess?.isKeyAuth == true
            ? L10n.shareFullAccessConfirmKey.localized()
            : L10n.shareFullAccessConfirmPassword.localized()
    }
}

// MARK: - Pages

/// The connection-share page: scope badge, explanation, URI, Copy / Share / QR,
/// and — when the caller supplies credentials — the full-access section.
struct ShareConnectionPage: View {
    let conn: ConnectionRecord
    let fullAccess: FullAccessShare?
    @Environment(\.dismiss) private var dismiss

    private var uri: String {
        switch conn.details {
        case .olcrtc(let p): return OlcrtcURI.encode(p)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                // The scope of a plain URI is the first thing on screen; in
                // full-access mode the section below carries its own warning.
                if fullAccess == nil { connectionOnlyBadge }

                Text(L10n.shareConnectionExplanation.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                // Answers "where do I paste this?": the URI has no consumer
                // outside olcOS, and the entry point on the other phone is
                // three taps deep.
                Text(L10n.shareRecipientHint.localized())
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    OlcSectionHeader(L10n.shareConnectionURIHeader.localized())
                    OlcCard {
                        Text(uri)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(spacing: Theme.Metrics.s2) {
                    OlcButton(L10n.copyURIAction.localized(), systemImage: "doc.on.doc",
                              role: .secondary, fillWidth: true) {
                        UIPasteboard.general.string = uri
                        LogStore.shared.log(.connection, L10n.copiedURI_fmt.formatted(conn.displayName))
                        dismiss()
                    }
                    ShareLink(item: uri, subject: Text(conn.displayName)) {
                        ShareLinkLabel(title: L10n.shareAction.localized(), systemImage: "square.and.arrow.up")
                    }
                    NavigationLink {
                        QRCodeView(uri: uri)
                            .padding(Theme.Metrics.s7)
                            .navigationTitle(ConnectionNaming.service(conn.details))
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        ShareLinkLabel(title: L10n.actionQR.localized(), systemImage: "qrcode")
                    }
                }

                if let fa = fullAccess {
                    Divider().overlay(Theme.Palette.separator).padding(.vertical, Theme.Metrics.s1)
                    OlcSectionHeader(L10n.shareFullAccessHeader.localized())
                    FullAccessSharePage(conn: conn, payload: fa, embedded: true)
                }
            }
            .padding(Theme.Metrics.s4)
        }
    }

    private var connectionOnlyBadge: some View {
        OlcCard {
            HStack(spacing: Theme.Metrics.s2) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Theme.Palette.textSecondary)
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    Text(L10n.shareConnectionOnlyBadge.localized())
                        .font(Theme.Typography.statusTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(L10n.shareConnectionOnlySub.localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }
}

/// The full-access page: the warning naming the secret, a reveal step, then
/// the `olcrtc://host/v1/…` link with Copy / Share. Only the action is logged.
struct FullAccessSharePage: View {
    let conn: ConnectionRecord
    let payload: FullAccessShare
    /// True when drawn inside `ShareConnectionPage` (no outer padding).
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = false

    var body: some View {
        if embedded { content } else { ScrollView { content.padding(Theme.Metrics.s4) } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            HStack(alignment: .top, spacing: Theme.Metrics.s2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.red)
                Text(payload.isKeyAuth
                     ? L10n.shareFullAccessWarningKey.localized()
                     : L10n.shareFullAccessWarning.localized())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(Theme.Metrics.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.redWeak,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))

            if !revealed {
                OlcButton(L10n.shareFullAccessReveal.localized(), systemImage: "eye",
                          role: .danger, fillWidth: true) {
                    revealed = true
                }
            } else if let link = payload.encoded() {
                OlcCard {
                    Text(link)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(spacing: Theme.Metrics.s2) {
                    OlcButton(L10n.shareFullAccessCopy.localized(), systemImage: "doc.on.doc",
                              role: .danger, fillWidth: true) {
                        UIPasteboard.general.string = link
                        LogStore.shared.log(.connection, L10n.shareFullAccessCopied_fmt.formatted(conn.displayName))
                        dismiss()
                    }
                    ShareLink(item: link, subject: Text(conn.displayName)) {
                        ShareLinkLabel(title: L10n.shareAction.localized(), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

/// A `ShareLink` / `NavigationLink` label drawn like `OlcButton(.secondary)`.
private struct ShareLinkLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(Theme.Typography.button)
            .foregroundStyle(Theme.Palette.accent)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metrics.controlHeight)
            .background(Theme.Palette.fill,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
    }
}
