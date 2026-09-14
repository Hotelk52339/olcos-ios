import XCTest
@testable import olcrtc_ios

// boc #490: pure presentation decisions only. No store, Keychain, preferences,
// clocks, SSH, network, tunnel mutation or UIKit feedback is exercised here.
final class SignalServers490Tests: XCTestCase {
    func testManagementRouteUsesLatestHostWithTheSameIdentity() {
        let snapshot = ServerHost(label: "Before edit", host: "old.example")
        var current = snapshot
        current.label = "After edit"
        current.host = "new.example"
        current.port = 2222
        current.username = "operator"
        current.authMethod = .privateKey
        current.lastContainerName = "adopted-container"
        current.lastConnectionID = UUID()
        current.extraConnectionIDs = [UUID()]
        let result = ServerPresentationPolicy.currentHost(snapshot: snapshot, hosts: [current])
        XCTAssertEqual(result, current, "every field must refresh, not only the displayed name")
        XCTAssertNotEqual(result, snapshot)
    }

    func testEqualDisplayNamesNeverSelectADifferentHost() {
        let snapshot = ServerHost(label: "Shared label", host: "first.example")
        let other = ServerHost(label: snapshot.label, host: snapshot.host)
        var current = snapshot
        current.port = 2200
        XCTAssertEqual(ServerPresentationPolicy.currentHost(snapshot: snapshot, hosts: [other, current]), current)
        XCTAssertNotEqual(other.id, current.id)
    }

    func testMissingRouteKeepsItsOwnIdentityUntilNavigationDismisses() {
        let snapshot = ServerHost(label: "Removed", host: "removed.example")
        let other = ServerHost(label: "Other", host: "other.example")
        XCTAssertEqual(ServerPresentationPolicy.currentHost(snapshot: snapshot, hosts: []), snapshot)
        XCTAssertEqual(ServerPresentationPolicy.currentHost(snapshot: snapshot, hosts: [other]), snapshot)
    }

    func testSuccessWithNoProtocolsIsNotAnUnreadList() {
        XCTAssertEqual(ServerProtocolListing.resolve(hasContainer: true, isLoading: false, hasRead: true), .loaded)
        XCTAssertEqual(ServerProtocolListing.resolve(hasContainer: false, isLoading: false, hasRead: true), .loaded)
        XCTAssertEqual(ServerProtocolListing.resolve(hasContainer: true, isLoading: false, hasRead: false), .unread)
        XCTAssertEqual(ServerProtocolListing.resolve(hasContainer: false, isLoading: false, hasRead: false), .absent)
    }

    func testOnlyAnActualReadInFlightPresentsLoading() {
        for container in [false, true] {
            for hasRead in [false, true] {
                XCTAssertEqual(ServerProtocolListing.resolve(hasContainer: container, isLoading: true,
                                                               hasRead: hasRead), .loading)
            }
        }
    }

    func testReadCompletionCannotInventAHealthVerdict() {
        // A failed read returns to unread; a successful read is only a loaded
        // listing. Neither outcome creates a verified tunnel-health verdict.
        XCTAssertEqual(ServerProtocolListing.resolve(hasContainer: true, isLoading: false, hasRead: false), .unread)
        XCTAssertEqual(ServerProtocolListing.resolve(hasContainer: true, isLoading: false, hasRead: true), .loaded)
    }

    func testSelectionRejectsDisabledAndUnchangedValuesWithoutNormalizingImports() {
        XCTAssertFalse(ServerPresentationPolicy.allowsSelectionChange(
            current: "imported-disabled", proposed: "imported-disabled", isDisabled: true))
        XCTAssertFalse(ServerPresentationPolicy.allowsSelectionChange(
            current: "supported", proposed: "unsupported", isDisabled: true))
        XCTAssertFalse(ServerPresentationPolicy.allowsSelectionChange(
            current: "supported", proposed: "supported", isDisabled: false))
        XCTAssertTrue(ServerPresentationPolicy.allowsSelectionChange(
            current: "imported-disabled", proposed: "supported", isDisabled: false))
    }

    func testReducedMotionRemovesTransitionAndNormalMotionIsShort() {
        XCTAssertEqual(ServerPresentationPolicy.transitionDuration(reduceMotion: true), 0)
        let duration = ServerPresentationPolicy.transitionDuration(reduceMotion: false)
        XCTAssertGreaterThan(duration, 0)
        XCTAssertLessThanOrEqual(duration, 0.2)
    }
}
// eoc #490
