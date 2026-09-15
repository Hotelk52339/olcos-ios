import SwiftUI

// MARK: - ServersView
//
// #457: the SECOND of three tabs (Connect · Servers · Settings). Manages SSH
// credentials for the servers where we can install / uninstall olcrtc, plus
// triggers those operations from the device.
// #457 was: "Third tab" — it was the third of five before Config and Logs
// stopped being tabs.
//
// #258: SINGLE-SOURCE display model (replaces the old dual-source
// `statusIconInfo`, which read `provisioner.status` + per-host `readiness`
// together and wrote optimistic base states mid-flight — the cause of the
// "status jumps"). A host now shows exactly ONE of:
//   • .base(HostBase)            — what the server IS; set ONLY by a confirmed probe
//   • .running(op, phase, note)  — what we're DOING; steady amber, phases advance
//                                  forward only, never touches base state
//   • .failed(op, phase, msg)    — an op threw; shown over the last base, with Retry
// The dot stays amber for the whole operation and changes colour exactly once,
// at the terminal probe result (`.animation(.easeInOut, value: display)`).
//
// Status / phase strings here are hardcoded English to match this file's existing
// convention (the old statusIconInfo did the same); menu/action labels reuse the
// existing L10n cases. Promoting these to L10n is a separate cleanup.

