import UPaneTree
import AgentKit
import AppKit
import SwiftUI
import SwiftData

/// 整个终端工作区：有序标签 + 当前活动标签 + 三栏 UI 状态 + 左/右栏的内置 model。
@MainActor
@Observable
final class WorkspaceModel {
    private(set) var tabs: [TabModel] = []
    var activeTabID: UUID?

    /// 三栏 UI 状态：sidebar 折叠 / inspector 显隐 / 预览-终端比例。持久化进 snapshot。
    var uiState = WorkspaceUIState()

    /// 左 sidebar 的 SFTP 浏览器 model；与 workspace 同生命周期。
    let fileBrowserModel: FileBrowserModel

    /// 右 inspector 的 AI 助手 model；与 workspace 同生命周期，
    /// 避免 inspector toggle 时丢失 chat 历史。
    let assistantModel = AssistantModel()

    /// 预览/编辑区的 model；与 workspace 同生命周期。Spec 2A §1.3。
    let filePreviewModel: FilePreviewModel

    /// 底部状态栏的远程遥测 model；与 workspace 同生命周期。复用 SFTP 连接轮询
    /// /proc 等，不碰终端 PTY。
    let telemetryModel: TelemetryModel

    /// 当前 workspace 内正在拖拽的源。用于 drop 时同步分发，避免依赖
    /// `NSItemProvider.loadDataRepresentation` 的异步回调决定 UI 是否更新。
    private(set) var dragSource: WorkspaceDragSource?

    @ObservationIgnored private var dragEndPollTask: Task<Void, Never>?
    @ObservationIgnored private var agentBackgroundRefreshTask: Task<Void, Never>?

    /// `dispose()` 时冻结的最后一份快照。窗口拆除时 `.onDisappear` 会同时触发
    /// 「释放资源」与「保存快照」两条路径，SwiftUI 不保证先后；先跑 dispose 会把
    /// `TabModel.panes` 清空，之后再取快照就丢掉了整棵布局树 —— 历史上还会给每个
    /// 叶子写进一个随机 `serverProfileID`，于是下次打开工作区恢复出一个永远
    /// 「服务器配置已被删除」的终端。dispose 前冻结一份，之后一律返回它。
    @ObservationIgnored private var frozenSnapshot: WorkspaceSnapshot?

    init(windowID: WorkspaceWindowID? = nil,
         fileBrowserModel: FileBrowserModel = FileBrowserModel()) {
        self.fileBrowserModel = fileBrowserModel
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

        // Agent 的 run_command 可以通过任意 shell 语法改动远端文件。命令结算后先
        // 刷新左侧目录（也负责断线重连），再重读已打开的安全 buffer。
        assistantModel.onCommandExecutionFinished = { [weak self] in
            await self?.refreshAfterAgentCommandAttempt()
        }
    }

