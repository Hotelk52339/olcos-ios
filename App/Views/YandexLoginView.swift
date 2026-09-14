import SwiftUI
import WebKit

// MARK: - YandexLoginView (#463)
//
// #463: the ONE place a Yandex password is ever typed — and it is typed into
// Yandex's own page, never into a field of ours. Nobody automates
// `passport.yandex.ru/auth`: it carries first-class captcha and SMS states by
// design. The proven pattern (and the one this copies) is that the human signs
// in ONCE in a real web view and the app then reuses the `Session_id` cookie
// that sign-in produced.
//
// What this view is responsible for, and nothing else:
//   • load the passport page with `retpath` back to Telemost, so a successful
//     sign-in lands on the domain the cookie is scoped to;
//   • poll `WKWebsiteDataStore.default().httpCookieStore` until a non-empty
//     `Session_id` shows up for a `*.yandex.ru` domain;
//   • hand that value back ONCE, then get out of the way.
//
// It deliberately does NOT know where the value is stored — the caller owns
// that (the Keychain, via YandexSessionStore). Keeping the store out of here
// means this file has no way to leak the credential anywhere else.
//
// SECURITY, in the order it matters:
//   • The warning line sits ABOVE the web view, so it is read BEFORE the
//     password is typed, not after. `Session_id` is a bearer credential for the
//     WHOLE Yandex identity — mail, Disk, Pay — usable without the password and
//     past 2FA, which is why the line names those things instead of saying
//     "your account".
//   • EVERY yandex.ru cookie is deleted from WebKit's own jar the moment the
//     session is read, so the credential ends up in exactly ONE place (the
//     Keychain) and a later "forget account" is complete rather than partial.
//     #463 (audit) was: only `Session_id` itself. Passport also issues
//     `sessionid2` — the HTTPS-only twin, a SECOND full bearer credential — so
//     deleting one cookie left the account signed in on disk in the PERSISTENT
//     store: "Forget this Yandex account" cleared the Keychain while WebKit kept
//     the keys to the same account. Deleting them is safe: joining a Telemost
//     room is anonymous (upstream internal/auth/telemost/api.go), so nothing
//     else in the app needs a signed-in Yandex session. Only cookies on
//     yandex.ru are touched — never the shared data store itself, which the
//     videochannel transport's WebView also lives in.
//   • The address is on screen. Yandex's sign-in redirects through several hosts
//     and this view can follow a link anywhere, so a password typed into an
//     in-app web view whose URL nobody can see is a phishing surface by
//     construction. The host of whatever is displayed sits under the warning.
//   • The value is never logged, never put in an error message and never held
//     anywhere but the callback.

