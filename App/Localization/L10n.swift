import Foundation

// MARK: - Localization
//
// Type-safe localization. The `L10n` enum is the single source of truth for
// every translation key — adding a new string requires (a) a new case here and
// (b) entries in every `L10nTable.<language>` dictionary. The unit test in
// `L10nTests.swift` guarantees no case is missing in any language.
//
// Adding a new language:
//   1. Add a case to `AppLocale`
// #488 was: Add the dictionary in L10nTable.swift.
//   2. Add a `[L10n: String]` dictionary (a separate L10nTable extension is fine)
//   3. Add it to the `switch` in L10nTable.value(for:in:)
//   4. Tests catch any gaps automatically.
//
// Format strings: cases that end in `_fmt` are passed through `String(format:)`
// via `L10n.formatted(_:)`. Patterns use standard %@/%d/%.0f placeholders.

enum AppLocale: String, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"
    case french = "fr" // #488: French is a fully translated app language.

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        case .french: return "Français" // #488: Use the native language name in the picker.
        }
    }

    // boc #488
    /// Seed a new installation from the first supported system preference.
    /// Persisted choices are resolved by `current`, not by this one-time helper.
    static func preferredLanguage(from languages: [String]) -> String {
        for language in languages {
            let code = language.lowercased()
            if code.hasPrefix("ru") { return AppLocale.russian.rawValue }
            if code.hasPrefix("fr") { return AppLocale.french.rawValue }
            if code.hasPrefix("en") { return AppLocale.english.rawValue }
        }
        return AppLocale.english.rawValue
    }
    // eoc #488

    /// Current locale resolved from SettingsStore. Falls back to English when
    /// the stored value is empty or unknown.
    static var current: AppLocale {
        AppLocale(rawValue: SettingsStore.shared.language) ?? .english
    }
}

enum L10n: String, CaseIterable {

    // MARK: Common
    case ok, cancel, save, close, done, error, edit
    case okPrompt           // "Done"

    // MARK: Tabs
    // #457 was: `tabLogs` — Logs stopped being a tab and became a detail
    // view pushed from the thing it explains (hero / server card).
    case tabConnections, tabServers, tabSettings
    case autoDetectedContainer_fmt          // #302: "Auto-detected existing container: %@"

    // boc #488: Complete EN/RU/FR coverage for automatic mode (#487).
    case tunnelModeAutomatic
    case tunnelModeAutomaticHint
    case tunnelModeVPNHint
    case tunnelModeProxyHint
    case vpnAutomaticFallback_fmt
    case vpnAutomaticFallbackSummary // #488: Compact disclosure label for the #486 hero.
    case vpnPermissionUnavailable_fmt
    // eoc #488

    // MARK: Tunnel mode (#vpn)
    case tunnelModeProxy, tunnelModeVPN     // #457: picker chips, Connect screen
    case configModeSectionHeader            // "Tunnel mode"
    case configVPNUnavailableFooter         // lead-in line above the capability reason
    case vpnVideochannelUnsupported         // videochannel transport can't run in the appex
    case vpnDisconnected                    // generic unexpected-drop reason
    case vpnSettingsEntryName               // "olcOS" — shown under Settings > VPN
    case vpnCapabilityUnavailable_fmt       // %@ = system error text from saveToPreferences

    // Automatic protocol failover has no UI; `SettingsStore.autoFailover` stays a stored key (default false).
    // #458: re-check servers and protocols when the app is opened
    case settingsRefreshOnEntryToggle
    case settingsRefreshOnEntryExplainer
    case failoverSwitching_fmt              // "%@ failing — switching to %@" (2 carrier labels)
    case failoverAllFailed                  // every protocol on the server failed
    // #454: connection-health card — merged into the Diagnostics card (#459).
    // #459 was: `healthTitle` ("Connection health"), `healthThroughputLabel`
    // ("Speed") and `healthRefresh` ("Refresh"). The card lost its own title to
    // `diagSessionHeader`, its throughput row moved into the speed test it
    // belongs to, and its refresh glyph was replaced by pull-to-refresh.
    case healthExitLabel                    // row: exit ip/geo
    // #460 was: `healthLatencyLabel` ("Latency"). The row measured a whole
    // fresh request — connect, handshake and answer — through the live tunnel,
    // so calling it "latency" invited the reader to compare it with the
    // per-connection round-trip, which it is ~8× larger than by construction
    // (findings 2 / 15). It is now `diagResponseLabel` + `diagResponseNote`.
    case healthLatencyMs_fmt                // "%d ms"
    // #455: premium redesign — editorial-consistency additions
    // #460 was: `configReliabilityHeader` ("Reliability") — the Settings
    // section it headed held only the auto-switch toggle, which moved to the
    // Connections screen, so the header lost its section and its last use.
    case unitSeconds                        // "s" unit after numeric fields
    case sshTestInvalidPort                 // add-host SSH reachability test: bad port
    // #455: localise LogLevel.label (was English-only — AGENTS.md flagged it)
    case logLevelOff
    case logLevelErrors
    case logLevelNormal
    case logLevelDebug
    case logLevelVerbose
    // #455: reset-to-defaults safety valve
    case resetSettingsAction
    case resetSettingsFooter
    case resetSettingsConfirmTitle
    case resetSettingsConfirmBody

    // MARK: Routing
    case routingHeader, routingAllTunnel, routingAllDirect, routingViaTunnel, routingDirect

    // MARK: Connection state
    case stateDisconnected, stateConnecting, stateConnected
    case stateConnectFailed                // "Connection failed" (#258 hero)
    case stateWaitingForNetwork            // "Waiting for network…" (#269 hero)
    case stateErrorPrefix_fmt              // "Error: %@"

    // MARK: ConnectionsView
    case emptyNoConnections                 // "No connections yet"
    case emptyNoConnectionsHint             // "Tap + to add a connection manually. If you have a VPS, go to the Servers tab to install and link automatically."
    case actionConnect, actionRetry
    case shareAction, copyURIAction
    case shareConnectionTitle, shareConnectionExplanation, shareConnectionURIHeader
    case copiedURI_fmt                      // "📋 URI copied: %@"
    // #135: full-access (co-admin) share — carries SSH creds; destructive.
    case shareFullAccessTitle               // "Share full access (SSH)"
    case shareFullAccessHeader              // "Full access (SSH)"
    case shareFullAccessWarning             // destructive warning
    case shareFullAccessReveal              // "Reveal full-access link"
    case shareFullAccessCopy                // "Copy full-access link"
    case shareFullAccessCopied_fmt          // "🔑 Full-access link copied: %@"
    // #366: receiving a full-access (olcrtc://host/v1/…) link — confirm import.
    case fullAccessImportTitle              // "Import full access?"
    case fullAccessImportBody_fmt           // warning + "saves SSH creds for %@"
    case fullAccessImportAddAction          // "Add full access"
    case fullAccessImportInvalid            // "This full-access link is invalid."

    // MARK: AddConnectionView
    case newConnectionTitle, editConnectionTitle
    case nameField, namePlaceholder         // "Label" / "My server"
    case groupDefault           // "Group" / "Servers"
    case importByURI                        // "Import from URI"
    case scanQRAction                       // "Scan QR" (#258 sheet shortcut)
    case pasteURIAction                     // "Paste URI" (#258 sheet shortcut)
    case importHint
    case clientIDFooter                     // explanation of client ID field
    case keyPlaceholder
    case roomIDLabel
    // (audit) hardcoded English FormField labels in the localized editor sheet.
    case clientIDLabel                      // "Client ID"
    case keyHexLabel                        // "Key (hex)"
    case vp8ParamsHeader
    case socksAuthHeader, socksAuthFooter
    case socksUserLabel, socksPassLabel
    case socksUserPlaceholder
    case vp8FpsLabel, vp8BatchLabel
    case globalDefault_fmt                  // "global (%d)"
    case overrideHint
    // #365: per-connection seichannel params (shown only for transport == seichannel)
    case seiParamsHeader                    // "SEI parameters"
    case seiFpsLabel                        // "FPS"
    case seiBatchLabel                      // "Batch size"
    case seiFragLabel                       // "Fragment size"
    case seiAckLabel                        // "ACK timeout (ms)"
    case seiParamsHint                      // explanation: only sent for seichannel transport