    private func refreshAfterAgentCommandAttempt() async {
        // 关键顺序保持：文件树原始列表先发布，再重读当前可见文件，最后才允许 Agent 续轮。
        await fileBrowserModel.refreshListingAfterRemoteCommand()
        let generation = await filePreviewModel.refreshVisibleAfterRemoteCommand()

        // owner/group 补全由 FileBrowserModel 自己后台完成；非活动 buffer 也不阻塞续轮。
        agentBackgroundRefreshTask?.cancel()
        agentBackgroundRefreshTask = Task { [weak preview = filePreviewModel] in
            await preview?.refreshInactiveAfterRemoteCommand(generation: generation)
        }
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
    ///
    /// `knownServerIDs` 非空时用作白名单：指向不存在服务器的叶子直接丢弃，叶子被
    /// 丢光的标签也一并丢弃。旧版本写坏的快照（叶子是随机 UUID）会在这里被清掉，
    /// 调用方随后靠「没有标签就开一个」兜底出一个真正可用的终端，而不是恢复出一个
    /// 永远卡在「服务器配置已被删除」的窗格。传空集合表示跳过校验（测试场景，或
    /// ServerProfile 尚未载入时不做误判）。
    func restore(from snapshot: WorkspaceSnapshot, knownServerIDs: Set<UUID> = []) {
        // 先 dispose 旧 tab 的资源（虽然实践中 restore 通常在空 model 上调用，
        // 但保留正确语义供未来"重连/切换布局"复用）。
        for tab in tabs { tab.disposeAll() }
        tabs.removeAll()

        // 记录每个保留下来的标签在快照里的原始下标，pruning 丢掉标签后
        // activeTabIndex 才不会指到别的标签上。
        var keptSourceIndices: [Int] = []
        for (index, tabSnap) in snapshot.tabs.enumerated() {
            guard let layout = Self.pruningUnknownServers(tabSnap.layout,
                                                          knownServerIDs: knownServerIDs)
            else { continue }
            var panes: [UUID: PaneModel] = [:]
            let root = Self.buildNode(layout, into: &panes)
            tabs.append(TabModel(title: tabSnap.title, root: root, panes: panes))
            keptSourceIndices.append(index)
        }
        if let idx = snapshot.activeTabIndex,
           let position = keptSourceIndices.firstIndex(of: idx) {
            activeTabID = tabs[position].id
        } else {
            activeTabID = tabs.first?.id
        }
        if let ui = snapshot.uiState {
            self.uiState = ui
        }
        if let path = snapshot.fileBrowserPath {
            fileBrowserModel.restoreCurrentPath(path)
        }
        filePreviewModel.restoreOpenFiles(snapshot.openFiles, activeIndex: snapshot.activeFileIndex)
        assistantModel.restore(from: snapshot.agentState)
    }

    /// 窗口关闭时调用：释放 tab 内所有窗格 + 左 sidebar 的 SFTP 会话 +
    /// 预览 buffers。AssistantModel 不持有持续资源（chat session 用完即关），无需显式 dispose。
    func dispose() {
        // 拆资源之前先把快照冻结：之后 tab.disposeAll() 会清空 panes 映射，
        // 再取快照就只剩空布局（见 `frozenSnapshot`）。
        if frozenSnapshot == nil {
            frozenSnapshot = makeSnapshot(agentState: assistantModel.snapshot())
        }
        endDrag()
        agentBackgroundRefreshTask?.cancel()
        agentBackgroundRefreshTask = nil
        for tab in tabs { tab.disposeAll() }
        fileBrowserModel.dispose()
        filePreviewModel.dispose()
        telemetryModel.stop()
    }

    var activeTab: TabModel? { tabs.first { $0.id == activeTabID } }

    /// 每次向工作区 Agent 发送消息时使用的实时上下文。活动文件来自预览模型，因而
    /// 切换编辑标签或分屏焦点后，Agent 能直接定位当前窗口对应的远端绝对路径。
    func assistantContext(for server: ServerProfile) -> String {
        var lines = ["服务器：\(server.name)（\(server.displayEndpoint)）"]
        if let path = filePreviewModel.activeBuffer?.remotePath {
            lines.append("当前文件：\(path)")
        }
        return lines.joined(separator: "\n")
    }

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

    func connectSharedSFTP(profile: ServerProfile, modelContainer: ModelContainer) async {
        await fileBrowserModel.connect(profile: profile, modelContainer: modelContainer)
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

    /// 记录一次 workspace 内拖拽源。`.onDrag` 没有结束回调，因此与 pane
    /// drag state 一样轮询鼠标释放兜底清理。
    func beginDrag(_ source: WorkspaceDragSource) {
        dragSource = source
        dragEndPollTask?.cancel()
        dragEndPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                if Task.isCancelled { return }
                if (NSEvent.pressedMouseButtons & 1) == 0 {
                    // Give SwiftUI/AppKit's drop target a brief chance to run
                    // `performDrop` before clearing the in-process source.
                    // Successful drops still clear immediately via
                    // `dropDragSource`.
                    try? await Task.sleep(for: .milliseconds(120))
                    if Task.isCancelled { return }
                    self?.endDrag()
                    return
                }
            }
        }
    }

    /// 清除当前 workspace 拖拽源。幂等。
    func endDrag() {
        dragSource = nil
        dragEndPollTask?.cancel()
        dragEndPollTask = nil
    }

    /// 把当前登记的拖拽源投放到 `targetPaneID`。这是 UI drop 的同步入口：
    /// provider 只用于系统识别拖拽类型，真正的源 id 从 `dragSource` 读取。
    @discardableResult
    func dropDragSource(onto targetPaneID: UUID, zone: PaneDropZone) -> Bool {
        guard let dragSource else { return false }
        defer { endDrag() }

        switch dragSource {
        case .pane(let sourcePaneID):
            return dropPane(sourcePaneID, onto: targetPaneID, zone: zone)
        case .tab(let sourceTabID):
            return dropTab(sourceTabID, onto: targetPaneID, zone: zone)
        case .fileBuffer(let bufferID):
            return dropFileBuffer(bufferID, onto: targetPaneID, zone: zone)
        }
    }

