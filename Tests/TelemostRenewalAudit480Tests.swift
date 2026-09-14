// boc #480: exercise the actual coordinator with in-memory state and suspended
// fake operations. No TunnelManager, stores, Keychain, HTTP or SSH are created.
import XCTest
@testable import olcrtc_ios

@MainActor
final class TelemostRenewalAudit480Tests: XCTestCase {
    private enum Failure: Error { case unreachable, authentication, restartDrop }

    @MainActor
    private final class Gate {
        let entered = XCTestExpectation(description: "Fake operation suspended")
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }

        func open() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    private final class Fixture {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var records: [ConnectionRecord]
        var host: ServerHost
        var hasTarget = true
        var engaged: ConnectionRecord?
        var connectedProxy = false
        var activity: Date?
        var foreignVPN = false
        var hasSession = true
        var creations = 0
        var applications: [InstallOptions] = []
        var updates: [ConnectionRecord] = []
        var disconnects = 0
        var connects: [ConnectionRecord] = []
        var claims = 0
        var releases = 0
        var savedPending: [UUID: TelemostRenewalCoordinator.PendingRenewal] = [:]
        let room = TelemostRoom(uri: "https://telemost.yandex.ru/j/222222", id: "222222")
        var reply: String? = "olcrtc://telemost?vp8channel@222222#test-key"
        var onCreate: @MainActor () async throws -> Void = {}
        var onApply: @MainActor () async throws -> Void = {}

        init(ageHours: Double? = 20) {
            let params = OlcrtcConnection(carrier: "telemost", transport: "vp8channel",
                roomID: "111111", key: "test-key", clientID: "default",
                roomCreatedAt: ageHours.map { Date(timeIntervalSince1970: 1_800_000_000 - $0 * 3600) })
            let record = ConnectionRecord(name: "Test room", details: .olcrtc(params))
            records = [record]
            host = ServerHost(label: "Test host", host: "192.0.2.1",
                lastContainerName: "olcrtc-test", lastConnectionID: record.id)
        }

        var record: ConnectionRecord { records[0] }
        var params: OlcrtcConnection {
            guard case .olcrtc(let params) = record.details else { fatalError("Fixture must be OlcRTC") }
            return params
        }

        func setRoom(_ id: String, ageHours: Double? = 23.5) {
            var value = params
            value.roomID = id
            value.roomCreatedAt = ageHours.map { now.addingTimeInterval(-$0 * 3600) }
            records[0].details = .olcrtc(value)
        }

        func makeCoordinator() -> TelemostRenewalCoordinator {
            TelemostRenewalCoordinator(environment: .init(
                records: { self.records },
                update: { record in
                    self.updates.append(record)
                    if let index = self.records.firstIndex(where: { $0.id == record.id }) {
                        self.records[index] = record
                    }
                },
                target: { _ in
                    guard self.hasTarget else { return nil }
                    return .init(host: self.host, secret: .password("test-only"),
                                 container: self.host.lastContainerName ?? "")
                },
                engagedRecord: { self.engaged },
                isConnectedProxy: { self.connectedProxy },
                lastActivity: { self.activity },
                foreignVPN: { self.foreignVPN },
                hasSession: { self.hasSession },
                createRoom: {
                    self.creations += 1
                    try await self.onCreate()
                    return self.room
                },
                applyRoom: { _, options in
                    self.applications.append(options)
                    try await self.onApply()
                    return self.reply
                },
                disconnect: { self.disconnects += 1; self.engaged = nil },
                connect: { self.connects.append($0); self.engaged = $0 },
                claimHost: {
                    self.claims += 1
                    return Provisioner.tryEnterHost($0)
                },
                releaseHost: {
                    self.releases += 1
                    Provisioner.leaveHost($0)
                },
                now: { self.now },
                loadPending: { self.savedPending },
                savePending: { self.savedPending = $0 }))
        }
    }

    func testConnectingOrRecoveryIsOccupiedAndNeverAutomaticallyRestarted() async {
        // Production supplies engagedRecord for BOTH connecting and recovery.
        for age in [20.0, 23.5, 25.0] {
            let f = Fixture(ageHours: age)
            f.engaged = f.record
            f.connectedProxy = false
            f.activity = f.now.addingTimeInterval(-600) // stale activity is not idle evidence
            let coordinator = f.makeCoordinator()
            let input = coordinator.input(for: f.record, now: f.now)
            XCTAssertTrue(input.isRidingThisRoom)
            XCTAssertFalse(input.activityIsObservable)
            await coordinator.checkNow()
            XCTAssertEqual(f.creations, 0)
            XCTAssertEqual(f.disconnects, 0)
            if age >= 23 { XCTAssertEqual(coordinator.warning?.reason, .expiring) }
        }
    }

