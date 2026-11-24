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
    /// 翻转」，scrollback 两种取法都不丢（`GhosttyHostView` 本来就复用
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
    @ObservationIgnored private var defaultServerTitle: String = String(localized: "终端", comment: "终端标签页的默认标题")

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
    @ObservationIgnored private var layoutWriter: HeldLayoutWriter<PaneModel>?
    /// 终端窗口的位置跟布局一起存；接回时照它还原（工作区窗口由系统恢复，不挂它）。
    @ObservationIgnored let windowTracker = HeldWindowTracker()
    /// 终端标签的会话 id（`PaneModel.id`，不是标签 id）；文件标签、Code 标签页不是会话，为 nil。
    /// 手机远控的标签顺序按它（`setTabOrder` / `setArranger`）。
    static let heldSessionID: (TerminalTab) -> UUID? = { $0.payload.isTerminal ? $0.payload.id : nil }

    /// 写进保持进程布局的标签 id：终端标签是会话 id，Code 标签页是它自己的 id（`PaneModel.id`；它是什么、里面跑着
    /// 哪些会话记在 `HeldSessionLayout.codeTabs`），重启后都在原位接回。文件标签不进布局。
    static let layoutTabID: (TerminalTab) -> UUID? = {
        $0.payload.isTerminal || $0.payload.codeTab != nil ? $0.payload.id : nil
    }

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
        terminalGroups.onTabRemoved = { [weak self] removed, remaining in
            removed.payload.dispose()
            // 终端区里由终端打开的文件：最后一个引用它的标签关掉时放掉文档（克隆出来的标签共用同一个）。
            if let buffer = removed.payload.fileBuffer,
               !remaining.contains(where: { $0.payload.fileBuffer === buffer }) {
                self?.filePreviewModel.releaseDetached(buffer.id)
            }
        }
        // 组内唯一标签拖到本组边缘 → 克隆。终端标签克隆 = 同服务器新开一条会话；
        // 文件标签克隆 = 同一个 buffer 再挂一份（对齐旧 `insertPane(copying:)`）。
        terminalGroups.cloneTab = { [weak self] tab in
            // Code 标签页克隆 = 同一台主机再开一个（空的，各自独立）。
            if let code = tab.payload.codeTab {
                return self?.makeCodeTab(serverID: tab.payload.serverProfileID, hostName: code.hostName,
                                         directory: code.newSessionDirectory)
            }
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
        // 布局写进每条 SSH 会话的 holder 归属：重启后没有工作区快照可用时（纯终端窗口、关了自动恢复）
        // 按它放回标签的顺序与分屏。文件标签不是会话，不进布局。
        // Code 标签页记成它自己的 id，里面跑着哪些会话记在 `codeTabs`：重启后它和里面的会话回到原位。
        let layoutWriter = HeldLayoutWriter(groups: terminalGroups, id: Self.layoutTabID, codeTabs: { [weak self] in
            self?.codeTabRecords() ?? []
        }) { [weak self] layout in
            // Code 标签页里跑着的会话也各存一份：窗口里只剩它们时也接得回来。
            for pane in self?.terminalPanes ?? [] { pane.updateLayout(layout) }
        }
        windowTracker.onChange = { [weak layoutWriter] in layoutWriter?.noteWindow($0) }
        self.layoutWriter = layoutWriter
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
        layoutWriter?.stop(flushingPending: TerminalQuitPolicy.shared.isQuitting)
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
        // 终端区开文件用的 SFTP 会话（共享连接池里的租约）一并归还。
        let providers = Array(fileProviders.values)
        fileProviders.removeAll()
        makeFileProvider = nil
        Task { for provider in providers { await provider.close() } }
        telemetryModel.stop()
    }

    /// 每次向工作区 Agent 发送消息时使用的实时上下文。活动文件来自预览模型，因而
    /// 切换编辑标签或分屏焦点后，Agent 能直接定位当前窗口对应的远端绝对路径。
    func assistantContext(for server: ServerProfile) -> String {
        var lines = [String(localized: "主机：\(server.name)（\(server.displayEndpoint)）",
                            comment: "附给 Agent 的上下文：当前主机名与地址")]
        if let path = filePreviewModel.activeBuffer?.remotePath {
            lines.append(String(localized: "当前文件：\(path)", comment: "附给 Agent 的上下文：当前打开的远端文件"))
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
        guard let pane = terminalGroups.activeTab?.payload else { return nil }
        // Code 标签页：右边正显示的那个终端；看着记录时没有。
        if let code = pane.codeTab { return (code.displayedTerminal as? PaneModel)?.session }
        return pane.session
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
        for pane in terminalPanes { pane.adopt(registrar: registrar) }
        // 手机远控关标签时「同时关闭 Mac 上的终端」走这里。
        registry.setCloser(forWindow: windowID) { [weak self] paneID in
            self?.closeTerminal(paneID: paneID) ?? false
        }
        // 点系统通知回到标签走这里。
        registry.setRevealer(forWindow: windowID) { [weak self] paneID in
            self?.revealTerminal(paneID: paneID) ?? false
        }
        // 手机远控按 Mac 上的标签顺序排标签：取写进 holder 的同一份布局。
        registry.setTabOrder(forWindow: windowID) { [weak self] in
            self?.terminalGroups.snapshot(Self.heldSessionID).tabOrder ?? []
        }
        // 手机远控上亲手排过 Mac 的标签：这个窗口跟着排。
        registry.setArranger(forWindow: windowID) { [weak self] order in
            self?.terminalGroups.arrangeTabs(by: order, id: Self.heldSessionID)
        }
        syncTerminalTitles()
    }

    /// 关掉某个终端窗格所在的标签（`onTabRemoved` 会 dispose 它、断开连接）。返回 false = 没有这个窗格。
    @discardableResult
    func closeTerminal(paneID: UUID) -> Bool {
        if let (_, code) = codeTab(running: paneID) { return code.end(paneID) }
        guard terminalGroups.allTabs.contains(where: { $0.payload.id == paneID }) else { return false }
        terminalGroups.closeTabs { $0.payload.id == paneID }
        return true
    }

    /// 把某个终端窗格的标签切到前台并带出窗口。返回 false = 没有这个窗格。
    /// 窗口要在切标签前取：目标标签的视图这时可能还没挂上去，组里正显示的那些才在窗口里。
    @discardableResult
    func revealTerminal(paneID: UUID) -> Bool {
        let window = terminalPanes.lazy.compactMap { $0.session.ghostty.view.window }.first
        // Code 标签页里跑着的会话：切到那个标签页，右边换成它的终端。
        if let (tab, code) = codeTab(running: paneID), let at = terminalGroups.locateTab(tab.id) {
            terminalGroups.activateTab(groupID: at.groupID, index: at.index)
            code.selectRun(paneID)
            window?.bringToFront()
            return true
        }
        guard let tab = terminalGroups.allTabs.first(where: { $0.payload.id == paneID }),
              let at = terminalGroups.locateTab(tab.id) else { return false }
        terminalGroups.activateTab(groupID: at.groupID, index: at.index)
        window?.bringToFront()
        return true
    }

    /// 某个窗格所在标签打开时定下的名字（`PaneModel.tabTitle`），没有则 nil。
    /// `TerminalSessionRegistrar` 的 title 钩子就查它。
    func tabTitle(paneID: UUID) -> String? {
        terminalPanes.first { $0.id == paneID }?.tabTitle
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
        for pane in terminalPanes {
            guard let title = pane.tabTitle ?? pane.connectedServerName else { continue }
            registrar.registry.update(id: pane.id, title: title)
        }
    }

    /// 当前前台的**终端**会话 id（文件窗格不算，返回 nil）。
    /// `TerminalRegistryBinding` 用它做 `onChange` 的观察源 —— 那边不想 import
    /// `UPaneGroups` 只为拿一个 `activeTab`。
    var focusedTerminalSessionID: UUID? {
        guard let pane = terminalGroups.activeTab?.payload else { return nil }
        if let code = pane.codeTab {
            guard case .terminal(let id) = code.detail else { return nil }
            return id
        }
        return pane.fileBuffer == nil ? pane.id : nil
    }

    /// 当前前台**终端**标签连的服务器（文件窗格不算，返回 nil）。终端窗口的标签可连不同
    /// 主机，标题栏 / 端口转发 / Agent 按它跟随活动标签。
    /// Code 标签页算它那台主机。
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
    private func makePane(id: UUID? = nil, serverProfileID: UUID, fileBuffer: FileBuffer? = nil,
                          codeTab: CodeTabModel? = nil, tabTitle: String? = nil,
                          sessionOrder: Double? = nil) -> PaneModel {
        let pane = PaneModel(id: id ?? UUID(), serverProfileID: serverProfileID, fileBuffer: fileBuffer, codeTab: codeTab,
                             tabTitle: tabTitle, sessionOrder: sessionOrder ?? Date().timeIntervalSince1970)
        stamp(pane)
        return pane
    }

    private func stamp(_ pane: PaneModel) {
        pane.registrar = sessionRegistrar
        let serverID = pane.serverProfileID, paneID = pane.id
        pane.session.onFilePreviewRequest = { [weak self] path in
            self?.terminalRequestedPreview(path, serverID: serverID, fromPane: paneID)
        }
    }

    /// 本窗口有预览区（工作区窗口）：侧栏连着的那台主机上的终端请求打开的文件开在预览区。
    @ObservationIgnored var acceptsTerminalFilePreviews = false

    /// 按主机建一条 SFTP 会话，给终端区里由终端打开的文件读写用（窗口视图注入：要 ModelContainer；走共享连接池，
    /// 和那台主机的终端共用一条 SSH 连接）。没注入时终端区不开文件。
    @ObservationIgnored var makeFileProvider: ((UUID) async throws -> any SFTPProviding)?
    @ObservationIgnored private var fileProviders: [UUID: any SFTPProviding] = [:]

    /// 终端里的程序请在旁边预览一个文件（`TerminalFilePreview`），或用户 ⌘ 点了终端里的路径。
    ///
    /// - 工作区窗口、终端连的正是侧栏那台主机：文件开在预览区的预览标签，目录在侧栏打开。
    /// - 其余情况（纯终端窗口；工作区里连别的主机的终端）：文件以临时标签开在终端区，放在发起那个终端旁边的组里
    ///   （只有一组就往右分出一组），按那个终端自己的主机读。目录不处理。
    ///
    /// 都不抢键盘焦点（用户还在终端里和程序对话）；不存在的不理（链接正则会把正文里像路径的词也认成链接）。
    func terminalRequestedPreview(_ rawPath: String, serverID: UUID, fromPane paneID: UUID? = nil) {
        // 终端给的是服务器上的原样文字；主机的文件 provider（`SFTPSession`）认的是 `RemoteName` 写法，换过去，
        // 名字里本来就有 U+2060 的文件才不会被还原成别的字节。
        let path = RemoteName.display(rawPath.utf8)
        if acceptsTerminalFilePreviews, fileBrowserModel.connectedHost?.id == serverID,
           let sftp = fileBrowserModel.sftpProvider {
            Task {
                guard let stat = try? await sftp.stat(path) else { return }
                switch TerminalLinkTarget.kind(stat) {
                case .directory: await fileBrowserModel.load(path)
                case .file: await filePreviewModel.reveal(path: path)
                case .other: return   // FIFO、设备：读了会卡住侧栏共用的 SFTP 会话
                }
            }
            return
        }
        guard makeFileProvider != nil else { return }
        Task { await openInTerminalArea(path, serverID: serverID, besidePane: paneID) }
    }

    /// `makeFileProvider` 的正式实现：按主机 id 取已保存的主机，经共享连接池建 SFTP 会话。主机密钥这时早已信任过
    /// （终端连得上）；对不上就失败，不在这里弹信任框。
    static func liveFileProvider(container: ModelContainer) -> (UUID) async throws -> any SFTPProviding {
        { serverID in
            let descriptor = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.id == serverID })
            guard let profile = try container.mainContext.fetch(descriptor).first else {
                throw CancellationError()
            }
            return try await SFTPSession.make(profile: profile, container: container, approver: { _ in false },
                                              approvesInteractively: false)
        }
    }

    /// `connectCodeRun` 的正式实现：按主机 id 取已保存的主机去连（同终端标签页的面板）。主机被删了就标成失败。
    static func liveCodeRunConnector(container: ModelContainer) -> (PaneModel) -> Void {
        { pane in
            let serverID = pane.serverProfileID
            let descriptor = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.id == serverID })
            guard let profile = try? container.mainContext.fetch(descriptor).first else {
                pane.markServerMissing()
                return
            }
            Task { await pane.connect(profile: profile, modelContainer: container) }
        }
    }

    private func fileProvider(for serverID: UUID) async -> (any SFTPProviding)? {
        if let cached = fileProviders[serverID] { return cached }
        guard let make = makeFileProvider, let provider = try? await make(serverID) else { return nil }
        if let raced = fileProviders[serverID] {
            await provider.close()
            return raced
        }
        fileProviders[serverID] = provider
        return provider
    }

    /// 终端区里开文件，见 `terminalRequestedPreview`。
    func openInTerminalArea(_ path: String, serverID: UUID, besidePane paneID: UUID?) async {
        guard let sftp = await fileProvider(for: serverID) else { return }
        guard let stat = try? await sftp.stat(path), TerminalLinkTarget.isOpenableFile(stat) else { return }
        let sourceTabID = paneID.flatMap { id in terminalGroups.allTabs.first { $0.payload.id == id }?.id }
        let source = sourceTabID.flatMap { terminalGroups.locateTab($0) }

        // 已经开着：带到它那一组的前台并重读（程序刚改过它）。
        if let existing = terminalGroups.allTabs.first(where: {
            $0.payload.serverProfileID == serverID && $0.payload.fileBuffer?.remotePath == path
        }), let at = terminalGroups.locateTab(existing.id), let buffer = existing.payload.fileBuffer {
            terminalGroups.activateTab(groupID: at.groupID, index: at.index)
            restoreFocus(to: sourceTabID)
            await filePreviewModel.reloadDetached(buffer)
            return
        }

        let buffer = await filePreviewModel.openDetached(path: path, provider: sftp)
        // 放进发起那个终端以外的组；只有一组时先开在本组，再挪到本组右边缘分出一组（不会顺带开一个新终端）。
        let otherGroup = terminalGroups.groupIDs.first { $0 != source?.groupID }
        let targetGroup = otherGroup ?? source?.groupID ?? terminalGroups.activeGroupID
        let displaced = targetGroup.flatMap { terminalGroups.groups[$0]?.tabs.first(where: \.isTransient)?.payload }
        let tabID = terminalGroups.openTab({ TerminalTab(payload: self.makePane(serverProfileID: serverID,
                                                                                  fileBuffer: buffer)) },
                                           asTransient: true, in: targetGroup)
        // 被顶替的临时标签是就地覆盖的，组件不发 `onTabRemoved`：它的文档在这里放掉。
        if let displaced, let old = displaced.fileBuffer,
           !terminalGroups.allTabs.contains(where: { $0.payload.fileBuffer === old }) {
            filePreviewModel.releaseDetached(old.id)
        }
        if otherGroup == nil, let group = targetGroup, (terminalGroups.groups[group]?.tabs.count ?? 0) > 1 {
            terminalGroups.moveTab(tabID, toGroup: group, zone: .trailing)
        }
        restoreFocus(to: sourceTabID)
    }

    /// 发起的那个终端回到它那一组的前台、那一组回到活动组（键盘焦点、标题栏跟着它）。
    private func restoreFocus(to tabID: UUID?) {
        guard let tabID, let at = terminalGroups.locateTab(tabID) else { return }
        terminalGroups.activateTab(groupID: at.groupID, index: at.index)
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

    /// 用户要关一个终端标签：前台还有程序在跑时先确认。程序化的关闭（手机远控、CLI）走
    /// `closeTerminal(paneID:)`，那边已经由发起方确认过。
    func requestCloseTerminalTab(_ tabID: UUID) {
        guard let tab = terminalGroups.allTabs.first(where: { $0.id == tabID }) else { return }
        if let code = tab.payload.codeTab {
            // Code 标签页：里面跑着的会话有前台程序时问一次，确认后一起结束（`onTabRemoved` → `CodeTabModel.close`）。
            TerminalCloseGuard.requestClose(code.terminals.compactMap { ($0 as? PaneModel)?.session }, tabName: TerminalArea.codeTabBaseTitle) { [weak self] in
                guard let self, let at = terminalGroups.locateTab(tabID) else { return }
                terminalGroups.closeTab(groupID: at.groupID, index: at.index)
            }
            return
        }
        if let buffer = tab.payload.fileBuffer {
            // 文件标签：没有程序要问，要问的是改过没存的内容。别处（另一个标签、预览区）还开着同一个文档就直接关。
            let elsewhere = terminalGroups.allTabs.contains { $0.id != tabID && $0.payload.fileBuffer === buffer }
                || filePreviewModel.panes.allTabs.contains { $0.payload === buffer }
            let close: @MainActor () -> Void = { [weak self] in
                guard let self, let at = terminalGroups.locateTab(tabID) else { return }
                terminalGroups.closeTab(groupID: at.groupID, index: at.index)
            }
            if elsewhere { close() } else { filePreviewModel.closeAfterSaving(buffer, close: close) }
            return
        }
        let pane = tab.payload
        let tabName = pane.session.shellTitle ?? pane.tabTitle ?? pane.connectedServerName
        TerminalCloseGuard.requestClose(pane.session, tabName: tabName) { [weak self] in
            // 确认期间标签可能被拖到别的组、或已经被关掉，到这时再定位。
            guard let self, let at = terminalGroups.locateTab(tabID) else { return }
            terminalGroups.closeTab(groupID: at.groupID, index: at.index)
        }
    }

    /// 终端区前台的文件标签的文档（终端窗口里 ⌘S 没带文档 id 时存它）。
    var activeTerminalFileBufferID: UUID? { terminalGroups.activeTab?.payload.fileBuffer?.id }

    /// ⌘W / 命令面板。活动组是空的时没有会话要问，直接收掉空组。
    func requestCloseActiveTerminalTab() {
        if let tab = terminalGroups.activeTab {
            requestCloseTerminalTab(tab.id)
        } else {
            _ = closeActiveTerminalTab()
        }
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
    ///
    /// 布局里记着的 Code 标签页也开回来（里面没有会话在跑的也开），记在它名下、还活着的会话回到它里面，不再各开一个
    /// 终端标签页；工具认不出来的照普通终端标签页接回，不丢。`knownServerIDs` 非空时，主机已经删了的 Code 标签页不开
    ///（会话本身由 `SSHSessionRestorer` 按同一张表筛过）。
    func adoptHeldSessions(_ sessions: [SSHSessionRestorer.Session], knownServerIDs: Set<UUID> = []) {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func makeSessionPane(_ id: UUID) -> PaneModel {
            let session = byID[id]!
            return makePane(id: session.id, serverProfileID: session.serverID, tabTitle: session.title,
                            sessionOrder: session.order)
        }
        func tab(_ id: UUID) -> TerminalTab { TerminalTab(payload: makeSessionPane(id)) }
        // 工作区快照已经放好了布局的话，快照为准（Code 标签页插到它在布局里的邻居旁边）；否则（纯终端窗口、
        // 关了自动恢复）按会话自己存的布局放回。
        let layout = HeldSessionLayout.newest(sessions.map(\.layout))
        let present = Set(terminalPanes.map(\.id))
        let codeTabs = (layout?.codeTabs ?? []).filter { record in
            guard let host = record.host else { return false }
            return knownServerIDs.isEmpty || knownServerIDs.contains(host)
        }
        let codeRuns = CodeTabRecord.adoptableRuns(codeTabs, live: Set(byID.keys).subtracting(present))
        let inCodeTabs = Set(codeRuns.values.flatMap { $0.map(\.session) })
        let records = Dictionary(codeTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func codeTab(_ id: UUID) -> TerminalTab? {
            guard let record = records[id], let host = record.host else { return nil }
            let tab = makeCodeTab(id: id, serverID: host, hostName: record.hostName ?? "", directory: record.directory)
            var terminals: [UUID: any CodeTabTerminal] = [:]
            for run in codeRuns[id] ?? [] { terminals[run.session] = makeSessionPane(run.session) }
            tab.payload.codeTab?.restore(record, terminals: terminals)
            return tab
        }
        let applied = terminalGroups.adoptHeldSessions(
            sessions.map(\.id).filter { !inCodeTabs.contains($0) && !present.contains($0) }, layout: layout,
            id: Self.layoutTabID, make: tab,
            append: { id in terminalGroups.openTab({ tab(id) }, in: nil) },
            extras: codeTabs.map(\.id), makeExtra: codeTab)
        // 窗口只有挂了 `HeldWindowTrackerBinding`（纯终端窗口）才会被摆；工作区窗口的位置归系统恢复。
        if applied { windowTracker.restore(layout?.window) }
        syncTerminalTitles()
    }

    /// 窗格平时要等显示出来才连接，后台标签就一直不连。接回不一样：不握手，几乎没有成本，而且没接回之前
    /// 手机和 CLI 看不到这条会话，退出时「全部结束」也关不到它。所以恢复时不等显示，立刻接回。
    func reattachHeldSessions(_ sessions: [SSHSessionRestorer.Session], profiles: [ServerProfile], modelContainer: ModelContainer) {
        // Code 标签页里接回的会话也在这里连（`terminalPanes` 含它们）。
        for session in sessions {
            guard let pane = terminalPanes.first(where: { $0.id == session.id }),
                  let profile = profiles.first(where: { $0.id == session.serverID }) else { continue }
            Task { await pane.connect(profile: profile, modelContainer: modelContainer) }
        }
    }

    // MARK: - Code 标签页

    /// 窗口里所有的终端会话：终端标签页，加上 Code 标签页里跑着的（它们不在标签树里）。
    var terminalPanes: [PaneModel] {
        terminalGroups.allTabs.flatMap { tab -> [PaneModel] in
            if let code = tab.payload.codeTab { return code.runs.compactMap { $0.terminal as? PaneModel } }
            return tab.payload.isTerminal ? [tab.payload] : []
        }
    }

    /// 关窗口前要问的那些终端会话。
    var terminalSessions: [TerminalSession] { terminalPanes.map(\.session) }

    /// Code 标签页里的会话连主机（窗口视图注入：要 ModelContainer）。没注入（测试、画廊）时由右边的面板显示出来时去连。
    @ObservationIgnored var connectCodeRun: ((PaneModel) -> Void)?

    /// 在 `groupID`（默认活动组）开一个 `serverID` 的 Code 标签页并设为前台。`directory` 是「＋」新会话默认的目录。
    @discardableResult
    func openCodeTab(serverID: UUID, hostName: String, directory: String?, in groupID: UUID? = nil) -> UUID {
        terminalGroups.openTab({ self.makeCodeTab(serverID: serverID, hostName: hostName, directory: directory) },
                               in: groupID)
    }

    /// 标签条上的 Code 按钮 / ⌘K：开那个组（默认活动组）前台标签页所在主机的 Code 标签页；组里一个标签页都没有时开
    /// `fallbackServerID`（本窗口绑定的那台，同「＋」）。目录取前台终端的当前目录。`hostName` 由主机 id 查名字。
    @discardableResult
    func openCodeTab(in groupID: UUID? = nil, fallbackServerID: UUID, hostName: (UUID) -> String) -> UUID {
        let group = groupID ?? terminalGroups.activeGroupID
        let front = group.flatMap { terminalGroups.groups[$0]?.activeTab?.payload } ?? terminalGroups.activeTab?.payload
        let serverID = front?.serverProfileID ?? fallbackServerID
        return openCodeTab(serverID: serverID, hostName: hostName(serverID),
                           directory: front.flatMap { Self.codeDirectory(of: $0) }, in: group)
    }

    /// 终端标签页右键「历史会话…」：这个组里已经有同一台主机的 Code 标签页就切过去，没有就新开一个；列表定位到那个终端所在目录的那一组。
    func showCodeTab(for pane: PaneModel, hostName: String) {
        guard let tab = terminalGroups.allTabs.first(where: { $0.payload === pane }),
              let at = terminalGroups.locateTab(tab.id) else { return }
        let directory = Self.codeDirectory(of: pane)
        if let existing = terminalGroups.groups[at.groupID]?.tabs.first(where: {
            $0.payload.codeTab != nil && $0.payload.serverProfileID == pane.serverProfileID
        }), let code = existing.payload.codeTab, let target = terminalGroups.locateTab(existing.id) {
            if let directory { code.newSessionDirectory = directory }
            code.requestReveal(directory: directory)
            terminalGroups.activateTab(groupID: target.groupID, index: target.index)
            return
        }
        let id = openCodeTab(serverID: pane.serverProfileID, hostName: hostName, directory: directory, in: at.groupID)
        terminalGroups.tab(id)?.payload.codeTab?.requestReveal(directory: directory)
    }

    /// 「移到新标签页」：把 Code 标签页里跑着的一个会话开成同一组里的普通终端标签页（同一条会话，不重开）。
    func moveCodeRunToTab(_ runID: UUID, fromCodeTab tabID: UUID) {
        guard let code = terminalGroups.tab(tabID)?.payload.codeTab, let at = terminalGroups.locateTab(tabID),
              let pane = code.detach(runID) as? PaneModel else { return }
        terminalGroups.openTab({ TerminalTab(id: pane.id, payload: pane) }, in: at.groupID)
        syncTerminalTitles()
    }

    /// 跑着 `paneID` 这个会话的 Code 标签页。
    func codeTab(running paneID: UUID) -> (tab: TerminalTab, code: CodeTabModel)? {
        for tab in terminalGroups.allTabs {
            if let code = tab.payload.codeTab, code.runs.contains(where: { $0.id == paneID }) { return (tab, code) }
        }
        return nil
    }

    private func makeCodeTab(id: UUID = UUID(), serverID: UUID, hostName: String, directory: String?) -> TerminalTab {
        let code = CodeTabModel(hostName: hostName, directory: directory) { [weak self] _ in
            self?.makeCodeRun(serverID: serverID, hostName: hostName)
        }
        return TerminalTab(payload: makePane(id: id, serverProfileID: serverID, codeTab: code, tabTitle: hostName))
    }

    /// 存进布局的 Code 标签页（`HeldSessionLayout.codeTabs`），id 是它的 `PaneModel.id`（同 `layoutTabID`）。
    func codeTabRecords() -> [CodeTabRecord] {
        terminalGroups.allTabs.compactMap { tab in
            tab.payload.codeTab?.record(id: tab.payload.id, host: tab.payload.serverProfileID)
        }
    }

    /// Code 标签页里继续 / 新开一个会话的终端：和普通标签页一样登记、写保持进程的归属，只是不进标签树。
    /// SSH 的新终端从主目录起，命令自己带 `cd`，所以不用目录。
    private func makeCodeRun(serverID: UUID, hostName: String) -> PaneModel {
        let pane = makePane(serverProfileID: serverID, tabTitle: hostName)
        connectCodeRun?(pane)
        syncTerminalTitles()
        return pane
    }

    /// 终端标签页的当前目录（Code 标签页取它记着的）。shell 没报过（没有 OSC 7）为 nil。
    private static func codeDirectory(of pane: PaneModel) -> String? {
        if let code = pane.codeTab { return code.newSessionDirectory }
        guard pane.isTerminal else { return nil }
        return ClaudeProjectPath.directory(fromOSC7: pane.session.shadow.workingDirectory)
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
            guard tab.payload.isTerminal else { return nil }
            return TerminalTabSnapshot(serverProfileID: tab.payload.serverProfileID,
                                       title: tab.payload.tabTitle ?? String(localized: "终端", comment: "终端标签页的默认标题"),
                                       sessionID: tab.payload.id)
        }

        var activeIdx: Int?
        var tabSnaps: [TabSnapshot] = []
        let activeTabID = terminalGroups.activeTab?.id
        for tab in terminalGroups.allTabs {
            guard tab.payload.isTerminal else { continue }
            if tab.id == activeTabID {
                activeIdx = tabSnaps.count
            }
            tabSnaps.append(TabSnapshot(
                title: tab.payload.tabTitle ?? String(localized: "终端", comment: "终端标签页的默认标题"),
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
