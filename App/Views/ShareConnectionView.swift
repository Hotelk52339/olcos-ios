import SwiftUI

// MARK: - ShareConnectionView (#304)
//
// Reusable "Share connection" sheet — explanation + the mono `olcrtc://` URI block
// (OlcCard) + Copy / Share / QR. Extracted from ConnectionsView and moved to the
// Manage VPS server card (#304): the connection is configured on the server card,
// and that's where sharing belongs (matching AmneziaVPN). The QR is a NavigationLink
// push (the sheet is already in a NavigationStack), so no second-sheet handoff is
// needed.
//
// #135: optional FULL-ACCESS share (co-admin). When the sheet is created with a
// `fullAccess` payload (the host's SSH fields + the Keychain password — read by
// the caller, ServersView), it adds an opt-in section behind a destructive-style
// warning that shares an `olcrtc://host/v1/…` link carrying BOTH the connection
// URI and the SSH credentials, so the recipient can MANAGE the VPS, not just
// connect (#366: the familiar olcrtc:// scheme — FullAccessShare for the format,
// App.handleIncomingURL for the recipient-side import). The secret is never logged.

struct ShareConnectionView: View {
    let conn: ConnectionRecord
    /// #135: present only when the caller supplies full-access credentials.
    let fullAccess: FullAccessShare?
    @Environment(\.dismiss) private var dismiss

    /// #135: gate the credential blob behind an explicit reveal so it isn't on
    /// screen until the user opts in past the warning.
    @State private var fullAccessRevealed = false

    init(conn: ConnectionRecord, fullAccess: FullAccessShare? = nil) {
        self.conn = conn
        self.fullAccess = fullAccess
    }