    /// 把当前登记的拖拽源投放到当前活动 terminal tab 的聚焦窗格。
    /// PreviewArea 使用独立的 file panel layout，不走这个入口。
    @discardableResult
    func dropDragSourceOntoFocusedPane(zone: PaneDropZone) -> Bool {
        guard let targetPaneID = activeTab?.focusedPaneID
                ?? activeTab?.root.firstLeafID
        else {
            endDrag()
            return false
        }
        return dropDragSource(onto: targetPaneID, zone: zone)
    }

    /// 把当前文件拖拽源投放到预览/编辑区的聚焦文件 panel。
    /// 文件预览区有自己的 panel layout，不能把文件 tab 转投到 terminal pane tree。
    @discardableResult
    func dropDragSourceOntoFocusedPreviewPanel(zone: PaneDropZone) -> Bool {
        guard let dragSource else { return false }
        defer { endDrag() }

        guard case .fileBuffer(let bufferID) = dragSource else {
            return false
        }
        return filePreviewModel.dropBufferOntoFocusedPanel(bufferID, zone: zone)
    }

    /// 把当前文件拖拽源投放到指定预览/编辑区 panel。
    @discardableResult
    func dropDragSource(ontoPreviewPanel targetPanelID: UUID,
                        zone: PaneDropZone) -> Bool {
        guard let dragSource else { return false }
        defer { endDrag() }

        guard case .fileBuffer(let bufferID) = dragSource else {
            return false
        }
        return filePreviewModel.dropBuffer(bufferID, onto: targetPanelID, zone: zone)
    }

    /// 从 `NSItemProvider` 载荷兜底投放文件 buffer。
    /// SwiftUI 有时会在 workspace dragSource 刷新前先命中 drop target；
    /// 这条路径让预览区不用依赖同步登记状态也能完成分屏。
    @discardableResult
    func dropFileBufferProviderPayload(_ bufferID: UUID,
                                       ontoPreviewPanel targetPanelID: UUID,
                                       zone: PaneDropZone) -> Bool {
        defer { endDrag() }
        return filePreviewModel.dropBuffer(bufferID, onto: targetPanelID, zone: zone)
    }

    @discardableResult
    private func dropPane(_ sourcePaneID: UUID, onto targetPaneID: UUID,
                          zone: PaneDropZone) -> Bool {
        guard sourcePaneID != targetPaneID,
              let targetTab = activeTab,
              targetTab.panes[sourcePaneID] != nil,
              targetTab.panes[targetPaneID] != nil
        else {
            return false
        }
        if zone == .center {
            targetTab.swapPanes(sourcePaneID, targetPaneID)
        } else {
            targetTab.movePane(sourcePaneID, toTarget: targetPaneID, zone: zone)
        }
        return true
    }

    /// 把一个标签作为新窗格投放到当前活动标签的某个窗格旁边。
    /// 源标签是当前标签时复制当前聚焦窗格；否则源标签关闭，目标标签保持活动。
    @discardableResult
    func dropTab(_ sourceTabID: UUID, onto targetPaneID: UUID,
                 zone: PaneDropZone) -> Bool {
        guard zone != .center,
              let targetTab = activeTab,
              targetTab.panes[targetPaneID] != nil,
              let sourceTab = tabs.first(where: { $0.id == sourceTabID }),
              let sourcePane = sourceTab.focusedPane
                ?? sourceTab.root.firstLeafID.flatMap({ sourceTab.panes[$0] })
        else {
            return false
        }

        let inserted = targetTab.insertPane(
            copying: sourcePane,
            toTarget: targetPaneID,
            zone: zone)
        guard inserted else { return false }
        if targetTab.id != sourceTabID {
            closeTab(sourceTabID)
        }
        activeTabID = targetTab.id
        return true
    }

    /// 把一个文件预览 buffer 作为新窗格投放到当前活动标签的某个窗格旁边。
    @discardableResult
    func dropFileBuffer(_ bufferID: UUID, onto targetPaneID: UUID,
                        zone: PaneDropZone) -> Bool {
        guard let buffer = filePreviewModel.buffers.first(where: { $0.id == bufferID }) else {
            return false
        }
        return dropFileBuffer(buffer, onto: targetPaneID, zone: zone)
    }