    // MARK: ServersView
    case serversTitle                       // "VPS list"
    case emptyNoServers, emptyNoServersHint
    case newServerTitle, editServerTitle
    case sshAccessHeader
    case hostField, portField, loginField, passwordField
    case actionInstall, actionUninstall, actionUpdate, actionReboot
    case actionChangeRoomTransport         // "Change Room / Transport"
    // #457 (audit fix): actionContainerLogs is BACK. It was retired on the
    // assumption the server card would open the container log as a detail view,
    // but no partition wired that route, so container logs became unreachable.
    // The menu item now pushes LogsView(subject: .container(host)).
    case actionDone
    case actionRemoveFromList               // "Remove host from list"
    case removeHostConfirmTitle_fmt         // "Remove %@?" — #470: the placeholder rule keys on the suffix
    case removeHostConfirmMessage           // explanation about Keychain/uninstall
    case uninstallConfirmTitle             // "Uninstall container?"
    case uninstallConfirmBody              // explanation about what is removed vs kept
    case deepUninstallConfirmBody          // explanation for deep uninstall confirmation
    case rebootConfirmTitle               // "Reboot server?"
    case rebootConfirmBody                // explanation that the entire VPS will reboot

    // MARK: #303 Recover connection from server
    case actionRecoverConnection           // "Recover connection" (host overflow menu)
    case recoverConfirmTitle               // "Recover connection from this server?"
    case recoverConfirmBody                // explanation: reads server.yaml + key, adds a connection
    case recoverConfirmAction              // "Recover" (confirm button)
    case provisioningRecovering            // "Reading server config…" (status step)
    case recoverResultSuccess_fmt          // "Recovered %@/%@ — connection added"
    case recoverErrorMissingYAML           // "Server config not found"
    case recoverErrorMissingField_fmt      // "Server config is missing '%@'"

    // MARK: #314 Generate new key (fallback when #303 recovery can't read server.yaml)
    case rotateKeyConfirmTitle             // "Server config unreadable — generate a new key?"
    case rotateKeyConfirmBody              // warning: rotation cuts off all other clients
    case rotateKeyConfirmAction            // "Generate new key" (destructive confirm button)
    case provisioningRotatingKey           // "Generating new server key…" (status step)
    case rotateKeyResultSuccess            // "New encryption key active" (provisioner status)
    case rotateKeyResultAdded_fmt          // "New key generated — %@/%@ connection added"
    case rotateKeyFailedNoURI              // rotation script printed no OLCRTC_URI=

    // MARK: Container status
    case containerRunning_fmt               // "Container running: %@"
    case containerStopped_fmt               // "Container stopped: %@"
    case containerNotFound                  // "Container not found"
    case containerNotFoundShort             // "not found"
    case containerNotInstalled              // "Container is not installed yet — tap «Install»."

    // MARK: VPS readiness state
    case readinessNoPodman                 // "Ready to install (Podman not found)"
    case readinessNoImage                  // "Image not cached (~300 MB on first install)"
    case readinessImageReady               // "Image cached — reinstall takes ~1 min"
    case readinessContainerStopped_fmt     // "Stopped: %@"
    case readinessContainerRunning_fmt     // "Running: %@"

    // MARK: VPS status card (#258/#261 — design-system status pill + op driver)
    case vpsTitleUnknown, vpsTitleReady, vpsTitlePodmanReady, vpsTitleStopped, vpsTitleRunning
    case vpsSubUnknown, vpsSubNoPodman, vpsSubNoImage, vpsSubImageReady, vpsSubStopped, vpsSubRunning
    case vpsVerbChecking, vpsVerbInstalling, vpsVerbStarting, vpsVerbStopping, vpsVerbReconfiguring
    case vpsVerbUpdating, vpsVerbUninstalling, vpsVerbDeepUninstalling, vpsVerbRebooting
    case vpsConnecting                      // "Connecting…" (initial running note)
    case vpsCheckServer                     // "Check server"
    case vpsWorking                         // "Working…"
    case vpsOpFailed_fmt                    // "%@ failed"

    // #339 was: MARK ContainerLogsView (emptyLogsTitle, emptyLogsHint_fmt) —
    // the sheet is gone; closeAction stays (sheet chrome + ShareConnectionView).
    case closeAction

    // MARK: LogsView
    case logsTitle                          // "Logs"
    case logsSearchPlaceholder              // "Search"
    case emptyLogsGeneric                   // "Empty"
    case noSearchResults                    // "Nothing found"
    case noSearchResultsHint_fmt            // "No matches for «%@»."
    case categoryConnection                 // "Connection"
    // #294 was: categoryIP ("IP") + categorySpeed ("Speed test") — merged
    // into one Diagnostics tab/category.
    case categoryDiagnostics                // "Diagnostics"
    case categoryProvisioning               // "VPS"
    case categoryContainerLogs              // "Container"

    // MARK: #294 — per-source Logs tabs
    case logsTabDescConnection              // "connection logs"
    case logsTabDescDiagnostics             // "IP and speed test logs"
    case logsTabDescVPS                     // "VPS provisioning logs"
    case logsTabDescContainer               // "Server container extracted logs"
    case logsFileNameLabel_fmt              // "File: %@"
    case logsContainerSelectServer          // "Server" — picker label for the Container tab
    case logsContainerNoServers             // "No servers configured" — Container tab with zero hosts

    // MARK: #295 — per-server container log files
    case duplicateServerNameError           // "A server with this name already exists"

    // MARK: #296 — Container tab always-present load button
    // #338 was: logsDownloadFromServer ("Download logs from server") — the
    // bare text button became the source card's "Fetch" OlcButton.
    case logsCheckServer                    // "Check server" — mirrors vpsCheckServer, gated by readiness
    case logsContainerEmptyHint             // "Logs need to be loaded from the server."

    // MARK: #316 — single-stack Logs tab
    case logsSegConnection                  // "Conn" — abbreviated segment label; full name in accessibilityLabel
    case logsSegDiagnostics                 // "Diag"
    case logsSegVPS                         // "VPS"
    case logsSegContainer                   // "Container"
    case logsLineCount_fmt                  // "%d lines" — file-header row, right-aligned
    case logsPeerCount_fmt                  // #367: "👥 %d peers" — live server peer count

    // MARK: #338 — inline container fetch with progress
    case logsFetchAction                    // "Fetch" — source-card button
    case logsFetchFromHost_fmt              // "Fetch from %@" — empty-state CTA
    case logsPhaseConnecting                // "Connecting…" — fetch phase 1/3 (covers the scan-first fallback)
    case logsPhaseCommand_fmt               // "podman logs --tail %d %@" — fetch phase 2/3
    case logsPhaseReceiving                 // "Receiving output…" — fetch phase 3/3

    // MARK: #332 — rendered-line cap
    case logsRenderTruncated_fmt            // "Showing the newest %d lines…" — notice above a capped log body

    // MARK: #432 — self-describing log export
    case logsShareThisAction                // "Share this log" — Logs overflow menu
    case logsExportAllAction                // "Export all logs" — Logs overflow menu

    // MARK: #440 — early restart of a wedged session
    case earlyRestartWedgeLabel             // Settings toggle
    case wedgeRestartLog                    // connection-log line when a wedge is detected
    case wedgeRestartReason                 // reason shown in the "↻ Reconnecting (…)" line

    // MARK: #436 — wbstream account token (install sheet)
    case wbTokenHeader                      // section header
    case wbTokenFieldLabel                  // SecureField placeholder
    case wbTokenFooter                      // help text