    private var uri: String {
        switch conn.details {
        case .olcrtc(let p): return OlcrtcURI.encode(p)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.s4) {   // #471: B9 — 16 → s4
                    // #456: what this link grants must be the FIRST thing on
                    // screen, not a conclusion the user draws from the absence of
                    // a warning.
                    // #456 (audit fix) was: rendered unconditionally — which put a
                    // green "no server access" shield at the top of a sheet that,
                    // in full-access mode, hands over SSH control. The badge is now
                    // shown only in the genuinely connection-only case; the
                    // full-access section below carries its own warning.
                    connectionOnlyBadge

                    Text(L10n.shareConnectionExplanation.localized())
                        // #471: B9 — prose is step 3 of the scale.
                        // #471 was: .font(.subheadline)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)

                    // boc #471: B8 — one of the five hand-rolled uppercase labels
                    // that each used a different (font, tint, tracking) recipe.
                    // `OlcSectionHeader` is the system's one section-header
                    // treatment and carries its own bottom gap, so the stack that
                    // holds it no longer adds a second one.
                    // #471 was: VStack(spacing: 6) { Text(header).tracking(0.6)
                    //   .font(Theme.Typography.sectionHeader).textCase(.uppercase)
                    //   .foregroundStyle(Theme.Palette.textSecondary); OlcCard {…} }
                    VStack(alignment: .leading, spacing: 0) {
                        OlcSectionHeader(L10n.shareConnectionURIHeader.localized())
                        OlcCard {
                            Text(uri)
                                // #471: the URI is step 6 (addresses / URIs), via
                                // its token. #471 was: .system(.caption, design: .monospaced)
                                .font(Theme.Typography.mono)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    // eoc #471

                    VStack(spacing: Theme.Metrics.s2) {   // #471: B9 — 8 → s2
                        OlcButton(L10n.copyURIAction.localized(), systemImage: "doc.on.doc",
                                  role: .secondary, fillWidth: true) {
                            UIPasteboard.general.string = uri
                            LogStore.shared.log(.connection, L10n.copiedURI_fmt.formatted(conn.displayName))
                            dismiss()
                        }
                        // ShareLink styled to match OlcButton(.secondary).
                        ShareLink(item: uri, subject: Text(conn.displayName)) {
                            Label(L10n.shareAction.localized(), systemImage: "square.and.arrow.up")
                                .font(Theme.Typography.button)
                                .foregroundStyle(Theme.Palette.accent)
                                .frame(maxWidth: .infinity)
                                .frame(height: Theme.Metrics.controlHeight)
                                .background(Theme.Palette.fill,
                                            in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
                        }
                        // #304: QR pushes within the sheet's own NavigationStack
                        // (was a second-sheet handoff in ConnectionsView).
                        NavigationLink {
                            QRCodeView(uri: uri)
                                .padding(32)
                                // #470: service first, like every other surface
                                // (#461) — the record label repeats the server.
                                .navigationTitle(ConnectionNaming.service(conn.details))
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label(L10n.actionQR.localized(), systemImage: "qrcode")
                                .font(Theme.Typography.button)
                                .foregroundStyle(Theme.Palette.accent)
                                .frame(maxWidth: .infinity)
                                .frame(height: Theme.Metrics.controlHeight)
                                .background(Theme.Palette.fill,
                                            in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
                        }
                    }

                    // #135: opt-in full-access (co-admin) share — only when the
                    // caller passed SSH credentials.
                    if let fa = fullAccess {
                        fullAccessSection(fa)
                    }
                }
                .padding(Theme.Metrics.s4)   // #471: B9 — 16 → s4
            }
            .navigationTitle(L10n.shareConnectionTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.closeAction.localized())
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Connection-only badge (#456)

    /// #456: states the scope of the `olcrtc://` URI in plain words — it lets
    /// someone connect THROUGH the server and nothing else. Extracted into its
    /// own @ViewBuilder because `body` is already a deep nest and this repo has
    /// hit the SwiftUI type-checker timeout twice on large bodies.
    @ViewBuilder
    private var connectionOnlyBadge: some View {
        // #456 (audit fix): show the reassurance ONLY when this sheet really is
        // connection-only. When a full-access payload is present the sheet can
        // hand over SSH control of the server, and leading with a green
        // "no server access" shield is the most dangerous kind of untrue —
        // a safety claim the screen itself contradicts further down.
        if fullAccess == nil {
        OlcCard {
            HStack(spacing: Theme.Metrics.s2) {   // #471: B9 — 8 → s2
                Image(systemName: "lock.shield")
                    .foregroundStyle(Theme.Palette.green)
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {   // #471: 2 → s1
                    Text(L10n.shareConnectionOnlyBadge.localized())
                        .font(Theme.Typography.statusTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(L10n.shareConnectionOnlySub.localized())
                        // #471: B9 — step 5 through its token. was: .font(.caption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
        }   // #456: end of the `fullAccess == nil` guard
    }

    // MARK: - Full-access (co-admin) section (#135)

    /// Opt-in section that shares an `olcrtc://host/v1/…` link carrying the SSH
    /// credentials AND the connection URI. Until the user taps "Reveal", only
    /// the destructive-style warning shows; revealing exposes the blob + the
    /// Copy / Share actions. The secret is never logged — only the action is.
    @ViewBuilder
    private func fullAccessSection(_ fa: FullAccessShare) -> some View {
        // boc #471: B8 + B9 — the sheet's second hand-rolled uppercase label
        // goes through `OlcSectionHeader` too, and the stack lands on the grid.
        // #471 was: spacing: 6 + Text(header).tracking(0.6).font(sectionHeader)
        //   .textCase(.uppercase).foregroundStyle(Theme.Palette.textSecondary)
        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            Divider().overlay(Theme.Palette.separator).padding(.vertical, Theme.Metrics.s1)

            OlcSectionHeader(L10n.shareFullAccessHeader.localized())

            // Destructive-style warning — always visible, even before reveal.
            HStack(alignment: .top, spacing: Theme.Metrics.s2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.red)
                Text(L10n.shareFullAccessWarning.localized())
                    // #471: prose is step 3. was: .font(.subheadline)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(Theme.Metrics.s3)   // #471: B9 — 12 → s3
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.redWeak,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))

            if !fullAccessRevealed {
                OlcButton(L10n.shareFullAccessReveal.localized(), systemImage: "eye",
                          role: .danger, fillWidth: true) {
                    fullAccessRevealed = true
                }
            } else if let link = fa.encoded() {
                OlcCard {
                    Text(link)
                        // #471: step 6 (the link is an address). #471 was:
                        // .font(.system(.caption, design: .monospaced))
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(spacing: Theme.Metrics.s2) {   // #471: B9 — 8 → s2
                    OlcButton(L10n.shareFullAccessCopy.localized(), systemImage: "doc.on.doc",
                              role: .danger, fillWidth: true) {
                        UIPasteboard.general.string = link
                        // #135: log the ACTION only — never the credential blob.
                        LogStore.shared.log(.connection, L10n.shareFullAccessCopied_fmt.formatted(conn.displayName))
                        dismiss()
                    }
                    // ShareLink styled to match OlcButton(.secondary), like the URI row.
                    ShareLink(item: link, subject: Text(conn.displayName)) {
                        Label(L10n.shareAction.localized(), systemImage: "square.and.arrow.up")
                            .font(Theme.Typography.button)
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Metrics.controlHeight)
                            .background(Theme.Palette.fill,
                                        in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
                    }
                }
            }
        }
        // eoc #471
    }
}
