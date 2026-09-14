import Foundation
import SwiftUI

// MARK: - LogLevel

enum LogLevel: Int, CaseIterable, Codable, Comparable {
    case off     = 0
    case error   = 1
    case info    = 2   // current level (non-debug)
    case debug   = 3   // current debugLogging=true
    case verbose = 4   // everything including Pion noise

    // #455: localised (was English-only — AGENTS.md flagged it). Computed at the
    // point of use (the log-level Picker), so it follows settings.language live.
    var label: String {
        switch self {
        case .off:     return L10n.logLevelOff.localized()
        case .error:   return L10n.logLevelErrors.localized()
        case .info:    return L10n.logLevelNormal.localized()
        case .debug:   return L10n.logLevelDebug.localized()
        case .verbose: return L10n.logLevelVerbose.localized()
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - AppearanceMode (#340)

/// App appearance: System follows iOS, Light/Dark force a scheme. Replaces
/// the Info.plist `UIUserInterfaceStyle = Dark` enforcement (project.yml);
/// applied via `.preferredColorScheme` on the root in App.swift.
/// #456 was: a fourth "gray" scheme (#299) that forced dark system chrome but
/// swapped the pure-black grounds for neutral mid-gray. Removed — a fourth
/// scheme diluted the palette and, producing no colorScheme trait change against
/// Dark, forced a full TabView rebuild in App.swift to refresh Theme's tokens.
/// A stored `"gray"` still decodes safely; see the `init` note below.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.appearanceSystem.localized()
        case .light:  return L10n.appearanceLight.localized()
        case .dark:   return L10n.appearanceDark.localized()
        }
    }

    /// nil = follow the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark   // #456 was: case .dark, .gray
        }
    }
}

