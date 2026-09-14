import SwiftUI
import Combine // #485: observe every route revision, not coalesced view changes.

// MARK: - App entry
//
// #457: hosts the root TabView with THREE tabs:
//   - Connect  — connection list, tunnel state, the one connect/disconnect action
//   - Servers  — SSH-managed hosts: install / uninstall / reboot olcrtc
//   - Settings — tunnel mode, SOCKS, DNS, appearance, diagnostics & logs
//
// #457 was: five tabs. Config held one 2-option picker plus one toggle while
// nine sibling settings lived in Settings — it is now `SettingsView.tunnelSection`
// (see ConfigView.swift). Logs needed a purpose-built pub/sub channel
// (`LogsRouter` + `onChange { selectedTab = 3 }` + `fetchingHostID`) just to be
// entered with the right context, which is the clearest possible proof it was a
// sub-view — it is now pushed with a `LogSubject` (see LogsView.swift). HIG Tab
// bars: "it's generally easier to navigate among fewer tabs."
//
// All @StateObject stores live on MainTabView so they survive tab switches
// and the tunnel can keep running while the user navigates around.
// SettingsStore is the only singleton (state shared between SwiftUI views
// and non-view callers like SOCKSSession), so it's referenced as .shared
// rather than @StateObject.

@main
// #241 was: struct OlcRTCiOSApp — the only identifier using the "OlcRTC" display
// form. Renamed to the Olcrtc* Swift type-prefix convention (OlcrtcConnection,
// OlcrtcURI). "OlcRTC" remains the brand's display spelling (UI title, app name).
struct OlcrtcApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

// #457 was: `final class LogsRouter: ObservableObject` (#339) with its
// `Request { hostID, autofetch }` and `fetchingHostID` (#334) — the app's ONLY
// cross-tab back-channel. It existed purely to teleport the user to the Logs
// tab and re-establish context the caller already held, then draw a busy
// indicator on a card that had just scrolled off-screen. A push carries its
// subject for free: see `LogSubject` in LogsView.swift.

struct MainTabView: View {
    // #412 was: `store`/`tunnel` had inline `= …` initializers and
    // `tunnel.secretsLocked` was wired later in `.onAppear` — a forgettable step
    // (a missed wiring reads as "never locked", #393). Both are now built in
    // `init()`, with the locked-secrets check injected into TunnelManager.
    @StateObject  private var store       : ConnectionStore
    @StateObject  private var tunnel      : TunnelManager
    @StateObject  private var ipCheck     = IPChecker()
    @StateObject  private var speed       = SpeedTest()
    @StateObject  private var serverStore : ServerHostStore   // #453: built in init() so the failover wiring can capture it
    @StateObject  private var botStore    = BotStore()      // #417: bot registry (Servers + Settings)
    // #457 was: `@StateObject private var logsRouter = LogsRouter()` (#339).
    @StateObject  private var updateChecker = UpdateChecker()   // #360
    // #465: renews a Telemost room before its 24 h clock runs out. Built in
    // init() like the failover wiring — it needs all three stores.
    @StateObject  private var telemostRenewal: TelemostRenewalCoordinator
    @ObservedObject private var settings  = SettingsStore.shared

    /// #375: re-hydrate Keychain secrets when the app returns to the foreground.
    /// If the device was locked before first unlock at launch, the encryption key
    /// couldn't be read (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) and was
    /// left empty — re-reading on `.active` (after the user has unlocked) fixes it
    /// before they can hit Connect.
    @Environment(\.scenePhase) private var scenePhase

    /// One-shot guard so the auto-connect setting only fires on cold start,
    /// not every time the user comes back to the Connections tab.
    @State private var didAutoConnect = false

    /// #470: `HealthCoordinator.verifyDue` cancels whatever sweep is running —
    /// a forced pull-to-refresh / "Check all" included — and re-queues the rest
    /// un-forced (debounced, no deep pass). scenePhase round-trips
    /// `.inactive → .active` on a Notification Center / Control Center pull, a
    /// Face ID prompt or a call banner, none of which is "opening the app"
    /// (#458). Only a return from `.background` re-arms the on-entry pass; true
    /// at launch so the first activation still sweeps.
    @State private var sweepOnActivate = true
    // #485: async preference reads from a previous activation must not publish
    // a sweep after a background/foreground cycle has superseded their owner.
    @State private var activationEpoch: UInt64 = 0