    // MARK: SettingsView
    case settingsTitle
    case sectionSOCKS5, sectionDNS, sectionVP8
    // #343 was: sectionKeepAlive, sectionFont — keep-alive folded into the
    // Connection section, the font section header became "Appearance".
    // #460 was: `sectionConnection` ("Connection") — one header over eight rows
    // covering at least four subjects (finding 13): a launch toggle, a start
    // timeout, keep-alive, background audio, a wedge toggle, a Servers-tab side
    // effect, update checking and the log level. A `Form` footer belongs to the
    // whole section, so no footer under it could say which row it meant
    // (finding 10). It is replaced by headers that each name ONE subject.
    case settingsSectionOnOpen              // #460: "When the app opens"
    case settingsSectionStart               // #460: "Starting a connection"
    case settingsSectionStayConnected       // #460: "Staying connected"
    case settingsSectionSpeedTest           // #460: "Speed test" — split out of "Diagnostics" (finding 21b)
    case settingsSectionUpdates             // #460: "Updates"
    case sectionLogs
    case sectionIPSources                   // "IP-check sources" (#286)
    case ipSourcesFooter                    // explanation of the IP-source toggles (#286)
    case sectionSpeedProvider               // "Speed-test provider" (#285)
    case speedProviderFooter                // explanation of the provider pick-list (#285)
    case speedAllFailed                     // "All measurements failed" (#285)
    case speedDatachannelHint               // tip: switch to datachannel for speed (#285)
    case settingsPortLabel
    case checkPortAction                    // "Check port"
    case randomPortAction                   // "Random"
    case portFree, portBusy                 // "free" / "busy"
    // MARK: #300 — three explicit port-check log lines (free / busy by
    // someone else / busy because our own tunnel reserved it), replacing
    // the old binary logPortBusy_fmt which couldn't tell those apart.
    case logPortFree_fmt                    // "✓ Port %d free"
    case logPortBusyOther_fmt               // "✗ Port %d busy"
    case logPortBusyOlcrtc_fmt              // "✓ Port %d in use by olcOS tunnel"
    // #343 was: socksFooter — cut per the one-short-footer rule (§7)
    case socksPortChangeNote                // "Port change takes effect on the next connection"
    case dnsFreeFormPlaceholder             // "IP:port"
    case dnsFooter
    // #460 was: `vp8Footer`, which opened with the gomobile symbol
    // "MobileSetVP8Options" and the literal "transport=vp8channel"
    // (finding 12). Same subject, said in the user's terms — including
    // the transport itself, which every picker in the app calls "VP8".
    case vp8Note
    case startTimeoutLabel                  // "Ready timeout"
    case startTimeoutNote                   // #460: what the timeout does, under its own field
    case autoConnectOnLaunchLabel
    case autoConnectOnLaunchNote            // #460: note under the auto-connect toggle
    case autoRemoveConnectionOnUninstallLabel
    case autoRemoveOnUninstallNote          // #460: note under the uninstall side-effect toggle
    case tunnelCheckLabel                   // "Tunnel check"
    case keepAliveOff                       // "off"
    case backgroundAudioLabel
    case backgroundAudioNote                // #460: note under the background-audio toggle
    case earlyRestartWedgeNote              // #460: note under the early-restart toggle
    case localSocksAuthLabel                // #343 was: + localSocksAuthFooter (footer cut, §7)
    case logLevelLabel
    case logLevelNote                       // #460: note under the log-level picker
    // #343 was: footerStartTimeout/AutoConnect/AutoRemove/BackgroundAudio/
    // DebugLogging + footerContainerTail — per-row footers cut when the
    // Connection and Logs groups merged into single sections (§7).
    case footerKeepAlive
    case footerLogBuffer
    case logBufferLabel, containerLogsTailLabel
    case containerLogsTailNote              // #460: note under the container-log tail field
    case clearAllLogsAction
    case copyAllAction                      // "Copy all" (#258 logs overflow)
    case clearCategoryAction                // "Clear this category" (#258 logs overflow)
    // (audit) leftmost slider position: follow iOS Text Size (no app override,
    // AX sizes reachable). The XS…XXXL positions stay an explicit override.
    // #460 was: `fontFooter` — "Applied app-wide (via SwiftUI dynamicTypeSize)"
    // named a framework API in a Settings footer (finding 18).
    case languageLabel
    // #299 was: themeRefined/themeConsole/directionLabel — the Refined/Console
    // "design direction" picker was removed when Theme became real colour schemes.
    case themeLabel                         // "Theme" — the appearance-scheme picker label
    // #340 — appearance scheme picker (System / Light / Dark / Gray)
    case appearanceLabel                    // "Appearance"
    case appearanceSystem                   // "System"
    case appearanceLight                    // "Light"
    case appearanceDark                     // "Dark"

    // MARK: InstallOptionsView
    case installTitle                       // "Install olcOS"
    case reconfigureTitle                   // "Change Room / Transport"
    case reconfigureInfoFooter              // "Container will be restarted with new flags — no reinstall."
    // #451: reconfigure rewrites only provider/id/transport (+ auth.token) —
    // vp8:/sei: tuning blocks are NOT written, so after a transport switch the
    // server runs its engine defaults. Surfaced in the reconfigure sheet.
    case reconfigureTransportTuningFooter
    case parametersHeader                   // "Parameters"
    case roomIDAutoGenHint
    case roomIDTelemostHint
    case roomIDWbstreamHint
    case matrixRecommended_fmt              // "★ Recommended for %@."
    case matrixWorks_fmt                    // "Works with %@."
    case matrixQuestion_fmt                 // "⚠ Working with %@ is uncertain."
    case matrixFail_fmt                     // "✗ Does not work with %@ — choose another transport."
    case matrixUnknown_fmt                  // "No compatibility data for %@."
    case carrierFooter                      // "client-id=ios-<random>..."
    case transportUsesServerDefaults_fmt    // "Server defaults will be used for %@ — advanced parameters are not yet exposed in the iOS settings UI."
    case transportSectionHeader, roomIDSectionHeader
    case seiSettingsHeader, seiSettingsFooter
    case jitsiServerHeader, jitsiServerFooter   // #256: Jitsi base-URL field
    case actionQR

    // MARK: Status banner

    // MARK: TunnelManager log lines
    case mobileStartOK                      // "✓ MobileStart OK, waiting for WaitReady…"
    case mobileStartFailed_fmt              // "✗ MobileStart: %@"
    case bgKeeperFailed_fmt                 // "⚠ Background runtime keeper failed: %@ (app may be suspended in background)"
    case waitReadyFailed_fmt                // "✗ WaitReady: %@"
    case connectNoPeer                      // #275: WaitReady timed out → no peer joined (likely key/room/carrier)
    case waitReadyOK                        // "✓ WaitReady OK — SOCKS5..."
    case tunnelOK                           // "✓ Tunnel works — traffic is flowing through the server"
    case tunnelFailed                       // "✗ Tunnel not responding (server unreachable or 403 Forbidden IP)"
    case keepAliveOK                        // "♡ Keep-alive OK"
    case keepAliveLost                      // "✗ Keep-alive..."
    case serverConnectionLost               // "Connection to server lost"
    case serverNotResponding                // "Server not responding"
    case disconnectingArrow                 // "→ Disconnecting"
    case netPathLost                        // "⚠ Network lost — waiting for connectivity" (#269)
    case waitingForPortRelease              // "⏳ Waiting for port release…" (#333: own-ghost same-port wait)
    case netPathRestored                    // "network restored" (#269 reconnect reason)
    case netPathChanged                     // "network path changed" (#269 reconnect reason)
    case reconnecting_fmt                   // "↻ Reconnecting (%@)" (#269/#270 sink entry)
    case reconnectAttempt_fmt               // "↻ attempt %d/%d in %ds" (#270 backoff)
    case reconnectGaveUp                    // "✗ Reconnect failed — tap Retry" (#270 give-up)
    case rejoinSettle_fmt                   // "⏳ Room settle: %.1fs before re-join" (#271)
    case connectingOlcrtc_fmt               // "→ olcOS carrier=%@..."
    // #308 was: portChangedAuto_fmt ("↪ Port %d is busy, using %d") — removed with
    // the auto-slide; the configured SOCKS port is now always bound (see errorPortBusy_fmt).

