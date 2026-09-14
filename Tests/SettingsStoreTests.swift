import XCTest
@testable import olcrtc_ios

// Regression tests for the `didSet` clamps on every numeric SettingsStore
// property. The clamps exist so a buggy slider, a malformed TextField
// commit, or UserDefaults corruption can't push a value to the Go runtime
// or to the install script that would crash or behave unpredictably
// (a SOCKS port of 0, a log buffer of 2 billion entries, etc.).
//
// SettingsStore is a singleton, so tests snapshot every numeric property in
// setUp and restore in tearDown. We also flush `UserDefaults.standard` for
// the relevant keys so a clamp's persistence side-effect doesn't leak
// across tests or back to the dev's running app between debug sessions.

final class SettingsStoreTests: XCTestCase {

    private var snapshot: [String: Any] = [:]

    private let snapshottedKeys = [
        "settings.socksPort",
        "settings.fontSizeIndex",
        "settings.startTimeoutSeconds",
        "settings.vp8FPS",
        "settings.vp8BatchSize",
        "settings.logBufferSize",
        "settings.containerLogsTailLines",
        "settings.keepAliveSeconds",
        "settings.connectionModePreference", // #487
        "settings.tunnelMode",   // #vpn (string-backed enum, snapshot pattern still applies)
        "settings.autoFailover",   // #453
        "settings.refreshOnEntry",   // #458
    ]

    private var s: SettingsStore { SettingsStore.shared }

    // boc #469: `s.reset()` (testResetRestoresAllNumericDefaults) resets EVERY
    // setting — language, DNS, log level, appearance, auto-connect, IP sources —
    // but tearDown restored only the numeric snapshot, so one run left the
    // developer's real app settings at factory defaults. Snapshot every
    // persisted `settings.*` default around each test and put it back exactly,
    // absent keys included.
    private var allSettingsSnapshot: [String: Any?] = [:]

    /// #470: `reset()` also deletes the `olcrtc.local.socks` Keychain item, so a
    /// test run would drop a developer's real local-SOCKS password.
    private var savedLocalSocksPass = ""

    private func snapshotAllSettings() {
        savedLocalSocksPass = SettingsStore.shared.localSocksPass   // #470
        let d = UserDefaults.standard
        allSettingsSnapshot = [:]
        for (key, value) in d.dictionaryRepresentation() where key.hasPrefix("settings.") {
            allSettingsSnapshot[key] = value
        }
    }