    func testConfirmedExplicitRenewalReplacesEngagedRecoverySnapshot() async {
        let f = Fixture(ageHours: 25)
        f.engaged = f.record
        let original = f.record
        let coordinator = f.makeCoordinator()
        await coordinator.renew(recordID: original.id)
        XCTAssertEqual(f.updates.count, 1)
        XCTAssertEqual(f.params.roomID, f.room.id)
        XCTAssertEqual(f.params.roomCreatedAt, f.now)
        XCTAssertEqual(f.disconnects, 1)
        XCTAssertEqual(f.connects, [f.record])
        XCTAssertNotEqual(f.connects.first?.details, original.details)
    }

    func testAllSSHFailuresPreserveRoomAndClockWithoutClaimingSuccess() async {
        for failure in [Failure.unreachable, .authentication, .restartDrop] {
            let f = Fixture()
            let original = f.record
            f.engaged = original
            f.onApply = { throw failure }
            let coordinator = f.makeCoordinator()
            await coordinator.renew(recordID: original.id)
            XCTAssertEqual(f.record, original)
            XCTAssertTrue(f.updates.isEmpty)
            XCTAssertTrue(f.connects.isEmpty)
            XCTAssertEqual(f.disconnects, 0)
            XCTAssertEqual(coordinator.warning?.reason, .applyUnconfirmed)
            XCTAssertEqual(coordinator.warning?.canRenew, false)
            XCTAssertEqual(f.claims, 1)
            XCTAssertEqual(f.releases, 1)
            XCTAssertFalse(Provisioner.busyHostIDs.contains(f.host.id))
            coordinator.dismissWarning()
            await coordinator.checkNow()
            XCTAssertEqual(f.applications.count, 1, "Unknown remote state must not be blindly retried")
        }
    }

    func testMissingMalformedOrWrongConfirmationDoesNotCommit() async {
        let replies: [String?] = [nil, "", "not a URI",
            "olcrtc://telemost?vp8channel@wrong-room#test-key",
            "olcrtc://jitsi?vp8channel@222222#test-key",
            "olcrtc://telemost?videochannel@222222#test-key"]
        for reply in replies {
            let f = Fixture()
            f.reply = reply
            let original = f.record
            let coordinator = f.makeCoordinator()
            await coordinator.checkNow()
            XCTAssertEqual(f.record, original)
            XCTAssertEqual(coordinator.warning?.reason, .applyUnconfirmed)
        }
    }

    func testRecordIsNotCommittedBeforeConfirmationAndAgeStartsAtCreation() async {
        let f = Fixture()
        let original = f.record
        let createdAt = f.now
        let gate = Gate()
        f.onApply = { await gate.wait() }
        let coordinator = f.makeCoordinator()
        let task = Task { await coordinator.checkNow() }
        await fulfillment(of: [gate.entered], timeout: 1)
        XCTAssertEqual(f.record, original)
        XCTAssertTrue(f.updates.isEmpty)
        f.now = f.now.addingTimeInterval(300)
        gate.open()
        await task.value
        XCTAssertEqual(f.params.roomID, f.room.id)
        XCTAssertEqual(f.params.roomCreatedAt, createdAt)
    }

    // #485: a room match cannot confirm that the retained client key still works.
    func testConfirmationRejectsADifferentServerKey() {
        let f = Fixture(ageHours: 20)
        let uri = "olcrtc://\(f.params.carrier)?\(f.params.transport)@\(f.room.id)#"
            + String(repeating: "f", count: 64)
        XCTAssertFalse(TelemostRenewalCoordinator.confirms(
            uri: uri, roomID: f.room.id, params: f.params))
    }

