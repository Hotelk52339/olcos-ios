import XCTest
@testable import olcrtc_ios

// boc #482: C4. Per-test UUID namespaces leave every real container untouched.
@MainActor
final class Review482LogsTests: XCTestCase {
    func testClearingSelectedContainerLeavesSiblingAndDropsSelectedPeerCount() {
        let store = LogStore.shared
        let prefix = "review482-" + UUID().uuidString
        let selected = LogStore.containerKey(prefix: prefix, container: "primary")
        let sibling = LogStore.containerKey(prefix: prefix, container: "telemost")
        let savedLevel = SettingsStore.shared.logLevel
        SettingsStore.shared.logLevel = .verbose
        defer {
            store.clearContainer(serverPrefix: selected)
            store.clearContainer(serverPrefix: sibling)
            SettingsStore.shared.logLevel = savedLevel
            SettingsStore.flushPendingWrites()
        }
        store.logContainer(serverPrefix: selected, "Current peers count: 2")
        store.logContainer(serverPrefix: sibling, "Current peers count: 3")
        XCTAssertEqual(store.peerCounts[selected], 2)
        XCTAssertEqual(store.peerCounts[sibling], 3)
        store.clearContainer(serverPrefix: selected)
        XCTAssertTrue(store.containerEntries[selected]?.isEmpty == true)
        XCTAssertNil(store.peerCounts[selected])
        XCTAssertEqual(store.containerEntries[sibling]?.count, 1)
        XCTAssertEqual(store.peerCounts[sibling], 3)
    }

    func testClearActionUsesTheSameSelectedKeyAsTheDisplayedBuffer() throws {
        // SwiftUI interaction itself is integration-only. This wiring assertion
        // pins the exact regression that a LogStore-only test cannot detect.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("App/Views/LogsView.swift"))
        XCTAssertTrue(text.contains("clearContainer(serverPrefix: selectedContainerKey(host))"))
        XCTAssertTrue(text.contains("store.containerEntries[selectedContainerKey(host)]"))
    }
}
// eoc #482