    private func restoreAllSettings() {
        SettingsStore.shared.localSocksPass = savedLocalSocksPass   // #470
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("settings.") {
            if allSettingsSnapshot[key] == nil { d.removeObject(forKey: key) }
        }
        for (key, value) in allSettingsSnapshot {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }
    // eoc #469

    override func setUp() {
        SettingsStore.flushPendingWrites() // #487: snapshot committed preferences.
        snapshotAllSettings()   // #469
        super.setUp()
        // Snapshot every numeric property AND its UserDefaults key so we can
        // restore both layers — the in-memory @Published and the persisted
        // value the next ConnectionStore.init / app launch would read.
        snapshot = [
            "socksPort":              s.socksPort,
            "fontSizeIndex":          s.fontSizeIndex,
            "startTimeoutSeconds":    s.startTimeoutSeconds,
            "vp8FPS":                 s.vp8FPS,
            "vp8BatchSize":           s.vp8BatchSize,
            "logBufferSize":          s.logBufferSize,
            "containerLogsTailLines": s.containerLogsTailLines,
            "keepAliveSeconds":       s.keepAliveSeconds,
            "connectionModePreference": s.connectionModePreference, // #487
            "tunnelMode":             s.tunnelMode,   // #vpn
            "autoFailover":           s.autoFailover,   // #453
            "refreshOnEntry":         s.refreshOnEntry,   // #458
            "vpsAutoPingInterval":    s.vpsAutoPingInterval,   // #470: clamped (10…300), was never covered
        ]
    }

    override func tearDown() {
        defer { restoreAllSettings() }   // #469: after the property restores below
        s.socksPort              = snapshot["socksPort"]              as! Int
        s.fontSizeIndex          = snapshot["fontSizeIndex"]          as! Int
        s.startTimeoutSeconds    = snapshot["startTimeoutSeconds"]    as! Int
        s.vp8FPS                 = snapshot["vp8FPS"]                 as! Int
        s.vp8BatchSize           = snapshot["vp8BatchSize"]           as! Int
        s.logBufferSize          = snapshot["logBufferSize"]          as! Int
        s.containerLogsTailLines = snapshot["containerLogsTailLines"] as! Int
        s.keepAliveSeconds       = snapshot["keepAliveSeconds"]       as! Int
        s.tunnelMode             = snapshot["tunnelMode"]             as! TunnelMode   // #vpn
        s.connectionModePreference = snapshot["connectionModePreference"] as! ConnectionModePreference // #487: restore AFTER legacy setter.
        s.autoFailover           = snapshot["autoFailover"]           as! Bool   // #453
        s.refreshOnEntry         = snapshot["refreshOnEntry"]         as! Bool   // #458
        s.vpsAutoPingInterval    = snapshot["vpsAutoPingInterval"]    as! Int    // #470
        SettingsStore.flushPendingWrites() // #487: no queued writes after exact disk restoration.
        super.tearDown()
    }

    // MARK: vpsAutoPingInterval (10...300) — #470

    func testVPSAutoPingIntervalClampsBothEnds() {
        s.vpsAutoPingInterval = 9
        XCTAssertEqual(s.vpsAutoPingInterval, 10)
        s.vpsAutoPingInterval = 301
        XCTAssertEqual(s.vpsAutoPingInterval, 300)
        s.vpsAutoPingInterval = 60
        XCTAssertEqual(s.vpsAutoPingInterval, 60)
    }

    // MARK: socksPort (1024...65535)

    func testSocksPortClampsBelowRangeToLowerBound() {
        s.socksPort = 0
        XCTAssertEqual(s.socksPort, 1024)
        s.socksPort = -1
        XCTAssertEqual(s.socksPort, 1024)
        s.socksPort = 1023
        XCTAssertEqual(s.socksPort, 1024)
    }

    func testSocksPortClampsAboveRangeToUpperBound() {
        s.socksPort = 65536
        XCTAssertEqual(s.socksPort, 65535)
        s.socksPort = 1_000_000
        XCTAssertEqual(s.socksPort, 65535)
        s.socksPort = Int.max
        XCTAssertEqual(s.socksPort, 65535)
    }

    func testSocksPortAcceptsInRangeUnchanged() {
        s.socksPort = 1024
        XCTAssertEqual(s.socksPort, 1024)
        s.socksPort = 8808
        XCTAssertEqual(s.socksPort, 8808)
        s.socksPort = 65535
        XCTAssertEqual(s.socksPort, 65535)
    }

    func testSocksPortClampPersistsToUserDefaults() {
        s.socksPort = 999_999
        // Persistence is dispatched to a serial background queue (so a
        // slider drag doesn't block MainActor on `CFPreferences`). Drain
        // the queue before reading UserDefaults, otherwise the assertion
        // races the write.
        SettingsStore.flushPendingWrites()
        // After clamping the didSet also writes the clamped value out — so
        // a fresh init wouldn't re-clamp a corrupt value indefinitely.
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "settings.socksPort"), 65535)
    }

    // MARK: startTimeoutSeconds (5...600)

    func testStartTimeoutClampsBothEnds() {
        s.startTimeoutSeconds = 0
        XCTAssertEqual(s.startTimeoutSeconds, 5)
        s.startTimeoutSeconds = 4
        XCTAssertEqual(s.startTimeoutSeconds, 5)
        s.startTimeoutSeconds = 601
        XCTAssertEqual(s.startTimeoutSeconds, 600)
        s.startTimeoutSeconds = 60
        XCTAssertEqual(s.startTimeoutSeconds, 60)
    }

    // MARK: keepAliveSeconds (0...300, where 0 means "disabled")

    func testKeepAliveAcceptsZeroAsDisabledSentinel() {
        // 0 is in-range and meaningful: "keep-alive off". The clamp must NOT
        // bump it up — that would silently re-enable a feature the user
        // deliberately turned off.
        s.keepAliveSeconds = 0
        XCTAssertEqual(s.keepAliveSeconds, 0)
    }

    func testKeepAliveClampsNegativeToZero() {
        s.keepAliveSeconds = -5
        XCTAssertEqual(s.keepAliveSeconds, 0)
    }

    func testKeepAliveClampsAboveRange() {
        s.keepAliveSeconds = 301
        XCTAssertEqual(s.keepAliveSeconds, 300)
        s.keepAliveSeconds = 99_999
        XCTAssertEqual(s.keepAliveSeconds, 300)
    }

    // MARK: vp8FPS (1...60)

    func testVP8FPSClampsBothEnds() {
        s.vp8FPS = 0
        XCTAssertEqual(s.vp8FPS, 1)
        s.vp8FPS = 61
        XCTAssertEqual(s.vp8FPS, 60)
        s.vp8FPS = 30
        XCTAssertEqual(s.vp8FPS, 30)
    }

    // MARK: vp8BatchSize (1...256)

    func testVP8BatchClampsBothEnds() {
        s.vp8BatchSize = 0
        XCTAssertEqual(s.vp8BatchSize, 1)
        s.vp8BatchSize = 257
        XCTAssertEqual(s.vp8BatchSize, 256)
        s.vp8BatchSize = 64
        XCTAssertEqual(s.vp8BatchSize, 64)
    }

    // MARK: logBufferSize (50...10_000)

    func testLogBufferClampsBothEnds() {
        s.logBufferSize = 49
        XCTAssertEqual(s.logBufferSize, 50)
        s.logBufferSize = 10_001
        XCTAssertEqual(s.logBufferSize, 10_000)
        s.logBufferSize = 1000
        XCTAssertEqual(s.logBufferSize, 1000)
    }

    // MARK: containerLogsTailLines (50...2000)

    func testContainerLogsTailClampsBothEnds() {
        s.containerLogsTailLines = 49
        XCTAssertEqual(s.containerLogsTailLines, 50)
        s.containerLogsTailLines = 2001
        XCTAssertEqual(s.containerLogsTailLines, 2000)
        s.containerLogsTailLines = 200
        XCTAssertEqual(s.containerLogsTailLines, 200)
    }

    // MARK: fontSizeIndex (systemFontSizeIndex...fontSizes.count-1)
    // (audit) was: 0...count-1 — the range gained the -1 "System" sentinel
    // (follow iOS Text Size; resolvedTypeSize == nil), so the lower clamp
    // boundary moved from 0 to -1.

    func testFontSizeIndexClampsBothEnds() {
        let maxIdx = SettingsStore.fontSizes.count - 1
        s.fontSizeIndex = SettingsStore.systemFontSizeIndex - 1
        XCTAssertEqual(s.fontSizeIndex, SettingsStore.systemFontSizeIndex)
        s.fontSizeIndex = maxIdx + 1
        XCTAssertEqual(s.fontSizeIndex, maxIdx)
        s.fontSizeIndex = maxIdx
        XCTAssertEqual(s.fontSizeIndex, maxIdx)
        s.fontSizeIndex = 0
        XCTAssertEqual(s.fontSizeIndex, 0)
    }

    func testResolvedTypeSizeMatchesClampedIndex() {
        s.fontSizeIndex = 3
        XCTAssertEqual(s.resolvedTypeSize, SettingsStore.fontSizes[3])
        // Even if the clamp on the setter is bypassed somehow, the getter
        // re-clamps before indexing the fontSizes array — defensive.
        s.fontSizeIndex = 999
        XCTAssertEqual(s.resolvedTypeSize, SettingsStore.fontSizes.last)
    }

    /// (audit) the "System" sentinel is a valid stored value: it survives the
    /// clamp and resolves to nil, which App.swift maps to "no app override —
    /// follow the iOS Text Size setting (AX sizes reachable)".
    func testSystemFontSentinelResolvesToNil() {
        s.fontSizeIndex = SettingsStore.systemFontSizeIndex
        XCTAssertEqual(s.fontSizeIndex, SettingsStore.systemFontSizeIndex)
        XCTAssertNil(s.resolvedTypeSize)
        // An explicit pick restores the override.
        s.fontSizeIndex = 0
        XCTAssertEqual(s.resolvedTypeSize, SettingsStore.fontSizes[0])
    }

    // MARK: tunnelMode (#vpn)

    /// The mode is a string-backed enum, not a clamped numeric — the contract
    /// is the rawValue round-trip through UserDefaults (`settings.tunnelMode`),
    /// mirroring how `appearanceMode` persists.
    func testTunnelModePersistsRawValueToUserDefaults() {
        s.tunnelMode = .vpn
        SettingsStore.flushPendingWrites()
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.tunnelMode"), "vpn")

        s.tunnelMode = .proxy
        SettingsStore.flushPendingWrites()
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.tunnelMode"), "proxy")
    }

    // boc #487
    func testLegacyModeWritesRemainExplicitEvenWhenEqualToAutomaticDefault() {
        s.connectionModePreference = .automatic
        XCTAssertEqual(s.tunnelMode, .vpn)
        s.tunnelMode = .vpn
        XCTAssertEqual(s.connectionModePreference, .vpn)
        s.tunnelMode = .proxy
        XCTAssertEqual(s.connectionModePreference, .proxy)
    }

    func testAutomaticPreferencePersistsSeparatelyFromLegacyBackend() {
        s.tunnelMode = .proxy
        s.connectionModePreference = .automatic
        SettingsStore.flushPendingWrites()
        let d = UserDefaults.standard
        XCTAssertEqual(d.string(forKey: "settings.connectionModePreference"), "automatic")
        XCTAssertEqual(s.tunnelMode, .vpn)
        XCTAssertEqual(ConnectionModePreference.restored(
            preference: d.string(forKey: "settings.connectionModePreference"),
            legacyMode: d.string(forKey: "settings.tunnelMode")), .automatic)
    }
    // eoc #487

    // #453
    func testAutoFailoverPersistsToUserDefaults() {
        s.autoFailover = true
        SettingsStore.flushPendingWrites()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "settings.autoFailover"))

        s.autoFailover = false
        SettingsStore.flushPendingWrites()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "settings.autoFailover"))
    }

    // MARK: reset()

    func testResetRestoresAllNumericDefaults() {
        // Push every clamped value to its upper bound, then reset.
        s.socksPort              = 65535
        s.startTimeoutSeconds    = 600
        s.vp8FPS                 = 60
        s.vp8BatchSize           = 256
        s.logBufferSize          = 10_000
        s.containerLogsTailLines = 2000
        s.keepAliveSeconds       = 300
        s.tunnelMode             = .vpn   // #vpn: non-numeric, but reset() covers it too
        s.autoFailover           = false  // #455: default is now true — mutate away so reset() is proven to restore it
        s.refreshOnEntry         = false  // #458: default true — mutate away so reset() is proven to restore it
        // #470: the fontSizeIndex assertion below compared the untouched value
        // (the default on any fresh install) to the default — it could not fail.
        s.fontSizeIndex          = SettingsStore.systemFontSizeIndex
        s.vpsAutoPingInterval    = 300    // #470

        s.reset()

        XCTAssertEqual(s.socksPort,              SettingsStore.Defaults.socksPort)
        XCTAssertEqual(s.startTimeoutSeconds,    SettingsStore.Defaults.startTimeoutSeconds)
        XCTAssertEqual(s.vp8FPS,                 SettingsStore.Defaults.vp8FPS)
        XCTAssertEqual(s.vp8BatchSize,           SettingsStore.Defaults.vp8BatchSize)
        XCTAssertEqual(s.logBufferSize,          SettingsStore.Defaults.logBufferSize)
        XCTAssertEqual(s.containerLogsTailLines, SettingsStore.Defaults.containerLogsTail)
        XCTAssertEqual(s.keepAliveSeconds,       SettingsStore.Defaults.keepAliveSeconds)
        XCTAssertEqual(s.fontSizeIndex,          SettingsStore.Defaults.fontSizeIndex)
        // #487 was: reset asserted .proxy. Auto is VPN-first until its lazy gate fails.
        XCTAssertEqual(s.connectionModePreference, .automatic)
        XCTAssertEqual(s.tunnelMode, .vpn)
        XCTAssertEqual(s.autoFailover, SettingsStore.Defaults.autoFailover)   // #455: assert against the default (now true), not a literal
        XCTAssertEqual(s.refreshOnEntry, SettingsStore.Defaults.refreshOnEntry)   // #458
        XCTAssertEqual(s.vpsAutoPingInterval, SettingsStore.Defaults.vpsAutoPingInterval)   // #470
    }

    // MARK: defaults sanity — protects the Defaults ranges from drift
    //
    // If anyone tightens a range without checking that the default still
    // lives inside it, an app launch on a fresh install would clamp the
    // default to the new boundary — visible to the user as "Settings
    // mysteriously changed". Catch that at compile/test time.

    func testEveryDefaultLiesInsideItsClampingRange() {
        XCTAssertTrue(SettingsStore.Defaults.socksPortRange.contains(SettingsStore.Defaults.socksPort))
        XCTAssertTrue(SettingsStore.Defaults.startTimeoutRange.contains(SettingsStore.Defaults.startTimeoutSeconds))
        XCTAssertTrue(SettingsStore.Defaults.vp8FPSRange.contains(SettingsStore.Defaults.vp8FPS))
        XCTAssertTrue(SettingsStore.Defaults.vp8BatchRange.contains(SettingsStore.Defaults.vp8BatchSize))
        XCTAssertTrue(SettingsStore.Defaults.logBufferRange.contains(SettingsStore.Defaults.logBufferSize))
        XCTAssertTrue(SettingsStore.Defaults.containerLogsTailRange.contains(SettingsStore.Defaults.containerLogsTail))
        XCTAssertTrue(SettingsStore.Defaults.keepAliveRange.contains(SettingsStore.Defaults.keepAliveSeconds))
        // #471 was: `0...` — but the range this value is actually clamped to
        // starts at the "System" sentinel (-1), which #470 made the default when
        // the font slider was removed. The test must assert the REAL range.
        XCTAssertTrue((SettingsStore.systemFontSizeIndex...(SettingsStore.fontSizes.count - 1))
            .contains(SettingsStore.Defaults.fontSizeIndex))
        XCTAssertTrue(SettingsStore.Defaults.vpsAutoPingRange.contains(SettingsStore.Defaults.vpsAutoPingInterval))   // #470
    }
}