    // MARK: TunnelManager errors
    case validateClientIDEmpty
    case validateClientIDWhitespace
    case validateKeyLength_fmt
    case validateKeyNonHex
    case validateRoomIDEmpty
    // #308 was: errorAllPortsBusy_fmt (port-range "all busy") — replaced by the
    // single-port errorPortBusy_fmt now that the port no longer slides.
    case errorPortBusy_fmt                  // "Port %d is busy — free it or change the port in Settings" (OLC-1026)
    // #375: the encryption key couldn't be read from Keychain because the device
    // was still locked at launch (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly).
    // Shown instead of the misleading "Key must be 64 hex characters (got: 0)".
    case errorSecretsLocked                 // "Unlock the device and reopen the app to load your saved key."
    // #445 (audit fix 7): the previous generation outlived both bounded stops
    // (5 s + a 10 s retry) — the runtime is still draining its goroutine, so
    // Start keeps throwing ErrAlreadyRunning. Actionable wait-and-retry message
    // instead of the raw untranslated "olcRTC runtime is already active".
    case errorRuntimeStillStopping          // "Previous session is still shutting down — try again in a few seconds."

    // MARK: OlcrtcURI errors
    case uriErrorInvalidScheme
    case uriErrorMissingField_fmt
    case uriErrorMixedBrackets               // #355 (audit S1): payload [...]/<...> brackets mismatched

    // MARK: Provisioning
    case provisioningSSHConnecting          // "Connecting via SSH…"
    case provisioningRebootSSH              // "Reboot: connecting via SSH…"
    case provisioningUninstallSSH           // "Delete: connecting via SSH…"
    case provisioningRebooting              // "Rebooting…"
    case provisioningUninstalling           // "Removing container and files…"
    case provisioningUpdating               // "Updating binary…"
    case provisioningReconfiguring          // "Reconfiguring container…"
    case provisioningStatusFetching         // "Container status…"
    case provisioningLogsFetching           // "Container logs…"
    case installStep1Upload                 // "[1/3] Uploading script…"
    case installStep2Launch                 // "[2/3] Running install script…"
    case installStep3PollRetry_fmt          // "[3/3] Server temporarily unavailable, retry (%d)…"
    case installPhaseWaiting, installPhaseSystemDeps, installPhaseClone, installPhasePullImage, installPhaseDeps, installPhaseBuild, installPhaseStart
    case installFailedNoURI_fmt             // "Script finished without URI. Last lines:\n%@"
    case installTimeout25min                // "Install timed out (25 minutes)"
    case installResultSuccess_fmt           // "olcOS server installed (%@/%@)"
    case uninstallResultSuccess             // "Server cleaned up"
    case updateResultSuccess                // "Binary updated"
    case provisioningStarting, startResultSuccess, actionStart
    case provisioningStopping, stopResultSuccess, actionStop
    case scanningContainers, actionScanVPS, scanNoContainers
    case scanRestoreAction
    case actionDeepUninstall, deepUninstallResultSuccess
    case reconfigureResultSuccess_fmt       // "Parameters updated (%@/%@)"
    case rebootResultSuccess                // "Reboot command sent"
    case logsBytesReceived_fmt              // "Logs received (%d bytes)"
    case provisionPasswordMissing           // "Password not found in Keychain"
    case provisionSSHPrefix_fmt             // "SSH: %@"
    case provisionCommandPrefix_fmt         // "Command: %@"
    case provisionParsePrefix_fmt           // "Failed to parse output: %@"
    case sshAttemptFailed_fmt               // "✗ SSH attempt %d/2..."
    case sshRetryIn4s                       // "  retry in 4 s…"
    case sshPortNotResponding_fmt           // "Port %d on %@ did not respond — verify SSH is open and the VPS is reachable"
    case serverUnreachable_fmt              // "Server %@ is not responding — check the VPS is online and SSH port is reachable"
    // #462 (audit): the SSH session was riding the app's own tunnel and that
    // tunnel died mid-command — the self-teardown case (reconfigure / update /
    // rotate key / stop / uninstall / reboot run through the very tunnel whose
    // exit container they restart). Without this the user only saw a raw
    // Citadel channel error.
    case sshTunnelDroppedMidOp_fmt          // "…tunnel dropped mid-operation… (%@)"

    // MARK: NetPing
    case pingTCPOK_fmt                      // "TCP/%d responded in %@ ms"
    case pingTCPFail_fmt                    // "TCP/%d unreachable"

    // MARK: ConnectionsView per-connection health check (#274 — merges #234 + #242)
    case pingNoFreePort                     // "No free local port available for ping"
    case pingFailed                         // "Ping failed"

    // MARK: ServersView alerts
    case alertPasswordMissingShort          // "Password not found"
    case alertKeyMissingShort               // #451: "SSH key not found" — key-auth hosts
    // #451: full-access sharing is disabled for key-auth hosts (the link would
    // embed the private key) — the menu item explains via this alert.

    // MARK: AddServerHostView
    case nameSettingLabel                   // "Name"
    case sectionDescription                 // "Description"
    // #451: SSH auth-method picker + private-key entry UI.
    case authMethodPickerLabel              // "Authentication"
    case authMethodPassword                 // "Password" (segment title)
    case authMethodKey                      // "SSH key" (segment title)
    case sshKeyFooter                       // help under the key editor
    case sshKeyPasteButton                  // "Paste key from clipboard"
    case sshKeyPassphraseField              // "Key passphrase"
    case sshKeyDetected_fmt                 // "✓ %@ key detected"
    case sshKeyDetectedEncrypted_fmt        // "✓ %@ key detected — encrypted…"
    case sshKeyErrorECDSA                   // ECDSA unsupported + guidance
    case sshKeyErrorUnsupportedFormat       // non-OpenSSH format + conversion hint
    case sshKeyErrorNotAKey                 // paste doesn't look like a private key

    // MARK: ConnectionsView misc
    case diagnosticsTitle                   // "Diagnostics" (#258 merged card)
    case ipCheckTitle                       // "IP check"
    case ipCheckRun                         // "Check IP"
    case speedTestRun                       // "Run test"

    // MARK: #311 — speed-tile metric labels/units + upload-fallback log line
    // #459 was: `speedLabelPing` — the speed test's one-off PING metric is gone;
    // "This session" measures latency every 8 s and dates each measurement.
    case speedLabelDL, speedLabelUL         // "DL"/"UL" — universal abbreviations, ru = en
    // #342 was: units baked into the formats ("%.0f ms"/"%.1f Mbps") — now
    // number-only, the unit renders separately via OlcMetric(unit:).
    case speedRateValue_fmt                  // "%.1f"
    case speedUnitMbps                       // "Mbps" — Latin in both languages
    case speedUploadFallback_fmt             // "  upload: %@ has no upload endpoint — using %@" — diagnostic log line, deliberately English (ru = en)

    // MARK: #236/#237 — UI strings localized after the i18n pass
    case ipChecking                         // "Checking…"
    case ipNotChecked                       // "Not checked yet"
    case ipDnsLeak                          // "IPs differ — possible DNS leak"
    case ipSourcesAgree_fmt                 // "✓ %@ (%d sources)"
    case socksProxyAddr_fmt                 // "SOCKS5 proxy: 127.0.0.1:%@"
    // #300 was: portInUseByTunnel ("in use by tunnel") — relabeled to make
    // explicit that *this app's* tunnel reserved the port (vs. some other
    // process), and gated on live tunnel state at the call site.
    case portInUseByOlcrtc                  // "in use by olcOS tunnel"
    case roomPrefix_fmt                     // "room: %@"
    case qrCodeURIA11y                      // "Connection URI QR Code"
    case qrCodeHintA11y                     // "Scan this code to import the connection on another device"
    case cameraUnavailableTitle             // "Camera not available"
    case cameraUnavailableBody              // "QR scanning requires a physical device with a camera."
    case sectionCarrier                     // "Carrier"
    case labelTransport                     // "Transport"
    // #283: friendly display names for the raw carrier/transport IDs
    case carrierTelemost, carrierWbstream, carrierJitsi
    case transportDatachannel, transportVp8channel, transportSeichannel, transportVideochannel
    case fieldRoomID                        // "Room ID"
    case fieldJitsiURL                      // "https://meet.example.org" (#256)

    // MARK: DNS carrier labels (RU operator names — localizable)
    case dnsLabelMts, dnsLabelBeeline, dnsLabelMegafon
    case dnsLabelTele2, dnsLabelYota