    /// 测试与内部调用用重载：允许直接传入已持有的 FileBuffer。
    @discardableResult
    func dropFileBuffer(_ buffer: FileBuffer, onto targetPaneID: UUID,
                        zone: PaneDropZone) -> Bool {
        guard zone != .center,
              let targetTab = activeTab,
              targetTab.panes[targetPaneID] != nil
        else {
            return false
        }
        return targetTab.insertFilePane(buffer, toTarget: targetPaneID, zone: zone)
    }

    // MARK: 快照

    func snapshot() -> WorkspaceSnapshot {
        if let frozenSnapshot { return frozenSnapshot }
        return makeSnapshot(agentState: assistantModel.snapshot())
    }

    /// 自动保存的结构变化签名。草稿单独由轻量 `onChange(input)` 监听，避免每次按键
    /// 都遍历标签布局、打开文件并构造完整快照；真正写盘前再调用 `snapshot()` 取最新值。
    func autosaveStructureSnapshot() -> WorkspaceSnapshot {
        if let frozenSnapshot { return frozenSnapshot }
        return makeSnapshot(agentState: AgentSnapshot(
            currentSessionID: assistantModel.currentSession?.id,
            input: ""))
    }

    private func makeSnapshot(agentState: AgentSnapshot) -> WorkspaceSnapshot {
        var activeIdx: Int?
        var tabSnaps: [TabSnapshot] = []
        for tab in tabs {
            guard let layout = Self.nodeSnapshot(tab.root, panes: tab.panes) else {
                continue
            }
            if tab.id == activeTabID {
                activeIdx = tabSnaps.count
            }
            tabSnaps.append(TabSnapshot(title: tab.title, layout: layout))
        }
        let (openFiles, activeFileIndex) = filePreviewModel.openFileSnapshots()
        return WorkspaceSnapshot(
            tabs: tabSnaps,
            activeTabIndex: activeIdx,
            uiState: uiState,
            fileBrowserPath: fileBrowserModel.snapshotCurrentPath,
            openFiles: openFiles,
            activeFileIndex: activeFileIndex,
            agentState: agentState)
    }

    private static func nodeSnapshot(_ node: LayoutNode,
                                     panes: [UUID: PaneModel]) -> NodeSnapshot? {
        switch node {
        case .leaf(let paneID):
            // 窗格查不到就丢掉这个叶子。旧代码在这里回落 `UUID()`，把一个不存在的
            // serverProfileID 写进快照 —— 下次打开工作区恢复出的终端永远显示
            // 「连接失败 / 服务器配置已被删除」，且没有可用的重试入口。
            guard let pane = panes[paneID], pane.fileBuffer == nil else { return nil }
            return .leaf(serverProfileID: pane.serverProfileID)
        case .split(let s):
            let first = nodeSnapshot(s.first, panes: panes)
            let second = nodeSnapshot(s.second, panes: panes)
            switch (first, second) {
            case let (first?, second?):
                return .split(direction: s.direction, fraction: s.fraction,
                              first: first, second: second)
            case let (first?, nil):
                return first
            case let (nil, second?):
                return second
            case (nil, nil):
                return nil
            }
        }
    }

    /// 剪掉指向未知服务器的叶子；某个 split 的两侧都被剪掉时整个 split 也返回 nil。
    /// `knownServerIDs` 为空表示不做校验，原样返回。
    nonisolated static func pruningUnknownServers(
        _ snap: NodeSnapshot, knownServerIDs: Set<UUID>) -> NodeSnapshot? {
        guard !knownServerIDs.isEmpty else { return snap }
        switch snap {
        case .leaf(let serverProfileID):
            return knownServerIDs.contains(serverProfileID) ? snap : nil
        case .split(let direction, let fraction, let first, let second):
            let f = pruningUnknownServers(first, knownServerIDs: knownServerIDs)
            let s = pruningUnknownServers(second, knownServerIDs: knownServerIDs)
            switch (f, s) {
            case let (f?, s?):
                return .split(direction: direction, fraction: fraction, first: f, second: s)
            case let (f?, nil):  return f
            case let (nil, s?):  return s
            case (nil, nil):     return nil
            }
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