struct YandexLoginView: View {
    /// #463: called at most once, with the raw `Session_id` cookie value. The
    /// caller stores it (Keychain) — this view keeps no copy.
    let onSession: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Belt-and-braces against a re-created representable firing twice; the
    /// coordinator has its own guard.
    @State private var captured = false
    /// #463 (audit): the host of the page currently on screen — the one thing
    /// that tells the user whether they are typing a password into Yandex or
    /// into wherever a link on the page took them.
    @State private var host = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                warning
                addressLine
                Divider()
                YandexAuthWebView(onHost: { host = $0 }) { value in
                    guard !captured else { return }
                    captured = true
                    onSession(value)
                    dismiss()
                }
            }
            .navigationTitle(L10n.yandexLoginTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel.localized()) { dismiss() }
                }
            }
        }
    }

    /// #463: the one line the user must read before they type a password. It is
    /// above the fold and above the web view on purpose — a warning shown after
    /// the credential exists is not a warning, it is a receipt.
    private var warning: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s2) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(Theme.Palette.orange)
            // #463 (audit) was: `Theme.Typography.caption` + `textSecondary` on
            // the whole block — the smallest step in the scale in the dimmest
            // ink, i.e. a footnote, for the one sentence that has to be READ
            // before a password is typed. Body/primary is the prose step; the
            // glyph and the amber wash already say "warning".
            Text(L10n.yandexLoginWarning.localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.s4)
        .padding(.vertical, Theme.Metrics.s3)
        .background(Theme.Palette.orange.opacity(0.12))
    }

    /// #463 (audit): the address bar this sheet did not have. A `WKWebView` with
    /// no visible URL is indistinguishable from a page that only LOOKS like
    /// passport.yandex.ru, and this one may navigate anywhere the sign-in flow —
    /// or a link on it — leads. Host only: a full URL is unreadable at this
    /// width and would put query parameters into every screenshot.
    /// No `L10n` case, deliberately — a host name is data, and the lock glyph
    /// needs no words.
    private var addressLine: some View {
        HStack(spacing: Theme.Metrics.s2) {
            Image(systemName: "lock.fill")
            Text(host.isEmpty ? "…" : host)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.mono)
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, Theme.Metrics.s4)
        .padding(.bottom, Theme.Metrics.s3)
        .background(Theme.Palette.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The web view

/// #463: a plain `WKWebView` on the shared (persistent) data store, plus a
/// once-a-second cookie poll. There is no script injection and no navigation
/// interception — Yandex's sign-in flow redirects through several hosts and
/// occasionally opens a captcha in place, so anything that tries to recognise
/// "the last page" breaks the first time the flow changes. The cookie is the
/// only reliable signal, so the cookie is what we watch.
private struct YandexAuthWebView: UIViewRepresentable {
    /// The passport sign-in page, returning to Telemost so a session that
    /// already exists resolves immediately instead of parking on a chooser.
    static let authURL = URL(string:
        "https://passport.yandex.ru/auth?retpath=https%3A%2F%2Ftelemost.yandex.ru%2F")!

    /// #463 (audit): called on every committed navigation with the host being
    /// displayed, so the sheet can show where the password is going.
    let onHost: (String) -> Void
    let onSessionCookie: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHost: onHost, onSessionCookie: onSessionCookie)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The DEFAULT store is the one Yandex's own page writes into and the one
        // this view polls; a non-persistent store would work for the flow but
        // would also mean a fresh full sign-in every single time.
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: Self.authURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Keep the callbacks fresh: `makeCoordinator` runs once, but the View
        // struct (and the closures it captured) is rebuilt on every render.
        context.coordinator.onSessionCookie = onSessionCookie
        context.coordinator.onHost = onHost
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Once a second: fast enough that the sheet closes as the redirect
        /// settles, slow enough to cost nothing.
        private static let pollSeconds: TimeInterval = 1

        var onSessionCookie: (String) -> Void
        var onHost: (String) -> Void
        private var timer: Timer?
        private var reported = false

        init(onHost: @escaping (String) -> Void,
             onSessionCookie: @escaping (String) -> Void) {
            self.onHost = onHost
            self.onSessionCookie = onSessionCookie
        }

        deinit { timer?.invalidate() }

        /// #463 (audit): report the host the moment the response that will be
        /// RENDERED is committed — the same moment a browser's address bar
        /// switches — and again when the page settles, which covers a redirect
        /// that resolves without a fresh commit.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onHost(webView.url?.host ?? "")
        }

        /// Polling starts only after the first page has actually loaded. A user
        /// whose session is still valid is signed in the moment the page
        /// resolves — which is the right outcome — but they should SEE the page
        /// they asked for rather than watch a sheet flash open and shut.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onHost(webView.url?.host ?? "")
            start()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func start() {
            guard timer == nil, !reported else { return }
            let t = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
                self?.poll()
            }
            // `.common` so the poll keeps running while the user is scrolling
            // the sign-in page.
            RunLoop.main.add(t, forMode: .common)
            timer = t
            poll()
        }

        private func poll() {
            guard !reported else { return }
            let store = WKWebsiteDataStore.default().httpCookieStore
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.reported,
                      // #463 (audit) was: a SECOND, weaker copy of the domain
                      // rule lived here — `domain.hasSuffix("yandex.ru")`, which
                      // accepts `evilyandex.ru`, the exact look-alike the store's
                      // own check (and `testLookalikeDomainIsRejected`) exists to
                      // reject. This view can navigate anywhere and `save(_:)`
                      // never re-checks the domain, so a look-alike page that set
                      // `Session_id` was adopted as "the Yandex account". One
                      // rule, living in the type that owns the credential.
                      let cookie = YandexSessionStore.sessionCookie(in: cookies) else { return }
                self.reported = true
                self.stop()
                let value = cookie.value
                // One credential, one home. See the security note at the top.
                Coordinator.purgeYandexCookies(cookies, from: store)
                self.onSessionCookie(value)
            }
        }

        /// #463 (audit): drop EVERY yandex.ru cookie, not only the one we copied.
        /// `sessionid2` is the HTTPS-only twin of `Session_id` and a full bearer
        /// credential on its own; `yandex_login` / `L` / `i` identify the account
        /// too. Leaving them in the shared PERSISTENT store meant the browser
        /// stayed signed in after "Forget this Yandex account" wiped the Keychain
        /// — the partial forget this file's own note promises not to be.
        /// The deletes are addressed to the process-wide `WKWebsiteDataStore`,
        /// not to the web view, so they complete even though the sheet dismisses
        /// immediately afterwards.
        static func purgeYandexCookies(_ cookies: [HTTPCookie], from store: WKHTTPCookieStore) {
            for cookie in cookies where isYandexDomain(cookie.domain) {
                store.delete(cookie, completionHandler: nil)
            }
        }

        /// PURE. `yandex.ru` or a subdomain of it — the same suffix rule
        /// `YandexSessionStore.isSessionCookie` applies (a cookie jar's leading
        /// dot, `.yandex.ru`, satisfies the suffix test), so `evilyandex.ru` is
        /// not a Yandex host here either.
        static func isYandexDomain(_ domain: String) -> Bool {
            let d = domain.lowercased()
            return d == YandexSessionStore.cookieDomain
                || d.hasSuffix("." + YandexSessionStore.cookieDomain)
        }
    }
}

// #340: both appearance variants.
#if DEBUG
#Preview("Yandex sign-in — Dark") {
    YandexLoginView { _ in }
        .preferredColorScheme(.dark)
}
#Preview("Yandex sign-in — Light") {
    YandexLoginView { _ in }
        .preferredColorScheme(.light)
}
#endif