    // MARK: SubscriptionFetcher errors
    case subDohFailed_fmt                   // "DoH could not resolve %@"
    case subInvalidResponse_fmt             // "HTTP %d"
    case subNoAddress                       // "DoH returned an empty address list"

    // MARK: Subscription import (#111: olcrtc-sub:// links)
    case subImportTitle                     // "Import subscription"
    case subImportConfirm_fmt               // "Add %d connection(s) from “%@”?"
    case subImportAddAction                 // "Add"
    case subInvalidLink                     // bad olcrtc-sub:// link
    case subEmptyList                       // fetched, but no valid olcrtc:// lines
    case subImportPastedSource              // #361: source label for a pasted raw sub.md body

    // MARK: #363 — surfaced subscription metadata (group detail + per-node)
    case subMetaSource                      // "Source"
    case subMetaServers                     // "Servers"
    case subMetaRefresh                     // "Refresh"
    case subMetaRefreshNever                // "Never"
    case subMetaRefreshInterval_fmt         // "every %@"
    case subMetaUsed                        // "Used"
    case subMetaAvailable                   // "Available"
    case subMetaMultipleSources_fmt         // "%d sources" — #396: group sharing a #name across sources
    // #459 was: `pullToRefreshSubscriptions` — a caption instructing the user to
    // perform a standard gesture. The pull now refreshes everything, silently.

    // MARK: #346 — VPS-card mini-stat labels (abbreviations; ru = en per operator)
    case vpsStatPing, vpsStatDisk, vpsStatRAM, vpsStatUp
    case scanRestored_fmt                   // "Restored: %@" — #303 restore alert (real ru)

    // MARK: #337 — screenshot-safe IP masking
    case maskIPsLabel                       // "Hide IP addresses" — Settings toggle
    case maskIPsFooter                      // explanation: display-only, copy stays real, logs unmasked

    // MARK: #328 — active-carrier endpoints with one-tap copy (proxy-loop exclusions)
    // #460 (finding 23) was: `carrierEndpointsTitle` ("Carrier endpoints") and
    // `carrierEndpointsHint` — both written in the vocabulary of the person who
    // built the feature, on the app's main screen, with nothing saying who
    // needs it. The row now opens with the question that selects its audience
    // and the sheet explains itself before the address list.
    case carrierEndpointsRowTitle           // #461: now the ⋯ menu item's title
    // #461 was: `carrierEndpointsRowHint`, `carrierEndpointsRowConnectHint`
    // and `carrierEndpointsShowAction`. The ~90 pt row left the Diagnostics
    // card for the live connection's ⋯ menu, and a menu item is a label: the
    // two-line audience hint and the "Show" button lost their last call site.
    // The explanation survives once, inside the sheet (`carrierEndpointsLead`).
    case carrierEndpointsScreenTitle        // #460: the sheet's title, named after the action
    case carrierEndpointsLead               // #460: the "is this screen for me?" paragraph
    case carrierEndpointsFootnote           // #460: these addresses rotate
    case carrierEndpointHost                // "Host"
    case carrierEndpointResolvedIPs         // "Resolved IPs"
    case carrierEndpointResolving           // "Resolving…"
    case carrierEndpointUnresolved          // "Could not resolve"
    case carrierEndpointNoHost              // "This carrier's room ID isn't a host — nothing to exclude."
    case carrierEndpointCopied_fmt          // "📋 Copied: %@"
    case carrierEndpointRefresh             // "Re-resolve" — IPs rotate
    // #406: carrier endpoints behind a Diagnostics button + a copy-all action.
    // #460 was: `carrierEndpointsCheckAction` ("Check" — it read as "check
    // these endpoints' health", which the button does not do),
    // `carrierEndpointsConnectHint` and `carrierEndpointsReadyHint`. Replaced
    // by `carrierEndpointsRowTitle` above (#461: now a ⋯ menu item).
    case carrierEndpointCopyAll             // "Copy host & IPs"

    // MARK: #359 — accessibility for the hero connect toggle + icon toolbar buttons
    case a11yConnectToggle                  // "Connect"
    case a11yConnectHintSelectFirst         // "Select a connection first"
    case a11yStateConnected, a11yStateConnecting, a11yStateDisconnected  // toggle a11y value

    // MARK: #360 — in-app update checker (GitHub Releases)
    case updateCheckLabel                   // "Check for updates" — Settings toggle
    case updateCheckFooter                  // explanation: anonymous, opt-out, links only
    case updateAvailableTitle_fmt           // "Update available — %@"
    case updateAvailableBody                // explanation: a newer build is on GitHub; sideload it
    case updateOpenReleasePage              // "Open release page"
    case updateInstallSideStore             // "Install with SideStore"
    case updateInstallLiveContainer         // "Install with LiveContainer"
    case updateLater                        // "Later"

    // MARK: Bot settings (#416–#420)
    case botPlatformTelegram, botPlatformMax            // platform names; ru = en
    // status + recoverable errors (Provisioner / SSHRunner)
    case botDeploying, botDeploySuccess, botChecking, botRemoving, botRemoveSuccess
    case botErrorNoSystemd, botErrorNoPython, botErrorNoRoot, botErrorGeneric_fmt
    case botErrorNotActive                  // #423: installed but the service didn't start
    // per-server sheet (#419)
    case botSheetTitle                      // "Bot" — sheet title + action button/menu label
    case botSheetFooter                     // generic how-it-works line
    case botSelectLabel                     // "Bot" — picker: which registry bot
    case botCommandsHeader, botRepliesHeader
    case botStartCmdLabel, botStopCmdLabel
    case botStartReplyLabel, botStopReplyLabel, botUnknownReplyLabel
    case botDefaultStartReply, botDefaultStopReply, botDefaultUnknownReply  // seed values
    case botCheckAction                     // "Check server"
    case botDeployAction                    // "Deploy bot"
    case botRemoveAction                    // "Remove bot from server"
    case botStatusRunning                   // "Running"
    case botStatusInstalledIdle             // "Installed, not running"
    case botStatusNone                      // "No bot on this server"
    case botNoBotsTitle, botNoBotsHint      // empty-registry state
    case botMissingTokenError               // selected bot has no token yet
    case botUnknownFound_fmt                // "Found a bot “%@” that isn't in your Settings."
    case botRemoveConfirmTitle, botRemoveConfirmBody
    // settings registry (#420)
    case sectionBots                        // "Bots" — Settings section + subscreen title
    case botsFooter                         // detection / delete caveat
    case botsEmptyHint                      // list empty
    case botAddTitle, botEditTitle          // editor titles
    case botAddAction, botDeleteAction
    case botNameLabel, botNamePlaceholder, botPlatformLabel
    case botTokenLabel, botTokenPlaceholder // masked, paste-only
    case botTokenSavedHint, botTokenNoneHint
    case botCopyTokenAction, botTokenCopied
    case botNameTakenError
    case botTokenStatusSaved, botTokenStatusMissing // #428: read-only status in the per-server sheet
    case botTokenManageHint                 // #428: "token is set in Settings → Bots"
    case botTokenCreateHint                 // #428: "create the bot on the platform first"

    // MARK: #452 Multi-carrier VPS — protocol rows on the host card + extras install
    case protocolsSectionHeader            // "Protocols" — host-card section label
    case addProtocolAction                 // "Add protocol" (button + sheet confirm)
    case addProtocolTitle                  // add-protocol sheet title
    case removeProtocolAction              // "Remove from server" (row menu, destructive)
    case removeProtocolConfirmTitle_fmt    // "Remove %@ from this server?"
    case removeProtocolConfirmBody         // container + config removed; connection too
    // #460 (findings 7 / 16) was: `protocolConnectedBadge` ("Connected" /
    // «Подключено») — the longest word on the protocol row's title line, in a
    // column too narrow for it, which SwiftUI resolved by hyphenating:
    // "Connec-ted". The badge says the same thing in a word that fits.
    case protocolLiveBadge                 // "Live" — the badge on the running protocol row
    case protocolRecordMissing             // no matching saved connection — suggest Recover
    case protocolAdded_fmt                 // "Added %@/%@ — connection saved"
    case protocolRemoved_fmt               // "Removed %@ from the server"
    case installExtrasHeader               // "Additional protocols" (install sheet section)
    case installExtrasFooter               // extras share the key; one connection each
    case installExtraToggle_fmt            // "Also install %@"
    case installExtrasPartialFail_fmt      // "Some protocols failed to install: %@"

