import UPaneTree
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

    func testMovePaneToLeadingPutsSourceFirst() {
        let tab = makeTab()
        let p1 = tab.focusedPaneID!
        tab.splitPane(p1, direction: .vertical, serverProfileID: UUID())
        let p2 = tab.focusedPaneID!
        tab.movePane(p2, toTarget: p1, zone: .leading)
        guard case .split(let s) = tab.root else { return XCTFail("应为 split") }
        XCTAssertEqual(s.direction, .horizontal)
        XCTAssertEqual(s.first, .leaf(paneID: p2))
        XCTAssertEqual(s.second, .leaf(paneID: p1))
        XCTAssertEqual(tab.focusedPaneID, p2)
    }

    func testMovePaneToBottomPutsSourceSecond() {
        let tab = makeTab()
        let p1 = tab.focusedPaneID!
        tab.splitPane(p1, direction: .horizontal, serverProfileID: UUID())
        let p2 = tab.focusedPaneID!
        tab.movePane(p2, toTarget: p1, zone: .bottom)
        guard case .split(let s) = tab.root else { return XCTFail("应为 split") }
        XCTAssertEqual(s.direction, .vertical)
        XCTAssertEqual(s.first, .leaf(paneID: p1))
        XCTAssertEqual(s.second, .leaf(paneID: p2))
    }

    func testMovePaneKeepsAllPanesAndCollapsesSourceOldSplit() {
        let tab = makeTab()
        let p1 = tab.focusedPaneID!
        tab.splitPane(p1, direction: .horizontal, serverProfileID: UUID())
        let p2 = tab.focusedPaneID!
        tab.splitPane(p2, direction: .horizontal, serverProfileID: UUID())
        let p3 = tab.focusedPaneID!
        tab.movePane(p3, toTarget: p1, zone: .top)
        XCTAssertEqual(Set(tab.root.leafIDs), [p1, p2, p3])
        XCTAssertEqual(tab.root.leafIDs.count, 3)
        XCTAssertEqual(tab.panes.count, 3)
        XCTAssertEqual(tab.focusedPaneID, p3)
    }

    func testMovePaneCenterZoneIsNoOp() {
        let tab = makeTab()
        let p1 = tab.focusedPaneID!
        tab.splitPane(p1, direction: .horizontal, serverProfileID: UUID())
        let p2 = tab.focusedPaneID!
        let before = tab.root
        tab.movePane(p2, toTarget: p1, zone: .center)
        XCTAssertEqual(tab.root, before)
    }

    func testMovePaneToSelfIsNoOp() {
        let tab = makeTab()
        let p1 = tab.focusedPaneID!
        tab.splitPane(p1, direction: .horizontal, serverProfileID: UUID())
        let before = tab.root
        tab.movePane(p1, toTarget: p1, zone: .top)
        XCTAssertEqual(tab.root, before)
    }

    func testSwapPanesExchangesPositions() {
        let tab = makeTab()
        let p1 = tab.focusedPaneID!
        tab.splitPane(p1, direction: .horizontal, serverProfileID: UUID())
        let p2 = tab.focusedPaneID!
        tab.swapPanes(p1, p2)
        guard case .split(let s) = tab.root else { return XCTFail("应为 split") }
        XCTAssertEqual(s.first, .leaf(paneID: p2))
        XCTAssertEqual(s.second, .leaf(paneID: p1))
    }

    func testSwapPanesUnknownIDIsNoOp() {
        let tab = makeTab()
        let p1 = tab.focusedPaneID!
        tab.splitPane(p1, direction: .horizontal, serverProfileID: UUID())
        let before = tab.root
        tab.swapPanes(p1, UUID())
        XCTAssertEqual(tab.root, before)
    }

    func testMoveThenSwapKeepsPanesAndFocusInvariants() {
        let tab = makeTab()
        let p1 = tab.focusedPaneID!
        tab.splitPane(p1, direction: .horizontal, serverProfileID: UUID())
        let p2 = tab.focusedPaneID!
        tab.splitPane(p2, direction: .vertical, serverProfileID: UUID())
        let p3 = tab.focusedPaneID!
        tab.movePane(p1, toTarget: p3, zone: .trailing)
        XCTAssertEqual(tab.focusedPaneID, p1)            // movePane 聚焦被移动窗格
        tab.swapPanes(p2, p3)
        XCTAssertEqual(tab.focusedPaneID, p1)            // swapPanes 不改聚焦
        XCTAssertEqual(Set(tab.root.leafIDs), [p1, p2, p3])
        XCTAssertEqual(tab.panes.count, 3)
    }
}
