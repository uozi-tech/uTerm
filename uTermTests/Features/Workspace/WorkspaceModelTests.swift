import UPaneGroups
import UPaneTree
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

    func testOpenServerAddsTabToActiveGroup() {
        let ws = WorkspaceModel()
        let server = UUID()
        let tabID = ws.openServer(profileID: server, title: "s1")
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 1)
        XCTAssertEqual(ws.terminalGroups.activeTab?.id, tabID)
        XCTAssertEqual(ws.terminalGroups.activeTab?.payload.serverProfileID, server)
        XCTAssertEqual(ws.terminalGroups.groupCount, 1)
    }

    func testCloseActiveTabSelectsNeighbor() {
        let ws = WorkspaceModel()
        let t1 = ws.openServer(profileID: UUID(), title: "a")
        _ = ws.openServer(profileID: UUID(), title: "b")
        XCTAssertTrue(ws.closeActiveTerminalTab())
        XCTAssertEqual(ws.terminalGroups.allTabs.map(\.id), [t1])
        XCTAssertEqual(ws.terminalGroups.activeTab?.id, t1)
    }

    /// 最后一个标签关掉后，唯一的那个组留着显示空态（`allowsLastGroupEmpty`）——
    /// 不再是旧模型的「关掉整个标签、activeTabID 变 nil」。再按一次 ⌘W 没东西可关，
    /// 由调用方回落到关窗口。
    func testCloseLastTabLeavesOneEmptyGroup() {
        let ws = WorkspaceModel()
        _ = ws.openServer(profileID: UUID(), title: "a")
        XCTAssertTrue(ws.closeActiveTerminalTab())
        XCTAssertTrue(ws.terminalGroups.isEmpty)
        XCTAssertEqual(ws.terminalGroups.groupCount, 1)
        XCTAssertNil(ws.terminalGroups.activeTab)
        XCTAssertFalse(ws.closeActiveTerminalTab())
    }

    func testReorderTabWithinGroup() {
        let ws = WorkspaceModel()
        let t1 = ws.openServer(profileID: UUID(), title: "a")
        let t2 = ws.openServer(profileID: UUID(), title: "b")
        ws.terminalGroups.reorderTab(t2, before: t1)
        XCTAssertEqual(ws.terminalGroups.allTabs.map(\.id), [t2, t1])
    }

    /// ⌘D / ⇧⌘D：新组里放一条**新会话**，服务器跟随当前活动标签
    /// （旧 `splitFocusedPane` 就是复制聚焦窗格的 serverProfileID）。
    func testSplitActiveGroupSeedsNewSessionOnSameServer() {
        let ws = WorkspaceModel()
        let server = UUID()
        let first = ws.openServer(profileID: server, title: "a")
        ws.splitActiveGroup(direction: .horizontal)

        XCTAssertEqual(ws.terminalGroups.groupCount, 2)
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 2)
        XCTAssertEqual(Set(ws.terminalGroups.allTabs.map(\.payload.serverProfileID)), [server])
        XCTAssertNotEqual(ws.terminalGroups.activeTab?.id, first, "新组成为活动组")
        XCTAssertEqual(ws.terminalGroups.activeGroup?.tabs.count, 1)
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

    func testAgentCommandRefreshHookReloadsOpenWorkspaceFile() async throws {
        let mtime = Date(timeIntervalSince1970: 1_000)
        let mock = MockSFTP(tree: ["/srv": []])
        await mock.setFile("/srv/app.ini", data: Data("old".utf8), mtime: mtime)
        let browser = FileBrowserModel(testProvider: mock, startPath: "/srv")
        let ws = WorkspaceModel(fileBrowserModel: browser)
        await ws.filePreviewModel.open(
            path: "/srv/app.ini", fileSize: 3, mtime: mtime)

        await mock.setFile("/srv/app.ini", data: Data("new".utf8), mtime: mtime)
        await ws.assistantModel.onCommandExecutionFinished?()

        XCTAssertEqual(ws.filePreviewModel.activeBuffer?.text, "new")
    }

    func testAgentCommandContinuationDoesNotWaitForOwnerNameEnrichment() async throws {
        let mtime = Date(timeIntervalSince1970: 1_000)
        let entry = RemoteEntry(
            name: "app.ini",
            posixPermissions: 0o100644,
            size: 3,
            modifiedAt: mtime,
            uid: 501,
            gid: 20)
        let mock = MockSFTP(tree: ["/srv": [entry]])
        await mock.setFile("/srv/app.ini", data: Data("old".utf8), mtime: mtime)
        let browser = FileBrowserModel(testProvider: mock, startPath: "/srv")
        let ws = WorkspaceModel(fileBrowserModel: browser)
        await ws.filePreviewModel.open(path: "/srv/app.ini", fileSize: 3, mtime: mtime)
        await mock.setFile("/srv/app.ini", data: Data("new".utf8), mtime: mtime)
        await mock.setBlockExec(true)

        let finished = expectation(description: "critical refresh completes")
        Task {
            await ws.assistantModel.onCommandExecutionFinished?()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(ws.fileBrowserModel.entries.map(\.name), ["app.ini"])
        XCTAssertEqual(ws.filePreviewModel.activeBuffer?.text, "new")
        let ownerLookupStarted = await mock.didStartExec()
        XCTAssertTrue(ownerLookupStarted)
        await mock.releaseExec()
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

    /// 标签在组之间移动由 `UPaneGroups` 全权处理：**真移动**，不复制、不关源。
    /// 旧 `dropTab` 是「复制源标签的聚焦窗格，源标签若非当前则整个关掉」。
    func testMoveTabToEdgeSplitsIntoNewGroup() {
        let ws = WorkspaceModel()
        let targetServer = UUID()
        let sourceServer = UUID()
        let target = ws.openServer(profileID: targetServer, title: "target")
        let source = ws.openServer(profileID: sourceServer, title: "source")
        guard let groupID = ws.terminalGroups.locateTab(target)?.groupID else {
            XCTFail("target tab should live in a group")
            return
        }

        ws.terminalGroups.moveTab(source, toGroup: groupID, zone: .trailing)

        XCTAssertEqual(ws.terminalGroups.groupCount, 2)
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 2, "移动不复制，也不关掉源")
        XCTAssertEqual(ws.terminalGroups.activeTab?.id, source)
        XCTAssertEqual(Set(ws.terminalGroups.allTabs.map(\.payload.serverProfileID)),
                       [targetServer, sourceServer])
    }

    /// 组里唯一的标签拖到**本组**边缘 → 走 `cloneTab`：同服务器新开一条会话。
    /// 真移动会让源组塌缩，分完还是一个组，等于没分。
    func testMoveOnlyTabToOwnEdgeClonesSession() {
        let ws = WorkspaceModel()
        let server = UUID()
        let only = ws.openServer(profileID: server, title: "target")
        guard let groupID = ws.terminalGroups.locateTab(only)?.groupID else {
            XCTFail("tab should live in a group")
            return
        }

        ws.terminalGroups.moveTab(only, toGroup: groupID, zone: .trailing)

        XCTAssertEqual(ws.terminalGroups.groupCount, 2)
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 2)
        XCTAssertEqual(
            ws.terminalGroups.allTabs.filter { $0.payload.serverProfileID == server }.count, 2)
    }

    /// 预览标签拖进终端组：组件不认识这个载荷，转给 app 的 `onForeignDrop`。
    /// 同步拖拽源优先，不依赖 provider 的异步回调。
    func testDropRegisteredFileBufferDragSourceCreatesFileTab() async {
        let ws = WorkspaceModel()
        _ = ws.openServer(profileID: UUID(), title: "target")
        await ws.filePreviewModel.open(path: "/tmp/readme.md", fileSize: 0, mtime: nil)

        guard let groupID = ws.terminalGroups.activeGroupID,
              let buffer = ws.filePreviewModel.buffers.first else {
            XCTFail("workspace should have a group and a preview buffer")
            return
        }

        ws.beginDrag(.fileBuffer(buffer.id))
        XCTAssertTrue(ws.dropForeignPayload([], ontoGroup: groupID, zone: .bottom))
        XCTAssertNil(ws.dragSource)
        XCTAssertEqual(ws.terminalGroups.groupCount, 2)
        XCTAssertEqual(
            ws.terminalGroups.allTabs.filter { $0.payload.fileBuffer?.id == buffer.id }.count, 1)
    }

    func testSnapshotSkipsFileBufferTabs() {
        let ws = WorkspaceModel()
        let server = UUID()
        _ = ws.openServer(profileID: server, title: "target")
        let buffer = FileBuffer(remotePath: "/tmp/readme.md", kind: .markdown)
        guard let groupID = ws.terminalGroups.activeGroupID else {
            XCTFail("workspace should have a group")
            return
        }
        ws.dropFileBuffer(buffer, ontoGroup: groupID, zone: .center)

        let restored = WorkspaceModel(snapshot: ws.snapshot())
        XCTAssertEqual(restored.terminalGroups.allTabs.count, 1)
        XCTAssertNil(restored.terminalGroups.allTabs.first?.payload.fileBuffer)
        XCTAssertEqual(restored.terminalGroups.allTabs.first?.payload.serverProfileID, server)
    }

    /// P4 起分屏形状进盘：往返后组数、每组的标签、活动标签全部还在。
    /// （P3 这条钉的是退化行为 —— 那时每次重启都会把分屏拍平成一个组。）
    /// 逐项保形的详细断言在 `TerminalGroupsPersistenceTests`。
    func testSnapshotRoundTripPreservesGroups() {
        let ws = WorkspaceModel()
        let s1 = UUID(), s2 = UUID()
        _ = ws.openServer(profileID: s1, title: "a")
        ws.splitActiveGroup(direction: .vertical)
        _ = ws.openServer(profileID: s2, title: "b")
        XCTAssertEqual(ws.terminalGroups.groupCount, 2)

        let restored = WorkspaceModel(snapshot: ws.snapshot())
        XCTAssertEqual(restored.terminalGroups.allTabs.count, 3)
        XCTAssertEqual(restored.terminalGroups.groupCount, 2, "分屏形状必须还原")
        XCTAssertEqual(restored.terminalGroups.allTabs.map(\.customTitle), ["a", "a", "b"])
        XCTAssertEqual(restored.terminalGroups.allTabs.map(\.payload.serverProfileID),
                       [s1, s1, s2])
        XCTAssertEqual(restored.terminalGroups.activeTab?.customTitle, "b")
        // 第一个组一个标签，第二个组两个（分屏克隆的 + 后开的 b）。
        let groupTabCounts = restored.terminalGroups.groupIDs.map {
            restored.terminalGroups.groups[$0]?.tabs.count ?? 0
        }
        XCTAssertEqual(groupTabCounts, [1, 2])
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

    /// 新语义 = 活动组的前台标签（旧语义是活动标签的聚焦窗格）。
    func testFocusedTerminalSessionReturnsSessionForActiveTab() {
        let ws = WorkspaceModel()
        ws.openServer(profileID: UUID(), title: "x")
        XCTAssertNotNil(ws.focusedTerminalSession())
        XCTAssertTrue(ws.focusedTerminalSession() === ws.terminalGroups.activeTab?.payload.session)
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
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 2)

        let restoredServer = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [TabSnapshot(title: "restored",
                               layout: .leaf(serverProfileID: restoredServer))],
            activeTabIndex: 0, uiState: nil)
        ws.restore(from: snap)
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 1)
        XCTAssertEqual(ws.terminalGroups.allTabs[0].customTitle, "restored")
    }

    func testConvenienceInitFromSnapshotGoesThroughRestore() {
        let id = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [TabSnapshot(title: "x", layout: .leaf(serverProfileID: id))],
            activeTabIndex: 0, uiState: nil)
        let ws = WorkspaceModel(snapshot: snap)
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 1)
        XCTAssertEqual(ws.terminalGroups.activeTab?.id, ws.terminalGroups.allTabs[0].id)
    }

    /// Fix #8：dispose 必须清理所有终端标签的会话 + 左 sidebar 的 SFTP 会话。
    /// FileBrowserModel / PaneModel 的真实 close 在自己的单测里覆盖。
    func testDisposeDoesNotCrash() {
        let ws = WorkspaceModel()
        ws.openServer(profileID: UUID(), title: "a")
        ws.openServer(profileID: UUID(), title: "b")
        ws.dispose()  // 不应抛错
    }

    // MARK: 拆除期快照不得写坏 serverProfileID

    /// 窗口关闭时 `.onDisappear` 会同时跑「dispose」与「保存快照」，SwiftUI 不保证
    /// 先后。dispose 先跑会清空 panes 映射 —— 旧实现在那之后取快照会给每个叶子写进
    /// 一个随机 UUID，下次打开工作区就恢复出一个永远「服务器配置已被删除」的终端。
    func testSnapshotAfterDisposeKeepsRealServerIDs() {
        let ws = WorkspaceModel()
        let server = UUID()
        ws.openServer(profileID: server, title: "a")
        ws.dispose()

        let snap = ws.snapshot()
        XCTAssertEqual(snap.tabs.count, 1, "dispose 后取快照不能丢掉标签")
        XCTAssertEqual(snap.tabs[0].layout, .leaf(serverProfileID: server),
                       "dispose 后取快照必须仍是真实的 serverProfileID")
    }

    /// 自动保存走的是 `autosaveStructureSnapshot()`，同样不能在拆除后漂移
    /// （旧实现每次调用都会生成新的随机 UUID，onChange 会被无限触发）。
    func testAutosaveSnapshotIsStableAfterDispose() {
        let ws = WorkspaceModel()
        ws.openServer(profileID: UUID(), title: "a")
        ws.dispose()
        XCTAssertEqual(ws.autosaveStructureSnapshot(), ws.autosaveStructureSnapshot())
    }

    // MARK: restore 的服务器白名单校验

    func testRestoreDropsTabsPointingAtUnknownServers() {
        let ws = WorkspaceModel()
        let dead = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [TabSnapshot(title: "坏的", layout: .leaf(serverProfileID: dead))],
            activeTabIndex: 0, uiState: nil)
        ws.restore(from: snap, knownServerIDs: [UUID()])
        XCTAssertTrue(ws.terminalGroups.isEmpty, "指向不存在服务器的标签必须被剪掉")
        XCTAssertNil(ws.terminalGroups.activeTab)
    }

    func testRestoreWithEmptyWhitelistSkipsValidation() {
        let ws = WorkspaceModel()
        let unknown = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [TabSnapshot(title: "x", layout: .leaf(serverProfileID: unknown))],
            activeTabIndex: 0, uiState: nil)
        ws.restore(from: snap, knownServerIDs: [])
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 1,
                       "空白名单 = 不校验（ServerProfile 未载入时不误伤）")
    }

    /// 分屏里只有一侧指向已删除服务器时，保留另一侧而不是整个标签作废。
    func testRestoreCollapsesSplitWhenOneSideIsUnknown() {
        let ws = WorkspaceModel()
        let live = UUID()
        let dead = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [TabSnapshot(title: "x", layout: .split(
                direction: .horizontal, fraction: 0.5,
                first: .leaf(serverProfileID: dead),
                second: .leaf(serverProfileID: live)))],
            activeTabIndex: 0, uiState: nil)
        ws.restore(from: snap, knownServerIDs: [live])
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 1)
        XCTAssertEqual(ws.terminalGroups.allTabs[0].payload.serverProfileID, live)
    }

    /// 剪掉靠前的标签后，activeTabIndex 必须跟着重映射，不能指到别的标签上。
    func testRestoreRemapsActiveTabIndexAfterPruning() {
        let ws = WorkspaceModel()
        let live = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [
                TabSnapshot(title: "坏的", layout: .leaf(serverProfileID: UUID())),
                TabSnapshot(title: "好的", layout: .leaf(serverProfileID: live)),
            ],
            activeTabIndex: 1, uiState: nil)
        ws.restore(from: snap, knownServerIDs: [live])
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 1)
        XCTAssertEqual(ws.terminalGroups.activeTab?.id, ws.terminalGroups.allTabs[0].id)
        XCTAssertEqual(ws.terminalGroups.activeTab?.customTitle, "好的")
    }
}