    /// Selected tab — #457: 0 Connect, 1 Servers, 2 Settings.
    // #294 was: also drove the Logs-tab visibility gate (#289) for the
    // merged-stream rebuild. With per-source Logs tabs (#294) each tab only
    // rebuilds its own small category buffer, so that gate was retired —
    // `selectedTab` now only does normal `TabView` selection.
    @State private var selectedTab = 0

    // boc #111: olcrtc-sub:// subscription links. A fetched-and-parsed list
    // waits in `subPrompt` for the user's confirmation ("Add N connections
    // from …?"); `subError` drives the failure alert.
    // #354: a bare olcrtc:// deep link reuses the same confirm sheet, wrapped as
    //   a one-entry list with `subSourceLink == nil` (plain add, no dedup).
    // #356: `subSourceLink` is the canonical olcrtc-sub:// link for a real
    //   subscription import — it keys the dedup/refresh bookkeeping in the store.
    @State private var subPrompt: OlcrtcSubscription?
    @State private var subSource = ""             // host/title shown in the confirm message
    @State private var subSourceLink: String?     // canonical olcrtc-sub:// link (nil for plain olcrtc://)
    @State private var subError: String?
    /// #366: parsed full-access (co-admin) link awaiting the user's confirm.
    @State private var fullAccessPrompt: FullAccessShare?
    // eoc #111

    // #412: build store + tunnel here so the locked-secrets check is injected into
    // TunnelManager at construction — no forgettable `.onAppear` wiring step.
    init() {
        let store = ConnectionStore()
        _store = StateObject(wrappedValue: store)
        // #453: serverStore is constructed here (not inline) so the auto-failover
        // provider can capture both stores — the sibling protocols to fail over
        // to are the ConnectionRecords a ServerHost links (last + extra).
        let serverStore = ServerHostStore()
        _serverStore = StateObject(wrappedValue: serverStore)
        // #465 was: the TunnelManager was built inline. It is now a local first,
        // because the renewal coordinator has to hold the SAME instance.
        let tunnel = TunnelManager(
            secretsLocked: { [weak store] in
                store?.secretsLocked ?? false
            },
            failoverCandidates: { [weak store, weak serverStore] current in
                TunnelManager.computeFailoverCandidates(current, store: store, serverStore: serverStore)
            })
        _tunnel = StateObject(wrappedValue: tunnel)
        _telemostRenewal = StateObject(wrappedValue: TelemostRenewalCoordinator(
            connections: store, tunnel: tunnel, hosts: serverStore))
    }

