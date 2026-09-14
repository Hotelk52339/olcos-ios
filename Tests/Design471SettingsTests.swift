import XCTest
@testable import olcrtc_ios

// #471 (design pass D): the Settings restructure moved ~25 controls behind one
// "Advanced" push and changed two stored behaviours on the way. The layout
// itself is SwiftUI and not unit-testable in this host, so what is pinned here
// is the pair of DECISIONS that layout rests on — both of them pure, both of
// them things a future edit could silently undo:
//
//   1. the appearance default is System (follow the device) WITHOUT undoing the
//      #456 gray→dark migration, which ThemeDirectionTests pins from the other
//      side;
//   2. "remove the connections a server created when that server is removed" is
//      no longer a toggle, so the uninstall confirm dialog's promise is the only
//      behaviour there is.
//
// Nothing here mutates SettingsStore.shared: every assertion reads a `static`
// or a `Defaults` constant, so this file needs no snapshot/restore and cannot
// leak a developer's real settings the way a `reset()` test would.

final class Design471SettingsTests: XCTestCase {

    // MARK: Appearance default (#471)

    /// A fresh install — nothing under `settings.appearanceMode` — follows the
    /// device. The old code read the key with `?? ""` first, so "absent" and
    /// "unreadable" arrived at the same `?? .dark` and every new user was
    /// forced-dark regardless of their iOS setting.
    func testFreshInstallFollowsTheDevice() {
        XCTAssertEqual(SettingsStore.appearance(stored: nil), .system)
        XCTAssertEqual(SettingsStore.Defaults.appearanceMode, .system)
    }

    /// #456's migration, unchanged: a user whose UserDefaults still says "gray"
    /// (the fourth scheme removed in #456) lands on Dark — the scheme Gray was
    /// closest to — and NOT on the new System default. Someone who chose a
    /// scheme keeps a chosen scheme.
    func testStoredGrayStillResolvesToDark() {
        XCTAssertNil(AppearanceMode(rawValue: "gray"))
        XCTAssertEqual(SettingsStore.appearance(stored: "gray"), .dark)
    }

    /// Any other unreadable value takes the same route as "gray" — an explicit
    /// choice, however stale, is never re-themed to the device's answer.
    func testUnknownStoredValueResolvesToDark() {
        XCTAssertEqual(SettingsStore.appearance(stored: ""), .dark)
        XCTAssertEqual(SettingsStore.appearance(stored: "sepia"), .dark)
    }

    /// Every real stored value round-trips. `rawValue` is the persisted form, so
    /// this also pins that the picker writes what the resolver reads.
    func testStoredChoiceIsHonoured() {
        for mode in AppearanceMode.allCases {
            XCTAssertEqual(SettingsStore.appearance(stored: mode.rawValue), mode,
                           "stored \(mode.rawValue) must resolve to itself")
        }
    }

    // MARK: Connection removal on uninstall (#471)

    /// The "Remove linked connection when VPS is uninstalled" toggle is gone
    /// from Settings, so removing a server ALWAYS removes the connections it
    /// created. `SettingsStore.init` pins the property on regardless of what is
    /// stored (the key stays for downgrade safety), which is what lets
    /// `uninstallConfirmBody` state the outcome instead of hedging it.
    ///
    /// ServersView reads this property in two places; if a future change makes
    /// it a choice again, the confirm copy has to hedge again too.
    func testConnectionRemovalOnUninstallIsAlwaysOn() {
        XCTAssertTrue(SettingsStore.shared.autoRemoveConnectionOnUninstall)
    }

    // MARK: The #470 font sentinel survived the restructure (#471)

    /// #470 deleted the font slider but kept `fontSizeIndex` and its key for
    /// downgrade safety, with the default pinned to the "System" sentinel so the
    /// app follows iOS › Display & Brightness. #471 rebuilt the Appearance
    /// section around that; assert the sentinel is still the default rather than
    /// an index into `fontSizes`.
    func testFontSizeDefaultIsTheSystemSentinel() {
        XCTAssertEqual(SettingsStore.Defaults.fontSizeIndex, SettingsStore.systemFontSizeIndex)
        XCTAssertEqual(SettingsStore.systemFontSizeIndex, -1)
    }
}
