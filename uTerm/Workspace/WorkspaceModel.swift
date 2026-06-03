import SwiftUI

/// 整个终端工作区：有序标签 + 当前活动标签 + 三栏 UI 状态 + 左/右栏的内置 model。
@MainActor
@Observable
final class WorkspaceModel {
    private(set) var tabs: [TabModel] = []
    var activeTabID: UUID?

    /// 三栏 UI 状态：sidebar 折叠 / inspector 显隐 / 预览-终端比例。持久化进 snapshot。
    var uiState = WorkspaceUIState()

    /// 左 sidebar 的 SFTP 浏览器 model；与 workspace 同生命周期。
    let fileBrowserModel = FileBrowserModel()

    /// 右 inspector 的 AI 助手 model；与 workspace 同生命周期，
    /// 避免 inspector toggle 时丢失 chat 历史。
    let assistantModel = AssistantModel()

    /// 预览/编辑区的 model；与 workspace 同生命周期。Spec 2A §1.3。
    let filePreviewModel: FilePreviewModel

    /// 底部状态栏的远程遥测 model；与 workspace 同生命周期。复用 SFTP 连接轮询
    /// /proc 等，不碰终端 PTY。
    let telemetryModel: TelemetryModel

    init(windowID: WorkspaceWindowID? = nil) {
        // 按 windowID 命名 recents 文件；windowID 为 nil（测试）走临时目录。
        let store: RecentFilesStore
        if let wid = windowID {
            store = RecentFilesStore(windowID: wid)
        } else {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("uTermTests-\(UUID().uuidString)", isDirectory: true)
            store = RecentFilesStore(rootDirectory: tmp,
                                     fileName: "recents-\(UUID().uuidString).json")
        }
        // FilePreviewModel 取 SFTP provider 走 fileBrowserModel —— 用 closure 延迟
        // 取（fileBrowserModel 在 init 中先初始化，对 self 不可用直到 init 完成；
        // 但 RecentFilesStore 与 sftpProvider closure 都不需要立即捕获 self。）
        self.filePreviewModel = FilePreviewModel(
            recentsStore: store,
            sftpProvider: { [weak fileBrowserModel] in fileBrowserModel?.sftpProvider })
        // 遥测复用 SFTP 的连接（同 FilePreviewModel 的延迟取法）。
        self.telemetryModel = TelemetryModel(
            provider: { [weak fileBrowserModel] in fileBrowserModel?.sftpProvider })
    }

    /// 从持久化快照重建工作区。便利构造器 —— 内部走 restore(from:) 走同一条路径。
    /// 不接 windowID（测试场景多用），recents 走临时目录。生产代码用 init(windowID:) +
    /// 后续 restore(from:)。
    convenience init(snapshot: WorkspaceSnapshot) {
        self.init(windowID: nil)
        restore(from: snapshot)
    }

    /// 把快照恢复到当前实例：替换 tabs、activeTabID、uiState。
    /// 不替换 fileBrowserModel/assistantModel —— 让 SFTPSidebar/AgentSidebar
    /// 的 .task(id:) 持有的引用始终稳定，避免「窗口实例换了但 view 的 task
    /// 不重启」的卡死。
    func restore(from snapshot: WorkspaceSnapshot) {
        // 先 dispose 旧 tab 的资源（虽然实践中 restore 通常在空 model 上调用，
        // 但保留正确语义供未来"重连/切换布局"复用）。
        for tab in tabs { tab.disposeAll() }
        tabs.removeAll()

        for tabSnap in snapshot.tabs {
            var panes: [UUID: PaneModel] = [:]
            let root = Self.buildNode(tabSnap.layout, into: &panes)
            tabs.append(TabModel(title: tabSnap.title, root: root, panes: panes))
        }
        if let idx = snapshot.activeTabIndex, tabs.indices.contains(idx) {
            activeTabID = tabs[idx].id
        } else {
            activeTabID = tabs.first?.id
        }
        if let ui = snapshot.uiState {
            self.uiState = ui
        }
    }