    var body: some View {
        // #457: three tabs — Connect / Servers / Settings. Everything else is a
        // pushed destination, entered FROM its subject.
        TabView(selection: $selectedTab) {
            ConnectionsView(store: store, tunnel: tunnel,
                            ipCheck: ipCheck, speed: speed,
                            onPasteImport: handlePastedImport)   // #361
                .tabItem { Label(L10n.tabConnections.localized(), systemImage: "network") }
                .tag(0)

            // #452: + tunnel, so a protocol row on the host card can connect directly.
            // #457 was: + logsRouter — "Container logs" pushes
            // LogsView(subject: .container(host)) now.
            ServersView(serverStore: serverStore, connections: store,
                        botStore: botStore, tunnel: tunnel)
                .tabItem { Label(L10n.tabServers.localized(), systemImage: "server.rack") }
                .tag(1)

            // #300: SettingsView needs live tunnel state to gate the
            // "in use by olcrtc tunnel" port-check result on an actual
            // connection, not just the configured port number (#313: the
            // gate compares against `tunnel.boundPort`, the port the live
            // session actually bound).
            // #457: + serverStore/connections, which the pushed
            // LogsView(subject: .all) needs; the tunnel-mode picker and the
            // failover toggle moved here from the deleted Config tab.
            SettingsView(tunnel: tunnel, botStore: botStore,
                         serverStore: serverStore, connections: store,
                         updateChecker: updateChecker)   // #475
                .tabItem { Label(L10n.tabSettings.localized(), systemImage: "gearshape") }
                .tag(2)
        }
        // #456 was: .id(settings.appearanceMode) — a full TabView rebuild that
        // reset nav stacks, scroll positions and in-progress sheet edits. It
        // existed ONLY because Dark↔Gray produced no colorScheme trait change;
        // with Gray gone every appearance switch flips colorScheme, so SwiftUI
        // re-resolves the tokens on its own.
        // Prevent the keyboard from incorrectly resizing tab content. SwiftUI
        // TabView already accounts for the home-indicator / tab-bar safe area,
        // but without this modifier the keyboard safe area can bleed through
        // and push scrollable content under the tab bar on some configurations.
        .ignoresSafeArea(.keyboard)
        // #470 was: `.dynamicTypeSize(appTypeRange)` — an app-level override of
        // the device's Text Size, driven by a Settings slider that duplicated
        // iOS › Display & Brightness. The slider is gone; the device setting
        // applies unmodified, Larger Accessibility Sizes included.
        // #340: appearance from the Settings picker (nil = follow the system).
        // The Info.plist UIUserInterfaceStyle=Dark enforcement is gone — it
        // would have overridden this modifier.
        .preferredColorScheme(settings.appearanceMode.colorScheme)
        // boc #485
        // The root lives while other tabs are visible. A published revision
        // catches even disconnect/reconnect cycles ending in the same state;
        // SwiftUI onChange may coalesce that cycle and preserve the old IP.
        .onReceive(tunnel.$routeRevision.dropFirst()) { _ in
            ipCheck.invalidateRoute()
            speed.invalidateRoute()
        }
        // eoc #485
        // #457 was: `.onChange(of: logsRouter.request) { if $1 != nil { selectedTab = 3 } }`
        // (#339) — the forced tab hop. Logs is pushed with its subject now.
        // #375: on every return to the foreground, re-read Keychain secrets. If
        // the device was locked at launch the encryption key was unreadable and
        // left empty (which would later surface as the misleading "key length 0");
        // re-hydrating after the user unlocks restores it before they Connect.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.rehydrateSecrets()
                tunnel.noteForeground()   // #432: log return + time spent backgrounded
                // #458: opening the app re-checks what you own, so the first
                // thing you see is current rather than whatever was true when
                // you last looked. Protocols only — the server's own SSH probe
                // needs credentials and runs when the Servers tab appears.
                // Debounced by `shouldProbe`, so returning to the foreground
                // repeatedly costs nothing, and it obeys the user's switch.
                // #470 was: `if SettingsStore.shared.refreshOnEntry { … }` on
                // EVERY `.active` — see `sweepOnActivate`.
                // #474: a return to the foreground is what re-arms automatic
                // checking; between two returns the app checks itself exactly
                // once, whichever screen asks first.
                // #477: a tunnel switched on from iOS Settings while the app was
                // away posts its status notification to a suspended process,
                // where nothing is listening and nothing is queued. Re-read it
                // on every return, before anything else decides what is running.
                // boc #485
                // #485 was: fire-and-forget adoption followed by an immediate
                // sweep, with every inactive/active round-trip rearming tabs.
                // Consume the real-reopen flag even when checking is disabled;
                // a consent prompt or Control Centre dismissal is not a reopen.
                let reopened = sweepOnActivate
                sweepOnActivate = false
                activationEpoch &+= 1
                let epoch = activationEpoch
                if reopened { HealthCoordinator.shared.noteForegrounded() }
                Task {
                    await ActivationRefresh.run(
                        adopt: { await tunnel.vpn.adoptRunningTunnel() },
                        isCurrent: { activationEpoch == epoch && scenePhase == .active },
                        refresh: {
                            if reopened, SettingsStore.shared.refreshOnEntry,
                               HealthCoordinator.shared.claimAutomaticSweep() {
                                HealthCoordinator.shared.verifyDue(store.connections, using: tunnel)
                            }
                        },
                        renew: { await telemostRenewal.checkNow() })
                }
                // eoc #485
            case .background:
                // #432: record the transition (loud if connected without keep-alive),
                // then fsync the logs so a following suspend/kill can't drop the tail.
                tunnel.noteBackground()
                LogStore.shared.flush()
                sweepOnActivate = true   // #470: the next activation is a real re-open
                activationEpoch &+= 1   // #485: invalidate an outstanding preference read
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        // boc #111: subscription links. olcrtc-sub://host/path → fetch
        // https://host/path (SubscriptionFetcher), parse the sub.md body,
        // then confirm before importing into the regular ConnectionStore.
        .onOpenURL { handleIncomingURL($0) }
        .alert(L10n.subImportTitle.localized(), isPresented: Binding(
            get: { subPrompt != nil },
            set: { if !$0 { subPrompt = nil; subSourceLink = nil } }   // #354/#356: clear provenance on dismiss
        )) {
            Button(L10n.subImportAddAction.localized()) { importSubscription() }
            Button(L10n.cancel.localized(), role: .cancel) { subPrompt = nil; subSourceLink = nil }
        } message: {
            Text(L10n.subImportConfirm_fmt.formatted(
                subPrompt?.entries.count ?? 0,
                subPrompt?.name ?? subSource))
        }
        .alert(L10n.subImportTitle.localized(), isPresented: Binding(
            get: { subError != nil },
            set: { if !$0 { subError = nil } }
        )) {
            Button(L10n.ok.localized()) { subError = nil }
        } message: {
            Text(subError ?? "")
        }
        // #366: confirm a full-access (co-admin) import behind a destructive
        // warning — it saves the VPS SSH password to this device.
        .alert(L10n.fullAccessImportTitle.localized(), isPresented: Binding(
            get: { fullAccessPrompt != nil },
            set: { if !$0 { fullAccessPrompt = nil } }
        )) {
            Button(L10n.fullAccessImportAddAction.localized(), role: .destructive) { importFullAccess() }
            Button(L10n.cancel.localized(), role: .cancel) { fullAccessPrompt = nil }
        } message: {
            Text(L10n.fullAccessImportBody_fmt.formatted(fullAccessPrompt?.label ?? ""))
        }
        // eoc #111
        .onAppear {
            // #412 was: `tunnel.secretsLocked = { store.secretsLocked }` wired here
            // (a forgettable step). It's now injected at construction in `init()`.
            guard !didAutoConnect else { return }
            didAutoConnect = true
            // #470: the catalog files this launch banner under OLC-1001, but
            // nothing ever passed the code, so the documented search found nothing.
            LogStore.shared.log(.connection, "▶ \(LogStore.appVersionString())", code: .sessionStart)  // OLC-1001
            // boc #477: the app can launch INTO a running tunnel — the profile
            // was left on, or switched on from iOS Settings while the app was
            // gone. Auto-connect used to fire regardless and start the in-app
            // proxy underneath it, putting a SECOND client with the same id into
            // the carrier room; two clients sharing an id break each other.
            // Adopt first, then decide — which is why this moved into the Task.
            // #477 was: `Task { await …adoptRunningTunnel() }` followed by an
            // unconditional auto-connect on the same turn (the adopt lost the race).
            Task {
                await tunnel.vpn.adoptRunningTunnel()
                guard settings.autoConnectOnLaunch, let p = store.primary else { return }
                guard !tunnel.systemTunnelIsUp else {
                    LogStore.shared.log(.connection,
                        "▶ Auto-connect skipped — the system VPN tunnel is already carrying the device")
                    return
                }
                LogStore.shared.log(.connection,
                    "▶ Auto-connect on launch → \(p.displayName)")
                // #393: the secretsLocked guard now lives in TunnelManager.connect,
                // so this direct call is covered too (was the #375 gap).
                tunnel.connect(record: p)
            }
            // eoc #477
        }
        // #360: interval-gated, anonymous GitHub-Releases update check. No-op
        // when disabled or checked within 24h; tolerates failure silently. On a
        // newer release it sets `available`, which raises the sheet below.
        .task { await updateChecker.checkIfDue() }
        // #362: on launch, silently re-fetch any subscription source whose
        // `#refresh` interval has elapsed (the import diff dedups, so servers
        // update in place). A per-source fetch failure is logged and skipped —
        // no modal on a background refresh. A manual pull-to-refresh reuses the
        // same `store.refreshDueSources()` trigger (exposed from the store).
        .task { await store.refreshDueSources() }
        // #465: a Telemost link dies 24 h after it is created, and the tunnel —
        // the only road to the VPS in a whitelist window — dies with it. This
        // loop replaces the room before that happens, choosing a moment the user
        // cannot feel. Sleeps and re-checks rather than returning: an id-less
        // `.task` never restarts.
        .task { await telemostRenewal.run() }
        // #465: raised ONLY when the room is nearly gone and the tunnel is busy,
        // i.e. the user is at the phone right now — which is what makes an alert
        // the right channel here rather than a badge nobody would see.
        // #485 was: every notice claimed a known expiry, even an imported room
        // with unknown age or a failed server-side application.
        .alert(telemostRenewal.warning?.title ?? L10n.telemostExpiryTitle.localized(), isPresented: Binding(
            get: { telemostRenewal.warning != nil },
            set: { if !$0 { telemostRenewal.dismissWarning() } }
        )) {
            // #469 was: `Task { await telemostRenewal.renewFromWarning() }`. The
            // Task is deferred; SwiftUI's dismissal writes `isPresented = false`
            // first (→ dismissWarning → warning = nil), so by the time the Task
            // ran the warning was gone and the renew returned without doing
            // anything — "Renew now" was a no-op. Capture the record while the
            // alert content is built, when the warning is still there.
            let expiringID = telemostRenewal.warning?.id
            // #485: setup/recovery notices must not offer an operation that
            // cannot repair them. The coordinator owns each notice's meaning.
            if telemostRenewal.warning?.canRenew == true {
                Button(L10n.telemostExpiryRenewAction.localized()) {
                    if let id = expiringID { Task { await telemostRenewal.renew(recordID: id) } }
                }
            }
            Button(L10n.later.localized(), role: .cancel) { telemostRenewal.dismissWarning() }
        } message: {
            Text(telemostRenewal.warning?.message ?? "") // #485: no invented room age
        }
        .sheet(item: $updateChecker.available) { update in
            UpdateAvailableSheet(update: update)
        }
    }