    // MARK: #456 Verified health vocabulary (NodeHealth / HealthDisplay)
    // One vocabulary for "is this node OK". Nothing here may claim success
    // without a probe behind it — `healthVerified` is granted ONLY by an
    // end-to-end result inside HealthPolicy.freshSeconds.
    case healthNeverChecked                 // "Not checked yet" — no probe on record
    case healthNeverCheckedHint             // what Verify actually does
    case healthChecking                     // "Checking…" — a probe is in flight
    case healthCheckingHint                 // what the probe is doing right now
    case healthVerified                     // "Working" — the ONLY green
    case healthVerifiedHint_fmt             // #459: "Verified %@ · %d ms" (age phrase, rtt)
    case healthVerifiedNoRTTHint_fmt        // #459: "Verified %@" (age phrase; no rtt)
    case healthFading                       // past tense: it worked, but not just now
    case healthHandshake                    // handshake only — data path unproven
    case healthHandshakeHint_fmt            // #459: "Joined the room %@, but…" (age phrase)
    case healthStale                        // older than HealthPolicy.staleSeconds
    case healthStaleHint_fmt                // #459: "Last checked %@ — …" (age phrase)
    case healthInconclusive                 // "Couldn't check" — NOT a failure verdict
    case healthCheckedAgo_fmt               // #459: "checked %@" — trailing age clause (age phrase)
    // Chip labels: lower case, no final period — they sit inside a pill.
    case healthChipNever                    // "not checked"
    case healthChipStale_fmt                // #459: "last seen %@" (age phrase)
    // #456 (audit fix): `.fading` must not share `.verified`'s words — past tense
    case healthChipFaded_fmt                // "was %@ · %@" (rtt, age SHORT)
    case healthChipFadedNoRTT_fmt           // #459: "worked %@" (age phrase)
    case healthChipFailed_fmt               // #459: "failed %@" (age phrase)
    case healthChipHandshake_fmt            // "no data · %@" (age SHORT)
    case healthChipUnchecked                // "couldn't check"
    // Relative age (HealthAge.phrase / HealthAge.short) — every verdict carries
    // its age. TWO forms, because one form produced "Verified just now ago":
    //   • phrase — a SELF-CONTAINED fragment ("just now", "2 min ago"). No format
    //     string that takes it may append "ago"/«назад» of its own.
    //   • short  — a bare DURATION for a chip where the value beside it supplies
    //     the grammar ("215 ms · 2m").
    case ageJustNow                         // phrase, < 1 min: "just now"
    case ageMinutesAgo_fmt                  // #459: phrase, "%d min ago" (minutes)
    case ageHoursAgo_fmt                    // #459: phrase, "%d hr ago" (hours)
    case ageDaysAgo_fmt                     // #459: phrase, "%d d ago" (days)
    case ageNowShort                        // #459: short, < 1 min: "now"
    case ageMinutes_fmt                     // short, "%dm" (minutes)
    case ageHours_fmt                       // short, "%dh" (hours)
    case ageDays_fmt                        // short, "%dd" (days)

    // MARK: #456 Failure reasons — plain words, never core log lines
    // Each reason has a long `message` (what happened + what to do) and a
    // `…Short` headline. HealthFailure.swift maps HealthReason → these.
    case healthReasonKeyMismatch, healthReasonKeyMismatchShort
    case healthReasonNoPeer, healthReasonNoPeerShort
    case healthReasonRoomInvalid, healthReasonRoomInvalidShort
    case healthReasonCarrierRejected, healthReasonCarrierRejectedShort
    case healthReasonNetworkDown, healthReasonNetworkDownShort
    case healthReasonHostUnreachable, healthReasonHostUnreachableShort
    case healthReasonSSHAuth, healthReasonSSHAuthShort
    case healthReasonPortBusy, healthReasonPortBusyShort
    case healthReasonVPNActive, healthReasonVPNActiveShort
    case healthReasonContainerStopped, healthReasonContainerStoppedShort
    case healthReasonTimedOut, healthReasonTimedOutShort
    case healthReasonUnknown, healthReasonUnknownShort

    // MARK: #456 Health actions (HealthAction.title)
    // Same wording as the equivalent action elsewhere in the app, on purpose:
    // healthActionRecover == actionRecoverConnection, healthActionStart ==
    // actionStart, healthActionCheckRoom == actionChangeRoomTransport,
    // healthActionRetry == actionRetry.
    case healthActionRecover                // "Recover connection"
    case healthActionCheckRoom              // "Change room / transport"
    case healthActionStart                  // "Start server"
    case healthActionPortSettings           // "Open port settings"
    case healthActionRetry                  // "Retry"
    case healthActionVerify                 // "Verify" — run the end-to-end probe
    // #459 was: `healthVerifyAllAction` ("Verify all") — a button inside a
    // section header, replaced by pull-to-refresh, which checks the whole screen.
    case healthShowReasonAction             // "What's wrong?" — reveals the full reason
    case healthLatencyNotMeasured           // nil rtt AFTER an attempt finished
    // #459 was: `healthSweepSkipped_fmt` — it named the deleted "Verify all".

    // MARK: #456 VPS card headlines (HostDisplay)
    // "Couldn't check" and "stopped" are different claims — requirement 2.
    case vpsHeadlineOpFailed                // last action failed; detail in subtitle
    case vpsHeadlineUnreachable             // SSH did not answer — NOT "stopped"
    case vpsHeadlineUnreachableHint_fmt     // #459: "SSH didn't answer (%@)" (age phrase)
    case vpsHeadlineUnreachableHintNever    // same, with no age on record
    case vpsHeadlineNotChecked              // no probe yet this session
    case vpsHeadlineNotCheckedHint          // the auto-refresh is running
    case vpsHeadlineStopped                 // container exists, is not running
    case vpsHeadlineStoppedHint             // what to do about it

    // MARK: #456 Misc UI copy
    case shareConnectionOnlyBadge           // scope of a plain olcrtc:// link
    case shareConnectionOnlySub             // what that link can and cannot do
    case roomIDLastUsed_fmt                 // "Use last room: %@" — remembered per carrier
    case installExistingFoundTitle_fmt      // "This VPS already runs %@"
    case installExistingFoundBody           // what a reinstall would destroy
    case installUseExistingAction           // adopt the existing container
    case installReinstallAction             // destructive: wipe and reinstall

    // MARK: #457 Tunnel-mode picker (moved out of the deleted Config tab)
    case tunnelModeLockedNote               // why the picker is disabled mid-session
    // The three questions the picker answers, each with a proxy and a VPN answer.
    case tunnelCompareScope, tunnelCompareScopeProxy, tunnelCompareScopeVPN
    case tunnelCompareNeeds, tunnelCompareNeedsProxy, tunnelCompareNeedsVPN
    case tunnelCompareRuns, tunnelCompareRunsProxy, tunnelCompareRunsVPN

    // MARK: #457 Logs as a detail view (the Logs tab is gone)
    // #460 (finding 21c) was: `settingsOpenLogsRow` ("Diagnostics and logs") —
    // the third thing in the app called "Diagnostics", and the only one of the
    // three that is a log reader. The row now says what it opens.
    case settingsViewLogsRow                // Settings row that opens the log reader
    case logsSubjectConnection              // title when the subject is the tunnel
    case logsSubjectProvisioning            // title when the subject is server work
    case logsSubjectContainer_fmt           // "Server log · %@" (server label)
    case logsEmptySubjectHint               // nothing recorded for this subject yet

    // MARK: #457 Connect hero
    case actionDisconnect                   // mirrors actionConnect
    case heroSubjectNone                    // no connection saved yet
    case heroPickAConnection                // what to do when there is nothing to connect to
    case heroEvidenceStarting_fmt           // "starting… %d s" (elapsed seconds)
    case heroEvidenceUnverified             // live, but nothing measured through it
    case heroEvidenceNoNetwork              // waitingForNetwork, session held
    case heroScopeProxy_fmt                 // what the tunnel covers, proxy (%@ port)
    case heroScopeVPN                       // what the tunnel covers, whole device

