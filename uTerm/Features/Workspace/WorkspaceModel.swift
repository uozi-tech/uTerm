import UPaneGroups
import UPaneTree
import AgentKit
import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 终端区标签的载荷就是 `PaneModel` —— 一条终端会话与一个标签 1:1，不可共享。
typealias TerminalTab = UPaneTab<PaneModel>

/// `UPaneGroups` 的 5 投放区。app 自己也有一个同名 `PaneDropZone`
/// （`Views/PaneDropZone.swift`，预览区仍在用），同模块类型会遮蔽导入的同名类型，
/// 故终端区一律用这个别名指组件那一个。
typealias GroupDropZone = UPaneGroups.PaneDropZone

/// 终端区那一套 `UPaneGroups` 参数里**唯一需要反复权衡**的一项，单独拎出来，
/// 免得散落在多处。
enum TerminalPaneAreaTuning {
    /// 终端区的保活策略。
    ///
    /// **暂定 `.activeTabPerGroup`，待 Release 构建复测确认。** 曾有一轮实测说
    /// 「隐藏但挂载的终端在全速重绘、拍平挂载太贵」，但那轮跑的是 **Debug** 构建，
    /// 而 VT 解析成本 Debug 与 Release 实测差 9.4×，绘制的加速比未知 —— 结论可能
    /// 反转成「可以用 `.allTabs`」。见 uAppKit `docs/pane-groups-design.md` §3.1
    /// 与「未确认清单」第 2 条。
    ///
    /// 改成 `.allTabs` 只需要动这一行：切标签会从「重挂 NSView」变成「纯透明度
    /// 翻转」，scrollback 两种取法都不丢（`TerminalHostView` 本来就复用
    /// `TerminalSession` 持有的那个 NSView，重挂只是 attach/detach）。
    static let keepAlive: UPaneGroupsPolicy.KeepAlive = .activeTabPerGroup
}

/// 整个终端工作区：一棵终端组树 + 三栏 UI 状态 + 左/右栏的内置 model。
///
/// 终端区是 **VSCode 编辑组模型**：全窗口一棵分屏树，树的叶子是「组」，每个组有
/// 自己的一条标签条与一个前台标签。旧模型（窗口级标签，每个标签内部一棵窗格树）
/// 连同 `TabModel` 已整个删除 —— 代价是「每个标签一套自己的分屏布局」这个能力在
/// 新模型下无法表达（设计文档 §4.4(b)，已确认接受）。
@MainActor
@Observable
final class WorkspaceModel {
    /// 终端区的组树。所有开 / 关 / 切 / 分屏 / 拖拽都走它。
    let terminalGroups: UPaneGroupsModel<PaneModel>

    /// 本窗口绑定的服务器。没有活动标签时（区域空掉、或分屏按钮开在空组上）的
    /// 回落来源，由 `TerminalArea` 注入。
    /// `@ObservationIgnored`：是接线不是状态，改它不该让任何视图失效。
    @ObservationIgnored private var defaultServerProfileID: UUID?
    @ObservationIgnored private var defaultServerTitle: String = "终端"

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

    /// 远端文件「在本机打开」：数据库交给 uTable，其余下载后交外部应用并监听回传。
    let externalOpen: ExternalOpenCoordinator

    /// 当前 workspace 内正在拖拽的源。用于 drop 时同步分发，避免依赖
    /// `NSItemProvider.loadDataRepresentation` 的异步回调决定 UI 是否更新。
    private(set) var dragSource: WorkspaceDragSource?

    @ObservationIgnored private var dragEndPollTask: Task<Void, Never>?
    @ObservationIgnored private var agentBackgroundRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var agentRefreshGeneration = UUID()

    /// `dispose()` 时冻结的最后一份快照。窗口拆除时 `.onDisappear` 会同时触发
    /// 「释放资源」与「保存快照」两条路径，SwiftUI 不保证先后；先跑 dispose 会把
    /// `TabModel.panes` 清空，之后再取快照就丢掉了整棵布局树 —— 历史上还会给每个
    /// 叶子写进一个随机 `serverProfileID`，于是下次打开工作区恢复出一个永远
    /// 「服务器配置已被删除」的终端。dispose 前冻结一份，之后一律返回它。
    @ObservationIgnored private var frozenSnapshot: WorkspaceSnapshot?