// MARK: - SettingsStore
//
// Singleton ObservableObject for app-wide preferences. UserDefaults is the
// source of truth — @Published mirrors it so SwiftUI views can observe and
// non-view callers (TunnelManager, SOCKSSession) can read synchronously.
//
// Numeric properties clamp themselves in didSet: any out-of-range write
// (from UserDefaults corruption or code bugs) is silently corrected before
// reaching the Go runtime or SSH layer.
//
// UserDefaults writes are dispatched to a serial background queue so a
// slider drag (which fires didSet ~60×/sec) doesn't block the MainActor on
// the `CFPreferences` plumbing. Order is preserved because the queue is
// serial — the last write to a key wins, matching the synchronous semantics.

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    // MARK: Defaults

    enum Defaults {
        static let socksPort            = 8808          // arbitrary, avoids common app ports
        static let socksPortRange       = 1024...65535
        static let dnsServer            = "77.88.8.8:53" // Yandex — reliable from RU VPS
        static let startTimeoutSeconds  = 60
        static let startTimeoutRange    = 5...600
        static let keepAliveSeconds     = 30            // 0 = disabled
        static let keepAliveRange       = 0...300
        static let vp8FPS               = 60            // Telemost/wbstream room limit
        static let vp8FPSRange          = 1...60
        static let vp8BatchSize         = 64            // tested on Telemost + wbstream
        static let vp8BatchRange        = 1...256
        // #470: SEI transport ranges, shared by the install / add / edit sheets
        // (upstream rejects ack_timeout_ms == 0 and fragment_size > 60000; the
        // ACK value is milliseconds, not a count).
        static let seiFPSRange          = 1...120
        static let seiBatchRange        = 1...256
        static let seiFragRange         = 100...60000
        static let seiACKRange          = 1...10000
        static let logBufferSize        = 5000
        static let logBufferRange       = 50...10000
        static let containerLogsTail    = 200
        static let containerLogsTailRange = 50...2000
        static let fontSizeIndex        = SettingsStore.systemFontSizeIndex   // #470: no app override; the slider is gone
        static let vpsAutoPingEnabled   = true
        static let vpsAutoPingInterval  = 30
        static let earlyRestartOnWedge  = false   // #440: opt-in, brittle log-signature feature
        // #455: optimal out-of-the-box defaults — a fresh install should already
        // survive backgrounding, reconnect on launch, and fail over between
        // protocols, so the user doesn't have to remember to enable them after a
        // reinstall. (keepAliveSeconds is already 30 = on.)
        static let autoConnectOnLaunch  = true    // #455 was: hardcoded false
        static let backgroundAudio      = true    // #455 was: hardcoded false — keeps the SOCKS port alive in the background
        static let autoFailover         = true    // #455 was: false — protocol failover on by default
        // #458: check servers and protocols when the app is opened. ON by default —
        // the user should not have to ask the app what is true; the probes are
        // debounced (nothing re-checked inside HealthPolicy.minRecheckSeconds).
        static let refreshOnEntry       = true
        static let vpsAutoPingRange     = 10...300
        static let updateCheckEnabled   = true          // #360: opt-out
        // #471 was: `.dark` hardcoded at BOTH the init fallback and in reset()
        // — the app was forced-dark before #340 and the default never moved on.
        // A premium iOS app follows the device unless it is told otherwise, and
        // Light is now a first-class scheme (#456), not a fallback. One
        // constant, so the two sites can no longer disagree.
        static let appearanceMode       = AppearanceMode.system
    }

    // MARK: Persistence dispatch
    //
    // Serial queue guarantees FIFO ordering: multiple rapid writes to the
    // same key (slider drag → settle) end with the final value persisted.
    // `Task.detached` would not give that guarantee.

    private static let writeQueue = DispatchQueue(label: "olcrtc.settings.userdefaults")

    private static func persist<T>(_ value: T, forKey key: String) {
        writeQueue.async {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    /// #360: persist a nullable value — store it when present, remove the key
    /// when nil. The generic `persist` would store a wrapped `Optional.none`,
    /// which `object(forKey:)` reads back as non-nil. Used for `lastUpdateCheck`.
    private static func persistOptionalDate(_ value: Date?, forKey key: String) {
        writeQueue.async {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Test-only synchronization point — blocks until the write queue drains.
    /// NOT for production code. Used by `SettingsStoreTests` to assert that
    /// a clamp's persistence side-effect has landed in UserDefaults.
    static func flushPendingWrites() {
        writeQueue.sync { }
    }

    // MARK: Published properties

    @Published var socksPort: Int {
        didSet {
            let v = socksPort.clamped(to: Defaults.socksPortRange)
            if v != socksPort { socksPort = v } else { Self.persist(socksPort, forKey: Keys.socksPort) }
        }
    }
    @Published var fontSizeIndex: Int {
        didSet {
            // (audit) range now admits the -1 "System" sentinel (follow iOS
            // Text Size); 0…count-1 remain the explicit XS…XXXL override.
            let v = fontSizeIndex.clamped(to: Self.systemFontSizeIndex...(Self.fontSizes.count - 1))
            if v != fontSizeIndex { fontSizeIndex = v } else { Self.persist(fontSizeIndex, forKey: Keys.fontSizeIndex) }
        }
    }
    @Published var dnsServer: String {
        didSet { Self.persist(dnsServer, forKey: Keys.dnsServer) }
    }
    @Published var logLevel: LogLevel {
        didSet { Self.persist(logLevel.rawValue, forKey: Keys.logLevel) }
    }

    /// Backward-compatibility shim. True when log level is debug or higher.
    var debugLogging: Bool { logLevel >= .debug }

    @Published var startTimeoutSeconds: Int {
        didSet {
            let v = startTimeoutSeconds.clamped(to: Defaults.startTimeoutRange)
            if v != startTimeoutSeconds { startTimeoutSeconds = v } else { Self.persist(startTimeoutSeconds, forKey: Keys.startTimeout) }
        }
    }
    @Published var vp8FPS: Int {
        didSet {
            let v = vp8FPS.clamped(to: Defaults.vp8FPSRange)
            if v != vp8FPS { vp8FPS = v } else { Self.persist(vp8FPS, forKey: Keys.vp8FPS) }
        }
    }
    @Published var vp8BatchSize: Int {
        didSet {
            let v = vp8BatchSize.clamped(to: Defaults.vp8BatchRange)
            if v != vp8BatchSize { vp8BatchSize = v } else { Self.persist(vp8BatchSize, forKey: Keys.vp8BatchSize) }
        }
    }
    @Published var logBufferSize: Int {
        didSet {
            let v = logBufferSize.clamped(to: Defaults.logBufferRange)
            if v != logBufferSize { logBufferSize = v } else { Self.persist(logBufferSize, forKey: Keys.logBufferSize) }
        }
    }
    @Published var containerLogsTailLines: Int {
        didSet {
            let v = containerLogsTailLines.clamped(to: Defaults.containerLogsTailRange)
            if v != containerLogsTailLines { containerLogsTailLines = v } else { Self.persist(containerLogsTailLines, forKey: Keys.containerLogsTail) }
        }
    }
    @Published var autoConnectOnLaunch: Bool {
        didSet { Self.persist(autoConnectOnLaunch, forKey: Keys.autoConnectOnLaunch) }
    }
    @Published var autoRemoveConnectionOnUninstall: Bool {
        didSet { Self.persist(autoRemoveConnectionOnUninstall, forKey: Keys.autoRemoveConnectionOnUninstall) }
    }
    @Published var backgroundAudio: Bool {
        didSet { Self.persist(backgroundAudio, forKey: Keys.backgroundAudio) }
    }
    /// #337: screenshot-safe mode — when true, IP addresses in the Connections
    /// diagnostics and on VPS cards are masked for display only (copy actions
    /// and stored values stay real; Logs are deliberately never masked).
    @Published var maskIPs: Bool {
        didSet { Self.persist(maskIPs, forKey: Keys.maskIPs) }
    }
    @Published var localSocksAuthEnabled: Bool {
        didSet { Self.persist(localSocksAuthEnabled, forKey: Keys.localSocksAuthEnabled) }
    }
    @Published var localSocksUser: String {
        didSet { Self.persist(localSocksUser, forKey: Keys.localSocksUser) }
    }
    /// #470: the Keychain slot behind `localSocksPass` — one definition, so
    /// `reset()` deletes exactly the item the getter/setter use.
    private static let localSocksKeychain = (service: "olcrtc.local.socks", account: "password")

    /// Password is NOT @Published — stored and read via Keychain only.
    var localSocksPass: String {
        // #470 was: the literal "olcrtc.local.socks" / "password" pair in both accessors.
        get { KeychainHelper.get(service: Self.localSocksKeychain.service,
                                 account: Self.localSocksKeychain.account) ?? "" }
        set { _ = KeychainHelper.set(newValue, service: Self.localSocksKeychain.service,
                                     account: Self.localSocksKeychain.account) }
    }
    @Published var vpsAutoPingEnabled: Bool {
        didSet { Self.persist(vpsAutoPingEnabled, forKey: Keys.vpsAutoPingEnabled) }
    }
    /// #440: opt-in early restart of a wedged session from core log signatures.
    @Published var earlyRestartOnWedge: Bool {
        didSet { Self.persist(earlyRestartOnWedge, forKey: Keys.earlyRestartOnWedge) }
    }
    /// #453: opt-in auto-failover — on repeated reconnect failure switch to
    /// another protocol on the same VPS (see TunnelManager.requestReconnect).
    @Published var autoFailover: Bool {
        didSet { Self.persist(autoFailover, forKey: Keys.autoFailover) }
    }
    /// #458: re-check servers and protocols on entering the app / the Servers tab.
    @Published var refreshOnEntry: Bool {
        didSet { Self.persist(refreshOnEntry, forKey: Keys.refreshOnEntry) }
    }
    @Published var vpsAutoPingInterval: Int {
        didSet {
            let v = vpsAutoPingInterval.clamped(to: Defaults.vpsAutoPingRange)
            if v != vpsAutoPingInterval { vpsAutoPingInterval = v } else { Self.persist(vpsAutoPingInterval, forKey: Keys.vpsAutoPingInterval) }
        }
    }
    /// Language code consumed by `L10n.localized()` via `AppLocale.current`.
    /// Empty / unknown values fall back to English at the resolver layer.
    @Published var language: String {
        didSet { Self.persist(language, forKey: Keys.language) }
    }
    // #299 was: @Published var designConsole — the Refined/Console "design
    // direction" (#267/#281) that only reskinned shape, never colours. Removed
    // when Theme switched to real colour schemes (System/Light/Dark/Gray).
    /// #340: appearance (System/Light/Dark).
    /// #471 was: "Defaults to .dark — the app was forced-dark until now, so
    /// existing users see no change on update." The default is System now.
    /// Anyone who ever picked a scheme keeps it (the pick is persisted, and
    /// `appearance(stored:)` honours it); someone who never opened the picker
    /// does move from Dark to whatever their device says — deliberately, and
    /// one tap from Dark again.
    @Published var appearanceMode: AppearanceMode {
        didSet { Self.persist(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }
    // boc #487: automatic policy is distinct from the concrete session backend.
    @Published var connectionModePreference: ConnectionModePreference {
        didSet {
            Self.persist(connectionModePreference.rawValue, forKey: Keys.connectionModePreference)
            // Keep the legacy getter/binding predictable without turning Auto
            // into a durable override. Only direct tunnelMode writes are explicit.
            updatingLegacyMode = true
            tunnelMode = connectionModePreference.effectiveMode(vpnUnavailable: false)
            updatingLegacyMode = false
        }
    }
    private var updatingLegacyMode = false
    // #487 was: @Published tunnelMode persisted only the concrete backend.
    @Published var tunnelMode: TunnelMode {
        didSet {
            Self.persist(tunnelMode.rawValue, forKey: Keys.tunnelMode)
            if !updatingLegacyMode {
                connectionModePreference = tunnelMode == .vpn ? .vpn : .proxy
            }
        }
    }
    // eoc #487
    @Published var keepAliveSeconds: Int {
        didSet {
            let v = keepAliveSeconds.clamped(to: Defaults.keepAliveRange)
            if v != keepAliveSeconds { keepAliveSeconds = v } else { Self.persist(keepAliveSeconds, forKey: Keys.keepAlive) }
        }
    }
    /// #286: which `AppConstants.ipCheckServices` labels the IP check queries.
    /// Persisted as an array (Set isn't a plist type). An empty set falls back
    /// to the defaults at query time so the check never silently does nothing.
    @Published var enabledIPSources: Set<String> {
        didSet { Self.persist(Array(enabledIPSources), forKey: Keys.enabledIPSources) }
    }
    /// #285: which speed-test provider a run uses (id into `AppConstants.SpeedTest.providers`).
    @Published var speedTestProviderID: String {
        didSet { Self.persist(speedTestProviderID, forKey: Keys.speedTestProviderID) }
    }
    /// #360: opt-out toggle for the in-app GitHub-Releases update check. The
    /// check is anonymous (no install id), interval-gated, and fails silently —
    /// this is the only user control over it.
    @Published var updateCheckEnabled: Bool {
        didSet { Self.persist(updateCheckEnabled, forKey: Keys.updateCheckEnabled) }
    }
    /// #360: timestamp of the last *completed* update check (nil = never).
    /// Drives the 24h interval gate so the network call runs at most once a day.
    /// Persisted explicitly (write the Date / remove the key) rather than via the
    /// generic `persist`, which would wrap a nil `Date?` in a double-optional that
    /// `UserDefaults.set` can't store cleanly.
    @Published var lastUpdateCheck: Date? {
        didSet { Self.persistOptionalDate(lastUpdateCheck, forKey: Keys.lastUpdateCheck) }
    }

    // MARK: Init

    private init() {
        let d = UserDefaults.standard
        // Clamp on read — guards against UserDefaults corruption or values
        // written by older app versions outside the current valid range.
        socksPort           = (d.object(forKey: Keys.socksPort)           as? Int)  .map { $0.clamped(to: Defaults.socksPortRange) }       ?? Defaults.socksPort
        fontSizeIndex       = (d.object(forKey: Keys.fontSizeIndex)       as? Int)  .map { $0.clamped(to: Self.systemFontSizeIndex...(Self.fontSizes.count-1)) }   ?? Defaults.fontSizeIndex
        dnsServer           =  d.string(forKey: Keys.dnsServer)                                                                              ?? Defaults.dnsServer
        // Migration: old Bool key → new Int enum. If neither exists, default to .info.
        if let raw = d.object(forKey: Keys.logLevel) as? Int, let level = LogLevel(rawValue: raw) {
            logLevel = level
        } else if let oldBool = d.object(forKey: Keys.debugLoggingLegacy) as? Bool {
            logLevel = oldBool ? .debug : .info
        } else {
            logLevel = .info
        }
        startTimeoutSeconds = (d.object(forKey: Keys.startTimeout)        as? Int)  .map { $0.clamped(to: Defaults.startTimeoutRange) }      ?? Defaults.startTimeoutSeconds
        vp8FPS              = (d.object(forKey: Keys.vp8FPS)              as? Int)  .map { $0.clamped(to: Defaults.vp8FPSRange) }            ?? Defaults.vp8FPS
        vp8BatchSize        = (d.object(forKey: Keys.vp8BatchSize)        as? Int)  .map { $0.clamped(to: Defaults.vp8BatchRange) }          ?? Defaults.vp8BatchSize
        logBufferSize       = (d.object(forKey: Keys.logBufferSize)       as? Int)  .map { $0.clamped(to: Defaults.logBufferRange) }         ?? Defaults.logBufferSize
        containerLogsTailLines = (d.object(forKey: Keys.containerLogsTail) as? Int) .map { $0.clamped(to: Defaults.containerLogsTailRange) } ?? Defaults.containerLogsTail
        autoConnectOnLaunch = (d.object(forKey: Keys.autoConnectOnLaunch) as? Bool)                                                          ?? Defaults.autoConnectOnLaunch
        // #471 was: (d.object(forKey: Keys.autoRemoveConnectionOnUninstall) as? Bool) ?? true
        // #471: the toggle is gone from Settings — this is a choice nobody makes
        // months in advance, so removing a server now ALWAYS removes the
        // connections it created, and the uninstall confirm dialog says so. The
        // property and its key stay (a downgrade still finds the value it
        // expects); the stored value is no longer read, so a user who once
        // turned it off can't be left with a dialog that lies and no switch to
        // fix it. Read by ServersView only.
        autoRemoveConnectionOnUninstall = true
        backgroundAudio          = (d.object(forKey: Keys.backgroundAudio)          as? Bool)   ?? Defaults.backgroundAudio
        maskIPs                  = (d.object(forKey: Keys.maskIPs)                  as? Bool)   ?? false   // #337
        localSocksAuthEnabled    = (d.object(forKey: Keys.localSocksAuthEnabled)    as? Bool)   ?? false
        localSocksUser           = (d.string(forKey: Keys.localSocksUser))                      ?? ""
        language                 = (d.string(forKey: Keys.language))                            ?? Self.defaultLanguage()
        // #456: the Gray removal needs NO migration code. A UserDefaults value
        // of "gray" no longer matches a case, so `AppearanceMode(rawValue:)`
        // returns nil and the fallback resolves it to Dark: the scheme Gray was
        // closest to, and a valid stored value from the next write onward
        // (pinned by ThemeDirectionTests.testStoredGrayStillDecodesToSomethingValid).
        // #471 was: `AppearanceMode(rawValue: d.string(forKey:) ?? "") ?? .dark`
        // — which conflated "nothing stored" with "stored something unreadable"
        // and so forced Dark on every fresh install. The two cases are told
        // apart in `appearance(stored:)` now, and the gray→dark migration above
        // is unchanged.
        appearanceMode           = Self.appearance(stored: d.string(forKey: Keys.appearanceMode))   // #340, #471
        // boc #487
        // #487 was: missing tunnelMode defaulted to .proxy.
        let preference = ConnectionModePreference.restored(
            preference: d.string(forKey: Keys.connectionModePreference),
            legacyMode: d.string(forKey: Keys.tunnelMode))
        connectionModePreference = preference
        tunnelMode = preference.effectiveMode(vpnUnavailable: false)
        // eoc #487
        keepAliveSeconds    = (d.object(forKey: Keys.keepAlive)           as? Int)  .map { $0.clamped(to: Defaults.keepAliveRange) }         ?? Defaults.keepAliveSeconds
        vpsAutoPingEnabled  = (d.object(forKey: Keys.vpsAutoPingEnabled)  as? Bool)                                                          ?? Defaults.vpsAutoPingEnabled
        earlyRestartOnWedge = (d.object(forKey: Keys.earlyRestartOnWedge) as? Bool)                                                          ?? Defaults.earlyRestartOnWedge
        autoFailover        = (d.object(forKey: Keys.autoFailover)        as? Bool)                                                          ?? Defaults.autoFailover           // #453
        refreshOnEntry      = (d.object(forKey: Keys.refreshOnEntry)      as? Bool)                                                          ?? Defaults.refreshOnEntry        // #458
        vpsAutoPingInterval = (d.object(forKey: Keys.vpsAutoPingInterval) as? Int)  .map { $0.clamped(to: Defaults.vpsAutoPingRange) }       ?? Defaults.vpsAutoPingInterval
        if let arr = d.object(forKey: Keys.enabledIPSources) as? [String] {
            enabledIPSources = Set(arr)
        } else {
            enabledIPSources = AppConstants.defaultEnabledIPCheckLabels
        }
        speedTestProviderID = d.string(forKey: Keys.speedTestProviderID) ?? AppConstants.SpeedTest.defaultProviderID
        updateCheckEnabled  = (d.object(forKey: Keys.updateCheckEnabled) as? Bool)  ?? Defaults.updateCheckEnabled   // #360
        lastUpdateCheck     = d.object(forKey: Keys.lastUpdateCheck)     as? Date                                    // #360 (nil = never)
    }

    // MARK: Reset

    /// Restores all settings to their default values and persists them.
    func reset() {
        socksPort              = Defaults.socksPort
        fontSizeIndex          = Defaults.fontSizeIndex
        dnsServer              = Defaults.dnsServer
        logLevel               = .info
        startTimeoutSeconds    = Defaults.startTimeoutSeconds
        vp8FPS                 = Defaults.vp8FPS
        vp8BatchSize           = Defaults.vp8BatchSize
        logBufferSize          = Defaults.logBufferSize
        containerLogsTailLines = Defaults.containerLogsTail
        autoConnectOnLaunch    = Defaults.autoConnectOnLaunch
        autoRemoveConnectionOnUninstall = true
        backgroundAudio        = Defaults.backgroundAudio
        maskIPs                = false   // #337
        localSocksAuthEnabled  = false
        localSocksUser         = ""
        // #470: the copy promises "every setting", but the Keychain-backed
        // password survived a reset and was live again the moment auth was
        // re-enabled (the SecureField even prefilled it).
        KeychainHelper.delete(service: Self.localSocksKeychain.service,
                              account: Self.localSocksKeychain.account)
        language               = Self.defaultLanguage()
        appearanceMode         = Defaults.appearanceMode   // #340; #471 was: .dark
        // #487 was: tunnelMode = .proxy
        connectionModePreference = .automatic // #487: reset opts back into capability-aware VPN-first.
        keepAliveSeconds       = Defaults.keepAliveSeconds
        vpsAutoPingEnabled     = Defaults.vpsAutoPingEnabled
        vpsAutoPingInterval    = Defaults.vpsAutoPingInterval
        earlyRestartOnWedge    = Defaults.earlyRestartOnWedge
        autoFailover           = Defaults.autoFailover   // #453
        refreshOnEntry         = Defaults.refreshOnEntry   // #458
        enabledIPSources       = AppConstants.defaultEnabledIPCheckLabels
        speedTestProviderID    = AppConstants.SpeedTest.defaultProviderID
        updateCheckEnabled     = Defaults.updateCheckEnabled   // #360
        lastUpdateCheck        = nil                           // #360: re-arm the check
    }

    /// #471 PURE: how a persisted appearance value resolves, with the two
    /// "not a valid mode" cases kept apart — the whole reason this is a function
    /// and not an `??` chain.
    ///
    /// - nothing stored (a fresh install, or a reset that removed the key):
    ///   `Defaults.appearanceMode` = System, so the app follows the device.
    /// - stored but no longer a case (the `"gray"` removed in #456): Dark, the
    ///   scheme Gray was closest to. Someone who CHOSE a scheme keeps it; only
    ///   someone who never chose gets the device's answer.
    ///
    /// Tested in Tests/Design471SettingsTests.swift.
    static func appearance(stored raw: String?) -> AppearanceMode {
        guard let raw else { return Defaults.appearanceMode }
        return AppearanceMode(rawValue: raw) ?? .dark
    }

    // boc #487: French/Russian/English share the locale resolver; saved choices
    // still win in init. #487 was: first language ru-prefix, otherwise en.
    private static func defaultLanguage() -> String {
        AppLocale.preferredLanguage(from: Locale.preferredLanguages)
    }
    // eoc #487

    // MARK: Font

    /// (audit, HIG typography) sentinel `fontSizeIndex` for "System": follow
    /// the iOS Text Size setting instead of overriding it — the only position
    /// from which the Larger Accessibility Sizes (AX1–AX5) are reachable.
    /// The XS…XXXL positions remain an explicit app-local override.
    static let systemFontSizeIndex = -1

    static let fontSizes: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge
    ]

    static let fontSizeLabels: [String] = [
        "XS", "S", "M", "L", "XL", "XXL", "XXXL"
    ]

    /// Explicit app-wide Dynamic Type override, or nil when the user picked
    /// "System" (the sentinel index) — App.swift then lets the device's own
    /// Text Size through unclamped.
    var resolvedTypeSize: DynamicTypeSize? {
        let idx = fontSizeIndex.clamped(to: Self.systemFontSizeIndex...(Self.fontSizes.count - 1))
        guard idx != Self.systemFontSizeIndex else { return nil }
        return Self.fontSizes[idx]
    }

    // MARK: Keys

    private enum Keys {
        static let socksPort           = "settings.socksPort"
        static let fontSizeIndex       = "settings.fontSizeIndex"
        static let dnsServer           = "settings.dnsServer"
        static let logLevel              = "settings.logLevel"
        static let debugLoggingLegacy    = "settings.debugLogging"   // migration only
        static let startTimeout        = "settings.startTimeoutSeconds"
        static let vp8FPS              = "settings.vp8FPS"
        static let vp8BatchSize        = "settings.vp8BatchSize"
        static let logBufferSize       = "settings.logBufferSize"
        static let containerLogsTail   = "settings.containerLogsTailLines"
        static let autoConnectOnLaunch = "settings.autoConnectOnLaunch"
        static let autoRemoveConnectionOnUninstall = "settings.autoRemoveConnectionOnUninstall"
        static let backgroundAudio           = "settings.backgroundAudio"
        static let maskIPs                   = "settings.maskIPs"   // #337
        static let localSocksAuthEnabled     = "settings.localSocksAuthEnabled"
        static let localSocksUser            = "settings.localSocksUser"
        static let language                  = "settings.language"
        // #299 was: designConsole = "settings.designConsole" — direction removed.
        static let appearanceMode            = "settings.appearanceMode"   // #340
        static let connectionModePreference = "settings.connectionModePreference" // #487
        static let tunnelMode                = "settings.tunnelMode"       // #vpn
        static let keepAlive                 = "settings.keepAliveSeconds"
        static let vpsAutoPingEnabled        = "settings.vpsAutoPingEnabled"
        static let vpsAutoPingInterval       = "settings.vpsAutoPingInterval"
        static let earlyRestartOnWedge       = "settings.earlyRestartOnWedge"
        static let autoFailover              = "settings.autoFailover"
        static let refreshOnEntry            = "settings.refreshOnEntry"
        static let enabledIPSources          = "settings.enabledIPSources"
        static let speedTestProviderID       = "settings.speedTestProviderID"
        static let updateCheckEnabled        = "settings.updateCheckEnabled"   // #360
        static let lastUpdateCheck           = "settings.lastUpdateCheck"      // #360
    }
}

// MARK: - Clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
