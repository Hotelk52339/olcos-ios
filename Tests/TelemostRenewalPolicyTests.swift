import XCTest
@testable import olcrtc_ios

// #465: every branch of the automatic-renewal decision.
//
// The policy is pure, so these are ordinary value-in/value-out tests — no app
// state, no Keychain, no network. The side-effecting half
// (TelemostRenewalCoordinator) is integration-only: it drives SSH and restarts a
// container, so it is not exercised here.
final class TelemostRenewalPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let altID = UUID()

    /// Default input: a fresh room, nothing connected, an account linked.
    private func input(
        ageHours: Double? = 0,
        riding: Bool = false,
        activitySecondsAgo: Double? = nil,
        alternative: UUID? = nil,
        session: Bool = true
    ) -> TelemostRenewalPolicy.Input {
        .init(now: now,
              roomCreatedAt: ageHours.map { now.addingTimeInterval(-$0 * 3600) },
              isRidingThisRoom: riding,
              lastTunnelActivity: activitySecondsAgo.map { now.addingTimeInterval(-$0) },
              alternativeRecordID: alternative,
              hasYandexSession: session)
    }

    // MARK: - Not yet time

    func testFreshRoomIsLeftAlone() {
        XCTAssertEqual(TelemostRenewalPolicy.decide(input(ageHours: 1)), .doNothing)
    }

    func testJustOutsideTheLeadIsLeftAlone() {
        // 24 h − 5 h lead = renewal starts at 19 h; 18.9 h is still too early.
        XCTAssertEqual(TelemostRenewalPolicy.decide(input(ageHours: 18.9)), .doNothing)
    }

    func testEnteringTheLeadWindowActs() {
        XCTAssertEqual(TelemostRenewalPolicy.decide(input(ageHours: 19.1)), .renewNow)
    }

    // MARK: - Nothing the policy can do

    func testWithoutAYandexSessionItStaysSilent() {
        // Even at the very edge: the sheet on the row already explains linking an
        // account, and a second nagging channel helps nobody.
        XCTAssertEqual(TelemostRenewalPolicy.decide(input(ageHours: 23.9, session: false)),
                       .doNothing)
    }

    func testUnknownAgeIsReportedRatherThanGuessed() {
        XCTAssertEqual(TelemostRenewalPolicy.decide(input(ageHours: nil)), .ageUnknown)
    }

    // MARK: - Choosing a moment

    func testNotRidingTheRoomRenewsImmediately() {
        // The restart costs this user nothing, so there is nothing to wait for.
        XCTAssertEqual(TelemostRenewalPolicy.decide(input(ageHours: 20, riding: false)),
                       .renewNow)
    }

    func testRidingWithAnAlternativeMovesFirst() {
        XCTAssertEqual(
            TelemostRenewalPolicy.decide(input(ageHours: 20, riding: true, alternative: altID)),
            .switchThenRenew(recordID: altID))
    }

    func testRidingAnIdleTunnelRenewsInPlace() {
        // Idle for longer than the grace period: nobody feels the drop.
        XCTAssertEqual(
            TelemostRenewalPolicy.decide(input(ageHours: 20, riding: true, activitySecondsAgo: 600)),
            .renewNow)
    }

    func testRidingABusyTunnelWaits() {
        XCTAssertEqual(
            TelemostRenewalPolicy.decide(input(ageHours: 20, riding: true, activitySecondsAgo: 5)),
            .waitForIdle)
    }

    // boc #480
    // #480 was: testATunnelThatNeverCarriedAnythingCountsAsIdle expected .renewNow.
    // An absent measurement is not proof that nobody is using this tunnel.
    func testUnknownActivityDoesNotCountAsIdle() {
        XCTAssertEqual(
            TelemostRenewalPolicy.decide(input(ageHours: 20, riding: true, activitySecondsAgo: nil)),
            .waitForIdle)
    }
    // eoc #480

    func testAnAlternativeWinsOverWaiting() {
        // Busy AND an alternative: moving is strictly better than waiting, because
        // it costs the user nothing and does not risk running out of time.
        XCTAssertEqual(
            TelemostRenewalPolicy.decide(input(ageHours: 20, riding: true,
                                               activitySecondsAgo: 1, alternative: altID)),
            .switchThenRenew(recordID: altID))
    }

    // MARK: - Running out of time

    func testBusyAndNearlyExpiredAsksTheUser() {
        // 23.5 h old → 30 min left, inside the critical hour, tunnel in use.
        // "In use" means the user is at the phone, which is what makes asking work.
        XCTAssertEqual(
            TelemostRenewalPolicy.decide(input(ageHours: 23.5, riding: true, activitySecondsAgo: 1)),
            .warnExpiringSoon(minutesLeft: 30))
    }

    func testBusyButNotYetCriticalStillWaits() {
        XCTAssertEqual(
            TelemostRenewalPolicy.decide(input(ageHours: 22, riding: true, activitySecondsAgo: 1)),
            .waitForIdle)
    }

    func testExpiredRoomIsStillWorthReplacing() {
        // The tunnel is probably already gone, but creating a room costs nothing
        // and the push may still land through another protocol.
        XCTAssertEqual(TelemostRenewalPolicy.decide(input(ageHours: 25)), .renewExpired)
    }

    func testExpiryIsAClockNotAnIdleTimer() {
        // A room in constant use is exactly as dead at 24 h as an unused one —
        // Yandex expires the link, not the session.
        XCTAssertEqual(
            TelemostRenewalPolicy.decide(input(ageHours: 24.5, riding: true, activitySecondsAgo: 0)),
            .renewExpired)
    }

    // MARK: - Helpers

    func testTimeLeftCountsDownAndGoesNegative() {
        let created = now.addingTimeInterval(-20 * 3600)
        XCTAssertEqual(TelemostRenewalPolicy.timeLeft(created: created, now: now),
                       4 * 3600, accuracy: 1)
        let old = now.addingTimeInterval(-30 * 3600)
        XCTAssertLessThan(TelemostRenewalPolicy.timeLeft(created: old, now: now), 0)
    }

    func testIdleBoundaryIsInclusive() {
        var i = input(ageHours: 20, riding: true, activitySecondsAgo: TelemostRenewalPolicy.idleGrace)
        XCTAssertTrue(TelemostRenewalPolicy.isIdle(i))
        i = input(ageHours: 20, riding: true, activitySecondsAgo: TelemostRenewalPolicy.idleGrace - 1)
        XCTAssertFalse(TelemostRenewalPolicy.isIdle(i))
    }

    // MARK: - Persistence of the stamp the whole policy depends on

    func testRoomCreatedAtSurvivesEncodingAndDecoding() throws {
        // The stamp is NOT a secret, so unlike `key`/`socksPass` it must persist.
        // If it silently did not, every launch would look like a room of unknown
        // age and nothing would ever renew.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let original = OlcrtcConnection(carrier: "telemost", transport: "vp8channel",
                                        roomID: "81650491011479", key: "k", clientID: "default",
                                        roomCreatedAt: stamp)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(OlcrtcConnection.self, from: data)
        // `accuracy:` has no Optional overload — unwrap, so a nil stamp fails as
        // a missing value rather than as a type error.
        let decoded = try XCTUnwrap(back.roomCreatedAt)
        XCTAssertEqual(decoded.timeIntervalSince1970,
                       stamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRecordsWrittenBeforeTheStampExistedDecodeAsUnknown() throws {
        // Evolution here is `decodeIfPresent` only (there is no migration code),
        // so an older record must decode with a nil stamp rather than failing —
        // and nil has to mean "unknown", never "brand new".
        let json = #"{"carrier":"telemost","transport":"vp8channel","roomID":"1","clientID":"default"}"#
        let back = try JSONDecoder().decode(OlcrtcConnection.self, from: Data(json.utf8))
        XCTAssertNil(back.roomCreatedAt)
        XCTAssertEqual(TelemostRenewalPolicy.decide(
            .init(now: now, roomCreatedAt: back.roomCreatedAt, isRidingThisRoom: false,
                  lastTunnelActivity: nil, alternativeRecordID: nil, hasYandexSession: true)),
            .ageUnknown)
    }

    // #470 was: `testTheStampIsNotWrittenIntoTheSecretlessEncoding` — the name
    // stated the opposite of the assertion (the stamp IS written; only the
    // secrets are absent), inviting a "fix" of CodingKeys in the wrong direction.
    func testTheStampIsPersistedWhileSecretsAreNot() throws {
        // Guards the opposite mistake: adding a CodingKey next to the deliberately
        // excluded ones is easy to get wrong in either direction — the stamp must
        // be in the encoding, `key` / `socksPass` must not.
        let data = try JSONEncoder().encode(
            OlcrtcConnection(carrier: "telemost", transport: "vp8channel", roomID: "1",
                             key: "SECRET", clientID: "default", socksPass: "SECRET",
                             roomCreatedAt: Date()))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("roomCreatedAt"))
        XCTAssertFalse(text.contains("SECRET"))
    }

    func testTheLeadIsLongEnoughToSurviveASleepingPhone() {
        // Guards the constant itself: iOS makes no promise about when a
        // background app runs, so the window has to contain a whole night.
        XCTAssertGreaterThanOrEqual(TelemostRenewalPolicy.renewalLead, 5 * 3600)
        XCTAssertLessThan(TelemostRenewalPolicy.criticalLead, TelemostRenewalPolicy.renewalLead)
    }
}