    init(windowID: WorkspaceWindowID? = nil,
         fileBrowserModel: FileBrowserModel = FileBrowserModel()) {
        self.fileBrowserModel = fileBrowserModel
        // 分屏按钮不限组数（uTerm 一向无上限，与 uTable 的 3 组封顶不同）；
        // 组丢掉最后一个标签就塌缩，但整棵树的最后一个组留着显示
        // 「没有打开的终端标签」空态 —— 那正是旧 `TerminalArea` 的空态。
        self.terminalGroups = UPaneGroupsModel<PaneModel>(policy: UPaneGroupsPolicy(
            splitButtonMaxGroups: nil,
            collapsesEmptyGroups: true,
            allowsLastGroupEmpty: true,
            releasesHiddenEditorFocusOnTabSwitch: true,
            keepAlive: TerminalPaneAreaTuning.keepAlive))
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
        self.externalOpen = ExternalOpenCoordinator(
            provider: { [weak fileBrowserModel] in fileBrowserModel?.sftpProvider },
            host: { [weak fileBrowserModel] in fileBrowserModel?.connectedHost })

        // Agent 的 run_command 可以通过任意 shell 语法改动远端文件。命令结算后先
        // 刷新左侧目录（也负责断线重连），再重读已打开的安全 buffer。
        assistantModel.onCommandExecutionFinished = { [weak self] in
            await self?.refreshAfterAgentCommandAttempt()
        }
        wireTerminalGroups()
    }

    /// 组树的三个钩子。组件对载荷零操作，会话生命周期全在这里收口。
    private func wireTerminalGroups() {
        // 标签被移出模型 = 那条会话该关（关 PTY + 解 host-key relay）。
        // 文件窗格的 `dispose()` 自带 no-op 守卫：buffer 归 FilePreviewModel 所有，
        // 关掉一个引用它的终端标签不该把它释放掉。
        terminalGroups.onTabRemoved = { removed, _ in removed.payload.dispose() }
        // 组内唯一标签拖到本组边缘 → 克隆。终端标签克隆 = 同服务器新开一条会话；
        // 文件标签克隆 = 同一个 buffer 再挂一份（对齐旧 `insertPane(copying:)`）。
        terminalGroups.cloneTab = { [weak self] tab in
            if let buffer = tab.payload.fileBuffer {
                let pane = PaneModel(serverProfileID: tab.payload.serverProfileID, fileBuffer: buffer)
                self?.stamp(pane)
                return TerminalTab(payload: pane)
            }
            let pane = PaneModel(serverProfileID: tab.payload.serverProfileID, tabTitle: tab.payload.tabTitle)
            self?.stamp(pane)
            return TerminalTab(payload: pane)
        }
        // 分屏按钮 / ⌘D 开的新组里放一条新会话 —— **保留旧的克隆语义**
        // （uTable 那边是有意开空组，理由是克隆大表的数据网格；终端没有这个问题，
        // 空的终端组只能显示一个「新建终端」按钮，白白多一次点击）。
        terminalGroups.makeTabForNewGroup = { [weak self] in
            guard let self, let seed = self.splitSeedServer() else { return nil }
            return TerminalTab(payload: self.makePane(serverProfileID: seed.id, tabTitle: seed.title))
        }
    }

    /// 分屏开新组时新会话连哪台服务器：跟随当前活动标签（旧
    /// `splitFocusedPane` 就是复制聚焦窗格的 `serverProfileID`），没有活动标签时
    /// 回落到本窗口绑定的服务器。
    private func splitSeedServer() -> (id: UUID, title: String)? {
        if let tab = terminalGroups.activeTab, tab.payload.fileBuffer == nil {
            return (tab.payload.serverProfileID, tab.payload.tabTitle ?? defaultServerTitle)
        }
        guard let id = defaultServerProfileID else { return nil }
        return (id, defaultServerTitle)
    }

    /// 由 `TerminalArea` 注入本窗口绑定的服务器。
    func bindDefaultServer(id: UUID, title: String) {
        defaultServerProfileID = id
        defaultServerTitle = title
    }

