import XCTest
@testable import uTerm

@MainActor
final class TabModelTests: XCTestCase {
    private func makeTab() -> TabModel {
        let server = UUID()
        return TabModel(title: "t", rootServerProfileID: server)
    }

    func testInitialTabHasOneFocusedPane() {
        let tab = makeTab()
        XCTAssertEqual(tab.root.leafIDs.count, 1)
        XCTAssertEqual(tab.focusedPaneID, tab.root.leafIDs.first)
        XCTAssertEqual(tab.panes.count, 1)
    }

    func testSplitFocusedPaneAddsAPane() {
        let tab = makeTab()
        let original = tab.focusedPaneID!
        tab.splitFocusedPane(direction: .vertical)
        XCTAssertEqual(tab.root.leafIDs.count, 2)
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertNotEqual(tab.focusedPaneID, original)
        let newPane = tab.panes[tab.focusedPaneID!]!
        XCTAssertEqual(newPane.serverProfileID, tab.panes[original]!.serverProfileID)
    }

    func testSplitPaneAddsPaneConnectedToGivenServer() {
        let tab = makeTab()
        let target = tab.focusedPaneID!
        let serverID = UUID()
        tab.splitPane(target, direction: .horizontal, serverProfileID: serverID)
        XCTAssertEqual(tab.root.leafIDs.count, 2)
        XCTAssertEqual(tab.panes.count, 2)
        let newPane = tab.panes[tab.focusedPaneID!]!
        XCTAssertEqual(newPane.serverProfileID, serverID)
        XCTAssertNotEqual(tab.focusedPaneID, target)
    }

    func testClosePaneRemovesItAndReturnsTrueWhenTabSurvives() {
        let tab = makeTab()
        let first = tab.focusedPaneID!
        tab.splitFocusedPane(direction: .horizontal)
        let stillOpen = tab.closePane(first)
        XCTAssertTrue(stillOpen)
        XCTAssertEqual(tab.root.leafIDs.count, 1)
        XCTAssertNil(tab.panes[first])
        XCTAssertEqual(tab.focusedPaneID, tab.root.leafIDs.first)
    }

    func testClosingLastPaneReturnsFalse() {
        let tab = makeTab()
        let only = tab.focusedPaneID!
        XCTAssertFalse(tab.closePane(only))
    }

    func testSetFraction() {
        let tab = makeTab()
        tab.splitFocusedPane(direction: .horizontal)
        guard case .split(let s) = tab.root else { return XCTFail("应为 split") }
        tab.setFraction(0.25, splitID: s.id)
        guard case .split(let s2) = tab.root else { return XCTFail("应为 split") }
        XCTAssertEqual(s2.fraction, 0.25, accuracy: 0.0001)
    }
}