    // MARK: #457 Connection rows
    // #459 was: `connectRowLive` — the live connection is the hero's subject and
    // is no longer drawn in the list at all, so no row can need a "Live" badge.
    case connectRowTapHint                  // VoiceOver hint for the row
    case connectRowRemove                   // destructive row action
    case connectGroupFailing_fmt            // "%d of %d not working" (failing, total)

    // MARK: #457 Where a suggested action lives
    case healthActionOnServersTab_fmt       // "%@ — on the Servers tab" (action title)
    case healthActionInSettings_fmt         // "%@ — in Settings" (action title)
    case healthNeverMeasured                // age clause when nothing was ever measured

    // MARK: #457 Server card — the process caption and the protocol rows
    // #459 was: the process-caption vocabulary — `vpsProcessRunning`,
    // `vpsProcessStopped`, `vpsProcessNothingInstalled`, `vpsProcessNotSetUp`
    // and `vpsProcessAge_fmt` ("%@ · read %@ ago"). The card's headline already
    // says what the server is doing; the caption repeated it and then dated it
    // with a phrase that read "read just now ago". Only the never-read case and
    // a bare dated stamp (`vpsReadAge_fmt`) survive.
    case vpsProcessUnread                   // nothing has ever been read from this host
    case protocolStoppedNote                // protocol row: container isn't running
    case vpsScanBeforeInstall               // install pre-scan, in progress
    case vpsScanFailed_fmt                  // install pre-scan failed (%@ = reason)

    // MARK: #458 Regression fixes — say what is known, name only controls that exist
    // The protocol list has not been read yet: an empty list is not "nothing
    // installed". Shown next to the Add-protocol button, which is still offered.
    case protocolsNotReadYet
    // Result of an Add-protocol tap that refreshed the list first and found
    // every carrier already there.
    case addProtocolAllInstalled
    // #458 replaces `healthNeverCheckedHint` at the point of use: the same
    // subtitle renders in three hosts, so it states the fact and names no
    // button (ConnectionRowView draws the Verify affordance itself).
    case healthNeverProbedHint
    case connectRowVerifyHint               // VoiceOver hint for the row's verdict button

    // MARK: #459 One-window redesign
    // Every string here exists because the screen it sits on stopped repeating
    // itself: the hero owns the live connection, the list below it became a
    // switcher, Health and Diagnostics merged into one card, and the server
    // card's thirteen-item ⋯ menu became five safe items plus a pushed screen.
    case connectListOtherHeader             // header over the switcher list
    // The Diagnostics card's two blocks, and the provenance of the numbers in
    // them — the owner asked, of the exit country and IP, "where do they even
    // come from?". Both hints name the service that actually answers.
    case diagSessionHeader                  // block A: the live session
    case diagToolsHeader                    // block B: the checks you can run
    // #460 was: `diagExitSourceHint` ("Asked ipinfo.io through the tunnel") —
    // three words in the row's narrow right-hand value column, where it wrapped
    // into a ragged stack. The provenance is now a full-width row note, and it
    // says what was measured as well as who answered (findings 3 / 22).
    case diagIPSourceHint_fmt               // what the IP check does (%d = sources)
    // Server card: the read stamp, and the way into the pushed screen.
    case vpsReadAge_fmt                     // "read %@" (age phrase)
    case vpsManageServer                    // card row: opens ServerAdvancedView
    // ServerAdvancedView. Each destructive row carries a sentence saying what it
    // destroys — the thing a Menu cannot render, and the reason this is a pushed
    // screen rather than a fourteenth menu item.
    case vpsAdvancedTitle_fmt               // "Manage %@" (server label)
    case vpsAdvancedConnectionHeader
    case vpsAdvancedMaintenanceHeader
    case vpsAdvancedRemoveHeader
    case vpsAdvancedRebootFooter
    case vpsAdvancedUninstallFooter
    case vpsAdvancedDeepUninstallFooter
    case vpsAdvancedRemoveHostFooter

    // MARK: #460 Screenshot round 2–4
    // The screen printed two numbers for one connection — 1109 ms in red on the
    // Diagnostics card, 133 ms on a connection's chip — and called both "the
    // latency" (findings 2 / 15). #460 kept both measurements and explained the
    // gap in a 250-character note.
    // #461: the owner did not want the explanation, he wanted the numbers to
    // agree. Both sides now measure the same way — best of several round-trips
    // on one kept-alive connection — so the note has nothing left to reconcile
    // and the row is simply "Latency", the word the chips always used.
    // #461 was: `diagResponseNote`.
    case diagResponseLabel                  // "Latency" — was `healthLatencyLabel`
    // #461 was: `heroExitSourceNote` — a whole sentence of provenance under the
    // hero's country line. The hero states the fact; the Diagnostics card's
    // `diagExitNote` still says where the country came from, once.
    // #460 / instruction 26: the auto-switch control moved from Settings onto
    // the Connections screen, above the protocols it switches between. Short
    // enough for a card — the long Settings sentence stayed behind.

    // MARK: #461 Screenshot round 5 — one page, protocol first
    // A server with exactly one installed protocol produced a switcher section
    // with a header and no rows — a silent gap between the hero and the
    // auto-switch card that governs a choice the user cannot make. The row
    // states that fact and names the screen that fixes it, following this
    // screen's rule of naming a place rather than drawing a control that
    // navigates away.

    // MARK: #463 One-button Telemost room renewal
    // A Telemost link dies 24 hours after it is created, and the only channel
    // left to the phone during a whitelist window is the tunnel the dead room
    // just took down. These strings cover the whole errand: the Yandex sign-in
    // whose cookie creates rooms, the sheet that creates one and hands it to
    // the server, and the honest warnings around renewing the very protocol
    // the connection is riding on.

    // Failures of the create call (TelemostRoomError.errorDescription). Each
    // says what happened AND what to do; none may ever carry the cookie.
    case telemostErrNoAccount
    case telemostErrSessionRejected
    case telemostErrRateLimited
    case telemostErrNetwork
    case telemostErrMalformed
    case telemostErrStatus_fmt              // %d = HTTP status

    // The sign-in web view. `yandexLoginWarning` is the most important string
    // in this feature: a `Session_id` is a bearer credential for the whole
    // Yandex identity, so the warning must be read BEFORE a password is typed.
    case yandexLoginTitle
    case yandexLoginWarning

    // The sheet: row menu item and sheet title share one name, so the thing
    // tapped and the thing opened are called the same.
    case telemostNewRoomAction
    case telemostRoomServerLine_fmt         // %@ = server label
    case telemostRoomExplainer              // why the button exists at all (24 h)
    case telemostRoomNoAccountTitle
    case telemostRoomNoAccountBody
    case telemostRoomSignInAction
    case telemostRoomIdleTitle
    case telemostRoomIdleBody
    case telemostRoomCreateAction
    case telemostRoomWorkingTitle
    case telemostRoomWorkingCreate
    case telemostRoomWorkingApply
    case telemostRoomDoneTitle
    case telemostRoomDoneBody
    case telemostRoomFailedTitle
    case telemostRoomRetryAction
    case telemostRoomOtherAccountAction
    case telemostRoomForgetAccountAction
    case telemostRoomKeychainNote

    // The live-row hazard: renewing the protocol you are tunnelling through
    // restarts the container carrying your own SSH.
    case telemostRenewLiveSwitchable_fmt    // %@ = another protocol on this host
    case telemostRenewSwitchAction_fmt      // %@ = the same protocol name
    case telemostRenewLiveOnly              // no alternative exists on this host
    case telemostRenewDropped_fmt           // %@ = the new room id

    // #465: automatic renewal — raised only when the room is nearly gone and the
    // tunnel is in use, so the user is at the phone and can decide.
    // #468: a protocol row's start/stop acts on THAT protocol's container, not
    // on the server — the card's own button is the one that says "server".
    // #468: picker label for a host whose primary protocol the app cannot name.
    case logsContainerPrimary