    /// 窗口关闭时调用：释放 tab 内所有窗格 + 左 sidebar 的 SFTP 会话 +
    /// 预览 buffers。AssistantModel 不持有持续资源（chat session 用完即关），无需显式 dispose。
    func dispose() {
        for tab in tabs { tab.disposeAll() }
        fileBrowserModel.dispose()
        filePreviewModel.dispose()
        telemetryModel.stop()
    }

    var activeTab: TabModel? { tabs.first { $0.id == activeTabID } }

    /// 折叠/展开左 sidebar —— 任何非 `.detailOnly` 状态都归到 `.detailOnly`；
    /// `.detailOnly` 归到 `.all`。这样窗口被 SwiftUI 自动 reflow 成 `.doubleColumn`
    /// 等中间态时，切换仍能可靠地隐藏/展开（Fix #5）。
    func toggleLeftSidebar() {
        uiState.leftSidebarVisibility = (uiState.leftSidebarVisibility == .detailOnly) ? .all : .detailOnly
    }

    /// 折叠/展开右 inspector。
    func toggleRightInspector() {
        uiState.rightInspectorPresented.toggle()
    }

    /// 当前活动 tab 的聚焦终端会话；无活动 tab / 无聚焦窗格则返回 nil。
    /// 工具栏徽标与状态栏按此决定要不要渲染。
    func focusedTerminalSession() -> TerminalSession? {
        activeTab?.focusedPane?.session
    }

    /// 新开一个标签连指定服务器，并设为活动标签。
    @discardableResult
    func openServer(profileID: UUID, title: String) -> TabModel {
        let tab = TabModel(title: title, rootServerProfileID: profileID)
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].disposeAll()
        tabs.remove(at: idx)
        if activeTabID == id {
            activeTabID = tabs.indices.contains(idx) ? tabs[idx].id
                : tabs.indices.contains(idx - 1) ? tabs[idx - 1].id
                : tabs.first?.id
        }
    }

    /// 把某标签移到 `toIndex`（`toIndex` 即目标标签槽位）。
    func moveTab(fromID: UUID, toIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == fromID }) else { return }
        let clamped = max(0, min(toIndex, tabs.count - 1))
        guard from != clamped else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: clamped)
    }

    // MARK: 快照

    func snapshot() -> WorkspaceSnapshot {
        let tabSnaps = tabs.map { tab in
            TabSnapshot(title: tab.title,
                        layout: Self.nodeSnapshot(tab.root, panes: tab.panes))
        }
        let activeIdx = tabs.firstIndex { $0.id == activeTabID }
        return WorkspaceSnapshot(tabs: tabSnaps, activeTabIndex: activeIdx, uiState: uiState)
    }

    private static func nodeSnapshot(_ node: LayoutNode,
                                     panes: [UUID: PaneModel]) -> NodeSnapshot {
        switch node {
        case .leaf(let paneID):
            let pane = panes[paneID]
            return .leaf(serverProfileID: pane?.serverProfileID ?? UUID())
        case .split(let s):
            return .split(direction: s.direction, fraction: s.fraction,
                          first: nodeSnapshot(s.first, panes: panes),
                          second: nodeSnapshot(s.second, panes: panes))
        }
    }

    private static func buildNode(_ snap: NodeSnapshot,
                                  into panes: inout [UUID: PaneModel]) -> LayoutNode {
        switch snap {
        case .leaf(let serverProfileID):
            let pane = PaneModel(serverProfileID: serverProfileID)
            panes[pane.id] = pane
            return .leaf(paneID: pane.id)
        case .split(let direction, let fraction, let first, let second):
            return .split(SplitNode(
                id: UUID(), direction: direction, fraction: fraction,
                first: buildNode(first, into: &panes),
                second: buildNode(second, into: &panes)))
        }
    }
}
