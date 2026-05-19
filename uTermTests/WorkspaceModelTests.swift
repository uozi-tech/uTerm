import XCTest
@testable import uTerm

@MainActor
final class WorkspaceModelTests: XCTestCase {
    func testOpenServerAddsActiveTab() {
        let ws = WorkspaceModel()
        let server = UUID()
        let tab = ws.openServer(profileID: server, title: "s1")
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.activeTabID, tab.id)
        XCTAssertEqual(tab.panes.values.first?.serverProfileID, server)
    }

    func testCloseTabSelectsNeighbor() {
        let ws = WorkspaceModel()
        let t1 = ws.openServer(profileID: UUID(), title: "a")
        let t2 = ws.openServer(profileID: UUID(), title: "b")
        ws.closeTab(t2.id)
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.activeTabID, t1.id)
    }

    func testCloseLastTabClearsActive() {
        let ws = WorkspaceModel()
        let t = ws.openServer(profileID: UUID(), title: "a")
        ws.closeTab(t.id)
        XCTAssertTrue(ws.tabs.isEmpty)
        XCTAssertNil(ws.activeTabID)
    }

    func testMoveTabReorders() {
        let ws = WorkspaceModel()
        let t1 = ws.openServer(profileID: UUID(), title: "a")
        let t2 = ws.openServer(profileID: UUID(), title: "b")
        ws.moveTab(fromID: t1.id, toIndex: 1)
        XCTAssertEqual(ws.tabs.map(\.id), [t2.id, t1.id])
    }

    func testMoveTabBackward() {
        let ws = WorkspaceModel()
        let t1 = ws.openServer(profileID: UUID(), title: "a")
        let t2 = ws.openServer(profileID: UUID(), title: "b")
        let t3 = ws.openServer(profileID: UUID(), title: "c")
        ws.moveTab(fromID: t3.id, toIndex: 0)
        XCTAssertEqual(ws.tabs.map(\.id), [t3.id, t1.id, t2.id])
    }

    func testSnapshotRoundTrip() {
        let ws = WorkspaceModel()
        let s1 = UUID(), s2 = UUID()
        let t1 = ws.openServer(profileID: s1, title: "a")
        t1.splitFocusedPane(direction: .vertical)
        _ = ws.openServer(profileID: s2, title: "b")

        let snapshot = ws.snapshot()
        let restored = WorkspaceModel(snapshot: snapshot)
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.tabs[0].root.leafIDs.count, 2)
        XCTAssertEqual(restored.tabs[0].title, "a")
        let restoredServers = restored.tabs[0].panes.values.map(\.serverProfileID)
        XCTAssertEqual(Set(restoredServers), [s1])
    }
}
