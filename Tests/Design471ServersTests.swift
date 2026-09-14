import XCTest
@testable import olcrtc_ios

// #471: the Servers-tab half of the design pass — "one claim, one age, one
// latency". Every fix below is a pure function or a pure reducer, which is the
// only kind of thing this file is allowed to hold; the view changes it protects
// (the deleted read stamp, failure banner, metrics grid, quick-action button
// and list footer) are visual and are documented at their sites.
//
// What each group pins:
//   • `HostHeadline.isPartial` — the rule that stops a card saying "Working"
//     above a dead protocol. It may only ever DOWNGRADE a green.
//   • `HostHeadline.reduce` with a tally — the counts and the age that replaced
//     `ServerCardView.failureBanner` and `ServerCardView.readStamp`.
//   • `reduce` WITHOUT a tally — the defaults, so the expectations in
//     HostDisplayTests / Review469Tests stay exactly as true as they were.
//   • the machine line — the caption that replaced `ServerMetricsGrid`, built
//     from the `shortUsage` / `shortRAM` / `shortUptime` statics
//     `VPSStatFormattingTests` pins by name.
final class Design471ServersTests: XCTestCase {

    private var savedLanguage = "en"

    override func setUp() {
        super.setUp()
        // The default language follows the simulator locale; every assertion
        // here compares against `L10n.x.localized()`, but a format string and
        // the value it is compared with must resolve in ONE language.
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: isPartial — green survives only while EVERY protocol is verified

    func testPartialOnlyDowngradesAVerifiedVerdict() {
        let verified = HealthDisplay.verified(ms: 42, age: 30)
        XCTAssertTrue(HostHeadline.isPartial(verified, verified: 1, total: 2))
        XCTAssertFalse(HostHeadline.isPartial(verified, verified: 2, total: 2),
                       "all of them verified is not partial")
        XCTAssertFalse(HostHeadline.isPartial(verified, verified: 0, total: 0),
                       "no protocols at all is not partial")
        // A failure must never be UPGRADED to "partly working": the summary
        // already reports the best evidence, so anything that is not verified
        // keeps its own verdict.
        XCTAssertFalse(HostHeadline.isPartial(.broken(.keyMismatch, age: 60), verified: 0, total: 2))
        XCTAssertFalse(HostHeadline.isPartial(.never, verified: 0, total: 2))
        XCTAssertFalse(HostHeadline.isPartial(.stale(age: 4000), verified: 0, total: 1))
    }

    // MARK: the tally IS the subtitle (#471 was: failureBanner + readStamp)

    func testEveryProtocolVerifiedReadsAsOneCountedClaim() {
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: 5, health: .verified(ms: 173, age: 120),
                                    verified: 2, total: 2, verifiedAge: 120)
        XCTAssertEqual(h.tone, .ok, "all verified stays the one route to green")
        XCTAssertEqual(h.title, HealthDisplay.verified(ms: 173, age: 120).title)
        XCTAssertEqual(h.subtitle,
                       L10n.vpsHeadlineProtocolsVerified_fmt.formatted(2, 2, HealthAge.phrase(120)))
        // The second latency leaves with the health sentence it arrived in: the
        // card prints ONE ms value, on the protocol row's evidence chip.
        XCTAssertFalse(h.subtitle.contains("173"), h.subtitle)
    }