    // boc #111: subscription-link handling

    /// Entry point for URLs opened with the app's registered schemes.
    /// `olcrtc-sub://` fetches and imports a whole list; #354: a bare
    /// `olcrtc://` link routes into the *same* confirm-then-add sheet for the
    /// single connection it encodes (instead of doing nothing).
    private func handleIncomingURL(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "olcrtc-sub": handleSubscriptionURL(url)
        case "olcrtc":
            // #366: a full-access (co-admin) link is `olcrtc://host/v1/…`; a
            // plain connection link is `olcrtc://<carrier>?…` (#354).
            if FullAccessShare.isFullAccessLink(url.absoluteString) {
                handleFullAccessURL(url)
            } else {
                handleConnectionURL(url)
            }
        default:           break
        }
    }

    private func handleSubscriptionURL(_ url: URL) {
        // olcrtc-sub:// → https swap; the canonical sub link keys the dedup.
        guard let fetchURL = try? OlcrtcSubscription.httpsURL(from: url) else {
            subError = OlcrtcSubscription.SubError.invalidSubURL.errorDescription
            return
        }
        fetchAndPromptSubscription(fetchURL: fetchURL, sourceLink: url.absoluteString)
    }

    /// #361: fetch a subscription body from `fetchURL` (HTTPS), parse it, and raise
    /// the confirm prompt. `sourceLink` keys the #356 dedup/refresh bookkeeping —
    /// the original olcrtc-sub:// link for a deep link, or the https URL itself for
    /// a pasted https subscription. Shared by `handleSubscriptionURL` and the paste
    /// route.
    private func fetchAndPromptSubscription(fetchURL: URL, sourceLink: String) {
        Task {
            do {
                LogStore.shared.log(.connection,
                    "⬇ subscription fetch → \(fetchURL.host ?? fetchURL.absoluteString)")
                let body = try await SubscriptionFetcher.fetch(from: fetchURL)
                try presentSubscriptionPrompt(
                    OlcrtcSubscription.parse(body),
                    sourceLink: sourceLink,
                    fallbackSource: fetchURL.host ?? fetchURL.absoluteString)
            } catch {
                LogStore.shared.log(.connection,
                    "✗ subscription import failed: \(error.localizedDescription)")
                subError = error.localizedDescription
            }
        }
    }

    /// #361: validate a parsed subscription and raise the confirm prompt, or throw
    /// `emptySubscription`. Factored out so the deep-link, https-paste, and
    /// raw-body-paste routes all confirm the same way.
    private func presentSubscriptionPrompt(_ sub: OlcrtcSubscription,
                                           sourceLink: String?,
                                           fallbackSource: String) throws {
        guard !sub.entries.isEmpty else {
            throw OlcrtcSubscription.SubError.emptySubscription
        }
        if sub.skippedURIs > 0 {
            LogStore.shared.log(.connection,
                "⚠ subscription: skipped \(sub.skippedURIs) unparseable URI line(s)")
        }
        subSource     = sub.name ?? fallbackSource
        subSourceLink = sourceLink
        subPrompt     = sub
    }

    /// #361: route a blob pasted into the AddConnection import box. A single
    /// olcrtc:// link is left to the editor (it fills the fields); the subscription
    /// routes (https URL / raw sub.md body) come here and join the same
    /// confirm-then-import + #356 dedup flow as a deep link.
    private func handlePastedImport(_ input: OlcrtcSubscription.ImportInput) {
        switch input {
        case .subscriptionURL(let url):
            // HTTPS-only (preserve the ATS / #008–#009 posture). olcrtc-sub:// is
            // swapped to https; a plain https URL is fetched as-is and keys dedup
            // on itself.
            if url.scheme?.lowercased() == "olcrtc-sub" {
                handleSubscriptionURL(url)
            } else if url.scheme?.lowercased() == "https" {
                fetchAndPromptSubscription(fetchURL: url, sourceLink: url.absoluteString)
            } else {
                subError = OlcrtcSubscription.SubError.invalidSubURL.errorDescription
            }
        case .subscriptionBody(let body):
            // Raw sub.md text — parse in place; no source link, so this is a plain
            // (non-deduping) add, like a single olcrtc:// link (#354).
            do {
                try presentSubscriptionPrompt(
                    OlcrtcSubscription.parse(body),
                    sourceLink: nil,
                    fallbackSource: L10n.subImportPastedSource.localized())
            } catch {
                subError = error.localizedDescription
            }
        case .connectionURI, .unrecognized:
            break   // the editor handles a single link; unrecognized → no-op
        }
    }

    /// #354: a single olcrtc:// link → the same confirm-then-add sheet, wrapped
    /// as a one-entry list with no source link (plain add, no subscription
    /// dedup/provenance).
    private func handleConnectionURL(_ url: URL) {
        do {
            // #398 was: a local raw-then-percent-decoded fallback here. That
            // normalization now lives inside OlcrtcURI.parse, so every caller
            // (paste / QR / subscription body) handles encoded URIs the same way.
            let parsed = try OlcrtcURI.parse(url.absoluteString)
            var sub = OlcrtcSubscription()
            sub.entries = [OlcrtcSubscription.Entry(parsed: parsed, name: nil)]
            subSource     = parsed.mimo.isEmpty ? "\(parsed.carrier) · \(parsed.transport)" : parsed.mimo
            subSourceLink = nil
            subPrompt     = sub
        } catch {
            LogStore.shared.log(.connection,
                "✗ olcrtc:// link parse failed: \(error.localizedDescription)")
            subError = error.localizedDescription
        }
    }

    /// #366: a full-access (co-admin) `olcrtc://host/v1/…` link → parse and raise
    /// the destructive confirm; `importFullAccess` then adds BOTH the connection
    /// and the VPS host (with its SSH password) to this device.
    private func handleFullAccessURL(_ url: URL) {
        do {
            fullAccessPrompt = try FullAccessShare.parse(url.absoluteString)
        } catch {
            LogStore.shared.log(.connection, "✗ full-access link parse failed")
            subError = L10n.fullAccessImportInvalid.localized()
        }
    }

    /// #366: confirmed full-access import — add the connection (like #354) AND
    /// register the VPS host, writing its SSH password to the Keychain. The
    /// password is NEVER logged (only the action + the host coordinates).
    private func importFullAccess() {
        guard let fa = fullAccessPrompt else { return }
        // #383: parse the embedded connection URI FIRST and bail on failure — a
        // malformed URI must NOT silently store the VPS host + SSH password. (#383
        // was: the host add + success log sat OUTSIDE this guard, so a bad URI
        // wrote credentials to the Keychain with no connection and no error.)
        guard let p = try? OlcrtcURI.parse(fa.uri) else {
            LogStore.shared.log(.connection,
                "✗ full-access import failed: embedded connection URI is invalid — nothing stored")
            subError = L10n.fullAccessImportInvalid.localized()
            fullAccessPrompt = nil
            return
        }
        let params = OlcrtcConnection(from: p)   // #401: shared Parsed → connection mapping
        // boc #469: #384 dedups the VPS, but the connection was still `add`ed
        // unconditionally, so re-opening the same link (share-sheet retry, QR
        // rescan) grew a duplicate row every time — and the record was never
        // linked to the host, so the fresh card reported no connection at all.
        // Reuse the record for the same node (carrier + room + key) and link it.
        let connID: UUID
        if let same = store.connections.first(where: { rec in
            if case .olcrtc(let q) = rec.details {
                return q.carrier == params.carrier && q.roomID == params.roomID && q.key == params.key
            }
            return false
        }) {
            connID = same.id
            LogStore.shared.log(.connection,
                "⬇ full-access import: connection already saved (\(same.displayName)) — reused")
        } else {
            let record = ConnectionRecord(name: fa.label,
                                          groupName: ConnectionRecord.defaultGroupName,
                                          details: .olcrtc(params))
            store.add(record)
            connID = record.id
        }
        // eoc #469
        // #384: route the VPS host through the same dedup + #323 label-collision
        // checks AddServerHostView enforces, instead of a blind serverStore.add:
        // re-opening the same link refreshes the existing card (no duplicate VPS
        // / Keychain entry), and a label clashing with a *different* host is
        // disambiguated so the two don't share a `<prefix>_container.log`.
        let candidate = ServerHost(label: fa.label, host: fa.sshHost,
                                   port: fa.sshPort, username: fa.sshUsername)
        switch ServerHostStore.resolveImport(candidate, into: serverStore.hosts) {
        case .updateExisting(let existing):
            var linked = existing
            linked.lastConnectionID = connID   // #469: the card must know its own connection
            serverStore.update(linked, password: fa.sshPassword)
            LogStore.shared.log(.connection,
                "⬇ full-access import: refreshed VPS \(existing.label) (\(existing.username)@\(existing.host):\(existing.port))")
        case .addNew(let host):
            var linked = host
            linked.lastConnectionID = connID   // #469
            serverStore.add(linked, password: fa.sshPassword)
            LogStore.shared.log(.connection,
                "⬇ imported full-access: connection + VPS \(host.label) (\(host.username)@\(host.host):\(host.port))")
        }
        fullAccessPrompt = nil
    }

    /// #470: the record a plain olcrtc:// import already holds for this node, if
    /// any — matched on the same five connection-defining fields as
    /// `OlcrtcSubscription.Entry.nodeKey` (carrier, transport, room, key,
    /// clientID), never on the display name. Pure → tested (Review470Chunk3Tests).
    static func existingRecord(matching params: OlcrtcConnection,
                               in records: [ConnectionRecord]) -> ConnectionRecord? {
        records.first { rec in
            guard case .olcrtc(let q) = rec.details else { return false }
            return q.carrier == params.carrier && q.transport == params.transport
                && q.roomID == params.roomID && q.key == params.key
                && q.clientID == params.clientID
        }
    }

    /// Confirmed import. A real subscription (`subSourceLink != nil`) goes
    /// through the diffing store import (#356: add/update/remove, no dup); a
    /// plain olcrtc:// link (#354) is a one-off add of its single entry.
    private func importSubscription() {
        guard let sub = subPrompt else { return }
        if let source = subSourceLink {
            store.importSubscription(sub, source: source)   // #356
        } else {
            // #354: single connection, no subscription provenance.
            let group = sub.name ?? ConnectionRecord.defaultGroupName
            // boc #470: `store.add` has no dedup, so tapping the same shared link
            // twice (or scanning the same QR twice) grew two identical rows with
            // two Keychain entries, splitting the health chip, the primary and
            // the host link between them. Reuse the row for a node already saved.
            var added = 0
            var duplicate: ConnectionRecord?
            for entry in sub.entries {
                // #355: sei params carried through (defaults when a key is absent).
                // #401: via the shared Parsed → connection mapping.
                let params = OlcrtcConnection(from: entry.parsed)
                if let same = Self.existingRecord(matching: params, in: store.connections) {
                    duplicate = same
                    LogStore.shared.log(.connection,
                        "⬇ olcrtc:// import: \(same.displayName) is already saved — reused")
                    continue
                }
                store.add(ConnectionRecord(name: entry.recordName,
                                           groupName: group,
                                           details: .olcrtc(params)))
                added += 1
            }
            LogStore.shared.log(.connection,
                "⬇ imported \(added) of \(sub.entries.count) connection(s) from olcrtc:// link")
            // The user confirmed an "Add" that added nothing — say so, the same
            // way a bad full-access link reports through this alert (#383).
            if added == 0, let same = duplicate {
                subError = L10n.subImportAlreadySaved_fmt.formatted(same.displayName)
            }
            // eoc #470
        }
        subPrompt     = nil
        subSourceLink = nil
    }
    // eoc #111
}