    private func refreshAfterAgentCommandAttempt() async {
        let expectedGeneration = agentRefreshGeneration
        // 关键顺序保持：文件树原始列表先发布，再重读当前可见文件，最后才允许 Agent 续轮。
        await fileBrowserModel.refreshListingAfterRemoteCommand()
        guard agentRefreshGeneration == expectedGeneration else { return }
        let generation = await filePreviewModel.refreshVisibleAfterRemoteCommand()
        guard agentRefreshGeneration == expectedGeneration else { return }

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
    /// `knownServerIDs` 非空时用作白名单：指向不存在服务器的标签直接丢弃，标签被
    /// 丢光的组也一并丢弃。旧版本写坏的快照（叶子是随机 UUID）会在这里被清掉，
    /// 调用方随后靠「没有标签就开一个」兜底出一个真正可用的终端，而不是恢复出一个
    /// 永远卡在「服务器配置已被删除」的窗格。传空集合表示跳过校验（测试场景，或
    /// ServerProfile 尚未载入时不做误判）。
    func restore(from snapshot: WorkspaceSnapshot, knownServerIDs: Set<UUID> = []) {
        agentRefreshGeneration = UUID()
        agentBackgroundRefreshTask?.cancel()
        agentBackgroundRefreshTask = nil
        // 先 dispose 旧标签的资源（实践中 restore 通常在空 model 上调用，但保留
        // 正确语义供未来「重连 / 切换布局」复用）。组件的 `restore` 整树替换、
        // 不走 `onTabRemoved`（它是换作用域，不是逐个关标签），所以这里手动 dispose。
        for tab in terminalGroups.allTabs { tab.payload.dispose() }

        // 终端区：新快照直接吃 `terminalGroups` 组树；老快照（该键为 nil）按设计
        // 文档 §4.2 的 M2 规则迁移 —— 见 `WorkspaceSnapshot.migratingLegacyTabs`。
        //
        // 白名单剪枝在下面这个 `make` 闭包里，对新老两种格式一视同仁：返回 nil 的
        // 标签丢掉 → 标签被丢光的组丢掉 → split 只剩一侧就把那一侧上提 → 整棵树都
        // 没剩下就回落到一个空组，由调用方「没有标签就开一个」兜底。
        // **绝不给缺失项回落一个随机 UUID。**
        terminalGroups.restore(snapshot.terminalGroupsForRestore) { tabSnap in
            guard knownServerIDs.isEmpty || knownServerIDs.contains(tabSnap.serverProfileID)
            else { return nil }
            return TerminalTab(payload: self.makePane(id: tabSnap.sessionID, serverProfileID: tabSnap.serverProfileID,
                                                      tabTitle: tabSnap.title))
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
    /// 预览 buffers，同时停止 Agent 的模型请求和自动续轮。
    func dispose() {
        agentRefreshGeneration = UUID()
        // 拆资源之前先把快照冻结：之后 tab.disposeAll() 会清空 panes 映射，
        // 再取快照就只剩空布局（见 `frozenSnapshot`）。
        if frozenSnapshot == nil {
            frozenSnapshot = makeSnapshot(agentState: assistantModel.snapshot())
        }
        endDrag()
        assistantModel.dispose()
        agentBackgroundRefreshTask?.cancel()
        agentBackgroundRefreshTask = nil
        for tab in terminalGroups.allTabs { tab.payload.dispose() }
        // 窗格各自注销了会话；这里再把本窗口的 key/focus 状态从注册表里抹掉。
        if let registrar = sessionRegistrar {
            registrar.registry.forgetWindow(registrar.windowID)
        }
        externalOpen.dispose()
        fileBrowserModel.dispose()
        filePreviewModel.dispose()
        telemetryModel.stop()
    }

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

    /// 活动组的前台终端会话；没有活动标签则返回 nil。
    /// 工具栏徽标与状态栏按此决定要不要渲染。
    ///
    /// 旧语义是「活动标签的**聚焦窗格**」；新语义是「活动组的前台标签」——
    /// 全窗口唯一，语义反而更准（旧模型里一个标签四个窗格连四台机器时，
    /// 这里只反映聚焦那一个）。
    func focusedTerminalSession() -> TerminalSession? {
        terminalGroups.activeTab?.payload.session
    }

    // MARK: - 跨窗口会话注册表（CLI 的 terminals / terminal-read / terminal-send）

    /// 本窗口发给旗下窗格的登记凭条。窗口视图注入注册表后才有值 ——
    /// 单测 / 预览里为 nil，注册全链路是 no-op。
    /// `@ObservationIgnored`：是接线不是状态。
    @ObservationIgnored private(set) var sessionRegistrar: TerminalSessionRegistrar?

    /// 由 `TerminalRegistryBinding`（窗口视图上挂的 ViewModifier）调用。
    ///
    /// 幂等：重复注入同一份凭条只会把现有窗格再 stamp 一遍。之所以要 stamp
    /// **已存在**的窗格，是因为窗口视图的 `.task` 与窗格自己的建连 `.task` 谁先跑
    /// SwiftUI 不保证 —— 晚到的凭条要能把已经连上的窗格补登记（`PaneModel.adopt`）。
    func attachSessionRegistry(
        _ registry: TerminalSessionRegistry,
        windowID: UUID,
        windowKind: String
    ) {
        let registrar = TerminalSessionRegistrar(
            registry: registry, windowID: windowID, windowKind: windowKind,
            customTitle: { [weak self] paneID in self?.tabTitle(paneID: paneID) })
        sessionRegistrar = registrar
        for tab in terminalGroups.allTabs { tab.payload.adopt(registrar: registrar) }
        // 手机远控关标签时「同时关闭 Mac 上的终端」走这里。
        registry.setCloser(forWindow: windowID) { [weak self] paneID in
            self?.closeTerminal(paneID: paneID) ?? false
        }
        syncTerminalTitles()
    }

    /// 关掉某个终端窗格所在的标签（`onTabRemoved` 会 dispose 它、断开连接）。返回 false = 没有这个窗格。
    @discardableResult
    func closeTerminal(paneID: UUID) -> Bool {
        guard terminalGroups.allTabs.contains(where: { $0.payload.id == paneID }) else { return false }
        terminalGroups.closeTabs { $0.payload.id == paneID }
        return true
    }

    /// 某个窗格所在标签打开时定下的名字（`PaneModel.tabTitle`），没有则 nil。
    /// `TerminalSessionRegistrar` 的 title 钩子就查它。
    func tabTitle(paneID: UUID) -> String? {
        terminalGroups.allTabs.first { $0.payload.id == paneID }?.payload.tabTitle
    }

    /// 把每条终端标签**当前**的名字推给注册表（`title` = `PaneModel.tabTitle`，没有就服务器名）。
    /// shell 设的标题不进注册表：它可能每秒变很多次，而注册表每变一次都要推给接入的手机。
    ///
    /// 登记发生在窗格连上的那一刻，而标签的名字可能在那之后才定下来
    ///（窗口视图的 `.task` 晚于窗格建连、标签在组树里被换、恢复出来的标题）——
    /// 所以注入注册表、开新标签、切前台标签这三处都补一次同步。
    /// 注册表里没有的窗格自动 no-op。
    func syncTerminalTitles() {
        guard let registrar = sessionRegistrar else { return }
        for tab in terminalGroups.allTabs where tab.payload.fileBuffer == nil {
            guard let title = tab.payload.tabTitle ?? tab.payload.connectedServerName else { continue }
            registrar.registry.update(id: tab.payload.id, title: title)
        }
    }

    /// 当前前台的**终端**会话 id（文件窗格不算，返回 nil）。
    /// `TerminalRegistryBinding` 用它做 `onChange` 的观察源 —— 那边不想 import
    /// `UPaneGroups` 只为拿一个 `activeTab`。
    var focusedTerminalSessionID: UUID? {
        terminalGroups.activeTab.flatMap { $0.payload.fileBuffer == nil ? $0.payload.id : nil }
    }

    /// 当前前台**终端**标签连的服务器（文件窗格不算，返回 nil）。终端窗口的标签可连不同
    /// 主机，标题栏 / 端口转发 / Agent 按它跟随活动标签。
    var focusedTerminalServerID: UUID? {
        terminalGroups.activeTab.flatMap { $0.payload.fileBuffer == nil ? $0.payload.serverProfileID : nil }
    }

    /// 把当前活动的终端标签同步给注册表（喂 `isKeyWindowFocused`）。
    /// 文件窗格不是终端会话，视作「本窗口没有终端在前台」。
    func syncFocusedTerminalSession() {
        guard let registrar = sessionRegistrar else { return }
        registrar.registry.setFocusedSession(focusedTerminalSessionID, inWindow: registrar.windowID)
        syncTerminalTitles()
    }

    /// 新建窗格的唯一入口：建出来立刻打上登记凭条。
    /// 组树的三个钩子（clone / 新组 / restore）与所有 `openXxx` 都必须走它，
    /// 否则那条会话对 CLI 永远不可见。
    private func makePane(id: UUID? = nil, serverProfileID: UUID, fileBuffer: FileBuffer? = nil, tabTitle: String? = nil,
                          sessionOrder: Double? = nil) -> PaneModel {
        let pane = PaneModel(id: id ?? UUID(), serverProfileID: serverProfileID, fileBuffer: fileBuffer, tabTitle: tabTitle,
                             sessionOrder: sessionOrder ?? Date().timeIntervalSince1970)
        stamp(pane)
        return pane
    }

    private func stamp(_ pane: PaneModel) {
        pane.registrar = sessionRegistrar
    }

    func connectSharedSFTP(profile: ServerProfile, modelContainer: ModelContainer) async {
        await fileBrowserModel.connect(profile: profile, modelContainer: modelContainer)
    }

    /// 在活动组（或指定组）里新开一个标签连指定服务器，并设为该组的前台标签。
    /// 旧 `openServer` 是「新开一个窗口级标签」；⌘T 的行为等价。
    @discardableResult
    func openServer(profileID: UUID, title: String, in groupID: UUID? = nil) -> UUID {
        let id = terminalGroups.openTab({
            TerminalTab(payload: self.makePane(serverProfileID: profileID, tabTitle: title))
        }, in: groupID)
        syncTerminalTitles()
        return id
    }

    /// ⌘D / ⇧⌘D / 标签条右侧的分屏按钮：对活动组分屏，新组里放一条新会话。
    func splitActiveGroup(direction: SplitDirection) {
        guard let groupID = terminalGroups.activeGroupID ?? terminalGroups.root.firstLeafID
        else { return }
        terminalGroups.splitGroup(groupID, direction: direction)
    }

    /// ⌘W 的终端分支：关活动组的前台标签；组因此空掉就从分屏树里塌缩。
    /// 活动组是空的（分屏开出来还没放东西）时改为收掉那个空组。
    /// 返回 false = 终端区没东西可关，调用方回落到关窗口。
    @discardableResult
    func closeActiveTerminalTab() -> Bool {
        terminalGroups.closeActiveTab()
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

    /// 外来拖拽落到终端区的某个组（组件的 `onForeignDrop`）。
    /// 终端区自己的标签拖拽由 `UPaneGroups` 全权处理（真移动，不复制、不关源），
    /// 这里只剩「预览标签的文件 buffer → 终端组」这一种外来载荷。
    ///
    /// **同步拖拽源优先**：不依赖 `NSItemProvider.loadDataRepresentation` 的异步
    /// 回调决定 UI 是否更新；provider 只作兜底。
    @discardableResult
    func dropForeignPayload(_ providers: [NSItemProvider], ontoGroup groupID: UUID,
                            zone: GroupDropZone) -> Bool {
        if case .fileBuffer(let bufferID)? = dragSource {
            endDrag()
            return dropFileBuffer(bufferID, ontoGroup: groupID, zone: zone)
        }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.utermFileBufferID.identifier)
        }) else { return false }
        endDrag()
        FileBufferDragPayload.load(from: provider) { [weak self] bufferID in
            guard let bufferID else { return }
            Task { @MainActor in
                _ = self?.dropFileBuffer(bufferID, ontoGroup: groupID, zone: zone)
            }
        }
        return true
    }

    /// 把一个预览 buffer 作为新标签投放到终端区的某个组。
    /// `center` = 并入该组；边缘 = 在那一侧开一个新组装它。
    @discardableResult
    /// `id` 可能是预览**标签** id（`UPaneGroupArea` 写进拖拽载荷的就是它），也可能是
    /// buffer id（旧路径 / 测试），由 `buffer(forDragPayloadID:)` 统一解析。只按 buffer id
    /// 查的话，从预览区拖标签到终端组会静默失败。
    func dropFileBuffer(_ id: UUID, ontoGroup groupID: UUID, zone: GroupDropZone) -> Bool {
        guard let buffer = filePreviewModel.buffer(forDragPayloadID: id) else { return false }
        return dropFileBuffer(buffer, ontoGroup: groupID, zone: zone)
    }

    /// 测试与内部调用用重载：允许直接传入已持有的 FileBuffer。
    @discardableResult
    func dropFileBuffer(_ buffer: FileBuffer, ontoGroup groupID: UUID,
                        zone: GroupDropZone) -> Bool {
        guard let group = terminalGroups.groups[groupID] else { return false }
        // 文件窗格跟着目标组当前那台服务器走（旧 `insertFilePane` 取的是目标窗格的
        // `serverProfileID`）。
        let serverID = group.activeTab?.payload.serverProfileID
            ?? defaultServerProfileID
            ?? UUID()
        let tab = TerminalTab(payload: makePane(serverProfileID: serverID, fileBuffer: buffer))
        // 空组的边缘 = 把一个空组再劈成两半，没有意义；一律并入。
        guard zone != .center, !group.tabs.isEmpty else {
            terminalGroups.openTab({ tab }, in: groupID)
            return true
        }
        // 组件的 `moveTab` 只搬**已经在树里**的标签，所以先开进目标组再搬到边缘。
        let id = terminalGroups.openTab({ tab }, in: groupID)
        terminalGroups.moveTab(id, toGroup: groupID, zone: zone)
        return true
    }

    /// 把上次留下的 SSH 会话放回来（窗格 id 就是会话 id，连接时接回）。已经在标签树里的（快照恢复的）跳过。
    func adoptHeldSessions(_ sessions: [SSHSessionRestorer.Session]) {
        let existing = Set(terminalGroups.allTabs.map(\.payload.id))
        for session in sessions where !existing.contains(session.id) {
            terminalGroups.openTab({
                TerminalTab(payload: self.makePane(id: session.id, serverProfileID: session.serverID, tabTitle: session.title,
                                                   sessionOrder: session.order))
            }, in: nil)
        }
        syncTerminalTitles()
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

    /// 终端区**同时写两份**：
    ///
    /// - 新键 `terminalGroups`：整棵组树（分屏形状 / fraction / 每组的标签顺序 /
    ///   每组前台标签 / 活动组），恢复时逐项还原。走组件的 `snapshot(_:)`。
    /// - 旧键 `tabs` + `activeTabIndex`：**降级回滚通道**（设计文档 §4.2 末条）。
    ///   把组树降维成「一个标签一条 `TabSnapshot`，layout 恒为单叶」——会话一条
    ///   不丢，装回旧版本会看到它们摊成一排窗口级标签，只是分屏形状没了。
    ///   （文档建议的「一个组一条」会把每个组的后台标签整条丢掉，这里不采纳。）
    ///
    /// 两份都**绝不给缺失项回落随机 UUID** —— 那会写进一个不存在的
    /// serverProfileID，恢复出永远「服务器配置已被删除」的终端。文件窗格返回 nil
    /// 直接丢掉（buffer 由 `openFiles` 单独持久化）。
    private func makeSnapshot(agentState: AgentSnapshot) -> WorkspaceSnapshot {
        let groups = terminalGroups.snapshot { tab -> TerminalTabSnapshot? in
            guard tab.payload.fileBuffer == nil else { return nil }
            return TerminalTabSnapshot(serverProfileID: tab.payload.serverProfileID,
                                       title: tab.payload.tabTitle ?? "终端", sessionID: tab.payload.id)
        }

        var activeIdx: Int?
        var tabSnaps: [TabSnapshot] = []
        let activeTabID = terminalGroups.activeTab?.id
        for tab in terminalGroups.allTabs {
            guard tab.payload.fileBuffer == nil else { continue }
            if tab.id == activeTabID {
                activeIdx = tabSnaps.count
            }
            tabSnaps.append(TabSnapshot(
                title: tab.payload.tabTitle ?? "终端",
                layout: .leaf(serverProfileID: tab.payload.serverProfileID)))
        }
        let (openFiles, activeFileIndex) = filePreviewModel.openFileSnapshots()
        return WorkspaceSnapshot(
            tabs: tabSnaps,
            activeTabIndex: activeIdx,
            terminalGroups: groups,
            uiState: uiState,
            fileBrowserPath: fileBrowserModel.snapshotCurrentPath,
            openFiles: openFiles,
            activeFileIndex: activeFileIndex,
            agentState: agentState)
    }
}