    func testUnknownImportedAgeProducesActionableNoticeWithoutInventingStamp() async {
        let f = Fixture(ageHours: nil)
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.warning?.reason, .ageUnknown)
        XCTAssertEqual(coordinator.warning?.canRenew, true)
        XCTAssertNotEqual(coordinator.warning?.title, L10n.telemostExpiryTitle.localized())
        XCTAssertNil(f.params.roomCreatedAt)
        XCTAssertEqual(f.creations, 0)
        await coordinator.renewFromWarning()
        XCTAssertEqual(f.params.roomID, f.room.id)
        XCTAssertNotNil(f.params.roomCreatedAt)
    }

    func testMissingSetupIsExplainedForKnownAndUnknownAges() async {
        let ages: [Double?] = [nil, 20]
        for age in ages {
            let f = Fixture(ageHours: age)
            f.hasTarget = false
            let coordinator = f.makeCoordinator()
            await coordinator.checkNow()
            XCTAssertEqual(coordinator.warning?.reason, .setupRequired)
            XCTAssertEqual(coordinator.warning?.canRenew, false)
            XCTAssertEqual(f.creations, 0)
            XCTAssertEqual(f.claims, 0)
        }
    }

    func testLaterSurvivesRepeatedForegroundChecksButNewRoomCanWarn() async {
        let f = Fixture(ageHours: 23.5)
        f.engaged = f.record
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.warning?.reason, .expiring)
        coordinator.dismissWarning()
        for _ in 0..<4 {
            f.now = f.now.addingTimeInterval(60)
            await coordinator.checkNow()
            XCTAssertNil(coordinator.warning)
        }
        f.setRoom("another-room")
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.warning?.reason, .expiring)
        XCTAssertEqual(f.creations, 0)
    }

    func testDeletedOrExternallyRenewedRecordClearsStaleWarning() async {
        let f = Fixture(ageHours: 23.5)
        f.engaged = f.record
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertNotNil(coordinator.warning)
        f.setRoom("fresh-room", ageHours: 1)
        await coordinator.checkNow()
        XCTAssertNil(coordinator.warning)
        f.setRoom("old-again")
        await coordinator.checkNow()
        XCTAssertNotNil(coordinator.warning)
        f.records = []
        await coordinator.checkNow()
        XCTAssertNil(coordinator.warning)
    }

    func testManualRenewalBlocksDuplicateManualAndForegroundWorkWhileCreating() async {
        let f = Fixture(ageHours: 23.5)
        let gate = Gate()
        f.onCreate = { await gate.wait() }
        let coordinator = f.makeCoordinator()
        let task = Task { await coordinator.renew(recordID: f.record.id) }
        await fulfillment(of: [gate.entered], timeout: 1)
        XCTAssertTrue(Provisioner.busyHostIDs.contains(f.host.id))
        XCTAssertFalse(Provisioner.tryEnterHost(f.host.id), "ServersView must use this same atomic claim")
        await coordinator.checkNow()
        await coordinator.renew(recordID: f.record.id)
        XCTAssertNil(coordinator.warning)
        XCTAssertEqual(f.creations, 1)
        gate.open()
        await task.value
        XCTAssertEqual(f.applications.count, 1)
        XCTAssertEqual(f.releases, 1)
    }

    func testAutomaticRenewalBlocksManualWorkWhileApplying() async {
        let f = Fixture()
        let gate = Gate()
        f.onApply = { await gate.wait() }
        let coordinator = f.makeCoordinator()
        let task = Task { await coordinator.checkNow() }
        await fulfillment(of: [gate.entered], timeout: 1)
        await coordinator.renew(recordID: f.record.id)
        await coordinator.checkNow()
        XCTAssertEqual(f.creations, 1)
        XCTAssertEqual(f.applications.count, 1)
        XCTAssertFalse(Provisioner.tryEnterHost(f.host.id))
        gate.open()
        await task.value
        XCTAssertFalse(Provisioner.busyHostIDs.contains(f.host.id))
    }

    func testPreclaimedHostBlocksRenewalAndIsNotReleasedByNonOwner() async {
        let f = Fixture()
        XCTAssertTrue(Provisioner.tryEnterHost(f.host.id))
        defer { Provisioner.leaveHost(f.host.id) }
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertEqual(f.creations, 0)
        XCTAssertEqual(f.releases, 0)
        XCTAssertTrue(Provisioner.busyHostIDs.contains(f.host.id))
    }

    func testCreationFailureAndCancellationReleaseClaimWithoutSSH() async {
        let f = Fixture()
        f.onCreate = { throw Failure.unreachable }
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.warning?.reason, .creationFailed)
        XCTAssertEqual(f.releases, 1)
        XCTAssertTrue(f.applications.isEmpty)
        XCTAssertFalse(Provisioner.busyHostIDs.contains(f.host.id))

        let cancelled = Fixture()
        let gate = Gate()
        cancelled.onCreate = { await gate.wait() }
        let other = cancelled.makeCoordinator()
        let task = Task { await other.checkNow() }
        await fulfillment(of: [gate.entered], timeout: 1)
        task.cancel()
        gate.open()
        await task.value
        XCTAssertTrue(cancelled.applications.isEmpty)
        XCTAssertEqual(cancelled.releases, 1)
        XCTAssertFalse(Provisioner.busyHostIDs.contains(cancelled.host.id))
    }

    func testSavedSiblingCannotTriggerADestructiveAutomaticSwitch() async {
        let f = Fixture(ageHours: 23.5)
        f.engaged = f.record
        f.connectedProxy = true
        f.activity = f.now
        let sibling = ConnectionRecord(name: "Unverified sibling",
            details: .olcrtc(.init(carrier: "jitsi", transport: "videochannel",
                roomID: "sibling-room", key: "test-key", clientID: "default")))
        f.records.append(sibling)
        f.host.extraConnectionIDs = [sibling.id]
        let coordinator = f.makeCoordinator()
        XCTAssertNil(coordinator.input(for: f.record, now: f.now).alternativeRecordID)
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.warning?.reason, .expiring)
        XCTAssertTrue(f.connects.isEmpty)
        XCTAssertEqual(f.disconnects, 0)
        XCTAssertEqual(f.creations, 0)
    }

    func testVPNActivityIsNeverInterpretedAsProxyIdleness() async {
        let observations: [Date?] = [nil, Date(timeIntervalSince1970: 1_799_000_000)]
        for activity in observations {
            let f = Fixture()
            f.engaged = f.record
            f.connectedProxy = false
            f.activity = activity
            let coordinator = f.makeCoordinator()
            let input = coordinator.input(for: f.record, now: f.now)
            XCTAssertFalse(TelemostRenewalPolicy.isIdle(input))
            XCTAssertEqual(TelemostRenewalPolicy.decide(input), .waitForIdle)
            await coordinator.checkNow()
            XCTAssertEqual(f.creations, 0)
        }
    }

    func testNilProxyActivityIsUnknownButMeasuredIdleProxyCanRenew() async {
        let f = Fixture()
        f.engaged = f.record
        f.connectedProxy = true
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertEqual(f.creations, 0)
        f.activity = f.now.addingTimeInterval(-TelemostRenewalPolicy.idleGrace)
        await coordinator.checkNow()
        XCTAssertEqual(f.creations, 1)
        XCTAssertEqual(f.disconnects, 1)
        XCTAssertEqual(f.connects, [f.record])
    }

    func testForeignVPNBlocksManualAndAutomaticWork() async {
        let f = Fixture()
        f.foreignVPN = true
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.warning?.reason, .foreignVPN)
        await coordinator.renew(recordID: f.record.id)
        XCTAssertEqual(f.creations, 0)
        XCTAssertEqual(f.claims, 0)
        XCTAssertEqual(f.disconnects, 0)
    }

    func testNewForeignVPNOrNewDialDuringCreationPreventsSSH() async {
        for foreignVPN in [true, false] {
            let f = Fixture()
            f.onCreate = {
                if foreignVPN { f.foreignVPN = true }
                else { f.engaged = f.record; f.connectedProxy = false }
            }
            let coordinator = f.makeCoordinator()
            await coordinator.checkNow()
            XCTAssertEqual(f.creations, 1)
            XCTAssertTrue(f.applications.isEmpty)
            XCTAssertTrue(f.updates.isEmpty)
            XCTAssertEqual(f.releases, 1)
        }
    }

    func testForeignVPNAppearingDuringSSHDoesNotTearDownEstablishedSession() async {
        let f = Fixture()
        f.engaged = f.record
        f.onApply = { f.foreignVPN = true }
        let coordinator = f.makeCoordinator()
        await coordinator.renew(recordID: f.record.id)
        XCTAssertEqual(f.params.roomID, f.room.id, "Confirmed server state still must be saved")
        XCTAssertEqual(f.disconnects, 0)
        XCTAssertTrue(f.connects.isEmpty)
        XCTAssertEqual(coordinator.warning?.reason, .foreignVPN)
    }

    func testUserDisconnectOrSwitchDuringSSHIsNotUndone() async {
        for switches in [false, true] {
            let f = Fixture()
            f.engaged = f.record
            let sibling = ConnectionRecord(name: "User's choice",
                details: .olcrtc(.init(carrier: "jitsi", transport: "vp8channel",
                    roomID: "sibling", key: "test-key", clientID: "default")))
            f.onApply = { f.engaged = switches ? sibling : nil }
            let coordinator = f.makeCoordinator()
            await coordinator.renew(recordID: f.record.id)
            XCTAssertEqual(f.params.roomID, f.room.id)
            XCTAssertEqual(f.disconnects, 0)
            XCTAssertTrue(f.connects.isEmpty)
        }
    }

    func testEditDuringCreationPreventsApplyAndEditDuringSSHIsNotOverwritten() async {
        let before = Fixture()
        before.onCreate = { before.setRoom("user-edit") }
        await before.makeCoordinator().checkNow()
        XCTAssertTrue(before.applications.isEmpty)
        XCTAssertEqual(before.params.roomID, "user-edit")
        XCTAssertEqual(before.releases, 1)

        let during = Fixture()
        during.onApply = { during.setRoom("user-edit") }
        let coordinator = during.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertTrue(during.updates.isEmpty)
        XCTAssertEqual(during.params.roomID, "user-edit")
        XCTAssertEqual(coordinator.warning?.reason, .applyUnconfirmed)
        XCTAssertEqual(during.releases, 1)
    }

    func testStoredAccountPresentationIsNeverGreenValidityEvidence() {
        XCTAssertEqual(TelemostRoomSheet.accountTone(hasAccount: true), .unknown)
        XCTAssertEqual(TelemostRoomSheet.accountTone(hasAccount: false), .unknown)
        XCTAssertEqual(TelemostRoomSheet.accountTitle(hasAccount: true), L10n.telemostSignInSaved.localized())
        XCTAssertEqual(TelemostRoomSheet.accountTitle(hasAccount: false),
                       L10n.telemostRoomNoAccountTitle.localized())
    }

    func testUnconfirmedCandidateSurvivesCoordinatorRecreationWithoutSecretMaterial() async throws {
        let f = Fixture()
        f.onApply = { throw Failure.restartDrop }
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        let pending = try XCTUnwrap(coordinator.pendingRenewals[f.record.id])
        XCTAssertEqual(pending.previousRoomID, "111111")
        XCTAssertEqual(pending.candidateRoomID, f.room.id)
        XCTAssertEqual(coordinator.warning?.candidateRoomID, f.room.id)
        XCTAssertTrue(coordinator.warning?.message.contains(f.room.id) == true)
        let data = try JSONEncoder().encode(f.savedPending)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("test-key"))
        XCTAssertFalse(encoded.contains("test-only"))
        XCTAssertEqual(try JSONDecoder().decode(
            [UUID: TelemostRenewalCoordinator.PendingRenewal].self, from: data), f.savedPending)

        let relaunched = f.makeCoordinator()
        await relaunched.checkNow()
        XCTAssertEqual(f.applications.count, 1, "Relaunch must not retry ambiguous SSH")
        XCTAssertEqual(relaunched.warning?.candidateRoomID, f.room.id)
        relaunched.dismissWarning()
        f.now = f.now.addingTimeInterval(24 * 3600)
        await relaunched.checkNow()
        XCTAssertEqual(f.applications.count, 1, "Expiry must not erase recovery evidence")
        XCTAssertNotNil(relaunched.pendingRenewals[f.record.id])
    }

    func testConfirmedRetryClearsPendingButFailedRetryDoesNot() async {
        let f = Fixture()
        f.onApply = { throw Failure.authentication }
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertNotNil(f.savedPending[f.record.id])
        f.onApply = {}
        await coordinator.renew(recordID: f.record.id)
        XCTAssertTrue(f.savedPending.isEmpty)
        XCTAssertTrue(coordinator.pendingRenewals.isEmpty)
        XCTAssertEqual(f.params.roomID, f.room.id)
    }

    func testUnknownAgeWithoutSessionOffersSetupInsteadOfImpossibleRenewal() async {
        let f = Fixture(ageHours: nil)
        f.hasSession = false
        let coordinator = f.makeCoordinator()
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.warning?.reason, .setupRequired)
        XCTAssertEqual(coordinator.warning?.canRenew, false)
        coordinator.dismissWarning()
        await coordinator.checkNow()
        XCTAssertNil(coordinator.warning)
        XCTAssertEqual(f.creations, 0)
    }

    func testCancellationAfterConfirmedSSHStopsStaleRecoveryWithoutStartingNetwork() async {
        let f = Fixture()
        f.engaged = f.record
        let gate = Gate()
        f.onApply = { await gate.wait() }
        let coordinator = f.makeCoordinator()
        let task = Task { await coordinator.renew(recordID: f.record.id) }
        await fulfillment(of: [gate.entered], timeout: 1)
        XCTAssertNotNil(f.savedPending[f.record.id], "Recovery evidence must precede SSH confirmation")
        task.cancel()
        gate.open()
        await task.value
        XCTAssertEqual(f.params.roomID, f.room.id)
        XCTAssertEqual(f.disconnects, 1)
        XCTAssertTrue(f.connects.isEmpty)
        XCTAssertTrue(f.savedPending.isEmpty)
        XCTAssertEqual(coordinator.warning?.reason, .reconnectRequired)
        XCTAssertFalse(Provisioner.busyHostIDs.contains(f.host.id))
    }
}
// eoc #480