    func testOneDeadSiblingSaysPartlyWorkingInsteadOfWorkingPlusABanner() {
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: 5, health: .verified(ms: 90, age: 60),
                                    verified: 1, total: 2, verifiedAge: 60)
        XCTAssertEqual(h.title, L10n.healthPartlyWorking.localized())
        XCTAssertEqual(h.tone, .warn, "amber — never green, and never red either")
        XCTAssertEqual(h.subtitle,
                       L10n.vpsHeadlineProtocolsVerified_fmt.formatted(1, 2, HealthAge.phrase(60)))
    }

    func testNothingVerifiedKeepsTheHealthVocabularysOwnDatedSentence() {
        // No verified reading ⇒ no age to date a verification with, so the
        // headline must fall back rather than borrow the SSH read's age.
        let broken = HealthDisplay.broken(.keyMismatch, age: 300)
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: 5, health: broken,
                                    verified: 0, total: 2, verifiedAge: nil)
        XCTAssertEqual(h.subtitle, broken.subtitle)
        XCTAssertEqual(h.title, broken.title)
        XCTAssertEqual(h.tone, .error)
    }

    // MARK: the read age, on the sentence it qualifies

    func testStoppedCarriesTheReadAgeInsteadOfASeparateStamp() {
        let h = HostHeadline.reduce(display: .base(.stopped), reachable: true,
                                    lastProbeAge: 120, health: .never)
        XCTAssertEqual(h, .containerStopped(age: 120))
        XCTAssertEqual(h.tone, .warn)
        XCTAssertEqual(h.subtitle,
                       L10n.vpsHeadlineStoppedHint_fmt.formatted(HealthAge.phrase(120)))
    }

    func testNothingInstalledAppendsTheReadAgeToTheBaseSentence() {
        let h = HostHeadline.reduce(display: .base(.imageReady), reachable: true,
                                    lastProbeAge: 600, health: .never)
        XCTAssertEqual(h, .noContainer(.imageReady, age: 600))
        XCTAssertTrue(h.subtitle.hasPrefix(HostBase.imageReady.subtitle), h.subtitle)
        XCTAssertTrue(h.subtitle.hasSuffix(
            L10n.healthCheckedAgo_fmt.formatted(HealthAge.phrase(600))), h.subtitle)
        XCTAssertEqual(h.title, HostBase.imageReady.title, "an age never changes the claim")
    }

    // MARK: the defaults keep every existing expectation true

    func testAnUncountedReduceIsExactlyWhatItAlwaysWas() {
        let verified = HealthDisplay.verified(ms: 42, age: 30)
        let h = HostHeadline.reduce(display: .base(.running), reachable: true,
                                    lastProbeAge: 5, health: verified)
        XCTAssertEqual(h, .health(verified, verified: 0, total: 0, age: nil))
        XCTAssertEqual(h.subtitle, verified.subtitle, "no tally ⇒ the health sentence stands")
        XCTAssertEqual(h.title, verified.title)
        XCTAssertEqual(h.tone, .ok)
    }

    func testPrecedenceIsUntouchedByTheNewInputs() {
        // Requirement 2: "couldn't check" outranks any tally, however good.
        let h = HostHeadline.reduce(display: .base(.running), reachable: false,
                                    lastProbeAge: 900, health: .verified(ms: 10, age: 5),
                                    verified: 3, total: 3, verifiedAge: 5)
        XCTAssertEqual(h, .unreachable(age: 900))
        XCTAssertEqual(h.tone, .unknown)
    }

    // MARK: the machine line (#471 was: ServerMetricsGrid)

    func testMachineLineJoinsTheThreeReadingsThatDescribeTheMachine() {
        let line = L10n.vpsMachineLine_fmt.formatted(ServersView.shortUsage("3.5G/8.0G"),
                                                     ServersView.shortRAM("407M/1967M"),
                                                     ServersView.shortUptime("14 min"))
        XCTAssertTrue(line.contains("3.5/8.0G"), line)
        XCTAssertTrue(line.contains("0.4/1.9G"), line)
        XCTAssertTrue(line.contains("14m"), line)
        // PING is NOT on this line: a TCP-22 round-trip is not a user fact, and
        // in the same `ms` unit beside a verified latency it only contradicted
        // it. The reading survives on the Manage screen.
        XCTAssertFalse(line.lowercased().contains("ping"), line)
        XCTAssertEqual(line.components(separatedBy: " · ").count, 3, line)
    }
}
