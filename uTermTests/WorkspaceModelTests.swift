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

    // MARK: ownership + UI state（Spec 1 §3.1）

    func testHasFileBrowserAndAssistantModels() {
        let ws = WorkspaceModel()
        _ = ws.fileBrowserModel  // 存在即过
        _ = ws.assistantModel
    }

    func testDefaultUIState() {
        let ws = WorkspaceModel()
        XCTAssertEqual(ws.uiState.leftSidebarVisibility, .all)
        XCTAssertTrue(ws.uiState.rightInspectorPresented)
        XCTAssertEqual(ws.uiState.previewTerminalRatio, 0.667, accuracy: 0.001)
    }

    func testSnapshotIncludesUIState() {
        let ws = WorkspaceModel()
        ws.uiState.rightInspectorPresented = false
        let snap = ws.snapshot()
        XCTAssertEqual(snap.uiState?.rightInspectorPresented, false)
    }

    func testInitFromSnapshotRestoresUIState() {
        var ui = WorkspaceUIState()
        ui.previewTerminalRatio = 0.4
        let snap = WorkspaceSnapshot(tabs: [], activeTabIndex: nil, uiState: ui)
        let ws = WorkspaceModel(snapshot: snap)
        XCTAssertEqual(ws.uiState.previewTerminalRatio, 0.4, accuracy: 0.0001)
    }

    func testInitFromSnapshotWithoutUIStateUsesDefault() {
        let snap = WorkspaceSnapshot(tabs: [], activeTabIndex: nil, uiState: nil)
        let ws = WorkspaceModel(snapshot: snap)
        XCTAssertEqual(ws.uiState.leftSidebarVisibility, .all)
        XCTAssertTrue(ws.uiState.rightInspectorPresented)
    }

    // MARK: toggle / focus helpers（Spec 1 §3.1）

    func testToggleLeftSidebarFlipsVisibility() {
        let ws = WorkspaceModel()
        XCTAssertEqual(ws.uiState.leftSidebarVisibility, .all)
        ws.toggleLeftSidebar()
        XCTAssertEqual(ws.uiState.leftSidebarVisibility, .detailOnly)
        ws.toggleLeftSidebar()
        XCTAssertEqual(ws.uiState.leftSidebarVisibility, .all)
    }

    /// Fix #5：NavigationSplitView 可能把 binding 写成 `.doubleColumn`
    /// 或 `.automatic`，旧实现遇到这两种状态会一直翻到 `.all`，
    /// 失去「按一下隐藏」的语义。新实现把任何非 `.detailOnly` 都视作
    /// 「可隐藏」状态，按一下进入 `.detailOnly`。
    func testToggleLeftSidebarHidesFromAnyVisibleState() {
        let ws = WorkspaceModel()
        ws.uiState.leftSidebarVisibility = .doubleColumn
        ws.toggleLeftSidebar()
        XCTAssertEqual(ws.uiState.leftSidebarVisibility, .detailOnly)

        ws.uiState.leftSidebarVisibility = .automatic
        ws.toggleLeftSidebar()
        XCTAssertEqual(ws.uiState.leftSidebarVisibility, .detailOnly)
    }

    func testToggleRightInspectorFlips() {
        let ws = WorkspaceModel()
        XCTAssertTrue(ws.uiState.rightInspectorPresented)
        ws.toggleRightInspector()
        XCTAssertFalse(ws.uiState.rightInspectorPresented)
        ws.toggleRightInspector()
        XCTAssertTrue(ws.uiState.rightInspectorPresented)
    }

    func testFocusedTerminalSessionNilWhenNoTab() {
        let ws = WorkspaceModel()
        XCTAssertNil(ws.focusedTerminalSession())
    }

    func testFocusedTerminalSessionReturnsSessionForFocusedPane() {
        let ws = WorkspaceModel()
        ws.openServer(profileID: UUID(), title: "x")
        XCTAssertNotNil(ws.focusedTerminalSession())
    }

    // MARK: restore(from:) & dispose（Fix #1 / #8）

    /// Fix #1：restore 必须在**同一个** WorkspaceModel 实例上 mutate，
    /// 不能创建新实例 —— 否则 SFTPSidebar 等持有的 fileBrowserModel 引用
    /// 失效，配合 `.task(id:)` 不重启的语义会导致永远不连接。
    func testRestoreMutatesInPlace() {
        let ws = WorkspaceModel()
        let originalFileModel = ws.fileBrowserModel
        let originalAssistant = ws.assistantModel
        var ui = WorkspaceUIState()
        ui.previewTerminalRatio = 0.5
        let snap = WorkspaceSnapshot(tabs: [], activeTabIndex: nil, uiState: ui)
        ws.restore(from: snap)
        XCTAssertTrue(ws.fileBrowserModel === originalFileModel,
                      "restore 后 fileBrowserModel 必须是同一个实例")
        XCTAssertTrue(ws.assistantModel === originalAssistant,
                      "restore 后 assistantModel 必须是同一个实例")
        XCTAssertEqual(ws.uiState.previewTerminalRatio, 0.5, accuracy: 0.0001)
    }

    func testRestoreClearsExistingTabsAndLoadsNew() {
        let ws = WorkspaceModel()
        ws.openServer(profileID: UUID(), title: "old1")
        ws.openServer(profileID: UUID(), title: "old2")
        XCTAssertEqual(ws.tabs.count, 2)

        let restoredServer = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [TabSnapshot(title: "restored",
                               layout: .leaf(serverProfileID: restoredServer))],
            activeTabIndex: 0, uiState: nil)
        ws.restore(from: snap)
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.tabs[0].title, "restored")
    }

    func testConvenienceInitFromSnapshotGoesThroughRestore() {
        let id = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [TabSnapshot(title: "x", layout: .leaf(serverProfileID: id))],
            activeTabIndex: 0, uiState: nil)
        let ws = WorkspaceModel(snapshot: snap)
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.activeTabID, ws.tabs[0].id)
    }

    /// Fix #8：dispose 必须清理所有 tab 的窗格 + 左 sidebar 的 SFTP 会话。
    /// 这里用 tabs.count 间接验证（disposeAll 不影响 count，但调用是否完成）；
    /// FileBrowserModel/PaneModel 的真实 close 在自己的单测里覆盖。
    func testDisposeDoesNotCrash() {
        let ws = WorkspaceModel()
        ws.openServer(profileID: UUID(), title: "a")
        ws.openServer(profileID: UUID(), title: "b")
        ws.dispose()  // 不应抛错
    }
}
