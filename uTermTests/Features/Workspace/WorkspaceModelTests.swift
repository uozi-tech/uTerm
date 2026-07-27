import XCTest
import SwiftData
@testable import uTerm

@MainActor
final class WorkspaceModelTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ServerProfile.self, configurations: config)
        return ModelContext(container)
    }

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

    func testConnectSharedSFTPStartsFileBrowserConnectionForTelemetryOnWorkspaceOpen() async throws {
        let context = try makeContext()
        let server = ServerProfile()
        server.name = "s1"
        server.host = "127.0.0.1"
        server.username = "root"
        context.insert(server)
        try context.save()

        let mock = MockSFTP(tree: ["/home/user": []])
        var connectCount = 0
        let browser = FileBrowserModel(sftpConnector: { _, _, _ in
            connectCount += 1
            return mock
        })
        let ws = WorkspaceModel(fileBrowserModel: browser)

        await ws.connectSharedSFTP(profile: server, modelContainer: context.container)

        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(ws.fileBrowserModel.state, .browsing)
        XCTAssertNotNil(ws.fileBrowserModel.sftpProvider)
    }

    func testAutosaveStructureSnapshotIgnoresDraftButFullSnapshotKeepsIt() {
        let ws = WorkspaceModel()
        ws.assistantModel.input = "first draft"
        let firstStructure = ws.autosaveStructureSnapshot()

        ws.assistantModel.input = "second draft"
        let secondStructure = ws.autosaveStructureSnapshot()

        XCTAssertEqual(firstStructure, secondStructure)
        XCTAssertEqual(ws.snapshot().agentState?.input, "second draft")
    }

    func testDropTabOntoActivePaneSplitsAndClosesSourceTab() {
        let ws = WorkspaceModel()
        let targetServer = UUID()
        let sourceServer = UUID()
        let targetTab = ws.openServer(profileID: targetServer, title: "target")
        let sourceTab = ws.openServer(profileID: sourceServer, title: "source")
        ws.selectTab(targetTab.id)

        guard let targetPaneID = targetTab.focusedPaneID else {
            XCTFail("target tab should have a focused pane")
            return
        }

        XCTAssertTrue(ws.dropTab(sourceTab.id, onto: targetPaneID, zone: .trailing))
        XCTAssertEqual(ws.tabs.map(\.id), [targetTab.id])
        XCTAssertEqual(ws.activeTabID, targetTab.id)
        XCTAssertEqual(targetTab.root.leafIDs.count, 2)
        XCTAssertEqual(Set(targetTab.panes.values.map(\.serverProfileID)),
                       [targetServer, sourceServer])
    }

    func testDropActiveTabOntoItsPaneCopiesFocusedPane() {
        let ws = WorkspaceModel()
        let server = UUID()
        let tab = ws.openServer(profileID: server, title: "target")

        guard let targetPaneID = tab.focusedPaneID else {
            XCTFail("tab should have a focused pane")
            return
        }

        XCTAssertTrue(ws.dropTab(tab.id, onto: targetPaneID, zone: .trailing))
        XCTAssertEqual(ws.tabs.map(\.id), [tab.id])
        XCTAssertEqual(ws.activeTabID, tab.id)
        XCTAssertEqual(tab.root.leafIDs.count, 2)
        XCTAssertEqual(tab.panes.values.filter { $0.serverProfileID == server }.count, 2)
    }

    func testDropRegisteredTabDragSourceSplitsAndClosesSourceTab() {
        let ws = WorkspaceModel()
        let targetServer = UUID()
        let sourceServer = UUID()
        let targetTab = ws.openServer(profileID: targetServer, title: "target")
        let sourceTab = ws.openServer(profileID: sourceServer, title: "source")
        ws.selectTab(targetTab.id)

        guard let targetPaneID = targetTab.focusedPaneID else {
            XCTFail("target tab should have a focused pane")
            return
        }

        ws.beginDrag(.tab(sourceTab.id))
        XCTAssertTrue(ws.dropDragSource(onto: targetPaneID, zone: .trailing))
        XCTAssertNil(ws.dragSource)
        XCTAssertEqual(ws.tabs.map(\.id), [targetTab.id])
        XCTAssertEqual(targetTab.root.leafIDs.count, 2)
        XCTAssertEqual(Set(targetTab.panes.values.map(\.serverProfileID)),
                       [targetServer, sourceServer])
    }

    func testDropRegisteredActiveTabDragSourceCopiesFocusedPane() {
        let ws = WorkspaceModel()
        let server = UUID()
        let tab = ws.openServer(profileID: server, title: "target")

        guard let targetPaneID = tab.focusedPaneID else {
            XCTFail("target tab should have a focused pane")
            return
        }

        ws.beginDrag(.tab(tab.id))
        XCTAssertTrue(ws.dropDragSource(onto: targetPaneID, zone: .trailing))
        XCTAssertNil(ws.dragSource)
        XCTAssertEqual(ws.tabs.map(\.id), [tab.id])
        XCTAssertEqual(tab.root.leafIDs.count, 2)
        XCTAssertEqual(tab.panes.values.filter { $0.serverProfileID == server }.count, 2)
    }

    func testDropRegisteredFileBufferDragSourceCreatesFilePane() async {
        let ws = WorkspaceModel()
        let server = UUID()
        let tab = ws.openServer(profileID: server, title: "target")
        await ws.filePreviewModel.open(path: "/tmp/readme.md", fileSize: 0, mtime: nil)

        guard let targetPaneID = tab.focusedPaneID,
              let buffer = ws.filePreviewModel.buffers.first else {
            XCTFail("workspace should have a focused pane and a preview buffer")
            return
        }

        ws.beginDrag(.fileBuffer(buffer.id))
        XCTAssertTrue(ws.dropDragSource(onto: targetPaneID, zone: .bottom))
        XCTAssertNil(ws.dragSource)
        XCTAssertEqual(tab.root.leafIDs.count, 2)
        XCTAssertEqual(tab.panes.values.filter { $0.fileBuffer?.id == buffer.id }.count, 1)
    }

    func testDropRegisteredFileBufferDragSourceOntoFocusedPaneCreatesFilePane() async {
        let ws = WorkspaceModel()
        let server = UUID()
        let tab = ws.openServer(profileID: server, title: "target")
        await ws.filePreviewModel.open(path: "/tmp/readme.md", fileSize: 0, mtime: nil)

        guard let buffer = ws.filePreviewModel.buffers.first else {
            XCTFail("workspace should have a preview buffer")
            return
        }

        ws.beginDrag(.fileBuffer(buffer.id))
        XCTAssertTrue(ws.dropDragSourceOntoFocusedPane(zone: .trailing))
        XCTAssertNil(ws.dragSource)
        XCTAssertEqual(tab.root.leafIDs.count, 2)
        XCTAssertEqual(tab.panes.values.filter { $0.fileBuffer?.id == buffer.id }.count, 1)
    }

    func testDropRegisteredFileBufferDragSourceOntoPreviewCreatesPreviewPanelNotTerminalPane() async {
        let ws = WorkspaceModel()
        let server = UUID()
        let tab = ws.openServer(profileID: server, title: "target")
        await ws.filePreviewModel.open(path: "/tmp/readme.md", fileSize: 0, mtime: nil)

        guard let buffer = ws.filePreviewModel.buffers.first else {
            XCTFail("workspace should have a preview buffer")
            return
        }

        ws.beginDrag(.fileBuffer(buffer.id))
        XCTAssertTrue(ws.dropDragSourceOntoFocusedPreviewPanel(zone: .trailing))
        XCTAssertNil(ws.dragSource)
        XCTAssertEqual(tab.root.leafIDs.count, 1)
        XCTAssertEqual(ws.filePreviewModel.panelBufferIDsInDisplayOrder, [buffer.id, buffer.id])
    }

    func testDropFileBufferProviderPayloadOntoPreviewCreatesPreviewPanelWithoutDragSource() async {
        let ws = WorkspaceModel()
        let server = UUID()
        let tab = ws.openServer(profileID: server, title: "target")
        await ws.filePreviewModel.open(path: "/tmp/readme.md", fileSize: 0, mtime: nil)

        guard let buffer = ws.filePreviewModel.buffers.first,
              let panelID = ws.filePreviewModel.panelRoot?.firstLeafID else {
            XCTFail("workspace should have a preview buffer and panel")
            return
        }

        XCTAssertTrue(ws.dropFileBufferProviderPayload(buffer.id,
                                                       ontoPreviewPanel: panelID,
                                                       zone: .trailing))
        XCTAssertNil(ws.dragSource)
        XCTAssertEqual(tab.root.leafIDs.count, 1)
        XCTAssertEqual(ws.filePreviewModel.panelBufferIDsInDisplayOrder, [buffer.id, buffer.id])
    }

    func testSplittingFilePaneCopiesFileBuffer() {
        let ws = WorkspaceModel()
        let server = UUID()
        let tab = ws.openServer(profileID: server, title: "target")
        let buffer = FileBuffer(remotePath: "/tmp/readme.md", kind: .markdown)

        guard let targetPaneID = tab.focusedPaneID else {
            XCTFail("target tab should have a focused pane")
            return
        }
        XCTAssertTrue(ws.dropFileBuffer(buffer, onto: targetPaneID, zone: .bottom))
        guard let filePaneID = tab.panes.values.first(where: { $0.fileBuffer?.id == buffer.id })?.id else {
            XCTFail("file pane should exist")
            return
        }

        tab.splitPane(filePaneID, direction: .horizontal, serverProfileID: server)

        XCTAssertEqual(tab.root.leafIDs.count, 3)
        XCTAssertEqual(tab.panes.values.filter { $0.fileBuffer?.id == buffer.id }.count, 2)
        XCTAssertEqual(tab.focusedPane?.fileBuffer?.id, buffer.id)
    }

    func testDropActiveTabWithFocusedFilePaneCopiesFilePane() {
        let ws = WorkspaceModel()
        let server = UUID()
        let tab = ws.openServer(profileID: server, title: "target")
        let buffer = FileBuffer(remotePath: "/tmp/readme.md", kind: .markdown)

        guard let targetPaneID = tab.focusedPaneID else {
            XCTFail("target tab should have a focused pane")
            return
        }
        XCTAssertTrue(ws.dropFileBuffer(buffer, onto: targetPaneID, zone: .bottom))
        guard let filePaneID = tab.panes.values.first(where: { $0.fileBuffer?.id == buffer.id })?.id else {
            XCTFail("file pane should exist")
            return
        }
        tab.focusedPaneID = filePaneID

        XCTAssertTrue(ws.dropTab(tab.id, onto: targetPaneID, zone: .trailing))

        XCTAssertEqual(tab.root.leafIDs.count, 3)
        XCTAssertEqual(tab.panes.values.filter { $0.fileBuffer?.id == buffer.id }.count, 2)
        XCTAssertEqual(tab.focusedPane?.fileBuffer?.id, buffer.id)
    }

    func testDropFileBufferOntoActivePaneCreatesFilePane() {
        let ws = WorkspaceModel()
        let server = UUID()
        let tab = ws.openServer(profileID: server, title: "target")
        let buffer = FileBuffer(remotePath: "/tmp/readme.md", kind: .markdown)

        guard let targetPaneID = tab.focusedPaneID else {
            XCTFail("target tab should have a focused pane")
            return
        }

        XCTAssertTrue(ws.dropFileBuffer(buffer, onto: targetPaneID, zone: .bottom))
        XCTAssertEqual(tab.root.leafIDs.count, 2)
        let filePanes = tab.panes.values.filter { $0.fileBuffer?.id == buffer.id }
        XCTAssertEqual(filePanes.count, 1)
        XCTAssertEqual(tab.focusedPaneID, filePanes.first?.id)
    }

    func testSnapshotSkipsFileBufferPanes() {
        let ws = WorkspaceModel()
        let server = UUID()
        let tab = ws.openServer(profileID: server, title: "target")
        let buffer = FileBuffer(remotePath: "/tmp/readme.md", kind: .markdown)

        guard let targetPaneID = tab.focusedPaneID else {
            XCTFail("target tab should have a focused pane")
            return
        }
        ws.dropFileBuffer(buffer, onto: targetPaneID, zone: .bottom)

        let restored = WorkspaceModel(snapshot: ws.snapshot())
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs[0].root.leafIDs.count, 1)
        XCTAssertNil(restored.tabs[0].panes.values.first?.fileBuffer)
        XCTAssertEqual(restored.tabs[0].panes.values.first?.serverProfileID, server)
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

    func testAssistantContextIncludesActiveRemoteFilePath() {
        let ws = WorkspaceModel()
        let server = ServerProfile()
        server.name = "prod"
        server.username = "root"
        server.host = "10.0.0.24"
        ws.filePreviewModel.restoreOpenFiles([
            OpenFileSnapshot(remotePath: "/usr/local/etc/xray/config.json",
                             byteSize: 2_048,
                             mtimeWhenLoaded: nil),
        ], activeIndex: 0)

        XCTAssertEqual(
            ws.assistantContext(for: server),
            "服务器：prod（root@10.0.0.24）\n当前文件：/usr/local/etc/xray/config.json")
    }

    func testAssistantContextOmitsFileLineWhenNoFileIsOpen() {
        let ws = WorkspaceModel()
        let server = ServerProfile()
        server.name = "prod"
        server.username = "root"
        server.host = "10.0.0.24"

        XCTAssertEqual(ws.assistantContext(for: server),
                       "服务器：prod（root@10.0.0.24）")
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

    func testSnapshotIncludesFileBrowserPathAndOpenFiles() async {
        let ws = WorkspaceModel()
        let server = UUID()
        _ = ws.openServer(profileID: server, title: "target")
        ws.fileBrowserModel.restoreCurrentPath("/etc/nginx")
        await ws.filePreviewModel.open(path: "/etc/nginx/nginx.conf", fileSize: 12, mtime: nil)

        let snap = ws.snapshot()

        XCTAssertEqual(snap.fileBrowserPath, "/etc/nginx")
        XCTAssertEqual(snap.openFiles?.map(\.remotePath), ["/etc/nginx/nginx.conf"])
        XCTAssertEqual(snap.activeFileIndex, 0)
    }

    func testSnapshotIncludesAgentDraftInput() {
        let ws = WorkspaceModel()
        ws.assistantModel.input = "explain this host"

        let snap = ws.snapshot()

        XCTAssertEqual(snap.agentState?.input, "explain this host")
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