    // #471: the design wave — the card states one claim, Settings holds six
    // sections, and the hero states instead of narrating.
    case vpsHeadlineProtocolsVerified_fmt   // %d of %d, %@ = HealthAge.phrase
    case healthPartlyWorking                // some protocols verified, some not
    case vpsHeadlineStoppedHint_fmt         // %@ = HealthAge.phrase
    case vpsMachineLine_fmt                 // %@ disk, %@ RAM, %@ uptime
    case vpsAdvancedMachineHeader           // Manage screen: the read-only block
    case vpsTitleNothingInstalled           // #471: .noPodman had to share vpsTitleReady
    case diagAgeVia_fmt                     // %@ = age; provenance folded in
    case subMetaUpdated_fmt                 // %@ = age (no gesture instruction)
    case settingsAdvancedRow
    case tunnelCompareDisclosure
    case settingsBackgroundLabel
    case settingsSectionAbout
    case settingsSectionConnection
    case settingsSectionProxy
    case settingsProxyAddressLabel          // #474: what to type into another app
    // #475: a check the user asked for, and its answer
    case updateCheckNowAction
    case updateUpToDate_fmt                 // %@ = the version being run
    case updateCheckFailed

    // #470: strings the review-batch fixes reference
    case protocolRecreateAction             // row menu: re-create a protocol whose container is gone
    case carrierFooterSharedKey             // add-protocol sheet footer
    case subImportAlreadySaved_fmt          // %@ = the record's display name
    case logsScanAmbiguous_fmt              // %d = number of olcrtc containers found
    case healthLatencyNoResponse            // chip text when the probe got nothing back
    case sshTunnelLoginTimedOut_fmt         // %@ = host, %d = port
    case dnsInvalidNote                     // Settings › DNS: the draft is not a valid host:port
    case speedTunnelDropped                 // speed test: the tunnel died mid-run

    // #469: the card names WHY the silent probe failed instead of "Checking…"
    case vpsHeadlineProbeFailed
    // #469 (issue #17): subscription footer — when the pull last refreshed it.

    case protocolStopAction
    case protocolStartAction

    case telemostExpiryTitle
    case telemostExpiryBody_fmt             // %@ = record name, %d = minutes left
    case telemostExpiryRenewAction
    // boc #480: distinguish unknown/blocked renewal from a known expiry.
    case telemostRenewalAttentionTitle
    case telemostAgeUnknown_fmt
    case telemostSetupRequired_fmt
    case telemostCreationFailed_fmt
    case telemostApplyUnconfirmed_fmt
    case telemostApplyCandidate_fmt
    case telemostForeignVPN_fmt
    case telemostReconnectRequired_fmt
    case telemostSignInSaved
    // eoc #480
    // #483: the credential lifetime intentionally excludes Settings-launched VPN.
    case vpnStartFromAppOnlyNote
    case vpnPacketDNSUnsupported // #485: reject an unusable VPN resolver before native startup.
    // boc #481: independently verified host identity; shared localization owner.
    case sshHostKeyFingerprintField
    case sshHostKeyVerificationAcknowledgement
    case sshHostKeyVerificationHelp
    case sshHostKeyFingerprintInvalid
    case sshHostKeyVerificationRequired
    case sshHostKeyMismatch
    // Automatic first-key trust: only failures expose security recovery.
    case sshHostKeyTrustStoreUnavailable
    case sshHostKeyChangedTitle
    case sshHostKeyResetAction
    case sshHostKeyResetWarning
    case sshHostKeyResetDone
    // eoc #481
    case later
    case addFlowStepAccess
    case addFlowStepCheck
    case addFlowStepProtocols
    case addFlowStepRoom
    case addFlowStepInstall
    case addFlowStepCounter_fmt
    case addFlowNext
    case addFlowBack
    case addFlowAccessLead
    case addFlowKeyPasted_fmt
    case addFlowKeyReplace
    case addFlowKeyNotShownNote
    case addFlowClipboardEmpty
    case addFlowLabelMissing
    case addFlowHostInvalid
    case addFlowPortInvalid
    case addFlowUserMissing
    case addFlowPasswordMissing
    case addFlowKeyMissing
    case addFlowPassphraseMissing
    case addFlowCheckLead
    case addFlowCheckRunning
    case addFlowCheckOK
    case addFlowCheckFailed
    case addFlowTofuFirstTitle
    case addFlowTofuFirstBody
    case addFlowTofuKnownTitle
    case addFlowTofuKnownBody
    case addFlowTofuMismatchTitle
    case addFlowFactOS
    case addFlowFactArch
    case addFlowFactRuntime
    case addFlowFactRuntimeNone
    case addFlowFactExisting_fmt
    case addFlowFactExistingNone
    case addFlowFactUnknown
    case addFlowProtocolsLead
    case addFlowBadgeRecommended
    case addFlowBadgeAlternative
    case addFlowBadgePrimary
    case addFlowNeedsYandex
    case addFlowTransportFor_fmt
    case addFlowPickAtLeastOne
    case addFlowRoomLead
    case addFlowYandexSignInBody
    case addFlowTelemostCreating
    case addFlowTelemostCreated
    case addFlowTelemostCreatedBody
    case addFlowTelemostFailed
    case addFlowJitsiInstance
    case addFlowJitsiInstanceNote
    case addFlowJitsiCustom
    case addFlowJitsiRoomName
    case addFlowJitsiRoomHint
    case addFlowRoomMissing_fmt
    case addFlowInstallLead
    case addFlowSummaryServer
    case addFlowSummaryProtocols
    case addFlowInstallRunning
    case addFlowInstallDone
    case addFlowInstallFailed
    case addFlowInstallFailedHint
    case addFlowResultConnections
    case addFlowResultPending
    case installOptionsLead
    case throughputKBps_fmt
    case throughputMBps_fmt
    case throughputA11y_fmt
    case throughputEstimateA11y_fmt
    case carrierJitsiDesc
    case carrierTelemostDesc
    case carrierWbstreamDesc
    case transportDatachannelDesc
    case transportVp8channelDesc
    case transportSeichannelDesc
    case transportVideochannelDesc
    case vpsSnapshotRefreshing
    case settingsCarrierEndpointsRow
    case settingsCarrierEndpointsEmpty
    case settingsBotsServersHeader
    case settingsBotsServersFooter
    case settingsConnectionSummary_fmt
    case settingsTransportSummary_fmt
    case settingsDiagnosticsSummary_fmt
    case settingsConnectionsCount_fmt
    case settingsBotsCount_fmt
    case protocolAboutAction
    case protocolAboutHide
    case shareServerTitle_fmt
    case shareServerProtocolsHeader
    case shareServerNoProtocols
    case shareFullAccessPasswordSub
    case shareFullAccessKeySub
    case shareFullAccessConfirmTitle
    case shareFullAccessConfirmAction
    case shareFullAccessConfirmPassword
    case shareFullAccessConfirmKey
    case shareFullAccessWarningKey
    case settingsUpdateCheckOn
    case settingsUpdateCheckOff
    case sshKeyStored_fmt
    case sshKeyReplaceAction
    case actionUpdateSub
    case vpsAdvancedOverviewHeader
    case vpsAdvancedActionsHeader
    case vpsAdvancedRecoverSub
    case healthActionSharedRecordNote
    case deviceNameSectionHeader
    case deviceNameLabel
    case deviceNameRegenerate
    case deviceNameFooter
    case fieldRevealSecret
    case fieldHideSecret
    case roomIDPlaceholder
    case roomIDLinkHint
    case wbTokenPlaceholder
    case formAccessSectionHeader
    case healthChipNotChecked
    case healthChipWas_fmt
    case healthChipNoData
    case shareRecipientHint
}

extension L10n {
    /// Returns the localized string for the current (or explicit) locale.
    func localized(_ locale: AppLocale = .current) -> String {
        L10nTable.value(for: self, in: locale)
    }

    /// Convenience for cases whose pattern contains %@/%d/%.0f placeholders.
    /// Cases that use this convention end with `_fmt`.
    func formatted(_ args: CVarArg...) -> String {
        String(format: self.localized(), arguments: args)
    }
}