struct ServersView: View {
    // boc #490
    // #490: presentation-only state transition; SSH scheduling stays unchanged.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var serverTransition: Animation? {
        reduceMotion ? nil : .easeOut(duration:
            ServerPresentationPolicy.transitionDuration(reduceMotion: reduceMotion))
    }
    // eoc #490

    @ObservedObject var serverStore: ServerHostStore
    @ObservedObject var connections: ConnectionStore
    // boc #457: `@ObservedObject var logsRouter: LogsRouter` is gone with the
    // Logs TAB. Container logs become a pushed, subject-scoped destination
    // (`LogsView(subject: .container(host))`) owned by the navigation layer —
    // a push carries its context for free, so the cross-tab back-channel
    // (`LogsRouter.request` + `MainTabView.onChange { selectedTab = 3 }` +
    // `fetchingHostID` + this file's `containerLogBusyStrip`) has nothing left
    // to do. Nothing here invents a route in its place.
    // #457 was: @ObservedObject var logsRouter: LogsRouter
    // eoc #457
    /// Per-tab lifecycle, NOT a shared singleton — intentional split from
    /// `TunnelManager.shared` / `SettingsStore.shared` / `LogStore.shared`.
    @StateObject  private var provisioner = Provisioner()
    /// #452: the tunnel, so a protocol row on the host card can connect directly
    /// ("pick which protocol to tunnel through, right from Manage VPS").
    @ObservedObject var tunnel: TunnelManager

    @State private var showAdd        = false
    @State private var editHost       : ServerHost?
    @State private var installFor     : ServerHost?
    // #452 was: reconfigureFor : ServerHost? — now a targeted request (container
    // + record + seed values), so a protocol row reconfigures ITS container.
    @State private var reconfigureRequest : ReconfigureRequest?
    /// #470: what the LAST reconfigure on each host targeted. `HostDisplay.failed`
    /// carries the op but not the container, so the card's Retry rebuilt the
    /// PRIMARY's request after a sibling-row failure — the expected outcome of
    /// renewing the live telemost carrier (#463) — and confirming it restarted
    /// the wrong container. Retry re-opens THIS request instead.
    @State private var lastReconfigure    : [UUID: ReconfigureRequest] = [:]
    // #339 was: logsPayload (ContainerLogsPayload?) — the container-logs sheet
    // is gone; the action routes to the Logs tab instead.
    // #258 was: readiness[id] + activeHostID (two competing display sources).
    // Now a single per-host display state; base is only ever set from a probe.
    @State private var display        : [UUID: HostDisplay] = [:]
    @State private var vpsStats       : [UUID: SSHRunner.VPSStats] = [:]
    @State private var pingLatencies  : [UUID: Double?] = [:]   // ms, nil=unreachable, absent=not pinged
    // #374: when each host was last probed, so the periodic sweep only re-pings
    // hosts whose last ping is older than the interval (instead of every host
    // every tick). Absent → never pinged → due immediately.
    @State private var lastPing       : [UUID: Date] = [:]
    // boc #456: when each host was last SSH-probed for readiness. Stamped on
    // BOTH the success and the failure path, so a dead host isn't hammered.
    @State private var lastProbe      : [UUID: Date] = [:]
    // #456 (audit): when a readiness probe last actually RETURNED a container
    // reading. Split from `lastProbe` (the attempt clock) because a FAILED probe
    // stamped `lastProbe` too — which told the card "checked just now" over the
    // previous, possibly hours-old, base, and suppressed the honest
    // "not checked yet" headline. This is the clock the card displays
    // (requirement 3: an age the user sees must be the age of the reading).
    @State private var lastProbeOK    : [UUID: Date] = [:]
    /// #456: re-entrancy guard for the on-entry refresh pass (requirement 4).
    @State private var entryRefreshing = false
    /// #456: an install about to run on a host that already carries olcrtc
    /// containers — scripts/srv.sh force-removes EVERY `olcrtc-server-*` before
    /// installing, so the user gets a choice instead of a silent wipe.
    @State private var installChoice  : InstallChoiceRequest?
    // eoc #456
    @State private var scanFor        : ServerHost?
    /// #457 (audit fix): the server whose container log is being pushed. The
    /// "Container logs" menu item was deleted with the Logs TAB, but its
    /// replacement push was never wired, so container logs became unreachable —
    /// a regression, not a simplification. Menu items are closures here, not
    /// links, so the push is driven by this optional.
    @State private var logsForHost    : ServerHost?
    /// #469: why the last silent probe of a host FAILED (SSH auth, host key,
    /// timeout). Without it a failed auto-check left the card on "Checking the
    /// server…" for the rest of the session — a dead end with no reason.
    @State private var lastProbeError : [UUID: String] = [:]
    /// Endpoint-scoped, backend-reported changed-key failures only. Never trust
    /// status, key material or a first-connection requirement.
    @State private var hostKeyMismatchEndpoints: Set<String> = []
    /// #459: the server whose "Manage server" screen is pushed — everything
    /// rare or destructive that used to sit in the card's 13-item ⋯ menu.
    // #459 (audit fix): its own wrapper type, NOT a second `ServerHost?`.
    // `navigationDestination(item:)` requires `D: Hashable` because it appends
    // the value to the stack's path and then resolves a destination registered
    // for that TYPE — so two of them bound to `ServerHost?` on one stack are two
    // registrations for one type, and the one closest to the root wins. With
    // both keyed on `ServerHost`, `logsForHost` would have pushed the Manage
    // screen and container logs would have been unreachable again — the exact
    // regression the #457 audit note above is about.
    @State private var advancedForHost: AdvancedHostRoute?
    @State private var foundContainers: [SSHRunner.FoundContainer] = []
    @State private var shareServer    : ServerShareRequest?   // card "Share": pick a protocol or full access
    @State private var alertText           : String?
    @State private var removeHost          : ServerHost?
    @State private var uninstallConfirmHost    : ServerHost?
    @State private var deepUninstallConfirmHost: ServerHost?
    @State private var rebootConfirmHost       : ServerHost?
    // #303: confirm before recovering/adding a ConnectionRecord from an
    // already-installed-but-unlinked host (#302 auto-detect with no
    // lastConnectionID).
    @State private var recoverConfirmHost      : ServerHost?
    // #314: fallback when #303 recovery finds server.yaml unreadable or
    // unparseable — confirm before rotating ~/.olcrtc_key (destructive for
    // every other client of that server).
    @State private var rotateKeyConfirmHost    : ServerHost?
    // boc #452: multi-carrier host card. `carrierRows` caches the per-host
    // protocol list (SSHRunner.CarrierInfo, from provisioner.listCarriers);
    // the request states drive the add-protocol sheet, the remove confirm and
    // the per-row recover confirm; `carrierBusyHostID` serializes the
    // outside-`run` protocol ops (add/remove/sibling start/stop), mirroring
    // how rotateKey/recoverConnection run without a HostOp.
    @State private var carrierRows          : [UUID: [SSHRunner.CarrierInfo]] = [:]
    // boc #470: the row list's own clocks. `carrierListInFlight` is the hosts
    // whose `listCarriers` is running right now — the card's lazy first load
    // and the on-entry pass both fired it on first entry, two SSH logins racing
    // for `carrierRows`. `carrierRowsAt` is when each host's rows were last
    // actually READ, so the entry pass can skip a listing the card just made.
    @State private var carrierListInFlight  : Set<UUID> = []
    /// Hosts whose background readiness probe is running right now — drives
    /// the card's quiet "updating…" note over the last known snapshot.
    @State private var probingHostIDs       : Set<UUID> = []
    @State private var carrierRowsAt        : [UUID: Date] = [:]
    // eoc #470
    @State private var addProtocolFor       : ServerHost?
    @State private var removeCarrierConfirm : CarrierRemoveRequest?
    @State private var recoverRowRequest    : CarrierRecoverRequest?
    @State private var carrierBusyHostID    : UUID?
    // eoc #452
    // boc #463: one-button Telemost room renewal. A Telemost link dies after 24
    // hours, and the manual cure (create a room in a browser, deliver the id
    // over SSH) needs exactly the channel a whitelist window blocks. `telemostRenew`
    // is the request the sheet is presented for (a value snapshot, the #330
    // rule); `telemostPhase` is the operation's state — ONE property, because
    // the SSH lane is serialized and only one renewal can ever be in flight;
    // `telemostAccount` mirrors whether a Yandex session is stored, refreshed
    // rather than observed so this file depends on no observability contract.
    @State private var telemostRenew        : TelemostRenewRequest?
    @State private var telemostPhase        : TelemostRoomPhase = .idle
    /// #470: WHICH row's renewal `telemostPhase` describes (its container id).
    /// The premise above — one renewal in flight, so one phase — held only
    /// while the SSH lane was busy; the room-creation half runs before any SSH
    /// op starts, and the sheet can be dismissed at any time. Opening another
    /// telemost row then reset the phase the running renewal kept writing, and
    /// its `.done(room)` landed in whichever sheet was open. A sheet now reads
    /// the phase only when it is about its own row, and `renewTelemostRoom`
    /// holds `carrierBusyHostID` for its whole duration, so a second renewal
    /// cannot start beside it.
    @State private var telemostPhaseOwner   : String?
    @State private var telemostAccount      = false
    // eoc #463
    // #374 was: pingTimer (Timer?) — a repeating Timer that re-pinged EVERY host
    // every tick, even mid-op. #474: there is no repeating pass at all now — one
    // staggered sweep on entry, and the pull.

    @ObservedObject private var settings = SettingsStore.shared
    /// #456: the ONE owner of measured evidence. Every green on this tab now
    /// traces back to a recent end-to-end probe recorded here — podman "Up"
    /// proves a process exists, nothing more (the user's telemost container was
    /// Up while its own logs read "session closed reason=liveness", in=0 out=0).
    /// Observed exactly like `settings`, so a probe result redraws the rows.
    @ObservedObject private var health = HealthCoordinator.shared

    // boc #459: `coreStack` was one `NavigationStack { List { … } }` carrying
    // the whole lifecycle chain inline. Pull-to-refresh (requirement 6) and the
    // inline title are two more modifiers on an expression this file has already
    // blown the type-checker's budget on three times, so the chain is split by
    // kind ONE level further: the List is its own tiny expression, the two
    // pushes sit in `hostDestinations`, and everything else is `listChrome`.
    // Same view, same order, no expression over 8 modifiers.
    private var coreStack: some View {
        NavigationStack {
            // #461: a FOURTH wrapper (`listBars`) rather than three more
            // modifiers on `listChrome` — this file has hit the type-checker's
            // budget three times and `listChrome` already carries eight.
            // #461 was: listChrome(hostDestinations(hostList))
            listBars(listChrome(hostDestinations(hostList)))
        }
    }

    private var hostList: some View {
        List {
            // #456 was: matrixSection — a build-time lab table shown as if it
            // described today. Deleted: the card carries measured evidence now.

            if serverStore.hosts.isEmpty {
                emptyState
            } else {
                ForEach(serverStore.hosts) { host in
                    hostCard(host)
                }
                // #470 was: `.onDelete { serverStore.remove(at: $0) }` — a
                // swipe deleted the host AND its Keychain SSH password / private
                // key on the spot, while the same verb on the Manage screen asks
                // first. Both paths now end in `hostConfirmations`' dialog.
                .onDelete { offsets in
                    removeHost = offsets.first.flatMap {
                        serverStore.hosts.indices.contains($0) ? serverStore.hosts[$0] : nil
                    }
                }
                // #471 was: `listFooter` — a FOURTH age ("checked 2 min ago"),
                // centred under the last card, restating the oldest of the ages
                // each card already prints beside its own claim.
            }
        }
    }

    /// #459: the two pushes. They live INSIDE the NavigationStack's content —
    /// `navigationDestination` is collected from the content by the stack, so a
    /// declaration applied to the NavigationStack itself (where `logsForHost`'s
    /// used to sit, in `hostSheets`) is not part of that content.
    @ViewBuilder
    private func hostDestinations(_ content: some View) -> some View {
        content
            // #457 (audit fix): the destination behind the "Container logs"
            // action. A push, not a tab hop — the log opens already scoped to
            // this server, so nothing has to re-derive which host it was about.
            .navigationDestination(item: $logsForHost) { host in
                LogsView(subject: .container(host),
                         serverStore: serverStore,
                         connections: connections)
            }
            // #459: everything rare or destructive, one deliberate step away.
            // Its item type is `AdvancedHostRoute`, not `ServerHost` — see the
            // note on the `advancedForHost` state above.
            .navigationDestination(item: $advancedForHost) { route in
                advancedView(route.host)
            }
    }

    @ViewBuilder
    private func listChrome(_ content: some View) -> some View {
        content
            // #459: inline. The tab bar directly below already says "Servers",
            // so a 34pt second copy of that word spent ~52pt of a screen the
            // owner described as half empty — the same waste #457 took off
            // Connect. The card grows into what this gives back.
            // #459 was: a large-title band, defended by #457's note that the
            // title "names the content, not the brand" — true, and still not
            // worth 52pt to say a word the tab bar is already saying.
            .navigationTitle(L10n.serversTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // #359: icon-only "+" needs an a11y label (reused newServerTitle).
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                            .frame(minWidth: Theme.Metrics.controlHeight,
                                   minHeight: Theme.Metrics.controlHeight) // #490: native touch floor.
                    }
                        .accessibilityLabel(L10n.newServerTitle.localized())
                }
            }
            // #459: requirement 6 — the same gesture as Connections, doing the
            // same job one layer down: re-read the servers, then re-verify what
            // runs on them.
            .refreshable { await refreshAllHosts() }
            // Lifecycle-bound first readings: SwiftUI cancels the task when the
            // view disappears. IDs only, so a probe's own host metadata writes
            // do not restart the pass.
            .task(id: serverStore.hosts.map(\.id)) {
                seedFromSnapshots()
                // Round 2 (D): the first frame is drawn from the seeded
                // snapshot alone; sockets open ≈300 ms later.
                guard await Self.deferPastFirstFrame() else { return }
                await autoPingOnce()
                await checkNeverProbedHosts()
            }
            // Entering the tab shows the persisted snapshot at once and
            // re-checks in the background, throttled per host.
            // Round 2 (D): the pass is DEFERRED past the first frame. It used
            // to start in the same run-loop turn as the appearance — the
            // Keychain read in `silentProbe`, the JSON encode + UserDefaults
            // write `pruneDanglingLinks` may do, and the SSH dial all competed
            // with the tab transition. Nothing about WHAT runs changed: once
            // per foreground (`claimServerPass`), 60 s per host
            // (`shouldRecheckHost`), pull-to-refresh forced.
            .onAppear {
                seedFromSnapshots()
                Task(priority: .utility) {
                    guard await Self.deferPastFirstFrame() else { return }
                    await refreshOnEntry()
                }
            }
            // #469 was: `.onDisappear { health.cancelAll() }` — both tabs verify
            // the SAME records through ONE sequential coordinator, and a tab
            // switch fires the new tab's onAppear and the old tab's onDisappear
            // in the same turn: the sweep the new tab had just scheduled was
            // cancelled before its first probe. "Check on opening" silently did
            // nothing on every Servers → Connections switch.
            // eoc #456
            // #258: route the provisioner's progress stream into the running host's
            // phase/subtitle ONLY — never the base state or the dot colour.
            .onChange(of: provisioner.status) { _, status in
                guard case .running(let msg) = status else { return }
                advancePhase(note: msg)
            }
    }
    // eoc #459

    // boc #461: the other half of "why is *checked 4 min ago* down at the bottom
    // there, where you can barely see it?" — the last card was ending UNDER THE
    // TAB BAR.
    //
    // A tab bar uses its transparent SCROLL-EDGE appearance while the scroll
    // view is at the bottom — which is exactly where the user is when they read
    // the last card on this list — so the content does not disappear behind the
    // bar, it shows THROUGH it. Forcing the bar to draw its background is the
    // fix; visibility only, no style argument, so it keeps the SYSTEM material
    // it would otherwise show and this tab's bars still look like every other
    // tab's. The navigation bar gets the same treatment for the same reason at
    // the other end, and for parity with ConnectionsView.
    //
    // The bottom content margin braces that belt: the last card gets the same
    // breathing room above the tab bar that a section gets from its neighbour,
    // instead of ending flush against it.
    //
    // This is #460's ConnectionsView fix (`ConnectionsView.listBars`), whose own
    // note asks for it here in as many words. NOTE for the tab that still wants
    // it: LogsView (`.scrollContentBackground(.hidden)`, line ~149) has neither
    // `toolbarBackground` call nor the margin; SettingsView has both
    // `toolbarBackground`s and no margin.
    private func listBars(_ content: some View) -> some View {
        content
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .tabBar)
            .contentMargins(.bottom, Theme.Metrics.s6, for: .scrollContent)
            // #471: the token grid used to stop at the card edge. Inside a card
            // blocks are 20pt apart; between cards the gap was `olcCardRow`'s
            // 8 + 8 PLUS the List's ~35pt default section spacing — ≈51pt
            // outside against 20 inside, a 2.5x ratio, which is exactly why the
            // screen read "half empty" while each card read "a dense slab".
            // 8 + 16 + 8 = 32 = `s7`, "screen-level separation", and 1.6x the
            // in-card block gap. Here rather than in `listChrome`, which
            // already carries eight modifiers (this file has blown the
            // type-checker's budget three times).
            .listSectionSpacing(Theme.Metrics.s4)
            // boc #490
            // #490 was: the system List ground behind all-in-one cards.
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.bg)
            .tint(Theme.Signal.stroke)
            // eoc #490
    }
    // eoc #461

    // boc #471 was: `listFooter` + `oldestReadDate` — "checked 2 min ago",
    // centred under the last card.
    //
    // #459 called it "the one fact worth the space under the last card". It is
    // the fourth place that fact was written: the status pill dates its own
    // claim, every protocol chip carries its own age, and `readStamp` (also
    // deleted) said it a third time 8pt under the pill. An age that qualifies
    // NOTHING in particular — the oldest reading among all hosts on screen —
    // cannot be acted on; an age beside the claim it dates can. Each card dates
    // itself now (`HostHeadline.reduce`), so the footer has nothing left to add.
    // eoc #471

    // #457 (audit fix): ServersView.coreStack carried 21 chained modifiers in a
    // single expression and CI failed with "unable to type-check this expression
    // in reasonable time" — the third time this file has hit that budget. The
    // chain is split by KIND: the List and its lifecycle stay in coreStack, the
    // presentation modifiers live in these wrappers. Same view, same order.
    // #459: that split went one level further — the lifecycle chain is
    // `listChrome` and the two pushes are `hostDestinations`, both applied
    // INSIDE the NavigationStack. These wrappers stay outside it, which is
    // correct for sheets, alerts and dialogs, and wrong for a
    // `navigationDestination` (see `hostDestinations`).
    @ViewBuilder
    private func hostSheets(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showAdd) {
                // Guided add flow: access → probe → protocols → room → install.
                // The store must hold the secret before `install` runs, because
                // the installer resolves credentials from the store.
                AddServerFlowView(otherLabels: serverStore.hosts.map(\.label),
                                  serverStore: serverStore,
                                  connections: connections,
                                  provisioner: provisioner) { host, secret, primary, extras in
                    serverStore.add(host, secret: secret)
                    Task { await install(host, primary: primary, extras: extras) }
                }
            }
            .sheet(item: $editHost) { host in
                // #451: prefill all credential kinds; `password(for:)` returns
                // the key text for key hosts, so gate it on authMethod and use
                // the dedicated accessors for the key fields.
                AddServerHostView(existing: host,
                                  existingPassword: host.authMethod == .privateKey
                                      ? nil : serverStore.password(for: host),
                                  existingKey: serverStore.privateKey(for: host),
                                  existingPassphrase: serverStore.keyPassphrase(for: host),
                                  otherLabels: serverStore.hosts.filter { $0.id != host.id }.map(\.label)) { updated, secret in
                    serverStore.update(updated, secret: secret)
                }
            }
            // #459 was: `.navigationDestination(item: $logsForHost)` — declared
            // HERE, i.e. on the NavigationStack itself rather than on its
            // content, where the stack cannot collect it. Moved into
            // `hostDestinations`, inside the stack, with the new one.
            .sheet(item: $installFor) { host in
                // #452: multi-protocol install plan (primary + extras).
                InstallOptionsView { primary, extras in
                    Task { await install(host, primary: primary, extras: extras) }
                }
            }
            .sheet(item: $reconfigureRequest) { req in
                // #452: targeted at one protocol's container (value snapshot,
                // #330 rule) and seeded from its current carrier/transport/room.
                // #456: also seeded with the wbstream token and the jitsi
                // instance the record already carries — a blank field here used
                // to DELETE the server's auth.token on confirm.
                ReconfigureOptionsView(initialCarrier: req.initialCarrier,
                                       initialTransport: req.initialTransport,
                                       initialRoom: req.initialRoom,
                                       initialWbToken: req.initialWbToken,
                                       initialJitsiBase: req.initialJitsiBase) { options in
                    Task {
                        await reconfigure(req.host, containerName: req.containerName,
                                          recordID: req.recordID, options: options)
                    }
                }
            }
            .sheet(item: $scanFor) { host in
                containerScanSheet(host: host)
            }
            .sheet(item: $shareServer) { req in
                ServerShareSheet(hostLabel: req.hostLabel, options: req.options,
                                 fullAccess: req.fullAccess,
                                 startWithFullAccess: req.startWithFullAccess)
            }
    }

    @ViewBuilder
    private func hostConfirmations(_ content: some View) -> some View {
        content
            .alert(L10n.okPrompt.localized(), isPresented: Binding(
                get: { alertText != nil },
                set: { if !$0 { alertText = nil } }
            )) {
                Button(L10n.ok.localized()) { alertText = nil }
            } message: {
                Text(alertText ?? "")
            }
            .confirmationDialog(
                removeHost.map { L10n.removeHostConfirmTitle_fmt.formatted($0.label) } ?? "",
                isPresented: Binding(
                    get: { removeHost != nil },
                    set: { if !$0 { removeHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: removeHost
            ) { host in
                Button(L10n.actionRemoveFromList.localized(), role: .destructive) {
                    removeFromList(host)
                    removeHost = nil
                    advancedForHost = nil   // #459: pop "Manage server" — its subject is gone
                }
                Button(L10n.cancel.localized(), role: .cancel) { removeHost = nil }
            } message: { _ in
                Text(L10n.removeHostConfirmMessage.localized())
            }
            .confirmationDialog(
                L10n.uninstallConfirmTitle.localized(),
                isPresented: Binding(
                    get: { uninstallConfirmHost != nil },
                    set: { if !$0 { uninstallConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: uninstallConfirmHost
            ) { host in
                Button(L10n.actionUninstall.localized(), role: .destructive) {
                    uninstallConfirmHost = nil
                    advancedForHost = nil   // #459: back to the card, where the op's progress shows
                    Task { await uninstall(host) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { uninstallConfirmHost = nil }
            } message: { _ in
                Text(L10n.uninstallConfirmBody.localized())
            }
            .confirmationDialog(
                L10n.actionDeepUninstall.localized(),
                isPresented: Binding(
                    get: { deepUninstallConfirmHost != nil },
                    set: { if !$0 { deepUninstallConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: deepUninstallConfirmHost
            ) { host in
                Button(L10n.actionDeepUninstall.localized(), role: .destructive) {
                    deepUninstallConfirmHost = nil
                    advancedForHost = nil   // #459
                    Task { await deepUninstall(host, removeImage: false) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { deepUninstallConfirmHost = nil }
            } message: { _ in
                Text(L10n.deepUninstallConfirmBody.localized())
            }
            .confirmationDialog(
                L10n.rebootConfirmTitle.localized(),
                isPresented: Binding(
                    get: { rebootConfirmHost != nil },
                    set: { if !$0 { rebootConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: rebootConfirmHost
            ) { host in
                Button(L10n.actionReboot.localized(), role: .destructive) {
                    rebootConfirmHost = nil
                    advancedForHost = nil   // #459
                    Task { await reboot(host) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { rebootConfirmHost = nil }
            } message: { _ in
                Text(L10n.rebootConfirmBody.localized())
            }
            // #303: recover/add a ConnectionRecord from this host's deployed
            // server.yaml — read-only on the server, only adds locally.
            .confirmationDialog(
                L10n.recoverConfirmTitle.localized(),
                isPresented: Binding(
                    get: { recoverConfirmHost != nil },
                    set: { if !$0 { recoverConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: recoverConfirmHost
            ) { host in
                Button(L10n.recoverConfirmAction.localized()) {
                    recoverConfirmHost = nil
                    advancedForHost = nil   // #459
                    Task { await recoverConnection(host) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { recoverConfirmHost = nil }
            } message: { _ in
                Text(L10n.recoverConfirmBody.localized())
            }
            // #314: #303's fallback branch — server.yaml was unreadable or
            // unparseable, so offer to generate a new key (rotate ~/.olcrtc_key,
            // repair server.yaml, restart) instead of just failing. Destructive:
            // the new key cuts off every other client of this server.
            .confirmationDialog(
                L10n.rotateKeyConfirmTitle.localized(),
                isPresented: Binding(
                    get: { rotateKeyConfirmHost != nil },
                    set: { if !$0 { rotateKeyConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: rotateKeyConfirmHost
            ) { host in
                Button(L10n.rotateKeyConfirmAction.localized(), role: .destructive) {
                    rotateKeyConfirmHost = nil
                    Task { await rotateKey(host) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { rotateKeyConfirmHost = nil }
            } message: { _ in
                Text(L10n.rotateKeyConfirmBody.localized())
            }
    }

    var body: some View {
        // #452: the multi-carrier modals (add-protocol sheet, remove/recover
        // confirms) are split off the main chain — with them inline the Swift
        // type-checker timed out on ServersView.body ("unable to type-check
        // this expression in reasonable time").
        // #457: three wrappers instead of one 21-modifier expression.
        observeHostKeyStatus(carrierModals(hostConfirmations(hostSheets(coreStack))))
    }

    /// Read-only status observation covers failures from every SSH entry point,
    /// including Logs/Bot/renewal while this tab is offscreen. It never dials.
    private func observeHostKeyStatus(_ content: some View) -> some View {
        content
            .onAppear { refreshHostKeyMismatchStatus() }
            .onReceive(NotificationCenter.default.publisher(for: SSHHostKeyTrustStore.statusDidChange)
                .receive(on: RunLoop.main)) { _ in
                refreshHostKeyMismatchStatus()
            }
            .onChange(of: serverStore.hosts) { _, _ in
                refreshHostKeyMismatchStatus()
            }
    }

    private func refreshHostKeyMismatchStatus() {
        hostKeyMismatchEndpoints = Set(serverStore.hosts.compactMap { host -> String? in
            guard SSHHostKeyTrustStore.shared.hasMismatch(host: host.host, port: host.port) else {
                return nil
            }
            return SSHHostKeyVerification.endpoint(host: host.host, port: host.port)
        })
    }

    @ViewBuilder
    private func carrierModals(_ content: some View) -> some View {
        content
            .sheet(item: $addProtocolFor) { host in
                InstallOptionsView(limitToCarriers: missingCarriers(host),
                                   singleOnly: true) { options, _ in
                    Task { await addCarrier(host, options: options) }
                }
            }
            .confirmationDialog(
                removeCarrierConfirm.map {
                    L10n.removeProtocolConfirmTitle_fmt.formatted(
                        CarrierTransportMatrix.carrierLabel($0.row.provider))
                } ?? "",
                isPresented: Binding(
                    get: { removeCarrierConfirm != nil },
                    set: { if !$0 { removeCarrierConfirm = nil } }
                ),
                titleVisibility: .visible,
                presenting: removeCarrierConfirm
            ) { req in
                Button(L10n.removeProtocolAction.localized(), role: .destructive) {
                    removeCarrierConfirm = nil
                    Task { await removeCarrier(req.host, row: req.row) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { removeCarrierConfirm = nil }
            } message: { _ in
                Text(L10n.removeProtocolConfirmBody.localized())
            }
            .confirmationDialog(
                L10n.recoverConfirmTitle.localized(),
                isPresented: Binding(
                    get: { recoverRowRequest != nil },
                    set: { if !$0 { recoverRowRequest = nil } }
                ),
                titleVisibility: .visible,
                presenting: recoverRowRequest
            ) { req in
                Button(L10n.recoverConfirmAction.localized()) {
                    recoverRowRequest = nil
                    Task {
                        await recoverConnection(req.host, containerName: req.container,
                                                configFile: req.file, asExtra: !req.isPrimary)
                    }
                }
                Button(L10n.cancel.localized(), role: .cancel) { recoverRowRequest = nil }
            } message: { _ in
                Text(L10n.recoverConfirmBody.localized())
            }
            // boc #456: requirement 8 — installing over an existing deployment
            // offers "use the existing one" instead of destroying it (and then
            // re-asking for the room ID the server already knows). Lives here,
            // with the other carrier modals, so `coreStack`'s modifier chain
            // stays inside the type-checker's budget.
            .confirmationDialog(
                installChoice.map {
                    L10n.installExistingFoundTitle_fmt.formatted($0.found.first?.name ?? "")
                } ?? "",
                isPresented: Binding(
                    get: { installChoice != nil },
                    set: { if !$0 { installChoice = nil } }
                ),
                titleVisibility: .visible,
                presenting: installChoice
            ) { req in
                Button(L10n.installUseExistingAction.localized()) {
                    installChoice = nil
                    adoptExisting(req)
                }
                Button(L10n.installReinstallAction.localized(), role: .destructive) {
                    installChoice = nil
                    installFor = req.host
                }
                Button(L10n.cancel.localized(), role: .cancel) { installChoice = nil }
            } message: { _ in
                Text(L10n.installExistingFoundBody.localized())
            }
            // eoc #456
            // #463: ONE new modifier on this chain, and the sheet's content is a
            // single concrete type built by `telemostSheet` — this file has hit
            // "unable to type-check this expression in reasonable time" three
            // times, so nothing new is inlined here.
            .sheet(item: $telemostRenew) { req in telemostSheet(req) }
    }

    private func removeFromList(_ host: ServerHost) {
        if let idx = serverStore.hosts.firstIndex(where: { $0.id == host.id }) {
            serverStore.remove(at: IndexSet([idx]))
            health.forgetHost(host.id)
        }
    }

    // #456 was: `matrixSection` — a Section wrapping MatrixView under the
    // "Carrier × Transport" header. Deleted with its call site above: the table
    // is a hand-synced snapshot of an upstream lab run at pin time, rendered as
    // if it described today's carriers. CarrierTransportMatrix itself stays —
    // the pickers still use it to gate impossible combos.

    // MARK: Empty state

    private var emptyState: some View {
        Section {
            // #258: shared OlcEmptyState with a primary CTA (was a bare VStack).
            OlcEmptyState(systemImage: "externaldrive.connected.to.line.below",
                          title: L10n.emptyNoServers.localized(),
                          hint: L10n.emptyNoServersHint.localized(),
                          ctaTitle: L10n.newServerTitle.localized()) {
                showAdd = true
            }
            .olcCardRow()
        }
    }

    // MARK: Display-state helpers (single source of truth)

    /// The host's current display state. Before any probe, seed a conservative
    /// base from persisted data: a known container → `.stopped` (so Start/Stop and
    /// the metrics surface, and we never offer a reinstall by mistake); otherwise
    /// `.unknown` ("tap Check"). Never asserts a running container without a probe.
    /// What the card shows: the live state, else the persisted last-known
    /// snapshot, else `.unknown` ("checking") — never a guessed "stopped".
    private func displayState(_ host: ServerHost) -> HostDisplay {
        if let live = display[host.id] { return live }
        if let snap = health.hostSnapshot(for: host.id) { return .base(HostBase(snapshot: snap.base)) }
        return .base(.unknown)
    }

    /// Fill the in-memory clocks and machine numbers from the persisted
    /// snapshots for hosts this view has not read yet, so a fresh view shows
    /// the last known reading with its true age instead of empty slots.
    private func seedFromSnapshots() {
        for host in serverStore.hosts where lastProbe[host.id] == nil {
            guard let snap = health.hostSnapshot(for: host.id) else { continue }
            lastProbe[host.id]   = snap.probedAt
            lastProbeOK[host.id] = snap.probedAt
            // Round 2 (D): the protocol rows too — a cold start used to show
            // "not read yet" until an SSH listing returned, although the last
            // listing was persisted alongside the base. Only a non-empty
            // listing is seeded (an empty one is re-read, never asserted), and
            // its own read clock comes with it so the entry pass applies the
            // same staleness rule as for a view that stayed alive.
            if carrierRows[host.id] == nil, let seeded = Self.seededRows(snap) {
                carrierRows[host.id]   = seeded
                carrierRowsAt[host.id] = snap.carriersReadAt ?? snap.probedAt
            }
            if display[host.id] == nil { display[host.id] = .base(HostBase(snapshot: snap.base)) }
            if vpsStats[host.id] == nil, let disk = snap.disk, let ram = snap.ram, let uptime = snap.uptime {
                vpsStats[host.id] = SSHRunner.VPSStats(disk: disk, ram: ram, uptime: uptime)
            }
            // A nil ping is "failed or not measured" — not evidence of
            // unreachability, so only a real number is seeded.
            if let ms = snap.pingMs, pingLatencies[host.id] == nil {
                pingLatencies[host.id] = ms
                lastPing[host.id] = snap.probedAt
            }
        }
    }

    /// Persist a confirmed base with the machine numbers currently on record.
    private func recordSnapshot(_ host: ServerHost, base: HostBase) {
        let stats = vpsStats[host.id]
        // The rows ride along from the previous snapshot: a probe says nothing
        // about them. A base without a container has no rows to remember.
        let previous = health.hostSnapshot(for: host.id)
        health.noteHostSnapshot(HostSnapshot(base: base.snapshotBase, probedAt: Date(),
                                             disk: stats?.disk, ram: stats?.ram, uptime: stats?.uptime,
                                             pingMs: pingLatencies[host.id] ?? nil,
                                             carriers: base.hasContainer ? previous?.carriers : nil,
                                             carriersReadAt: base.hasContainer ? previous?.carriersReadAt : nil),
                                for: host.id)
    }

    /// The rows a persisted snapshot can seed: nil when it holds none or an
    /// empty listing (which is re-read rather than shown as "no protocols").
    nonisolated static func seededRows(_ snap: HostSnapshot) -> [SSHRunner.CarrierInfo]? {
        guard let carriers = snap.carriers, !carriers.isEmpty else { return nil }
        return carriers.map(\.carrierInfo)
    }

    /// Store the rows a successful listing returned (or drop them after a
    /// failed one, #470) in the host's persisted snapshot, if it has one.
    private func recordCarriers(_ rows: [SSHRunner.CarrierInfo]?, for hostID: UUID, at: Date?) {
        guard var snap = health.hostSnapshot(for: hostID) else { return }
        let carriers = rows?.map { HostSnapshotCarrier($0) }
        guard snap.carriers != carriers || snap.carriersReadAt != at else { return }
        snap.carriers      = carriers
        snap.carriersReadAt = at
        health.noteHostSnapshot(snap, for: hostID)
    }

    /// Round 2 (D): the tab's first frame is the seeded snapshot; every
    /// socket, Keychain read and UserDefaults write waits this long after the
    /// appearance so the transition is not competing with them. False when the
    /// owning task was cancelled during the wait (the view went away).
    static let firstFrameDeferMilliseconds = 300
    nonisolated static func deferPastFirstFrame() async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(firstFrameDeferMilliseconds))
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    /// The #470 / #452 lazy-load guard, in one place so the deferred task can
    /// re-ask it after the wait.
    private func shouldLazyListRows(_ host: ServerHost) -> Bool {
        carrierRows[host.id] == nil && host.lastContainerName != nil
            && !actionsDisabled && !entryRefreshing
            && !carrierListInFlight.contains(host.id)
    }

    /// The base under whatever is currently shown (running/failed keep the base
    /// they started from). Drives the menu / button shape.
    private func currentBase(_ host: ServerHost) -> HostBase { displayState(host).base }

    private func hasContainer(_ host: ServerHost) -> Bool { currentBase(host).hasContainer }
    // #459 was: `isRunning(_:)` — its only caller was the ⋯ menu's Start/Stop
    // pair, which was a literal duplicate of the card's primary button
    // (`primaryAction` reads the same base) and is gone with it.

    // MARK: #456 — verified health (the ONE vocabulary for "is this OK?")
    //
    // podman "Up" only proves a process exists. It proved nothing about the
    // telemost node that shipped this task: Up-and-green while its own container
    // logs read "control unhealthy" → "session closed reason=liveness" and
    // "traffic: addr=www.google.com:443 in=0 out=0". Green here comes from
    // HealthCoordinator alone — a recent end-to-end probe through that node's own
    // SOCKS listener. Everything weaker renders neutral, never good.

    /// #456: every ConnectionRecord this host's protocol rows resolve to.
    private func hostRecords(_ host: ServerHost) -> [ConnectionRecord] {
        (carrierRows[host.id] ?? []).compactMap { connectionRecord(host, row: $0) }
    }

    /// #456: this host's protocols aggregated into one verdict (best evidence
    /// wins, but "couldn't check" never masquerades as "broken").
    private func hostHealth(_ host: ServerHost) -> HealthDisplay {
        health.summary(for: hostRecords(host).map(\.id))
    }

    /// #456: one protocol row's verdict. No record → nothing has ever been
    /// measured for it, which must LOOK like nothing, not like good.
    private func rowHealth(_ host: ServerHost, row: SSHRunner.CarrierInfo) -> HealthDisplay {
        guard let rec = connectionRecord(host, row: row) else { return .never }
        return health.display(for: rec.id)
    }

    /// #456: the card headline. `reachable` is the TCP-22 verdict — ABSENT means
    /// "never pinged", which is not the same as unreachable, and neither is the
    /// same as "stopped" (requirement 2).
    private func headline(_ host: ServerHost, state: HostDisplay) -> HostHeadline {
        let reachable: Bool? = {
            switch pingLatencies[host.id] {
            case .some(.some): return true
            case .some(.none): return false
            case .none:        return nil
            }
        }()
        // #456 (audit) was: `lastProbe` — the ATTEMPT clock, stamped even when the
        // probe threw, so a failed auto-check made an hours-old base read as a
        // present-tense reading and skipped the honest `.notChecked` headline.
        let age = lastProbeOK[host.id].map { Date().timeIntervalSince($0) }
        let tally = verifiedTally(host)   // #471
        return HostHeadline.reduce(display: state, reachable: reachable,
                                   lastProbeAge: age, health: hostHealth(host),
                                   probeError: lastProbeError[host.id],   // #469
                                   verified: tally.verified,              // #471
                                   total: tally.total,
                                   verifiedAge: tally.age)
    }

    // boc #471: the tally that replaces `failureBanner`.
    //
    // NOT `health.failingCount` minus anything: that helper deliberately does
    // not count `.inconclusive` / `.never` as failures ("couldn't check" is not
    // a verdict), so `total - failing` would report an unchecked protocol as
    // verified — fake green, in the one number the pill now leads with. This
    // counts only `.isVerified`, which is the single place in the app green is
    // granted (App/Models/NodeHealth.swift).
    //
    // The age is the OLDEST of those verified readings, so "2 of 2 protocols
    // verified 2 min ago" is true of every one of them rather than of the
    // luckiest. nil when nothing is verified — there is no age to date a
    // verification that did not happen, and `HostHeadline.subtitle` falls back
    // to the health vocabulary's own dated sentence.
    //
    // The denominator is the larger of "records we can measure" and "rows drawn
    // below", for #470's reason: a container with no saved record still draws a
    // row, and a count that ignored it said "1 of 2" above three rows.
    private func verifiedTally(_ host: ServerHost) -> (verified: Int, total: Int, age: TimeInterval?) {
        let ids = hostRecords(host).map(\.id)
        let now = Date()
        var verified = 0
        var oldest: Date?
        for id in ids where health.display(for: id, now: now).isVerified {
            verified += 1
            guard let at = health.health(for: id)?.checkedAt else { continue }
            if oldest == nil || at < oldest! { oldest = at }
        }
        let total = max(ids.count, (carrierRows[host.id] ?? []).count)
        return (verified, total, oldest.map { now.timeIntervalSince($0) })
    }
    // eoc #471

    // #459 was: `unverifiedCount(_:)` — the aggregate "N more not checked" that
    // fed the card's sweep note. The note is gone (pull-to-refresh checks
    // everything, so a footnote advertising a Verify-all button advertises
    // nothing), and the fact survives per item: every unchecked protocol row
    // still says "not checked" in its own chip, which is the honest place to
    // say it.

    /// The ConnectionRecord this host installed/owns (by `lastConnectionID`),
    /// if still present.
    private func linkedConnection(_ host: ServerHost) -> ConnectionRecord? {
        guard let id = host.lastConnectionID else { return nil }
        return connections.connections.first { $0.id == id }
    }

    /// The full-access payload for a host: the primary connection URI plus the
    /// SSH coordinates and the ONE stored credential — the password, or the
    /// private key (+ passphrase) for key hosts — read live from the Keychain.
    /// nil when nothing is stored, so a credential-less link is never offered.
    private func fullAccessPayload(_ host: ServerHost, conn: ConnectionRecord) -> FullAccessShare? {
        guard let secret = serverStore.secret(for: host) else { return nil }
        let uri: String
        switch conn.details {
        case .olcrtc(let p): uri = OlcrtcURI.encode(p)
        }
        var payload = FullAccessShare(
            uri: uri,
            label: host.label,
            sshHost: host.host,
            sshPort: host.port,
            sshUsername: host.username,
            sshPassword: "")
        switch secret {
        case .password(let pw):
            payload.sshPassword = pw
        case .privateKey(let text, let passphrase):
            payload.sshPrivateKey = text
            payload.sshKeyPassphrase = (passphrase?.isEmpty == false) ? passphrase : nil
        }
        return payload
    }

    /// The card's share sheet: every protocol connection of this host (the
    /// linked one first), plus full access when a credential is stored.
    private func shareRequest(_ host: ServerHost, startWithFullAccess: Bool = false) -> ServerShareRequest? {
        var records = hostRecords(host)
        if let linked = linkedConnection(host) {
            records.removeAll { $0.id == linked.id }
            records.insert(linked, at: 0)
        }
        guard let first = records.first else { return nil }
        return ServerShareRequest(
            hostLabel: host.label,
            options: records.map { ServerShareOption(conn: $0) },
            fullAccess: fullAccessPayload(host, conn: first),
            startWithFullAccess: startWithFullAccess)
    }

    /// Any host mid-operation. Operations are serialized (one provisioner), so we
    /// disable every card's actions while one runs — this also keeps `runningHostID`
    /// unambiguous for phase routing.
    private var anyBusy: Bool { display.values.contains { $0.isRunning } }
    private var actionsDisabled: Bool { anyBusy || provisioner.status.isRunning }
    private var runningHostID: UUID? { display.first { $0.value.isRunning }?.key }

    // MARK: The ONE operation driver
    //
    // Sets `.running`, lets `work` do the SSH work + the confirming probe (the
    // ONLY thing that returns a base), then makes a SINGLE terminal assignment:
    // `.base` on success, `.failed` on throw. `work` must not write `display`.

    private func run(_ op: HostOp, on host: ServerHost,
                     _ work: @escaping (_ secret: SSHSecret) async throws -> HostBase?) async {
        guard !anyBusy else { return }
        // #470: claim the host for the whole op so the unattended Telemost
        // renewal (its own Provisioner) cannot restart a container underneath it.
        // #482 was: Provisioner.enterHost(host.id) — never tested ownership.
        guard Provisioner.tryEnterHost(host.id) else { return }
        defer { Provisioner.leaveHost(host.id) }
        let prev = currentBase(host)
        display[host.id] = .start(op, from: prev)

        guard let secret = secret(for: host) else {
            withAnimation(serverTransition) { // #490 was: unconditional 0.35s transition.
                display[host.id] = HostDisplay.start(op, from: prev)
                    .failed(message: missingCredentialMessage(host))
            }
            return
        }

        do {
            let resolved = try await work(secret)
            // boc #470: a base the op returned IS a fresh reading of the server
            // (every op ends in `probeReadiness`; uninstall's is the script's own
            // confirmation), yet only `checkServer` stamped the clocks — so after
            // Start on a never-probed host the button read "Stop server" while
            // the headline still said "Not checked yet", and with the entry probe
            // on, the stamp said "read 5 min ago" seconds after the op's probe.
            if resolved != nil {
                lastProbe[host.id]      = Date()
                lastProbeOK[host.id]    = Date()
                lastProbeError[host.id] = nil
            }
            // eoc #470
            // One terminal change — the probe result is authoritative (no optimism);
            // else the op's nominal target; else keep the previous base (e.g. reboot).
            let base = HostDisplay.terminalBase(op: op, probed: resolved, previous: prev)
            // #490 was: withAnimation(.easeInOut(duration: 0.35)).
            withAnimation(serverTransition) { display[host.id] = .base(base) }
            if resolved != nil { recordSnapshot(host, base: base) }
        } catch {
            let current = display[host.id] ?? .start(op, from: prev)
            withAnimation(serverTransition) { // #490 was: unconditional 0.35s transition.
                display[host.id] = current.failed(message: error.localizedDescription)
            }
        }
    }

    /// Maps a provisioner progress message onto the running host: phase forward
    /// (monotonic, capped) + subtitle = the live message. Never touches base/dot.
    private func advancePhase(note: String) {
        guard let id = runningHostID else { return }
        display[id] = display[id]?.advanced(note: note)
    }

    /// Re-runs the failed op. Returns to the previous base first, then dispatches
    /// (sheet-driven ops reopen their sheet so the user reconfirms options).
    private func retry(_ op: HostOp, on host: ServerHost) async {
        if let restored = display[host.id]?.retryBase() { display[host.id] = restored }
        switch op {
        case .check:         await checkServer(host)
        case .start:         await startContainer(host)
        case .stop:          await stop(host)
        case .update:        await update(host)
        case .reboot:        await reboot(host)
        case .install:       installFor = host
        // #470: the request that failed, not the primary's — see `lastReconfigure`.
        // #470 was: reconfigureRequest = primaryReconfigureRequest(host)   // #452
        case .reconfigure:   reconfigureRequest = lastReconfigure[host.id] ?? primaryReconfigureRequest(host)
        case .uninstall:     uninstallConfirmHost = host
        case .deepUninstall: deepUninstallConfirmHost = host
        }
    }

    // MARK: Auto-ping
    //
    // Automatic checking happens once, on entry; after that the pull is the
    // only re-read. The loop runs inside `.task`, so SwiftUI cancels it on
    // disappear. Two legacy settings keys behind the old periodic loop stay for
    // downgrade safety and have no UI.

    /// Small per-host gap so a fleet doesn't fire every probe on one tick.
    private static let pingStaggerSeconds: Double = 0.4

    private func autoPingOnce() async {
        await pingNeverPingedHosts()
    }

    /// Hosts added since the entry pass get a first reading without reopening
    /// the once-per-foreground claim or rechecking the rest of the fleet.
    /// `lastProbe` is seeded from persisted snapshots, so a host with a recent
    /// snapshot is not "never probed".
    nonisolated static func neverProbedHosts(_ hosts: [ServerHost],
                                             lastProbe: [UUID: Date]) -> [ServerHost] {
        hosts.filter { lastProbe[$0.id] == nil }
    }

    private func checkNeverProbedHosts() async {
        guard SettingsStore.shared.refreshOnEntry else { return }
        // Ride out an entry/manual pass rather than race its SSH reads. This
        // bounded-by-work wait is lifecycle-cancelled; it is not a periodic sweep.
        while entryRefreshing || actionsDisabled {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        entryRefreshing = true
        defer { entryRefreshing = false }
        for candidate in Self.neverProbedHosts(serverStore.hosts, lastProbe: lastProbe) {
            while Provisioner.busyHostIDs.contains(candidate.id) {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            // The wait may have removed/updated the host or completed its first op.
            guard let host = serverStore.hosts.first(where: { $0.id == candidate.id }),
                  lastProbe[host.id] == nil else { continue }
            await silentProbe(host)
            guard !Task.isCancelled else { return }
            await refreshCarriers(host.id)
        }
    }

    /// Pings every host that has never been pinged in this session (snapshot
    /// pings count). Staggered, so a fleet does not open every socket at once.
    private func pingNeverPingedHosts() async {
        let due = serverStore.hosts.filter { lastPing[$0.id] == nil }
        for (i, host) in due.enumerated() {
            if i > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.pingStaggerSeconds * 1_000_000_000))
                } catch {
                    return   // cancelled mid-stagger
                }
            }
            if Task.isCancelled { return }
            await doPing(host)
        }
    }

    private func doPing(_ host: ServerHost) async {
        // #469: `clamping:` — a stored port can predate the range check in
        // AddServerHostView, and a trap here took the whole app down on entry.
        let result = await NetPing.tcp(host: host.host, port: UInt16(clamping: host.port), timeout: 5)
        pingLatencies[host.id] = result.success ? result.ms : nil
        lastPing[host.id] = Date()   // #374: record so the sweep can skip fresh hosts
    }

    // MARK: Host card
    //
    // #457: the card itself now lives in App/Views/ServerCardView.swift and the
    // protocol row in App/Views/ProtocolRowView.swift. Everything below is glue —
    // it resolves state into plain values and hands them over. Nothing that
    // RENDERS may grow inside this file again: it has hit the Swift
    // type-checker's expression budget twice already (see `carrierModals`).
    // #459: same rule, one more file — the pushed management screen is
    // App/Views/ServerAdvancedView.swift, and `advancedView(_:)` below is its
    // way: plain values and closures, nothing rendered here.
    // #471 was: "…`quickActions(_:)` is the card's new button row" — that row
    // is deleted; `machineLine(_:)` and `verifiedTally(_:)` are the resolvers
    // this pass adds, and both return plain values too.
    //
    // #457 was: hostCard / hostCardTop / hostCardBottom / statusRegion /
    // processCaption / metricsStrip / pingMiniStat / actionBar / primaryButton /
    // protocolsSection / carrierRowView / carrierRowLead / healthSweepFooter /
    // containerLogBusyStrip — ~340 lines of view code in this file.

    private func hostCard(_ host: ServerHost) -> some View {
        Section {
            serverCard(host)
                // #452: lazy first load of the protocol rows (skipped while an op
                // holds the SSH lane; refreshed after every op anyway).
                .onAppear {
                    // #470: not while the on-entry pass is reading this host (it
                    // lists the rows itself) and not on top of a listing already
                    // in flight — the two used to race on first entry.
                    // Round 2 (D): rows seeded from the persisted snapshot make
                    // this a no-op on most cold starts; when it does run, it
                    // waits past the first frame and re-checks the guards, since
                    // the deferred entry pass may have claimed the host meanwhile.
                    guard shouldLazyListRows(host) else { return }
                    Task(priority: .utility) {
                        guard await Self.deferPastFirstFrame(), shouldLazyListRows(host) else { return }
                        await refreshCarriers(host.id)
                    }
                }
                .olcCardRow()
        }
    }

    /// #457: resolves one host into `ServerCardView`'s inputs. Arguments are
    /// listed in the struct's declaration order — Swift enforces that order for
    /// a memberwise init, and getting it wrong is a compile error.
    private func serverCard(_ host: ServerHost) -> ServerCardView {
        let state  = displayState(host)
        // #471 was: `let counts = health.failingCount(...)` feeding
        // `failingCount:` / `protocolCount:` — the card's deleted failure
        // banner. The same question is answered by `verifiedTally`, inside the
        // headline, so the card gets one claim instead of a claim plus a
        // contradiction of it.
        // A protocol-level op holds the SSH lane just like a HostOp does, so it
        // locks the host's actions too (they would collide on one connection).
        let locked = actionsDisabled || carrierBusyHostID != nil
        return ServerCardView(
            name:            host.label,
            addressLine:     addressLine(host),
            headline:        headline(host, state: state),
            progress:        statusBarFraction(state),
            machineLine:     machineLine(host),
            isRefreshing:    probingHostIDs.contains(host.id) || carrierListInFlight.contains(host.id),
            rows:            carrierRows[host.id] ?? [],
            rowsBusy:        carrierBusyHostID == host.id,
            // #490: show a real list read distinctly from unknown or empty.
            listing:         ServerProtocolListing.resolve(hasContainer: hasContainer(host),
                                isLoading: carrierListInFlight.contains(host.id),
                                hasRead: carrierRows[host.id] != nil),
            canAddProtocol:  !missingCarriers(host).isEmpty,
            actionsDisabled: locked,
            primary:         primaryAction(state),
            canOpenLogs:     hasContainer(host),           // #471 was: quickActions(host)
            menuItems:       menuItems(host),
            onPrimary:       { runPrimary(host, state: state) },
            onAddProtocol:   { addProtocolFor = host },
            onLogs:          { logsForHost = host },       // #471
            onManage:        { advancedForHost = AdvancedHostRoute(host: host) },   // #459
            row:             { rowView(host, row: $0) })
    }

    // boc #471 was: `quickActions(_:)` — the card's one visible quick-action
    // button ("Container logs"), gated on `hasContainer`.
    //
    // #459 lifted it out of a thirteen-item ⋯ menu and #461 cut it from two
    // buttons to one; this pass takes the last of it off the card's action
    // stack. Nothing is removed from the app: the same verb, the same gate and
    // the same destination (`logsForHost`) are a text link in the card's
    // `manageRow` now, beside "Manage ›". What that buys is the hierarchy — a
    // card that ended in a grey full-width button above a red full-width button
    // above a hairline above a tiny grey link ends in ONE filled button and one
    // row of two links, and the loudest thing on it is the action it is
    // actually offering.
    //
    // The gate is `canOpenLogs: hasContainer(host)` in `serverCard`, verbatim
    // what this function guarded on, so a never-installed server still shows
    // nothing but its primary CTA — and `primary == .check` (the only case that
    // could duplicate a Logs verb) still happens exactly on `HostBase.unknown`,
    // which has no container.
    // eoc #471

    /// Resolves one host into `ServerAdvancedView`'s inputs. Each destructive
    /// verb still ends in the confirmation dialog `hostConfirmations` owns.
    /// Host metadata is re-resolved on every parent render so an edit or
    /// adoption made while the screen is open shows up in place.
    private func advancedView(_ host: ServerHost) -> ServerAdvancedView {
        let host = ServerPresentationPolicy.currentHost(snapshot: host, hosts: serverStore.hosts)
        return ServerAdvancedView(
            hostLabel:           host.label,
            isKeyAuth:           host.authMethod == .privateKey,
            hasRecoverOption:    hasContainer(host) && linkedConnection(host) == nil,
            hasLinkedConnection: linkedConnection(host) != nil,
            hasContainer:        hasContainer(host),
            canDeepUninstall:    currentBase(host) != .noPodman,
            actionsDisabled:     actionsDisabled || carrierBusyHostID != nil,
            onRecover:           { recoverConfirmHost = host },
            onShareFullAccess:   { presentFullAccessShare(host) },
            // No dialog stands behind Update, so it pops on the way out — the
            // card is where its progress bar is.
            onUpdate:            { advancedForHost = nil; Task { await update(host) } },
            onReboot:            { rebootConfirmHost = host },
            onUninstall:         { uninstallConfirmHost = host },
            onDeepUninstall:     { deepUninstallConfirmHost = host },
            onRemoveHost:        { removeHost = host },
            addressLine:         addressLine(host),
            machine:             machineStats(host),
            readCaption:         readCaptionText(host),
            headline:            headline(host, state: displayState(host)),
            menuItems:           advancedMenuItems(host),
            hasHostKeyMismatch:  hasHostKeyMismatch(host),
            onResetHostKeyTrust: { resetHostKeyTrust(host) })
    }

    private func hasHostKeyMismatch(_ host: ServerHost) -> Bool {
        guard let endpoint = SSHHostKeyVerification.endpoint(host: host.host, port: host.port) else {
            return false
        }
        return hostKeyMismatchEndpoints.contains(endpoint)
    }

    /// Called only by the management screen's destructive confirmation.
    /// Re-resolve the row and endpoint so an old dialog cannot reset a new host.
    private func resetHostKeyTrust(_ snapshot: ServerHost) {
        guard !actionsDisabled, carrierBusyHostID == nil,
              let current = serverStore.hosts.first(where: { $0.id == snapshot.id }),
              let endpoint = SSHHostKeyVerification.endpoint(host: current.host, port: current.port),
              endpoint == SSHHostKeyVerification.endpoint(host: snapshot.host, port: snapshot.port),
              hostKeyMismatchEndpoints.contains(endpoint),
              SSHHostKeyTrustStore.shared.hasMismatch(host: current.host, port: current.port) else { return }
        do {
            try SSHHostKeyTrustStore.shared.resetTrust(host: current.host, port: current.port)
            // The trust record is endpoint-wide. Clear every legacy alias only
            // AFTER a durable reset; never rewrite credentials or other metadata.
            for host in serverStore.hosts where
                SSHHostKeyVerification.endpoint(host: host.host, port: host.port) == endpoint {
                guard host.sshHostKeyPin != nil else { continue }
                var updated = host
                updated.sshHostKeyPin = nil
                serverStore.update(updated, secret: nil)
            }
            hostKeyMismatchEndpoints.remove(endpoint)
            alertText = L10n.sshHostKeyResetDone.localized()
            // No automatic retry, scan, scheduling or success/health verdict.
        } catch {
            alertText = error.localizedDescription
        }
    }

    /// Safe actions on the management screen: the card menu (minus Share)
    /// plus Logs and Add protocol, with the listing's own gates.
    private func advancedMenuItems(_ host: ServerHost) -> [OlcMenuItem] {
        var items = menuItems(host, includeShare: false)
        if hasContainer(host) {
            items.append(.action(L10n.logsTitle.localized(), systemImage: "doc.text") {
                logsForHost = host
            })
        }
        if !missingCarriers(host).isEmpty {
            items.append(.action(L10n.addProtocolAction.localized(), systemImage: "plus.circle") {
                addProtocolFor = host
            })
        }
        return items
    }

    /// "Share full access" from the Manage screen: the share sheet opens on
    /// the full-access confirmation.
    private func presentFullAccessShare(_ host: ServerHost) {
        guard let req = shareRequest(host, startWithFullAccess: true), req.fullAccess != nil else {
            alertText = missingCredentialMessage(host)
            return
        }
        shareServer = req
    }

    /// #337: mask the host for display when screenshot-safe mode is on (IP
    /// literals to bullets; hostnames pass through). Display-only — `host.host`
    /// stays real.
    private func addressLine(_ host: ServerHost) -> String {
        "\(host.username)@\(IPMask.display(host.host, masked: settings.maskIPs)):\(String(host.port))"
    }

    /// #457: one protocol row, resolved. The view is dumb; the resolution from a
    /// container to a saved connection stays here, where the stores are.
    ///
    /// #461: the row's identity is the SERVICE the traffic hides inside
    /// ("Yandex Telemost"), and under it HOW it is carried ("VP8") — the same
    /// inversion the Connect tab now makes with `ConnectionNaming.service(_:)` /
    /// `.transport(_:)` — which lives at the foot of App/Views/ConnectionRowView.swift
    /// until the next `xcodegen generate` pass can give it a file of its own; its
    /// own partition note there says so. Those two resolve a
    /// `ConnectionDetails`; a row here is a CONTAINER, which may have no saved
    /// record at all (`connectionRecord` returns nil for one), so it composes
    /// the same strings from the same and only source of them,
    /// `CarrierTransportMatrix` — which is what makes the two screens name one
    /// connection identically instead of merely similarly.
    /// The row carries NO host label, deliberately: the card IS the host (its
    /// header holds the label and the address), so `ConnectionNaming.host` has
    /// no venue here.
    private func rowView(_ host: ServerHost, row: SSHRunner.CarrierInfo) -> ProtocolRowView {
        ProtocolRowView(
            title:             CarrierTransportMatrix.carrierLabel(row.provider),
            transport:         CarrierTransportMatrix.transportLabel(row.transport),
            isLive:            isLiveRow(row),
            isRunningOnServer: Self.isUp(row.status),
            health:            rowHealth(host, row: row),
            menuDisabled:      actionsDisabled || carrierBusyHostID != nil,
            menuItems:         carrierMenuItems(host, row: row),
            detailLines:       ProtocolDescriptions.lines(carrier: row.provider, transport: row.transport),
            onVerify:          { verifyRow(host, row: row) },
            onConnect:         { connectVia(host, row: row) })
    }

    /// #457 was: `row.status.shortLabel.hasPrefix("Up")` repeated at three call
    /// sites — string-matching a label that is also user-visible text.
    /// `ContainerStatus.parse` already decided this; ask it instead.
    static func isUp(_ status: ContainerStatus) -> Bool {
        if case .running = status { return true }
        return false
    }

    /// #457: three container-lifecycle states, three DIFFERENT glyphs — running,
    /// present-but-stopped, and not-there-at-all were one dot in three hues.
    /// Neutral colour throughout: none of this is a health claim, and the label
    /// beside it already says "Up 3 hours" / "Exited (137) …" / "Not found".
    static func scanGlyph(_ status: ContainerStatus) -> String {
        switch status {
        case .running:  return "play.circle"
        case .stopped:  return "pause.circle"
        case .notFound: return "questionmark.circle"
        }
    }

    // MARK: The primary action
    //
    // #457: the card offers exactly ONE next step, and never one that no
    // evidence justifies.
    // #457 was: `primaryButton`'s `else` branch rendered a full-width **Install**
    // for every base without a container — INCLUDING `.unknown`, i.e. a server
    // nothing had ever read. `scripts/srv.sh` force-removes every
    // `olcrtc-server-*` container before installing, so one tap on a re-added
    // VPS destroyed a working deployment and every sibling protocol on it.
    // `.unknown` now offers **Check server**; Install appears only on a base a
    // real probe returned.

    private func primaryAction(_ state: HostDisplay) -> ServerPrimaryAction {
        switch state {
        case .running: return .busy
        case .failed:  return .retry
        case .base(let b):
            if b == .running  { return .stop }
            if b.hasContainer { return .start }
            if b == .unknown  { return .check }
            return .install
        }
    }

    private func runPrimary(_ host: ServerHost, state: HostDisplay) {
        switch state {
        case .running:
            break   // the button is a spinner; nothing to dispatch
        case .failed(let op, _, _, _):
            Task { await retry(op, on: host) }
        case .base(let b):
            if b == .running       { Task { await stop(host) } }
            else if b.hasContainer { Task { await startContainer(host) } }
            else if b == .unknown  { Task { await checkServer(host) } }
            else                   { Task { await beginInstall(host) } }
        }
    }

    // MARK: The read stamp
    //
    // #471: still built here, drawn one screen away — it is the footer of the
    // Manage screen's Machine section (App/Views/ServerAdvancedView.swift),
    // where it dates the four readings above it. On the CARD the age is folded
    // into the status pill's own subtitle by `HostHeadline.reduce`, because an
    // age belongs beside the claim it dates and the card's claim is the pill.
    // #471 was: `ServerCardView.readStamp`, a second line under that pill.
    //
    // boc #459: what is LEFT of the process caption — its age, and only its age.
    //
    // #459 was: `processCaptionText` + `processWord(_:)` → "Server process is
    // running · read 2m ago", a whole sentence under the status pill. The
    // sentence part restated the pill directly above it, and every protocol row
    // already says whether its own container is up (`protocolStoppedNote`), so
    // it was the same claim written a third time. The AGE was the load-bearing
    // half, and it belongs to the readings it dates: the card now prints it on
    // the metrics block, trailing, where the disk / RAM / uptime numbers it
    // actually stamps are.
    //
    // `lastProbeOK`, not `lastProbe`: the attempt clock is stamped even when the
    // probe threw, which would date the PREVIOUS reading to "just now". With no
    // reading at all the seeded base is a GUESS, so the stamp says exactly that
    // instead of dressing a guess up with an age.
    // #459 also was: HealthAge.label(…) inside "%@ · read %@ ago" — that is the
    // "read just now ago" bug. `phrase` carries its own preposition and
    // `vpsReadAge_fmt` no longer appends one.
    private func readCaptionText(_ host: ServerHost) -> String {
        guard let probed = lastProbeOK[host.id] else { return L10n.vpsProcessUnread.localized() }
        return L10n.vpsReadAge_fmt.formatted(HealthAge.phrase(Date().timeIntervalSince(probed)))
    }
    // eoc #459

    /// The progress fraction while running; nil when the bar slot is empty.
    private func statusBarFraction(_ state: HostDisplay) -> Double? {
        guard case .running(let op, let phase, _, _) = state else { return nil }
        return Double(min(phase + 1, op.stepCount)) / Double(max(op.stepCount, 1))
    }

    // MARK: Metrics
    //
    // #457: the numbers describe the MACHINE, not whether anything on it works,
    // so the card draws them below the protocol rows. The formatting statics stay
    // on this type — `VPSStatFormattingTests` pins them by name.

    /// #471 was: `metrics(_:) -> ServerCardMetrics`, feeding the card's 2x2
    /// grid. Same readings, same formatters, one screen further in: the Manage
    /// screen's Machine section.
    private func machineStats(_ host: ServerHost) -> ServerMachineStats {
        let stats = vpsStats[host.id]
        return ServerMachineStats(
            ping:     pingValue(host),
            pingTone: pingTone(host),
            // #346: labels through L10n (ru = en for the abbreviations); units
            // like "G"/"M"/"d" inside the values stay English.
            disk:     Self.shortUsage(stats?.disk),
            // #451: shortRAM, not shortUsage — a 2 GB VPS reports "407M/1967M"
            // and the 9-char "407/1967M" overflowed the strip on 375pt phones.
            ram:      Self.shortRAM(stats?.ram),
            uptime:   Self.shortUptime(stats?.uptime))
    }

    // boc #471: the machine, as ONE caption under the card's address line.
    //
    // Three readings, not four: PING leaves the card entirely. It is a TCP-22
    // round-trip to the SSH port, printed in the same `ms` unit as the verified
    // end-to-end latency on the protocol row directly below it and routinely
    // disagreeing with it — two latencies on one screen, the disease the
    // Connect tab documents having cured. Whether the host answers at all is
    // already the pill's `.unreachable` state, and the number itself survives
    // on the Manage screen.
    //
    // "" when nothing has been read: a line of three em-dashes is noise, not
    // honesty, and the pill above it already says the host has not answered.
    private func machineLine(_ host: ServerHost) -> String {
        guard let stats = vpsStats[host.id] else { return "" }
        return L10n.vpsMachineLine_fmt.formatted(Self.shortUsage(stats.disk),
                                                 Self.shortRAM(stats.ram),
                                                 Self.shortUptime(stats.uptime))
    }
    // eoc #471

    private func pingValue(_ host: ServerHost) -> String {
        switch pingLatencies[host.id] {
        // #470 was: `String(format: "%.0fms", ms)` — the one unit on this card
        // that has a localized form («мс»), rendered in English under a
        // Russian «Ping». The health chips already use this key for the same
        // value; the G/M/d suffixes in the other stats stay as #346 decided.
        case .some(.some(let ms)): return L10n.healthLatencyMs_fmt.formatted(Int(ms.rounded()))
        case .some(.none):         return "✕"
        case .none:                return "—"
        }
    }

    /// #456 was: `ms < 100 ? green : ms < 300 ? orange : red` — an SSH round-trip
    /// says NOTHING about whether the tunnel passes traffic, and that green was
    /// one of the loudest false-green sources on this card. A reachable value is
    /// neutral; only the honest negative stays red.
    private func pingTone(_ host: ServerHost) -> Color {
        switch pingLatencies[host.id] {
        case .some(.some): return Theme.Palette.textPrimary
        case .some(.none): return Theme.Palette.red
        case .none:        return Theme.Palette.textTertiary
        }
    }

    /// #341: compact a `df`/`free` "36G/40G" pair to "36/40G" (shared unit
    /// suffix hoisted to the right side); mixed units stay as-is. Internal
    /// static so the unit tests can pin the edge cases.
    static func shortUsage(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let u0 = parts[0].last, let u1 = parts[1].last,
              u0 == u1, u0.isLetter else { return s }
        return "\(parts[0].dropLast())/\(parts[1])"
    }

    /// #451: RAM-specific compaction. `free -m` reports MB, so a 2 GB VPS
    /// yields "407M/1967M" — shortUsage's "407/1967M" (9 mono chars) is the
    /// longest stat in the strip and the one that overflowed. When both sides
    /// are MB and the total is ≥ 1000M, convert to a shared-G form
    /// ("0.4/1.9G", 7 chars); smaller totals and anything unparseable fall
    /// through to shortUsage ("241/512M", "—", garbage passthrough).
    static func shortRAM(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              parts[0].hasSuffix("M"), parts[1].hasSuffix("M"),
              let used  = Double(parts[0].dropLast()),
              let total = Double(parts[1].dropLast()),
              total >= 1000
        else { return shortUsage(s) }
        return String(format: "%.1f/%.1fG", used / 1024, total / 1024)
    }

    /// #341: compact the `uptime` tail — "3 days" → "3d", "35 min" → "35m";
    /// the "H:MM" (<1 day) form stays as-is.
    static func shortUptime(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        return s.replacingOccurrences(of: " days", with: "d")
                .replacingOccurrences(of: " day",  with: "d")
                .replacingOccurrences(of: " min",  with: "m")
    }

    // MARK: Overflow menu — the occasional, non-destructive actions
    //
    // boc #459: THIRTEEN items became five, and none of the five is destructive.
    //
    // The owner's complaint was literal: "to do anything I have to go into those
    // tiny three dots where SO MUCH is shown". A menu that lists everything is
    // not a source of truth, it is a wall — the two verbs reached for constantly
    // sat below Stop and above Update with nothing to tell them apart.
    //
    // Where the other eight went, and why NOTHING was removed from the app:
    //   Container logs               → a text link on the card, beside
    //                                  "Manage ›" (#471 was: a visible
    //                                  full-width button, `quickActions`; #461
    //                                  was: "Check server, Container logs" —
    //                                  Check server duplicated pull-to-refresh
    //                                  and is gone)
    //   Start / Stop / Install       → the card's primary button ALREADY offered
    //                                  exactly these, keyed off the same base;
    //                                  they were a literal duplicate
    //   Update, Recover connection, Share full access, Reboot,
    //   Remove container, Wipe all, Remove host from list
    //                                → the pushed "Manage server" screen, where
    //                                  a Form footer can finally say what each
    //                                  destructive verb destroys
    //
    // #258's rule still holds one level up: the card's buttons and this menu are
    // still ONE derived action set, resolved here from one host state.
    /// The card's ⋯ menu: Scan (only while nothing is listed), Share, Edit.
    /// Per-protocol actions live on the protocol rows, not here.
    /// `includeShare: false` is the management screen, whose Connection
    /// section already offers full access.
    private func menuItems(_ host: ServerHost, includeShare: Bool = true) -> [OlcMenuItem] {
        var items: [OlcMenuItem] = []

        // Scan answers the one case the listing cannot: no container adopted
        // yet, or the recorded name went stale and the listing failed.
        if (carrierRows[host.id] ?? []).isEmpty {
            items.append(.action(L10n.actionScanVPS.localized(), systemImage: "magnifyingglass") {
                Task { await scanContainers(host) }
            })
        }
        items.append(.divider)
        // Share: pick which protocol connection to hand out, or full access.
        // Never offered before a connection exists.
        // Round 2 (D) was: `shareRequest(host) != nil` — which built the full
        // request, and `fullAccessPayload` inside it read the host's credential
        // from the Keychain (`serverStore.secret(for:)`) — one or two
        // synchronous `SecItemCopyMatching` calls PER HOST PER RENDER of the
        // card list. The menu only needs to know that a connection exists; the
        // request itself is built in the tap action, once.
        if includeShare, !hostRecords(host).isEmpty {
            items.append(.action(L10n.shareAction.localized(), systemImage: "square.and.arrow.up") {
                shareServer = shareRequest(host)
            })
        }
        items.append(.action(L10n.edit.localized(), systemImage: "pencil") { editHost = host })
        return items
    }
    // eoc #459

    // MARK: Actions (each drives the card through `run`; the probe sets base)

    /// #451 was: password(for:) → String?. The card's actions now resolve the
    /// full SSHSecret (password or private key + passphrase) from the store.
    private func secret(for host: ServerHost) -> SSHSecret? {
        serverStore.secret(for: host)
    }

    /// #451: method-appropriate "credential missing" message for the guards.
    private func missingCredentialMessage(_ host: ServerHost) -> String {
        host.authMethod == .privateKey
            ? L10n.alertKeyMissingShort.localized()
            : L10n.alertPasswordMissingShort.localized()
    }

    // MARK: #456 — auto-refresh on tab entry (requirements 2, 3 and 4)
    //
    // The card used to show whatever the last manual Check left behind: an
    // hours-old "Running", or the pre-probe seed ("stopped") for a server that
    // was in fact up. Entering the tab now re-probes on its own, and a probe that
    // FAILS records "couldn't check" instead of inventing a stopped state.

    /// #456: how stale a host's SSH probe must be before entering the tab re-runs it.
    private static let entryProbeStaleSeconds: TimeInterval = 120

    /// #470: a connection removed from the Connections tab leaves its id behind
    /// in the host that linked it. The id resolves to nothing, so every slot
    /// lookup misses and the card keeps offering actions for a record that is
    /// gone. Drop the dangling links whenever this tab opens.
    private func pruneDanglingLinks() {
        for host in serverStore.hosts {
            var fixed = host
            if let id = host.lastConnectionID,
               !connections.connections.contains(where: { $0.id == id }) {
                fixed.lastConnectionID = nil
            }
            if let extras = host.extraConnectionIDs {
                let live = extras.filter { id in connections.connections.contains { $0.id == id } }
                fixed.extraConnectionIDs = live.isEmpty ? nil : live
            }
            if fixed != host { serverStore.update(fixed, password: nil) }
        }
    }

    private func refreshOnEntry() async {
        pruneDanglingLinks()
        // The user's switch. Off ⇒ nothing happens on entry and every reading
        // keeps its honest age until they ask for a check themselves.
        guard SettingsStore.shared.refreshOnEntry else { return }
        guard !entryRefreshing, !actionsDisabled else { return }
        // Once per foreground session — see HealthCoordinator.
        guard health.claimServerPass() else { return }
        // Round 2 (D): the same once-per-foreground gate refreshes the store's
        // in-memory credential cache, so this pass re-reads the Keychain once
        // per host and every later caller in the session is served from memory.
        serverStore.invalidateSecrets()
        entryRefreshing = true
        defer { entryRefreshing = false }
        // Throttled per host: a snapshot younger than
        // `HostSnapshotPolicy.recheckSeconds` is shown as-is; only a pull or an
        // explicit action re-reads it sooner.
        let due = serverStore.hosts.filter { health.shouldRecheckHost($0.id, force: false) }
        for host in due {
            if Task.isCancelled { return }
            await silentProbe(host)
            // One listing per host per entry: the card's own lazy first load
            // may be landing right now. A pull (`refreshAllHosts`) is forced.
            if carrierListInFlight.contains(host.id) { continue }
            if let at = carrierRowsAt[host.id],
               Date().timeIntervalSince(at) < Self.entryProbeStaleSeconds { continue }
            await refreshCarriers(host.id)
        }
        // Returns immediately: the coordinator serialises the probes and skips
        // the room the live tunnel holds. Unreached nodes stay "not checked"
        // in their own chip.
        health.verifyDue(serverStore.hosts.flatMap { hostRecords($0) }, using: tunnel)
    }

    /// Pull-to-refresh: the forced twin of `refreshOnEntry()` — no throttle and
    /// no `refreshOnEntry` setting guard. Per host it re-reads TCP reachability
    /// and latency, the readiness probe (base + disk/RAM/uptime) and the
    /// container listing, then force-verifies every protocol. The system
    /// spinner is held for the whole SSH pass. `silentProbe` never lies on
    /// failure: a probe that throws leaves the base and the stats alone, so a
    /// failed pull ages the read stamp instead of inventing a state.
    private func refreshAllHosts() async {
        // An SSH op already holds the lane and paints its own progress bar;
        // queueing probes behind it would tell the user nothing new. A running
        // entry pass is ridden out, then the forced pass the user asked for runs.
        guard !actionsDisabled else { return }
        while entryRefreshing {
            if Task.isCancelled { return }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return   // the pull was cancelled while waiting
            }
        }
        entryRefreshing = true
        defer { entryRefreshing = false }
        for host in serverStore.hosts {
            if Task.isCancelled { return }
            await silentProbe(host)
            await refreshCarriers(host.id)
        }
        // Uncapped and forced, unlike the on-entry `verifyDue` — the user asked.
        health.verifyAll(serverStore.hosts.flatMap { hostRecords($0) }, using: tunnel)
    }

    /// A readiness probe that never lies. On success it sets the base, the
    /// stats, the display clock and the persisted snapshot; on any failure it
    /// leaves all of them alone, so the card keeps the last real reading with
    /// its true age plus the TCP verdict `doPing` just recorded — a network or
    /// SSH error is never rendered as "stopped". Status-silent, except that on
    /// a host with no container on record `adoptOrphanContainer` runs a scan
    /// that publishes `provisioner.status`.
    private func silentProbe(_ host: ServerHost) async {
        guard let secret = secret(for: host) else { return }
        // The first-reading path may adopt a container; own the same host lane
        // as manual operations while it awaits SSH.
        guard Provisioner.tryEnterHost(host.id) else { return }
        defer { Provisioner.leaveHost(host.id) }
        probingHostIDs.insert(host.id)
        defer { probingHostIDs.remove(host.id) }
        await doPing(host)                       // refreshes pingLatencies + lastPing
        guard !Task.isCancelled else { return }
        do {
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, secret: secret, containerName: host.lastContainerName)
            guard !Task.isCancelled else { return } // no orphan adoption after cancellation
            if let stats { vpsStats[host.id] = stats }
            // Adopt an orphaned container first, so the base the card shows is
            // the adopted one.
            let base = await adoptOrphanContainer(host, secret: secret, base: HostBase(rstate))
            // Never clobber an op that started while we were awaiting the probe.
            if !(display[host.id]?.isRunning ?? false) {
                display[host.id] = .base(base)
            }
            lastProbeOK[host.id] = Date()       // a REAL container reading
            lastProbeError[host.id] = nil
            recordSnapshot(host, base: base)
        } catch {
            LogStore.shared.log(.provisioning, "⚠ auto-check failed: \(error.localizedDescription)")
            lastProbeError[host.id] = error.localizedDescription   // the card says why
            // Nothing else is written: `doPing` already recorded the TCP truth,
            // and `lastProbeOK` is deliberately not stamped so the card keeps
            // saying how old the last real reading is.
        }
        // Stamped on BOTH paths — the attempt clock (no hammering). The DISPLAY
        // clock is `lastProbeOK`, written only where a reading actually came back.
        lastProbe[host.id] = Date()
    }

    // boc #461: the #302 auto-detect/adopt, extracted so BOTH read paths run it.
    //
    // #302: a readiness probe on a host with no *known* container reports
    // "image cached, ready for reinstall" even when an `olcrtc-server-*`
    // container already exists (just stopped) — and Install, the CTA that base
    // offers, force-removes every olcrtc container on the machine. Adopting the
    // container we can already see is what stops a re-added VPS from being
    // wiped by one tap.
    //
    // #461 was: this block sat inline in `checkServer`, so it ran ONLY when the
    // (now deleted) **Check server** button or the `.unknown` primary CTA was
    // pressed. Pull-to-refresh reads the same server through `silentProbe` and
    // left the orphan unadopted. One function, two callers — which is what let
    // the button go without taking the behaviour with it.
    //
    // Cheap by construction: both guards fail on every host that already has a
    // container on record, so the extra SSH round-trip only happens on a host
    // the app knows nothing about. `scanContainers` is the one call in this path
    // that touches `provisioner.status`, so on exactly that host the cards lock
    // for its duration — the honest cost of an SSH call, and it clears itself.
    private func adoptOrphanContainer(_ host: ServerHost, secret: SSHSecret,
                                      base: HostBase) async -> HostBase {
        // #469 was: `.first` — podman lists newest first, so on a multi-protocol
        // host the freshly added SIBLING was adopted as the host's "primary",
        // and every host-level op (stop, update, uninstall, logs) then aimed at
        // it. The primary is `olcrtc-server-<id>`; every sibling is that name
        // plus `-<carrier>`, so the primary is the shortest name of the set.
        guard host.lastContainerName == nil, !base.hasContainer,
              let scanned = try? await provisioner.scanContainers(on: host, secret: secret),
              let found = scanned.min(by: { $0.name.count < $1.name.count })
        else { return base }
        var updated = host
        updated.lastContainerName = found.name
        serverStore.update(updated, password: nil)
        LogStore.shared.log(.provisioning, L10n.autoDetectedContainer_fmt.formatted(found.name))
        if case .running = found.status { return .running }
        return .stopped
    }
    // eoc #461

    // MARK: #456 — ops must prove themselves
    //
    // "Installed" used to mean "the script printed a URI and podman says Up".
    // Every op that creates or changes a deployment now ends with a forced,
    // end-to-end verification of the record it produced. The op's terminal
    // HostBase is NOT blocked on it: the base stays the honest podman-level
    // fact, and health is the separate, honest claim beside it.

    /// #456: forced verification of ONE record, if it still exists.
    private func verifyRecord(_ id: UUID?) async {
        guard let id, let rec = connections.connections.first(where: { $0.id == id }) else { return }
        await health.verify(rec, using: tunnel, force: true)
    }

    /// #456: forced verification of every record this host links to (primary +
    /// extras), read back from the store so a just-finished install is included.
    /// The coordinator runs them one at a time.
    private func verifyLinked(_ hostID: UUID) async {
        guard let host = serverStore.hosts.first(where: { $0.id == hostID }) else { return }
        let ids = [host.lastConnectionID].compactMap { $0 } + (host.extraConnectionIDs ?? [])
        for id in ids { await verifyRecord(id) }
    }

    /// #456: the record this host's PRIMARY container serves, read fresh from
    /// the store (an op may have just linked it).
    private func primaryRecordID(_ hostID: UUID) -> UUID? {
        serverStore.hosts.first(where: { $0.id == hostID })?.lastConnectionID
    }

    /// #456: remember a room per carrier so install / reconfigure stop asking
    /// for what the app already knows (requirement 8). Auto-generated (empty)
    /// rooms are never stored.
    private func rememberRoom(_ options: InstallOptions) {
        let room = options.roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !room.isEmpty else { return }
        RoomMemory.remember(carrier: options.carrier, room: room)
    }

    /// SSH status probe + TCP ping. The probe is the authoritative base setter.
    private func checkServer(_ host: ServerHost) async {
        Task { await doPing(host) }  // parallel TCP ping; updates the Ping metric
        await run(.check, on: host) { secret in
            let (rstate, stats) = try await provisioner.checkReadiness(
                on: host, secret: secret, containerName: host.lastContainerName)
            if let stats { vpsStats[host.id] = stats }
            // #456: stamp the probe so the process caption can say how old this
            // verdict is, and so the on-entry refresh skips a freshly-checked host.
            // Both clocks: `checkReadiness` RETURNED, so this is a real reading.
            lastProbe[host.id]   = Date()
            lastProbeOK[host.id] = Date()   // #456 (audit)
            // #461 was: the #302 auto-detect/adopt block, inline here. Same
            // code, same guards, now shared with `silentProbe` so a pull adopts
            // an orphaned container too. Kept on THIS path as well: `.unknown`
            // offers Check server as its only CTA, and a re-added VPS is exactly
            // the host that must not be offered Install instead.
            return await adoptOrphanContainer(host, secret: secret, base: HostBase(rstate))
        }
        await refreshCarriers(host.id)   // #452
    }

    // boc #456: requirement 8 — never blow away a working deployment silently.
    // scripts/srv.sh force-removes EVERY `olcrtc-server-*` container (and every
    // superseded deploy dir) before installing, and Install is the primary CTA
    // whenever no container is on record — which includes "never probed". So a
    // host we don't know is scanned first, and anything found becomes a choice.

    // boc #457: the scan is now VISIBLE and its failure is FATAL to the install.
    // #457 was: the whole body ran silently (tapping Install blocked for seconds
    // with no feedback at all) and swallowed the error —
    //   `guard let found = try? await provisioner.scanContainers(…) else { installFor = host }`
    // — so a scan that could not run fell straight through to the destructive
    // branch. Nothing may be asserted from an absence of information: a failed
    // scan offers NEITHER fork, and says why on the card.
    private func beginInstall(_ host: ServerHost) async {
        guard !actionsDisabled else { return }
        guard !currentBase(host).hasContainer, let secret = secret(for: host) else {
            installFor = host; return
        }
        let previous = currentBase(host)
        // The card already knows how to render a running op — reuse it rather
        // than inventing a second busy vocabulary. `.check` is the honest verb:
        // this IS a read of the server, and its Retry re-runs the full check.
        display[host.id] = HostDisplay.start(.check, from: previous)
            .advanced(note: L10n.vpsScanBeforeInstall.localized())
        do {
            let found = try await provisioner.scanContainers(on: host, secret: secret)
            display[host.id] = .base(previous)
            if found.isEmpty { installFor = host }
            else             { installChoice = InstallChoiceRequest(host: host, found: found) }
        } catch {
            LogStore.shared.log(.provisioning,
                "⚠ pre-install scan failed: \(error.localizedDescription)")
            // The raw Citadel / stderr text never becomes the headline — route it
            // through the same mapper the health layer uses (#456).
            let why = HealthFailureMapper.reason(forSSH: error.localizedDescription).message
            display[host.id] = HostDisplay.start(.check, from: previous)
                .failed(message: L10n.vpsScanFailed_fmt.formatted(why))
        }
    }
    // eoc #457

    /// #456: adopt what is already running — link the container, then recover its
    /// connection (room + key) from the deployed server.yaml. Nothing is
    /// destroyed and nothing is re-asked that the server already knows.
    private func adoptExisting(_ req: InstallChoiceRequest) {
        guard let container = req.found.first else { return }
        restoreContainer(container, on: req.host)
        Task {
            await recoverConnection(req.host, containerName: container.name,
                                    configFile: "server.yaml", asExtra: false)
        }
    }
    // eoc #456

    // #452 was: install(_ host:options:) — single protocol. Now installs the
    // primary via srv.sh, then each additional protocol via add-carrier.sh
    // (sibling containers off the same deploy dir, shared key), creating one
    // ConnectionRecord per protocol.
    private func install(_ host: ServerHost, primary: InstallOptions, extras: [InstallOptions]) async {
        await run(.install, on: host) { secret in
            let result = try await provisioner.install(on: host, secret: secret, options: primary)
            let cfg = try OlcrtcURI.parse(result.uri)
            // #355 (audit A1): carry the vp8 + sei tuning the install URI may
            // encode (server-script format) instead of dropping them to
            // defaults; nil payload fields fall back to OlcrtcConnection's own
            // defaults, same as the recover path.
            // #401: via the shared Parsed → connection mapping.
            var params = OlcrtcConnection(from: cfg)
            // #436: the wbstream token isn't in the URI (upstream keeps it out), so
            // carry it from the install options onto the connection — the client
            // must send the same auth.token it just wrote into the server config.
            params.wbToken = primary.wbToken
            // #452: with extras every record (primary included) is suffixed by
            // its carrier, so the per-protocol connections stay tellable-apart.
            // boc #470: an install over a host that still links records — its
            // container vanished, or the user chose "Reinstall anyway" — is an
            // uninstall of everything the host linked (srv.sh force-removes every
            // olcrtc-server-* first) followed by a fresh install. It used to
            // `add` beside the old records: the list grew a twin with the same
            // name, the dead twin stayed the primary, and auto-connect dialled
            // it. The #467 rule applies — correct the linked record in place,
            // add only when the slot holds none; an extra the reinstall does not
            // bring back follows the uninstall rule (`clearInstalledState`).
            // #470 was:
            //     let record = ConnectionRecord(name: …, details: .olcrtc(params))
            //     connections.add(record)
            //     var updated = host
            //     updated.lastContainerName = result.containerName
            //     updated.lastConnectionID  = record.id
            var updated = host
            updated.lastContainerName = result.containerName
            updated.lastConnectionID  = upsertRecord(
                id: host.lastConnectionID,
                name: Self.recordName(host: host, carrier: primary.carrier, multi: !extras.isEmpty),
                params: params)
            var spareExtras = host.extraConnectionIDs ?? []
            // eoc #470
            // boc #452: additional protocols — one add-carrier.sh run each. A
            // per-protocol failure skips just that protocol (collected into one
            // alert) instead of failing the whole install.
            var extraIDs: [UUID] = []
            var failedCarriers: [String] = []
            for extra in extras {
                do {
                    let extraResult = try await provisioner.addCarrier(
                        on: host, secret: secret,
                        baseContainer: result.containerName, options: extra)
                    let extraCfg = try OlcrtcURI.parse(extraResult.uri)
                    var extraParams = OlcrtcConnection(from: extraCfg)
                    extraParams.wbToken = extra.wbToken
                    // #470: reuse this carrier's previous extra record (see above).
                    let reuse = spareExtras.first { recordCarrier($0) == extra.carrier }
                    spareExtras.removeAll { $0 == reuse }
                    // #470 was: let extraRecord = ConnectionRecord(name: …, details: …)
                    //           connections.add(extraRecord); extraIDs.append(extraRecord.id)
                    extraIDs.append(upsertRecord(
                        id: reuse,
                        name: Self.recordName(host: host, carrier: extra.carrier, multi: true),
                        params: extraParams))
                    LogStore.shared.log(.provisioning,
                        "＋ protocol \(extra.carrier)/\(extra.transport) added → \(extraResult.containerName)")
                } catch {
                    failedCarriers.append(CarrierTransportMatrix.carrierLabel(extra.carrier))
                    LogStore.shared.log(.provisioning,
                        "✗ extra protocol \(extra.carrier) failed: \(error.localizedDescription)")
                }
            }
            // #470: extras the reinstall did not bring back — their containers
            // are gone, exactly as after an uninstall.
            forgetSupersededRecords(spareExtras)
            updated.extraConnectionIDs = extraIDs.isEmpty ? nil : extraIDs
            serverStore.update(updated, password: nil)
            if !failedCarriers.isEmpty {
                alertText = L10n.installExtrasPartialFail_fmt.formatted(
                    failedCarriers.joined(separator: ", "))
            }
            // eoc #452
            // #258 was: readiness[id] = .containerRunning("just installed") (optimistic).
            // Confirm the real post-install state with a probe instead.
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, secret: secret, containerName: result.containerName)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
        await refreshCarriers(host.id)   // #452
        // boc #456: the install must PROVE itself — "installed" stops meaning
        // "the script printed a URI". Also remember the rooms it used.
        rememberRoom(primary)
        for extra in extras { rememberRoom(extra) }
        await verifyLinked(host.id)
        // eoc #456
    }

    private func uninstall(_ host: ServerHost) async {
        await run(.uninstall, on: host) { secret in
            try await provisioner.uninstall(on: host, secret: secret,
                                            containerName: host.lastContainerName)
            // #452 was: inline lastConnectionID-only cleanup — the shared helper
            // also removes the extra-protocol records + the cached rows.
            serverStore.update(clearInstalledState(host), password: nil)
            return .imageReady   // container gone, image still cached (deterministic)
        }
    }

    private func update(_ host: ServerHost) async {
        await run(.update, on: host) { secret in
            // #451: the update script resolves a container even when none is
            // recorded (first olcrtc-server-* sweep) and reports it via
            // OLCRTC_UPDATE_CONTAINER — adopt it like checkServer's #302
            // auto-detect does. Previously the resolved name was discarded, so
            // the post-update probe was silently skipped for such hosts.
            let resolved = try await provisioner.update(on: host, secret: secret,
                                                        containerName: host.lastContainerName)
            var cname = host.lastContainerName
            if let resolved, !resolved.isEmpty, resolved != cname {
                var updated = host
                updated.lastContainerName = resolved
                serverStore.update(updated, password: nil)
                LogStore.shared.log(.provisioning, L10n.autoDetectedContainer_fmt.formatted(resolved))
                cname = resolved
            }
            guard let cname else { return nil }
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, secret: secret, containerName: cname)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
        await refreshCarriers(host.id)   // #452
    }

    private func startContainer(_ host: ServerHost) async {
        await run(.start, on: host) { secret in
            guard let cname = host.lastContainerName else {
                throw ProvisionError.parseFailed(L10n.containerNotInstalled.localized())
            }
            // #258 was: readiness[id] = .containerRunning("starting…") before the probe.
            try await provisioner.start(on: host, secret: secret, containerName: cname)
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, secret: secret, containerName: cname)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
        await refreshCarriers(host.id)   // #452
        // #456: a started container is a running PROCESS — prove it carries
        // traffic before anything on this card turns green.
        await verifyRecord(primaryRecordID(host.id))
    }

    private func stop(_ host: ServerHost) async {
        await run(.stop, on: host) { secret in
            guard let cname = host.lastContainerName else {
                throw ProvisionError.parseFailed(L10n.containerNotInstalled.localized())
            }
            // #258 was: readiness[id] = .containerStopped("stopping…") before the probe.
            try await provisioner.stop(on: host, secret: secret, containerName: cname)
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, secret: secret, containerName: cname)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
        await refreshCarriers(host.id)   // #452
    }

    private func deepUninstall(_ host: ServerHost, removeImage: Bool) async {
        await run(.deepUninstall, on: host) { secret in
            try await provisioner.deepUninstall(on: host, secret: secret,
                                                containerName: host.lastContainerName,
                                                removeImage: removeImage)
            // #452 was: inline lastConnectionID-only cleanup — the shared helper
            // also removes the extra-protocol records + the cached rows.
            serverStore.update(clearInstalledState(host), password: nil)
            let (rstate, _) = try await provisioner.probeReadiness(
                on: host, secret: secret, containerName: nil)
            return HostBase(rstate)
        }
    }

    private func reboot(_ host: ServerHost) async {
        await run(.reboot, on: host) { secret in
            try await provisioner.reboot(on: host, secret: secret)
            return nil   // host going down; keep the previous base, user re-checks
        }
    }

    // #452 was: reconfigure(_ host:options:) targeting host.lastContainerName +
    // host.lastConnectionID. Now targets an explicit protocol container and its
    // resolved record, so each row on a multi-protocol host reconfigures ITS
    // own container.
    private func reconfigure(_ host: ServerHost, containerName: String,
                             recordID: UUID?, options: InstallOptions) async {
        // #469: read BEFORE the restart takes the answer away (same rule as the
        // telemost renewal): is the live tunnel riding the record we are about
        // to reconfigure?
        let wasRiding = recordID != nil && tunnel.connectedRecord?.id == recordID
        // #470: remember WHAT this run targets, so the card's Retry re-opens the
        // sheet on the same container with the same values (see `lastReconfigure`).
        lastReconfigure[host.id] = ReconfigureRequest(
            host: host, containerName: containerName, recordID: recordID,
            initialCarrier: options.carrier, initialTransport: options.transport,
            initialRoom: options.roomID,
            initialWbToken: options.wbToken.isEmpty ? nil : options.wbToken,
            initialJitsiBase: options.carrier == "jitsi" ? options.jitsiBaseURL : nil)
        await run(.reconfigure, on: host) { secret in
            let newURI = try await provisioner.reconfigure(on: host, secret: secret,
                                                           containerName: containerName, options: options)
            // Update the linked ConnectionRecord with the new room/transport.
            // #452 was: connID = host.lastConnectionID — now the record the
            // reconfigured row resolved to.
            if let uri = newURI,
               let connID = recordID,
               let existing = connections.connections.first(where: { $0.id == connID }),
               case .olcrtc(let oldParams) = existing.details,
               let cfg = try? OlcrtcURI.parse(uri) {
                // #355 (audit A1): carry the sei tuning through the rebuild —
                // these were dropped, resetting SEI to defaults on every
                // reconfigure. Mirror how vp8FPS/vp8BatchSize are preserved.
                // #451: wbToken tracks what reconfigure just wrote server-side
                // — the new token for wbstream, cleared for other carriers
                // (reconfigureScript deletes the auth.token line) — so client
                // and server auth stay in lock-step.
                let updated = OlcrtcConnection(
                    carrier:      cfg.carrier,
                    transport:    cfg.transport,
                    roomID:       cfg.roomID,
                    key:          cfg.key.isEmpty ? oldParams.key : cfg.key,
                    clientID:     cfg.clientID,
                    vp8FPS:       oldParams.vp8FPS,
                    vp8BatchSize: oldParams.vp8BatchSize,
                    socksUser:    oldParams.socksUser,
                    socksPass:    oldParams.socksPass,
                    wbToken:      cfg.carrier == "wbstream" ? options.wbToken : "",
                    seiFPS:       oldParams.seiFPS,
                    seiBatch:     oldParams.seiBatch,
                    seiFrag:      oldParams.seiFrag,
                    seiACK:       oldParams.seiACK,
                    // #465: the 24 h clock belongs to the ROOM, so it restarts
                    // only when the room actually changed — a transport-only
                    // reconfigure must not make an old room look fresh. Carrying
                    // it explicitly is required: this rebuild lists every field,
                    // which is exactly how sei and wbToken were once lost here.
                    roomCreatedAt: cfg.roomID == oldParams.roomID
                                 ? oldParams.roomCreatedAt : Date()
                )
                var updatedRecord = existing
                updatedRecord.details = .olcrtc(updated)
                connections.update(updatedRecord)
            }
            // #452: probe the PRIMARY container — the host base describes it,
            // and a sibling-row reconfigure must not flip the card's base to
            // the sibling's state.
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, secret: secret, containerName: host.lastContainerName ?? containerName)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
        // boc #469: the EXPECTED outcome when the command rides the container it
        // restarts — the yaml is rewritten, `podman restart` kills the SSH
        // session, and the OLCRTC_URI line that would have updated the record
        // never arrives. The server changed; the record did not. Unlike a key
        // rotation nothing here is unknowable: carrier, transport and room are
        // what we just asked for, and reconfigure never touches the key. Apply
        // them locally and reconnect; the #456 re-measure below is the
        // trustworthy answer, not this SSH error.
        if wasRiding, reconfigureFailure(host.id) != nil,
           let id = recordID,
           var existing = connections.connections.first(where: { $0.id == id }),
           case .olcrtc(var p) = existing.details {
            let roomChanged = p.roomID != options.roomID
            p.carrier   = options.carrier
            p.transport = options.transport
            p.roomID    = options.roomID
            if roomChanged { p.roomCreatedAt = Date() }
            existing.details = .olcrtc(p)
            connections.update(existing)
            LogStore.shared.log(.provisioning,
                "• Reconfigure dropped the session it rode (expected) — applied \(options.carrier)/\(options.transport) locally; re-measuring")
            tunnel.disconnect()
            if let fresh = connections.connections.first(where: { $0.id == id }) {
                tunnel.connect(record: fresh)
            }
        }
        // eoc #469
        await refreshCarriers(host.id)   // #452
        // boc #456: a reconfigure rewrites room/transport server-side — the row's
        // old verdict describes a deployment that no longer exists, so re-measure.
        rememberRoom(options)
        await verifyRecord(recordID)
        // eoc #456
    }

    // MARK: #452 — Protocols on the host card (multi-carrier)
    //
    // One VPS can now run several olcrtc protocols side by side (sibling
    // containers off one deploy dir / one key — scripts/add-carrier.sh). The
    // card lists them as rows: status dot + carrier/transport + a row menu
    // (Connect / Start / Stop / Reconfigure / Recover / Remove). Rows come from
    // provisioner.listCarriers (SSHRunner.CarrierInfo) and refresh after every
    // op. Add/remove/sibling start/stop run OUTSIDE `run` — the host's base
    // state describes the PRIMARY container and doesn't change — following the
    // rotateKey/recoverConnection pattern, serialized by `carrierBusyHostID`.

    private func missingCarriers(_ host: ServerHost) -> [String] {
        guard let rows = carrierRows[host.id] else { return [] }
        let present = Set(rows.map(\.provider))
        return CarrierTransportMatrix.carriers.filter { !present.contains($0) }
    }

    /// Row → the ConnectionRecord to connect with: the host-linked records
    /// first (primary + extras), then any record matching carrier + room.
    // boc #467: the room is MUTABLE state of a protocol, not part of its
    // identity. Matching on carrier+room meant that the moment the server's room
    // changed — a renewal, an edit made elsewhere, or #466 applying one to the
    // wrong config — the row stopped recognising its own record and the app
    // reported "no saved connection for this protocol" while that connection sat
    // right there. The user's only exit was Recover, which then ADDED a second
    // record for the same protocol (see recover below), so the list grew a
    // duplicate every time. Match by slot and carrier; use the room only to
    // break ties.
    private func connectionRecord(_ host: ServerHost, row: SSHRunner.CarrierInfo) -> ConnectionRecord? {
        // #470: the resolution itself is the pure static below, so the #467
        // order is pinned by `Review470ServersTests` instead of trusted.
        Self.resolveRecord(host: host, row: row, records: connections.connections)
    }

    /// #470: the #467 row → record resolution as a pure function. Order:
    /// own slot exact → own slot by carrier → any linked exact → any linked by
    /// carrier → an unlinked import, exact only. This is the READ resolver —
    /// what a row connects and verifies through; the write side is
    /// `resolveSlotRecord`.
    static func resolveRecord(host: ServerHost, row: SSHRunner.CarrierInfo,
                              records: [ConnectionRecord]) -> ConnectionRecord? {
        func record(_ id: UUID) -> ConnectionRecord? {
            records.first { $0.id == id }
        }
        func carrier(of rec: ConnectionRecord) -> String? {
            if case .olcrtc(let p) = rec.details { return p.carrier }
            return nil
        }
        func exact(_ rec: ConnectionRecord) -> Bool {
            if case .olcrtc(let p) = rec.details {
                return p.carrier == row.provider && p.roomID == row.room
            }
            return false
        }
        // A host can legitimately hold two rows of the SAME carrier (the primary
        // and a sibling), so resolve inside the row's own slot first — that is
        // what keeps a sibling from claiming the primary's record.
        if let rec = resolveSlotRecord(host: host, isPrimary: row.isPrimary,
                                       carrier: row.provider, room: row.room,
                                       records: records) { return rec }
        // Then anything else linked to this host, then an unlinked import.
        let linked = ([host.lastConnectionID].compactMap { $0 } + (host.extraConnectionIDs ?? []))
            .compactMap(record)
        if let rec = linked.first(where: exact) { return rec }
        if let rec = linked.first(where: { carrier(of: $0) == row.provider }) { return rec }
        return records.first(where: exact)
    }
    // eoc #467

    /// #470: the WRITE-side twin of `resolveRecord`, for what destroys or
    /// re-keys a record: strictly the row's OWN slot (the host's extras for a
    /// sibling, `lastConnectionID` for the primary) — exact carrier+room first,
    /// then carrier alone — and nothing beyond it. `resolveRecord`'s wider
    /// fallbacks exist so a row can still be CONNECTED through a record the
    /// host merely knows about; handed to Remove protocol they deleted the
    /// primary's record (same carrier, the sibling's own record gone) and the
    /// host's link dangled, and handed to the post-rotation refresh they
    /// rewrote another host's key.
    static func resolveSlotRecord(host: ServerHost, isPrimary: Bool, carrier: String, room: String,
                                  records: [ConnectionRecord]) -> ConnectionRecord? {
        func params(_ rec: ConnectionRecord) -> OlcrtcConnection? {
            if case .olcrtc(let p) = rec.details { return p }
            return nil
        }
        let slotIDs: [UUID] = isPrimary
            ? [host.lastConnectionID].compactMap { $0 }
            : (host.extraConnectionIDs ?? [])
        let slot = slotIDs.compactMap { id in records.first { $0.id == id } }
        if let rec = slot.first(where: { rec in
            guard let p = params(rec) else { return false }
            return p.carrier == carrier && p.roomID == room
        }) { return rec }
        return slot.first(where: { params($0)?.carrier == carrier })
    }

    /// #470: the row is the container's CURRENT room; a record that resolved by
    /// carrier alone (the #467 fallback) may still hold the room the server has
    /// since LEFT — a renewal made elsewhere, another device, a hand edit. The
    /// verdict under such a row was measured against that old room, and Verify
    /// would dial it again. An empty row room is an unread yaml, not a drift.
    static func roomDrifted(_ record: ConnectionRecord?, from row: SSHRunner.CarrierInfo) -> Bool {
        guard let record, case .olcrtc(let p) = record.details, !row.room.isEmpty else { return false }
        return p.roomID != row.room
    }

    /// Whether the LIVE tunnel runs through this row's protocol (carrier+room).
    private func isLiveRow(_ row: SSHRunner.CarrierInfo) -> Bool {
        guard let rec = tunnel.connectedRecord, case .olcrtc(let p) = rec.details else { return false }
        return p.carrier == row.provider && p.roomID == row.room
    }

    private func connectVia(_ host: ServerHost, row: SSHRunner.CarrierInfo) {
        guard let record = connectionRecord(host, row: row) else {
            alertText = L10n.protocolRecordMissing.localized()
            return
        }
        LogStore.shared.log(.provisioning,
            "▶ Connect via \(row.provider)/\(row.transport) (host card)")
        // A live session through another record is handled by connect() itself
        // (it disconnects, then dials the new record).
        tunnel.connect(record: record)
    }

    // boc #457: `protocolsSection`, `carrierRowView` and `carrierRowLead` moved
    // to App/Views/ProtocolRowView.swift (the row) and App/Views/ServerCardView.swift
    // (the section around it); `rowView` above resolves one row's inputs. What
    // changed on the way out:
    //   • #455's aurora WASH, its `signalCyan` hairline and the cyan checkmark
    //     are gone — `Theme.Palette.auroraSoft` is deleted, and "live" was a
    //     colour with no word behind it. The aurora is now a 3pt leading spine
    //     shown only on a live row a probe has VERIFIED: a verdict, not a style.
    //   • the raw `podman ps` status ("Up 3 hours", "Exited (137) 5 minutes ago")
    //     is out of the row subtitle; a stopped protocol says so in one sentence.
    // eoc #457

    // #456 was: carrierStatusColor(_:) — the podman-"Up"→green rule that painted
    // the user's dead telemost row green. Deleted; the dot is health-driven now.

    /// #456: probe THIS row end-to-end and stamp the result. Forced — the user
    /// asked, so the coordinator's 2-minute debounce doesn't apply.
    private func verifyRow(_ host: ServerHost, row: SSHRunner.CarrierInfo) {
        guard let rec = connectionRecord(host, row: row) else {
            alertText = L10n.protocolRecordMissing.localized()
            return
        }
        Task { await health.verify(rec, using: tunnel, force: true) }
    }

    private func carrierMenuItems(_ host: ServerHost, row: SSHRunner.CarrierInfo) -> [OlcMenuItem] {
        let rowState = rowHealth(host, row: row)
        let suggested = rowState.suggestedAction
        var items: [OlcMenuItem] = []
        // A telemost row leads with "new room": an expired room's suggested fix
        // is "Change room / transport", which asks for a room id the owner does
        // not have yet — this item is the errand that produces one.
        if row.provider == "telemost" {
            items.append(.action(L10n.telemostNewRoomAction.localized(),
                                 systemImage: "arrow.triangle.2.circlepath") {
                beginTelemostRenew(host, row: row)
            })
        }
        // A verdict that names its own fix offers it first (and is skipped in
        // its usual position below, so no action is listed twice). A record
        // whose room drifted from the container's room gets Recover the same way.
        let drifted = Self.roomDrifted(connectionRecord(host, row: row), from: row)
        if suggested == .recoverConnection || drifted { items.append(recoverItem(host, row: row)) }
        if suggested == .checkRoom         { items.append(reconfigureItem(host, row: row)) }
        items.append(.action(L10n.healthActionVerify.localized(), systemImage: "checkmark.shield") {
            verifyRow(host, row: row)
        })
        if !isLiveRow(row) {
            items.append(.action(L10n.actionConnect.localized(), systemImage: "personalhotspot") {
                connectVia(host, row: row)
            })
        }
        if Self.isUp(row.status) {
            // #468 was: `L10n.actionStop` — "Stop server". On a protocol row this
            // stops that protocol's container, and on a multi-protocol host the
            // others keep running, so the old wording promised something the
            // action does not do. The card's own button still says "Stop server".
            items.append(.action(L10n.protocolStopAction.localized(), systemImage: "stop.fill", role: .destructive) {
                if row.isPrimary { Task { await stop(host) } }
                else             { Task { await stopCarrier(host, row: row) } }
            })
        } else if !row.isPrimary, row.status == .notFound {
            // boc #470: the yaml is there but its container is not
            // (`STATUS=missing`, e.g. removed by hand). "Start" here ran
            // `podman start` on a name that does not exist and could only fail
            // with a raw podman error — a dead end whose one real exit was
            // Remove + Add protocol. add-carrier.sh replaces in place (it
            // `rm -f`s a same-named container and rewrites the yaml), so the
            // row can be rebuilt from exactly what it still describes.
            items.append(.action(L10n.protocolRecreateAction.localized(), systemImage: "arrow.clockwise.circle") {
                Task { await addCarrier(host, options: recreateOptions(host, row: row)) }
            })
            // eoc #470
        } else {
            items.append(.action(L10n.protocolStartAction.localized(), systemImage: "play.fill") {
                if row.isPrimary { Task { await startContainer(host) } }
                else             { Task { await startCarrier(host, row: row) } }
            })
        }
        if suggested != .checkRoom { items.append(reconfigureItem(host, row: row)) }   // #457
        // #456 was: `if connectionRecord(host, row: row) == nil` — the user's actual
        // incident was the opposite case: they reinstalled the server, so its key
        // changed, their stored key stopped matching, and the handshake failed with
        // "read welcome / handshake client". A row whose probe reported a key
        // mismatch now offers Recover right here, stale record and all.
        // #457: …and when the verdict asked for it, it is already at the top.
        if suggested != .recoverConnection, connectionRecord(host, row: row) == nil {
            items.append(recoverItem(host, row: row))
        }
        // #456: explain a failure in human terms, in place — never raw core log
        // lines. "Couldn't check" gets the same item; it is a different sentence.
        switch rowState {
        case .broken, .inconclusive:
            items.append(.action(L10n.healthShowReasonAction.localized(), systemImage: "questionmark.circle") {
                alertText = "\(rowState.title)\n\n\(rowState.subtitle)"
            })
        default:
            break
        }
        if !row.isPrimary {
            items.append(.divider)
            items.append(.action(L10n.removeProtocolAction.localized(), systemImage: "trash", role: .destructive) {
                removeCarrierConfirm = CarrierRemoveRequest(host: host, row: row)
            })
        }
        return items
    }

    /// #457: "Re-read the settings from the server" as ONE item, so it can be
    /// hoisted to the top of the menu when the verdict asks for it without being
    /// written out twice.
    private func recoverItem(_ host: ServerHost, row: SSHRunner.CarrierInfo) -> OlcMenuItem {
        .action(L10n.actionRecoverConnection.localized(), systemImage: "arrow.counterclockwise.circle") {
            recoverRowRequest = CarrierRecoverRequest(
                host: host, container: row.container, file: row.file, isPrimary: row.isPrimary)
        }
    }

    /// #457: same, for "Change room / transport".
    private func reconfigureItem(_ host: ServerHost, row: SSHRunner.CarrierInfo) -> OlcMenuItem {
        .action(L10n.actionChangeRoomTransport.localized(), systemImage: "slider.horizontal.3") {
            // #456: seeded through the shared builder, so the wbstream token and
            // the jitsi instance the record already holds are carried in.
            reconfigureRequest = rowReconfigureRequest(host, row: row)
        }
    }

    /// Passive rows refresh — logs failures, never alerts.
    private func refreshCarriers(_ hostID: UUID) async {
        guard let host = serverStore.hosts.first(where: { $0.id == hostID }),
              let cname = host.lastContainerName,
              let secret = secret(for: host) else { return }
        carrierListInFlight.insert(hostID)            // #470
        defer { carrierListInFlight.remove(hostID) }  // #470
        do {
            let rows = try await provisioner.listCarriers(
                on: host, secret: secret, baseContainer: cname)
            let now = Date()
            carrierRows[hostID]   = rows
            carrierRowsAt[hostID] = now               // #470: the rows' own read clock
            recordCarriers(rows, for: hostID, at: now) // round 2 (D): the next cold start draws these
        } catch {
            LogStore.shared.log(.provisioning,
                "⚠ protocol list failed: \(error.localizedDescription)")
            // boc #470: the previous rows used to stay put — hours-old podman
            // state per protocol under a read stamp the readiness probe (a
            // different SSH call) had just refreshed, and with rows on screen
            // the Scan item that repairs a stale container name never showed.
            // Nothing is asserted from a listing that did not happen: the card
            // says the protocols have not been read, and the next appear
            // re-fetches them (`hostCard`'s lazy load keys on nil).
            carrierRows[hostID]   = nil
            carrierRowsAt[hostID] = nil
            recordCarriers(nil, for: hostID, at: nil) // and the snapshot forgets them too
            // eoc #470
        }
    }

    private func addCarrier(_ host: ServerHost, options: InstallOptions) async {
        guard let secret = secret(for: host) else {
            alertText = missingCredentialMessage(host); return
        }
        guard let cname = host.lastContainerName else {
            alertText = L10n.containerNotInstalled.localized(); return
        }
        carrierBusyHostID = host.id
        defer { carrierBusyHostID = nil }
        do {
            let result = try await provisioner.addCarrier(
                on: host, secret: secret, baseContainer: cname, options: options)
            let cfg = try OlcrtcURI.parse(result.uri)
            // #401: shared Parsed → connection mapping; #436: the wb token isn't
            // in the URI, carry it from the options (same as install).
            var params = OlcrtcConnection(from: cfg)
            params.wbToken = options.wbToken
            // boc #470: the #467 rule here too. The extras slot may already hold
            // this carrier's record — the yaml vanished and "Add protocol" offers
            // the carrier again, or a `.notFound` row is being re-created — and
            // `add` grew a second record for one protocol. Correct it in place.
            // #470 was: let record = ConnectionRecord(name: …, details: .olcrtc(params))
            //           connections.add(record)
            //           updated.extraConnectionIDs = (updated.extraConnectionIDs ?? []) + [record.id]
            let reuse = Self.resolveSlotRecord(host: host, isPrimary: false,
                                               carrier: options.carrier, room: options.roomID,
                                               records: connections.connections)
            let addedID = upsertRecord(
                id: reuse?.id,
                name: Self.recordName(host: host, carrier: options.carrier, multi: true),
                params: params)
            var updated = host
            var extraIDs = updated.extraConnectionIDs ?? []
            if !extraIDs.contains(addedID) { extraIDs.append(addedID) }
            updated.extraConnectionIDs = extraIDs
            // eoc #470
            serverStore.update(updated, password: nil)
            LogStore.shared.log(.provisioning,
                "＋ protocol \(cfg.carrier)/\(cfg.transport) added → \(result.containerName)")
            // #470: the service's name, as the row underneath prints it (#461).
            // #470 was: .formatted(cfg.carrier, cfg.transport)
            alertText = L10n.protocolAdded_fmt.formatted(
                CarrierTransportMatrix.carrierLabel(cfg.carrier),
                CarrierTransportMatrix.transportLabel(cfg.transport))
            await refreshCarriers(host.id)
            // boc #456: prove the protocol we just added actually carries
            // traffic, and remember the room it used. Fire-and-forget: this
            // function holds `carrierBusyHostID` until it returns (its `defer`),
            // and a ~10 s probe must not keep the row's menus locked — the chip
            // renders `.checking` on its own while the coordinator works.
            rememberRoom(options)
            // #470 was: let addedID = record.id
            Task { await verifyRecord(addedID) }
            // eoc #456
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    private func removeCarrier(_ host: ServerHost, row: SSHRunner.CarrierInfo) async {
        guard let secret = secret(for: host) else {
            alertText = missingCredentialMessage(host); return
        }
        guard let cname = host.lastContainerName else {
            alertText = L10n.containerNotInstalled.localized(); return
        }
        carrierBusyHostID = host.id
        defer { carrierBusyHostID = nil }
        do {
            // #469 was: `carrier: row.provider` → `<base>-<provider>`. A sibling's
            // carrier is mutable (Change room / transport rewrites `provider:` in
            // ITS file), after which the derived name pointed at a container
            // that does not exist — or at a different sibling. The row already
            // knows its container and its config file; delete exactly those.
            try await provisioner.removeCarrier(
                on: host, secret: secret, baseContainer: cname,
                container: row.container, configFile: row.file)
            // #470 was: `connectionRecord(host, row: row)` — the READ resolver,
            // whose fallbacks reach the primary's record and unlinked imports.
            // With the sibling's own record gone it deleted the primary's (same
            // carrier) and left `lastConnectionID` dangling, or dropped a QR
            // import of the same room. Only a record in the extras slot goes.
            // `isPrimary: false` unconditionally: the script has just refused
            // anything that names the primary, so this can only be a sibling.
            if let record = Self.resolveSlotRecord(host: host, isPrimary: false,
                                                   carrier: row.provider, room: row.room,
                                                   records: connections.connections) {
                connections.remove(id: record.id)
                var updated = host
                updated.extraConnectionIDs = (updated.extraConnectionIDs ?? []).filter { $0 != record.id }
                if updated.extraConnectionIDs?.isEmpty == true { updated.extraConnectionIDs = nil }
                serverStore.update(updated, password: nil)
            }
            LogStore.shared.log(.provisioning, "− protocol \(row.provider) removed")
            alertText = L10n.protocolRemoved_fmt.formatted(CarrierTransportMatrix.carrierLabel(row.provider))
            await refreshCarriers(host.id)
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    /// Start/Stop for a NON-primary protocol container — outside `run` (the
    /// host's base tracks the primary; a sibling flip doesn't change it).
    private func startCarrier(_ host: ServerHost, row: SSHRunner.CarrierInfo) async {
        guard let secret = secret(for: host) else {
            alertText = missingCredentialMessage(host); return
        }
        carrierBusyHostID = host.id
        defer { carrierBusyHostID = nil }
        do {
            try await provisioner.start(on: host, secret: secret, containerName: row.container)
            await refreshCarriers(host.id)
            // #456: same rule as the primary Start — a running process is not
            // yet a working protocol, so measure it before anything turns green.
            // Fire-and-forget for the same reason as addCarrier (busy flag).
            let startedID = connectionRecord(host, row: row)?.id
            Task { await verifyRecord(startedID) }
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    private func stopCarrier(_ host: ServerHost, row: SSHRunner.CarrierInfo) async {
        guard let secret = secret(for: host) else {
            alertText = missingCredentialMessage(host); return
        }
        carrierBusyHostID = host.id
        defer { carrierBusyHostID = nil }
        do {
            try await provisioner.stop(on: host, secret: secret, containerName: row.container)
            await refreshCarriers(host.id)
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    /// #452: shared uninstall cleanup — clears the container link and removes
    /// EVERY connection this host installed (primary + extra protocols) when
    /// the auto-remove setting is on. Returns the cleared host to persist.
    private func clearInstalledState(_ host: ServerHost) -> ServerHost {
        var updated = host
        updated.lastContainerName = nil
        let ids = [updated.lastConnectionID].compactMap { $0 } + (updated.extraConnectionIDs ?? [])
        if SettingsStore.shared.autoRemoveConnectionOnUninstall {
            for id in ids {
                if let conn = connections.connections.first(where: { $0.id == id }) {
                    connections.remove(id: id)
                    LogStore.shared.log(.provisioning, "Connection «\(conn.displayName)» also removed from list.")
                }
            }
        }
        updated.lastConnectionID   = nil
        updated.extraConnectionIDs = nil
        carrierRows[host.id] = nil
        return updated
    }

    /// #452: connection naming — a multi-protocol install suffixes every record
    /// with its carrier ("MyVPS · telemost"); single-protocol keeps the label.
    /// #470: the suffix is the RAW carrier id, never its localized label. The
    /// label was stamped into a persisted name in whichever language was on at
    /// install time, and `ConnectionNaming.stripCarrierSuffix` recognises the
    /// id or the CURRENT label only — so a record installed in Russian kept
    /// «ams-1 · Яндекс Телемост» under an English hero that already said
    /// "Yandex Telemost" above it. A persisted token stays locale-stable
    /// (AGENTS.md); the service's name is drawn at render time from the id.
    /// #470 was: multi ? "\(host.label) · \(CarrierTransportMatrix.carrierLabel(carrier))" : host.label
    static func recordName(host: ServerHost, carrier: String, multi: Bool) -> String {
        multi ? "\(host.label) · \(carrier)" : host.label
    }

    // boc #470: the #467 rule for every path that PRODUCES a connection from the
    // server — install, reinstall, add protocol, re-create.

    /// When `id` still resolves, correct that record in place (its id is what
    /// auto-connect, a live tunnel, the health history and the user's name hang
    /// off) and return it; otherwise add a fresh record and return the new id.
    /// Params straight from the server never know the LOCAL SOCKS credentials,
    /// so those ride along from the prior record — the same merge as recover.
    private func upsertRecord(id: UUID?, name: String, params: OlcrtcConnection) -> UUID {
        if let id, var found = connections.connections.first(where: { $0.id == id }),
           case .olcrtc(let prior) = found.details {
            var merged = params
            merged.socksUser = prior.socksUser
            merged.socksPass = prior.socksPass
            found.details = .olcrtc(merged)
            connections.update(found)
            return id
        }
        let record = ConnectionRecord(name: name, details: .olcrtc(params))
        connections.add(record)
        return record.id
    }

    /// The carrier a linked record holds, for matching a reinstall's extras to
    /// the records the host linked before it.
    private func recordCarrier(_ id: UUID) -> String? {
        guard let rec = connections.connections.first(where: { $0.id == id }),
              case .olcrtc(let p) = rec.details else { return nil }
        return p.carrier
    }

    /// Records whose containers a reinstall has just destroyed without
    /// bringing them back — the `clearInstalledState` rule, on that subset.
    private func forgetSupersededRecords(_ ids: [UUID]) {
        guard SettingsStore.shared.autoRemoveConnectionOnUninstall else { return }
        for id in ids {
            guard let conn = connections.connections.first(where: { $0.id == id }) else { continue }
            connections.remove(id: id)
            LogStore.shared.log(.provisioning, "Connection «\(conn.displayName)» also removed from list.")
        }
    }

    /// The add-carrier.sh options that rebuild a sibling whose container is
    /// gone, from the row the yaml still describes — plus what the yaml row does
    /// not carry (the wbstream token, the sei tuning), read from the record in
    /// the extras slot. A jitsi row's room is the full URL, which the script
    /// keeps verbatim, so the base URL never matters here.
    private func recreateOptions(_ host: ServerHost, row: SSHRunner.CarrierInfo) -> InstallOptions {
        var options = InstallOptions(carrier: row.provider, transport: row.transport, roomID: row.room)
        if let rec = Self.resolveSlotRecord(host: host, isPrimary: false,
                                            carrier: row.provider, room: row.room,
                                            records: connections.connections),
           case .olcrtc(let p) = rec.details {
            options.wbToken  = p.wbToken
            options.seiFPS   = p.seiFPS
            options.seiBatch = p.seiBatch
            options.seiFrag  = p.seiFrag
            options.seiACK   = p.seiACK
        }
        return options
    }
    // eoc #470

    /// Primary reconfigure entry (action bar / host menu / retry): targets the
    /// primary container, seeded from its row when the rows are loaded.
    /// #456: when the rows are NOT loaded yet the seeds used to be nil — the
    /// sheet opened blank and confirming it rewrote the server with defaults.
    /// Fall back to the host's linked record, which carries the same values.
    private func primaryReconfigureRequest(_ host: ServerHost) -> ReconfigureRequest? {
        guard let cname = host.lastContainerName else { return nil }
        let row = carrierRows[host.id]?.first(where: { $0.isPrimary })
        let rec = linkedConnection(host)
        var carrier   = row?.provider
        var transport = row?.transport
        var room      = row?.room
        if carrier == nil, let rec, case .olcrtc(let p) = rec.details {
            carrier = p.carrier; transport = p.transport; room = p.roomID
        }
        return ReconfigureRequest(host: host, containerName: cname,
                                  recordID: host.lastConnectionID,
                                  initialCarrier: carrier,
                                  initialTransport: transport,
                                  initialRoom: room,
                                  initialWbToken: Self.wbToken(of: rec),
                                  initialJitsiBase: Self.jitsiBase(of: rec))
    }

    /// #456: reconfigure targeted at ONE protocol row, seeded with everything
    /// the app already knows about it.
    private func rowReconfigureRequest(_ host: ServerHost, row: SSHRunner.CarrierInfo) -> ReconfigureRequest {
        let rec = connectionRecord(host, row: row)
        return ReconfigureRequest(host: host, containerName: row.container,
                                  recordID: rec?.id,
                                  initialCarrier: row.provider,
                                  initialTransport: row.transport,
                                  initialRoom: row.room,
                                  initialWbToken: Self.wbToken(of: rec),
                                  initialJitsiBase: Self.jitsiBase(of: rec))
    }

    /// #456: the wbstream token the record already holds (Keychain-hydrated by
    /// ConnectionStore). Seeding it is what stops a reconfigure from deleting
    /// the server's `auth.token` line just because the field started blank.
    private static func wbToken(of rec: ConnectionRecord?) -> String? {
        guard let rec, case .olcrtc(let p) = rec.details, !p.wbToken.isEmpty else { return nil }
        return p.wbToken
    }

    /// #456: the jitsi instance behind a full room URL ("https://host/room" →
    /// "https://host"), so reconfiguring a self-hosted Jitsi doesn't silently
    /// fall back to the shared public default.
    private static func jitsiBase(of rec: ConnectionRecord?) -> String? {
        guard let rec, case .olcrtc(let p) = rec.details, p.carrier == "jitsi",
              let url = URL(string: p.roomID), let scheme = url.scheme,
              let h = url.host, !h.isEmpty else { return nil }
        if let port = url.port { return "\(scheme)://\(h):\(port)" }
        return "\(scheme)://\(h)"
    }

    // MARK: - #463 — One-button Telemost room renewal
    //
    // A Yandex Telemost link stops working 24 hours after it is created
    // («ссылка на созвон работает 24 часа»), and a server parked in the room
    // does not extend it. The manual cure — open telemost.yandex.ru, create a
    // conference, copy the id, deliver it to the VPS over SSH — needs exactly
    // the channel a whitelist window blocks. This is the same errand as one
    // press, and it runs on the PHONE for a structural reason: if the VPS
    // rotated its own room, the phone could never learn the new id, because the
    // only channel to it during a whitelist window is the tunnel that just died
    // with the old room.
    //
    // Nothing about DELIVERING a room is reinvented here. `renewTelemostRoom`
    // creates the room and then hands it to `reconfigure(_:containerName:recordID:options:)`
    // — the existing path, which rewrites `room.id` in that container's yaml,
    // restarts that ONE container, rebuilds the ConnectionRecord from the URI
    // the server prints back, refreshes the protocol rows and re-verifies the
    // node. This section only supplies the room and handles the one thing that
    // path never had to face: renewing the carrier you are standing on.

    private func beginTelemostRenew(_ host: ServerHost, row: SSHRunner.CarrierInfo) {
        // #470 was: `telemostPhase = .idle` unconditionally — see
        // `telemostPhaseOwner`. A renewal still running keeps its phase (and
        // re-opening ITS row shows it); any other row starts idle.
        if !telemostWorking {
            telemostPhase      = .idle
            telemostPhaseOwner = row.container
        }
        telemostAccount = YandexSessionStore.hasStoredSession()
        telemostRenew   = TelemostRenewRequest(host: host, row: row,
                                               recordID: connectionRecord(host, row: row)?.id)
    }

    /// #470: a renewal is between Create and its outcome.
    private var telemostWorking: Bool {
        if case .working = telemostPhase { return true }
        return false
    }

    /// Resolves the request into the sheet's inputs. Concrete return type, plain
    /// values and closures — the `.sheet(item:)` in `carrierModals` stays one
    /// cheap expression.
    private func telemostSheet(_ req: TelemostRenewRequest) -> TelemostRoomSheet {
        TelemostRoomSheet(
            serverLabel:     req.host.label,
            hasAccount:      telemostAccount,
            // #470: only this row's own phase — another row's outcome is not
            // this sheet's to show.
            // #470 was: phase: telemostPhase,
            phase:           telemostPhaseOwner == req.id ? telemostPhase : .idle,
            hazard:          telemostHazard(req),
            busy:            actionsDisabled || carrierBusyHostID != nil,
            onSignedIn:      { adoptYandexSession($0) },
            onForgetAccount: { forgetYandexSession() },
            onCreate:        { Task { await renewTelemostRoom(req) } },
            onSwitchCarrier: { switchCarrierBeforeRenewal(req) })
    }

    /// #463: THE hazard. SSH now rides the tunnel (`App/Core/SSHTransport.swift`),
    /// so restarting the container the tunnel runs through cuts the command's own
    /// transport mid-flight. Recomputed on every render — this view observes
    /// `tunnel`, so the moment the user takes the "connect through X first"
    /// offer the warning disappears by itself and the safe press is the only
    /// press left.
    private func telemostHazard(_ req: TelemostRenewRequest) -> TelemostRenewHazard {
        guard isLiveRow(req.row) else { return .none }
        guard let alt = alternativeCarrier(req) else { return .liveOnly }
        return .liveSwitchable(CarrierTransportMatrix.carrierLabel(alt.provider))
    }

    /// Another protocol on the SAME host that is up server-side and has a saved
    /// connection — somewhere safe to stand while telemost's container restarts.
    /// This is why a multi-protocol host exists: a jitsi room never expires.
    private func alternativeCarrier(_ req: TelemostRenewRequest) -> SSHRunner.CarrierInfo? {
        (carrierRows[req.host.id] ?? []).first {
            $0.container != req.row.container
                && Self.isUp($0.status)
                && connectionRecord(req.host, row: $0) != nil
        }
    }

    private func switchCarrierBeforeRenewal(_ req: TelemostRenewRequest) {
        guard let alt = alternativeCarrier(req),
              let rec = connectionRecord(req.host, row: alt) else { return }
        LogStore.shared.log(.provisioning,
            "▶ Moving the tunnel to \(alt.provider) before renewing the telemost room")
        // #469 was: an explicit disconnect() + connect(), because connect used
        // to RETURN on a live session. It switches by itself now, and only
        // after the old engine has really stopped — the manual pair raced its
        // own teardown and could start on top of a runtime still shutting down.
        tunnel.connect(record: rec)
    }

    private func renewTelemostRoom(_ req: TelemostRenewRequest) async {
        guard !actionsDisabled, carrierBusyHostID == nil else { return }
        // boc #470: hold the protocol-op lane for the WHOLE renewal, the
        // room-creation half included. That half ran with nothing locked, so a
        // second Create (another row, or this one re-opened) passed the guard
        // above, and the two flows then wrote one phase in turns — and the
        // later `reconfigure` was refused by `run` while its caller still
        // reported "Room replaced". Same serialisation as add/remove protocol.
        carrierBusyHostID = req.host.id
        defer { carrierBusyHostID = nil }
        telemostPhaseOwner = req.id
        // eoc #470

        telemostPhase = .working(L10n.telemostRoomWorkingCreate.localized())
        // #463 (audit) was: `let room: String` — `createRoom()` returns a
        // `TelemostRoom` (uri + bare id), so this did not compile. The BARE ID is
        // what every use site below wants: the server config, the record, the
        // status line and the log.
        let room: TelemostRoom
        do {
            room = try await TelemostRoomService.createRoom()
        } catch {
            // The reason, never the credential.
            LogStore.shared.log(.provisioning,
                "✗ Telemost room creation failed: \(error.localizedDescription)")
            telemostAccount = YandexSessionStore.hasStoredSession()
            telemostPhase   = .failed(error.localizedDescription)
            return
        }
        LogStore.shared.log(.provisioning, "✓ New Telemost room: \(room.id.prefix(8))…")

        // Read the hazard BEFORE the restart takes the answer away.
        let wasLive = isLiveRow(req.row)
        telemostPhase = .working(L10n.telemostRoomWorkingApply.localized())
        let options = InstallOptions(carrier:   req.row.provider,
                                     transport: req.row.transport,
                                     roomID:    room.id)
        await reconfigure(req.host, containerName: req.row.container,
                          recordID: req.recordID, options: options)

        // #463 (audit): keep the record honest on EVERY path, not only the one
        // where the command died. `Provisioner.reconfigure` returns nil — and
        // `run` still reports success — when the server applied the change but
        // printed no `OLCRTC_URI=` line ("Reconfigure succeeded but server did
        // not emit URI"). The record was then left on the room that just expired
        // while the sheet said "Room replaced" and the reconnect below dialled
        // the dead room. A no-op when reconfigure already rebuilt the record
        // from the returned URI (the guard compares roomID).
        applyRoomLocally(req, room: room.id)

        guard let failure = reconfigureFailure(req.host.id) else {
            telemostPhase = .done(room.id)
            if wasLive { reconnectAfterRenewal(req) }
            return
        }
        guard wasLive else {
            telemostPhase = .failed(failure)
            return
        }
        // boc #463: the EXPECTED outcome of renewing the carrier you are riding.
        // `reconfigureScript` seds `room.id` and THEN restarts the container, so
        // the command dies after the write and before it can print the new URI —
        // the server changed, the confirmation did not survive. Reporting that as
        // a plain failure would leave the record pointing at a room that is
        // expired by definition, which is the lying state this feature exists to
        // end. The record was already moved to the new room above, so what is
        // left here is: re-probe it (HealthCoordinator dials the room directly
        // and does NOT use the tunnel, so its verdict — not this SSH error — is
        // the trustworthy answer), say exactly that, and reconnect. The card
        // still reads "Reconfigure failed", which is TRUE of the command; the
        // row's own health chip carries the real answer.
        await verifyRecord(req.recordID)
        telemostPhase = .failed(L10n.telemostRenewDropped_fmt.formatted(room.id))
        reconnectAfterRenewal(req)
        // eoc #463
    }

    /// The terminal message `run` wrote onto the card, or nil when the op
    /// finished cleanly. The card's state is the single source of truth for
    /// whether an op succeeded (#258), so this asks it instead of keeping a
    /// second copy. Pinned to `.reconfigure` so a stale failure from some other
    /// op can never be reported as this one's.
    private func reconfigureFailure(_ hostID: UUID) -> String? {
        guard let state = display[hostID],
              case .failed(let op, _, let message, _) = state,
              op == .reconfigure else { return nil }
        return message
    }

    /// #463: keep the record honest when the server's confirmation was lost.
    /// ONLY the room changes — `reconfigureScript` rewrites `room.id`, never the
    /// key — so everything else is carried through untouched.
    private func applyRoomLocally(_ req: TelemostRenewRequest, room: String) {
        guard let id = req.recordID,
              let existing = connections.connections.first(where: { $0.id == id }),
              case .olcrtc(let params) = existing.details,
              params.roomID != room else { return }
        var moved = params
        moved.roomID = room
        moved.roomCreatedAt = Date()   // #465: starts this room's 24 h clock
        var updated = existing
        updated.details = .olcrtc(moved)
        connections.update(updated)
    }

    /// #463: `TunnelManager.lastRecord` is a snapshot taken at connect time, so
    /// after a room change the reconnect loop would keep dialing the room that
    /// just expired until it gives up (OLC-1014). `disconnect()` cancels that
    /// loop and clears `lastRecord`; the dial that follows uses the record as it
    /// now stands.
    private func reconnectAfterRenewal(_ req: TelemostRenewRequest) {
        guard let id = req.recordID,
              let rec = connections.connections.first(where: { $0.id == id }) else { return }
        tunnel.disconnect()
        tunnel.connect(record: rec)
    }

    // boc #463: the ONLY place in this file that touches the credential. A live
    // `Session_id` is a bearer token for the user's whole Yandex identity — mail,
    // Disk, Pay — usable without the password and past 2FA, so it goes straight
    // from the web view into the Keychain-backed store and is never held here,
    // never logged, and never formatted into a message.
    // #463 (audit) was: `YandexSessionStore.shared` — that singleton does not
    // exist (the store documents that it deliberately has none), and `save` takes
    // an UNLABELLED value. The store owns no state beyond the published flag, so
    // a transient instance writes and the nonisolated static re-reads the truth
    // back out of the Keychain — which is also what makes the flag right when the
    // Keychain write FAILED. The two duplicate log lines went with it: the store
    // already logs both outcomes accurately, and these claimed success
    // unconditionally.
    private func adoptYandexSession(_ sessionID: String) {
        YandexSessionStore().save(sessionID)
        telemostAccount = YandexSessionStore.hasStoredSession()
    }

    private func forgetYandexSession() {
        YandexSessionStore().clear()
        telemostAccount = YandexSessionStore.hasStoredSession()
        telemostPhase   = .idle
    }
    // eoc #463

    // MARK: Container scan (no base change → outside `run`)
    // #339 was: fetchLogs(_:) — ran provisioner.containerLogs and presented the
    // ContainerLogsPayload sheet; replaced by the Logs-tab route (the fetch now
    // runs inside LogsView with phase progress, #338).

    // #303: read the deployed server.yaml + ~/.olcrtc_key for `host`'s linked
    // container and add a ConnectionRecord from it — recovers a usable
    // connection when Connections is empty (new device / reinstall) but the
    // server is already running olcrtc. Read-only on the server.
    // #452: gained containerName/configFile/asExtra so a protocol row can
    // recover ITS config (server-<carrier>.yaml in the shared deploy dir); the
    // host-level entry keeps the old defaults (primary container, server.yaml,
    // links lastConnectionID).
    private func recoverConnection(_ host: ServerHost,
                                   containerName: String? = nil,
                                   configFile: String = "server.yaml",
                                   asExtra: Bool = false) async {
        guard let secret = secret(for: host) else {
            alertText = missingCredentialMessage(host); return
        }
        guard let cname = containerName ?? host.lastContainerName else {
            alertText = L10n.containerNotInstalled.localized(); return
        }
        do {
            let cfg = try await provisioner.recoverConfig(on: host, secret: secret,
                                                          containerName: cname, configFile: configFile)
            // #303: default-struct values (30/10/1200/1) match OlcrtcConnection's
            // own seiFPS/seiBatch/seiFrag/seiACK defaults (App/Models/OlcrtcConnection.swift)
            // — used as a fallback only if the deployed server.yaml's sei: block
            // somehow lacked a field (shouldn't happen for srv.sh-written configs).
            // #401: NOT routed through OlcrtcConnection(from: Parsed) — `cfg` here is
            // an SSHRunner.RecoveredConfig (recovered server.yaml), not an
            // OlcrtcURI.Parsed, so it keeps its own explicit field mapping; clientID
            // is forced to "default" (a recovered server.yaml carries no client segment).
            let params = OlcrtcConnection(
                carrier:      cfg.carrier,
                transport:    cfg.transport,
                roomID:       cfg.roomID,
                key:          cfg.key,
                clientID:     "default",
                vp8FPS:       cfg.vp8FPS,
                vp8BatchSize: cfg.vp8BatchSize,
                wbToken:      cfg.wbToken,      // #470: the server's own auth.token, if any
                seiFPS:       cfg.seiFPS   ?? 30,
                seiBatch:     cfg.seiBatch ?? 10,
                seiFrag:      cfg.seiFrag  ?? 1200,
                seiACK:       cfg.seiACK   ?? 1
            )
            // #452: an extra-protocol recover names + links the record like an
            // extra install would (carrier-suffixed name, extraConnectionIDs).
            // boc #467: recover used to `add` unconditionally, so re-running it on
            // a protocol that already had a record — the thing #467a's dead end
            // pushed users into doing — left TWO records for one protocol and
            // appended a second id to the host. Recover reads the server's own
            // config, so when a record for this protocol is already linked the
            // honest outcome is to correct it in place, keeping its id (live
            // tunnel, health history and the user's name for it all hang off
            // that id) rather than growing a duplicate beside it.
            let slotIDs: [UUID] = asExtra
                ? (host.extraConnectionIDs ?? [])
                : [host.lastConnectionID].compactMap { $0 }
            let existing = slotIDs
                .compactMap { id in connections.connections.first { $0.id == id } }
                .first { rec in
                    if case .olcrtc(let p) = rec.details { return p.carrier == cfg.carrier }
                    return false
                }
            let recoveredID: UUID   // #470: the record to re-measure below
            if var found = existing {
                // #469: `params` comes from the server's yaml, which knows nothing
                // about the local SOCKS credentials, the WB token the record
                // carries, or when the room was created. Overwriting wholesale
                // reset the #465 clock to "unknown" on every Recover and dropped
                // the in-memory secrets until relaunch. Carry them through; the
                // stamp only survives when the room is the same room.
                var merged = params
                if case .olcrtc(let prior) = found.details {
                    merged.socksUser     = prior.socksUser
                    merged.socksPass     = prior.socksPass
                    // #470: a token the server reported wins; the prior one only fills a gap
                    merged.wbToken       = !merged.wbToken.isEmpty ? merged.wbToken
                                         : (prior.carrier == merged.carrier ? prior.wbToken : "")
                    merged.roomCreatedAt = prior.roomID == merged.roomID ? prior.roomCreatedAt : nil
                }
                found.details = .olcrtc(merged)
                connections.update(found)
                recoveredID = found.id
            } else {
                let record = ConnectionRecord(
                    name: Self.recordName(host: host, carrier: cfg.carrier, multi: asExtra),
                    details: .olcrtc(params))
                connections.add(record)
                var updated = host
                if asExtra {
                    updated.extraConnectionIDs = (updated.extraConnectionIDs ?? []) + [record.id]
                } else {
                    updated.lastConnectionID = record.id
                }
                serverStore.update(updated, password: nil)
                recoveredID = record.id
            }
            // eoc #467
            // #470: the service's name, as the row prints it (#461).
            // #470 was: .formatted(cfg.carrier, cfg.transport)
            alertText = L10n.recoverResultSuccess_fmt.formatted(
                CarrierTransportMatrix.carrierLabel(cfg.carrier),
                CarrierTransportMatrix.transportLabel(cfg.transport))
            // boc #470: the record just changed under its verdict. Reconfigure,
            // add-carrier and start all re-measure; recover did not, so the row
            // kept its red "key no longer matches" — Recover still hoisted at
            // the top of its menu — for up to 30 minutes after the alert said
            // the recover succeeded, and the user ran it again. Fire-and-forget
            // like add-carrier: the chip renders `.checking` on its own.
            Task { await verifyRecord(recoveredID) }
            // eoc #470
        // boc #314: server.yaml unreadable/unparseable — the key/params can't
        // be extracted read-only, so offer the "generate new key" fallback
        // instead of a dead-end error alert. Other errors (SSH, network,
        // missing container) keep the plain alert below.
        } catch let error as SSHRunner.RecoverConfigError {
            LogStore.shared.log(.provisioning,
                "⚠ Recover unusable (\(error.localizedDescription)) — offering key rotation (#314)")
            rotateKeyConfirmHost = host
        // eoc #314
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    // #314: "generate new key" fallback for #303 — rotates ~/.olcrtc_key on the
    // VPS via scripts/rotate-key.sh (repairs server.yaml with srv.sh's exact
    // key/yaml semantics + restarts the container), then adds the resulting
    // connection exactly like a fresh install does (parse OLCRTC_URI=).
    private func rotateKey(_ host: ServerHost) async {
        guard let secret = secret(for: host) else {
            alertText = missingCredentialMessage(host); return
        }
        guard let cname = host.lastContainerName else {
            alertText = L10n.containerNotInstalled.localized(); return
        }
        // boc #469: rotate-key.sh restarts the container BEFORE it prints the new
        // URI. Run through a tunnel riding that host, the restart killed the SSH
        // session and the new key never arrived: server re-keyed, app kept the
        // old key, nothing could connect. A rotation forces a reconnect anyway,
        // so drop the session first and let the command travel a route that
        // survives the restart.
        if let live = tunnel.connectedRecord, hostRecords(host).contains(where: { $0.id == live.id }) {
            LogStore.shared.log(.provisioning,
                "▶ Disconnecting before the key rotation — the command must not ride the container it restarts")
            tunnel.disconnect()
        }
        // eoc #469
        do {
            let result = try await provisioner.rotateKey(on: host, secret: secret, containerName: cname)
            let cfg = try OlcrtcURI.parse(result.uri)
            // vp8 tuning comes from the URI payload (salvaged server values may
            // differ from this app's global defaults). sei tuning can't round-trip
            // through OlcrtcURI.Parsed — defaults apply, same as the install path.
            // #401: shared Parsed → connection mapping (sei defaults 30/10/1200/1
            // == the struct's own defaults, so behavior is unchanged).
            let params = OlcrtcConnection(from: cfg)
            // boc #469 was: always `add` a fresh record and re-point the host at
            // it — the SAME duplicate pattern #467 removed from Recover. The old
            // primary record stayed in the list with a key that no longer
            // decrypts anything; a live tunnel through it could never reconnect.
            // Correct the linked record in place (its id is what the tunnel, the
            // health history and the user's name hang off); add only when the
            // host has none.
            var updated = host
            updated.lastContainerName = result.containerName
            if let id = host.lastConnectionID,
               var found = connections.connections.first(where: { $0.id == id }) {
                var merged = params
                if case .olcrtc(let prior) = found.details {
                    merged.socksUser     = prior.socksUser
                    merged.socksPass     = prior.socksPass
                    merged.wbToken       = prior.carrier == merged.carrier ? prior.wbToken : ""
                    merged.roomCreatedAt = prior.roomID == merged.roomID ? prior.roomCreatedAt : nil
                }
                found.details = .olcrtc(merged)
                connections.update(found)
            } else {
                let record = ConnectionRecord(name: host.label, details: .olcrtc(params))
                connections.add(record)
                updated.lastConnectionID = record.id
            }
            serverStore.update(updated, password: nil)
            // eoc #469
            // #472: the key just changed on both sides. `ConnectionStore.update`
            // has already dropped the stale verdict; measure the new one now so
            // the row answers by itself instead of waiting for the user to press
            // Verify — the complaint that opened this task.
            await verifyLinked(host.id)
            // boc #452: sibling protocol containers were restarted with the SAME
            // new key — refresh every matching record so a multi-protocol host
            // stays fully usable after a rotation.
            // boc #470: the match was carrier+room inside the extras, then the
            // SAME match over EVERY record in the app. Both halves were wrong
            // since #467: the room is mutable, so a sibling whose room had moved
            // matched nothing and kept its dead key while the log said "Rotated
            // N sibling carrier(s) too"; and the app-wide half rewrote any record
            // that shared the room — another host's, which then carried THIS
            // host's key. Slot first (exact, then carrier — the #467 order); past
            // it only a record no host links at all (an import of this very
            // room), never another host's.
            let linkedAnywhere = Set(serverStore.hosts.flatMap { h in
                [h.lastConnectionID].compactMap { $0 } + (h.extraConnectionIDs ?? [])
            })
            for sib in result.siblings {
                guard let sibCfg = try? OlcrtcURI.parse(sib.uri) else { continue }
                func matches(_ rec: ConnectionRecord) -> Bool {
                    if case .olcrtc(let p) = rec.details {
                        return p.carrier == sibCfg.carrier && p.roomID == sibCfg.roomID
                    }
                    return false
                }
                // #470 was:
                //     let linked = (updated.extraConnectionIDs ?? [])
                //         .compactMap { id in connections.connections.first(where: { $0.id == id }) }
                //         .first(where: matches)
                //     guard let match = linked ?? connections.connections.first(where: matches),
                let slot = Self.resolveSlotRecord(host: updated, isPrimary: false,
                                                  carrier: sibCfg.carrier, room: sibCfg.roomID,
                                                  records: connections.connections)
                let orphan = connections.connections.first { !linkedAnywhere.contains($0.id) && matches($0) }
                guard let match = slot ?? orphan,
                      case .olcrtc(let old) = match.details else { continue }
                // eoc #470
                // Mirror the reconfigure merge (#355-style): only the key/room/
                // transport come from the URI; tuning + secrets are preserved.
                let refreshed = OlcrtcConnection(
                    carrier:      sibCfg.carrier,
                    transport:    sibCfg.transport,
                    roomID:       sibCfg.roomID,
                    key:          sibCfg.key.isEmpty ? old.key : sibCfg.key,
                    clientID:     sibCfg.clientID,
                    vp8FPS:       old.vp8FPS,
                    vp8BatchSize: old.vp8BatchSize,
                    socksUser:    old.socksUser,
                    socksPass:    old.socksPass,
                    wbToken:      old.wbToken,
                    seiFPS:       old.seiFPS,
                    seiBatch:     old.seiBatch,
                    seiFrag:      old.seiFrag,
                    seiACK:       old.seiACK
                )
                var updatedRecord = match
                updatedRecord.details = .olcrtc(refreshed)
                connections.update(updatedRecord)
            }
            // eoc #452
            // #470: the service's name, as the row prints it (#461).
            // #470 was: .formatted(cfg.carrier, cfg.transport)
            alertText = L10n.rotateKeyResultAdded_fmt.formatted(
                CarrierTransportMatrix.carrierLabel(cfg.carrier),
                CarrierTransportMatrix.transportLabel(cfg.transport))
            await refreshCarriers(host.id)   // #452
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    private func scanContainers(_ host: ServerHost) async {
        guard let secret = secret(for: host) else {
            alertText = missingCredentialMessage(host); return
        }
        do {
            let found = try await provisioner.scanContainers(on: host, secret: secret)
            foundContainers = found
            scanFor = host
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    // boc #490
    // #490 was: scan result layout and restore button nested here in 75 lines.
    // Result ownership, Restore, Done, disappearance cleanup and detents stay.
    @ViewBuilder
    private func containerScanSheet(host: ServerHost) -> some View {
        ServerContainerScanView(containers: foundContainers,
                                onRestore: { restoreContainer($0, on: host) },
                                onDone: { scanFor = nil })
            .onDisappear { foundContainers = [] }
            .presentationDetents([.medium, .large])
    }
    // eoc #490

    private func restoreContainer(_ container: SSHRunner.FoundContainer, on host: ServerHost) {
        scanFor = nil
        var updated = host
        updated.lastContainerName = container.name
        serverStore.update(updated, password: nil)
        // #456 was: display[host.id] = .base(.stopped) — the scan had ALREADY
        // told us whether the container is Up; seeding "stopped" for a running
        // one was a present-tense claim we held evidence against.
        // #457 was: `container.status.shortLabel.hasPrefix("Up")`
        let base: HostBase = Self.isUp(container.status) ? .running : .stopped
        display[host.id] = .base(base)
        recordSnapshot(host, base: base)
        // #456: the scan IS a fresh SSH observation — both clocks.
        lastProbe[host.id]   = Date()
        lastProbeOK[host.id] = Date()   // #456 (audit)
        alertText = L10n.scanRestored_fmt.formatted(container.name)   // #346 was: "Restored: \(container.name)"
        Task { await refreshCarriers(host.id) }   // #452
    }
}

/// #459 (audit fix): the "Manage server" push's own item TYPE.
///
/// `navigationDestination(item:)` takes `D: Hashable` because it appends the
/// value to the stack's path and resolves the destination registered for that
/// type — so two of them bound to `ServerHost?` on one stack are two
/// registrations for one type and only one of them can ever run. ServersView
/// pushes two different screens off the same host, so the second one carries
/// its own single-field wrapper rather than a second `ServerHost?`.
struct AdvancedHostRoute: Hashable {
    let host: ServerHost
}

/// Drives the card's share sheet: the host's protocol connections plus the
/// optional full-access payload. `startWithFullAccess` opens straight onto the
/// full-access confirmation (Manage screen entry).
struct ServerShareRequest: Identifiable {
    let id = UUID()
    let hostLabel: String
    let options: [ServerShareOption]
    let fullAccess: FullAccessShare?
    var startWithFullAccess = false
}

// boc #452: multi-carrier request payloads — value snapshots (the #330 rule)
// driving one `.sheet(item:)` / `.confirmationDialog(presenting:)` each.

/// Reconfigure targeted at ONE protocol's container, with the row's current
/// values as sheet seeds and the record to update on success.
struct ReconfigureRequest: Identifiable {
    let host: ServerHost
    let containerName: String
    let recordID: UUID?
    let initialCarrier: String?
    let initialTransport: String?
    let initialRoom: String?
    // boc #456: the sheet used to seed these blank, so confirming a wbstream
    // reconfigure DELETED the server's auth.token and a self-hosted jitsi
    // silently fell back to the shared public default. Defaulted + last, so
    // every pre-#456 construction still compiles.
    var initialWbToken: String? = nil
    var initialJitsiBase: String? = nil
    // eoc #456
    var id: String { containerName }
}

/// #456: an install about to run on a host that already carries olcrtc
/// containers. `scripts/srv.sh` force-removes EVERY `olcrtc-server-*` container
/// (and its rooms and keys) before installing, so the user chooses between
/// adopting what is there and a deliberate, warned reinstall.
struct InstallChoiceRequest: Identifiable {
    let id = UUID()
    let host: ServerHost
    let found: [SSHRunner.FoundContainer]
}

struct CarrierRemoveRequest: Identifiable {
    let host: ServerHost
    let row: SSHRunner.CarrierInfo
    var id: String { row.container }
}

struct CarrierRecoverRequest: Identifiable {
    let host: ServerHost
    let container: String
    let file: String
    let isPrimary: Bool
    var id: String { container }
}
// eoc #452

/// #463: the telemost row a room renewal was started for — a value snapshot
/// (the #330 rule), so the sheet keeps working while the card behind it
/// re-renders under a live tunnel. `recordID` is resolved once at open time
/// rather than inside the sheet: resolving it needs the stores, which the sheet
/// deliberately does not have.
struct TelemostRenewRequest: Identifiable {
    let host: ServerHost
    let row: SSHRunner.CarrierInfo
    let recordID: UUID?
    var id: String { row.container }
}

// #340: both appearance variants.
#if DEBUG
#Preview("Servers — Dark") {
    ServersView(serverStore: ServerHostStore(), connections: ConnectionStore(),
                tunnel: TunnelManager())
        .preferredColorScheme(.dark)
}
#Preview("Servers — Light") {
    ServersView(serverStore: ServerHostStore(), connections: ConnectionStore(),
                tunnel: TunnelManager())
        .preferredColorScheme(.light)
}
#endif
