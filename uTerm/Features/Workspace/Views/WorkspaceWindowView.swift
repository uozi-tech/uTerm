import UDesignKit
import SwiftUI
import SwiftData

/// 一个工作区窗口：绑定单台服务器（由 `WorkspaceWindowID` 指定）。
/// 三栏布局：左 SFTPSidebar（NavigationSplitView 的 sidebar）/ 中 WorkspaceCenter
/// （NavigationSplitView 的 detail）/ 右 AgentSidebar（.inspector）。
struct WorkspaceWindowView: View {
    let windowID: WorkspaceWindowID?

    @Query private var profiles: [ServerProfile]
    @Query(sort: \AIProvider.sortOrder) private var providers: [AIProvider]
    @AppStorage("activeProviderID") private var activeProviderIDString: String = ""
    @AppStorage("restoreTerminalSession") private var restoreTerminalSession = true
    @State private var workspace: WorkspaceModel
    @State private var didRestore = false
    /// 大文件确认 / 阻断 sheet 的状态（Spec 2A §1.5 / §7）。
    @State private var largeFileConfirm: LargeFileConfirm?
    @State private var blockedFile: BlockedFile?
    @State private var palette = CommandPaletteModel()
    /// 用于把全局 CommandGroup 通知限定到当前 key window —— 多窗口下避免后台窗口
    /// 也被切换。`.controlActiveState` 在窗口为 key 时为 `.key`。
    @Environment(\.modelContext) private var modelContext
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow
    /// 全局端口转发协调器（由 App 根注入）。标题栏读活跃隧道数；打开管理窗用 openWindow。
    @Environment(ForwardingCoordinator.self) private var forwarding

    init(windowID: WorkspaceWindowID?) {
        self.windowID = windowID
        // @State 初值在 init 时构造一次；用 windowID 让 FilePreviewModel
        // 拿到正确的 RecentFilesStore 命名（按服务器范围）。
        self._workspace = State(initialValue: WorkspaceModel(windowID: windowID))
    }

    private struct LargeFileConfirm: Identifiable {
        let id = UUID()
        let path: String
        let size: Int64
        let mtime: Date?
        /// 确认后按原打开方式（单击预览 / 双击永久）继续。
        let asPreview: Bool
    }
    private struct BlockedFile: Identifiable {
        let id = UUID()
        let path: String
        let size: Int64
    }

    /// 本窗口绑定的服务器（按 `windowID.serverID` 查；查不到 = 已删除）。
    private var server: ServerProfile? {
        guard let id = windowID?.serverID else { return nil }
        return profiles.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let windowID {
                if let server {
                    workspaceBody(server: server, windowID: windowID)
                } else {
                    // 有窗口身份但查不到服务器 —— 该服务器已被删除。
                    ContentUnavailableView("服务器已删除", systemImage: "server.rack")
                }
            } else {
                // windowID 尚未注入（macOS 窗口状态恢复过程中的瞬态）。
                ContentUnavailableView("正在恢复…", systemImage: "clock")
            }
        }
        // .frame(minWidth:) 必须挂在 body 最外层，否则 ContentUnavailableView
        // 路径（server 已删除 / windowID 恢复中）会渲染没有 min-size 约束，
        // NSWindow.contentMinSize 从那一帧的 intrinsic content 推上去 → 远小于
        // 1280×720，窗口可被拖到任意小。
        //
        // 1280pt 选定理由：sidebar.max(240) + detail.min(480) + inspector.max(360)
        // = 1080，splitter + chrome 几十 pt，windowMin 1280 留 ~195pt 缓冲。
        //
        // 注意：不要再加 .windowResizability(.contentMinSize) on scene
        //（macOS 26 实测它把 NSWindow.styleMask 的 .resizable 抹掉）。
        .frame(minWidth: 1280, minHeight: 720)
    }

    @ViewBuilder
    private func workspaceBody(server: ServerProfile,
                               windowID: WorkspaceWindowID) -> some View {
        let chromeTitle = serverChromeTitle(for: server)
        VStack(spacing: 0) {
            // 自绘标题栏（替代系统 toolbar）：左「文件」开关 / 居中服务器名 + 状态
            // 胶囊 / 右 Agent 开关。彻底脱离系统 toolbar 及其 Liquid Glass。
            WorkspaceTitleBar(
                serverName: chromeTitle,
                session: workspace.focusedTerminalSession(),
                activeForwardCount: forwarding.activeCount(forServer: server.id),
                onToggleSidebar: {
                    withAnimation(.easeInOut(duration: 0.18)) { workspace.toggleLeftSidebar() }
                },
                onToggleInspector: {
                    withAnimation(.easeInOut(duration: 0.18)) { workspace.toggleRightInspector() }
                },
                onOpenForwarding: {
                    openWindow(value: PortForwardWindowID(id: UUID(), serverID: server.id))
                },
                onOpenSettings: { openWindow(id: SettingsWindow.id) })

            // 自绘三栏（替代 NavigationSplitView + .inspector）：列宽 / 折叠态进
            // uiState 持久化。center 显式 minWidth(480) + 列宽 clamp 保证
            // sidebar.max(320) + inspector.max(420) + 480 = 1220 ≤ windowMin(1280)，
            // 永不 overflow 裁切。
            WorkspaceColumns(
                sidebarVisible: workspace.uiState.leftSidebarVisible,
                inspectorVisible: workspace.uiState.rightInspectorPresented,
                sidebarWidth: Binding(
                    get: { workspace.uiState.sidebarWidth },
                    set: { workspace.uiState.sidebarWidth = $0 }),
                inspectorWidth: Binding(
                    get: { workspace.uiState.inspectorWidth },
                    set: { workspace.uiState.inspectorWidth = $0 })
            ) {
                SFTPSidebar(model: workspace.fileBrowserModel, server: server)
            } center: {
                WorkspaceCenter(workspace: workspace, server: server,
                                onRequestCloseBuffer: { requestCloseBuffer($0) })
                    .frame(minWidth: 480)
            } inspector: {
                AgentSidebar(
                    model: workspace.assistantModel,
                    serverContext: workspace.assistantContext(for: server),
                    serverName: server.name,
                    activeProviderIDString: $activeProviderIDString)
            }

            // status bar 作为兄弟节点（非 safeAreaInset）—— SwiftTerm NSView 会渲染到
            // inset 区域下面挡住末行（issue 反馈）。
            Rectangle().fill(UD.border).frame(height: 1)
            StatusBarView(workspace: workspace)
        }
        // 让内容延伸到标题栏区域之下（配合 WorkspaceWindowChrome 的
        // .fullSizeContentView）—— 否则 SwiftUI 顶部安全区 inset 会把自绘标题栏
        // 顶到系统标题栏下方，形成「红绿灯一条 + 自绘标题栏一条」的双栏割裂。
        // 忽略顶部安全区后，自绘 38px 标题栏占住标题栏区，红绿灯叠在其左侧留白上。
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        // 自绘窗口 chrome：透明标题栏 + full-size content + 不透明 WS 底 + 深色外观 +
        // 标题栏（WindowDragHandle）可拖移窗口。无系统 toolbar / NavigationSplitView ⇒
        // 不可能再有系统玻璃。
        .background(WorkspaceWindowChrome(serverName: chromeTitle))
        // ⌘W：仅工作区窗口接管，按焦点先关内容、最后关窗口（见 handleCloseShortcut）。
        .background(WorkspaceCloseShortcutInstaller { window in
            handleCloseShortcut(window: window)
        })
        // host-key sheet 放在 NavigationSplitView 根，sidebar 折叠时也能弹（Fix #2）。
        // SFTPSidebar 不再自挂 sheet —— 二处同名 sheet 会互相抢占。
        .hostKeySheet(workspace.fileBrowserModel.hostKeyRelay)
        .commandPalette(model: palette,
                        searchProvider: workspaceFileSearch()) {
            workspaceCommandItems(server: server)
        }
        .task {
            // 仅首次执行：载入本窗口的持久化布局，无则开一个默认终端标签。
            // 在原 workspace 实例上 mutate（不再替换实例）—— SFTPSidebar 的
            // .task(id: server.id) 持有的 fileBrowserModel 引用因此稳定，
            // 修复「快照恢复后 SFTP 永久停在 .connecting」的卡死（Fix #1）。
            //
            // restoreTerminalSession (spec 02): false 时跳过 snapshot.load()，
            // 直接开空白单 tab。但保存逻辑（onChange）不动——用户切回 ON 时
            // 能复现最近一次状态。
            guard !didRestore else { return }
            didRestore = true
            if restoreTerminalSession, let snapshot = WorkspaceStore(windowID: windowID).load() {
                workspace.restore(from: snapshot)
            } else {
                workspace.openServer(profileID: server.id, title: server.name)
            }
            await workspace.connectSharedSFTP(profile: server, modelContainer: modelContext.container)
            if workspace.fileBrowserModel.state == .browsing {
                await workspace.filePreviewModel.loadRestoredBuffersIfNeeded()
            }
        }
        // 窗口关闭时释放资源（Fix #8）。WorkspaceModel.dispose 关闭 SFTP 会话
        // 与所有终端 session。SwiftUI 在 view 离开层级时调 onDisappear，
        // 而正常 re-render 不会触发，故此处是安全的窗口生命周期挂点。
        // 遥测轮询：start() 幂等且独立于视图生命周期；窗口关闭 dispose→stop。
        .task { workspace.telemetryModel.start() }
        // Agent run_command 真实执行器：每台服务器解析一次认证材料并注入。
        // 解析失败（缺密码 / 私钥等）→ try? 吞掉、executor 留 nil → Agent 不提供工具。
        .task(id: server.id) {
            workspace.assistantModel.executor = (try? WorkspaceCommandExecutorFactory.make(
                server: server, container: modelContext.container))?.executor
        }
        // 快捷命令「AI 介入」运行入口：欢迎页把命令入队 QuickCommandInbox 并打开本窗口。
        // 抽成独立 ViewModifier —— 内联 .task + .onChange 会把本就庞大的 body 推过类型检查上限。
        .modifier(QuickCommandInboxConsumer(workspace: workspace, server: server))
        .onDisappear {
            workspace.dispose()
        }
        // 快照防抖保存 + SFTP 进入 browsing 后恢复预览缓冲。抽成独立 ViewModifier ——
        // 两个内联 .onChange 会把本就庞大的 body 推过类型检查上限。
        .modifier(WorkspaceSnapshotAutosave(workspace: workspace, windowID: windowID))
        // 全局 CommandGroup 通知（分屏 / 折叠 sidebar/inspector / 新建终端标签）会广播到所有
        // 打开的工作区窗口；内部用 controlActiveState == .key 守卫，只让前台窗口响应（Fix #6）。
        // 抽成独立 ViewModifier —— 五个内联 .onReceive 会把本就庞大的 body 推过类型检查上限。
        .modifier(WorkspaceGlobalCommandHandlers(workspace: workspace, server: server))
        // SFTPSidebar 文件 tap → 通知 → 在 PreviewArea 打开。Spec 2A §3.1。
        .onReceive(NotificationCenter.default.publisher(for: .openRemoteFile)) { note in
            guard controlActiveState == .key,
                  let info = note.userInfo,
                  let path = info["path"] as? String else { return }
            let size = info["size"] as? Int64
            let mtime = info["mtime"] as? Date
            let asPreview = (info["preview"] as? Bool) ?? false
            switch WorkspaceRemoteFileOpenGate.decision(forSize: size) {
            case .block:
                guard let size else { return }
                blockedFile = BlockedFile(path: path, size: size)
            case .confirmLargeFile:
                guard let size else { return }
                largeFileConfirm = LargeFileConfirm(path: path, size: size, mtime: mtime,
                                                    asPreview: asPreview)
            case .openDirectly:
                Task {
                    await workspace.filePreviewModel.open(
                        path: path, fileSize: size, mtime: mtime, asPreview: asPreview)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .savePreviewBuffer)) { note in
            guard controlActiveState == .key else { return }
            // 编辑器聚焦时由本地 keyDown 监听器带入正在编辑的 buffer id（分屏下精确保存它，
            // 不被过期的 activeBufferID 误导）；菜单点击 / 非编辑器聚焦时回落到 activeBufferID。
            let requested = note.userInfo?[SavePreviewBufferKey.bufferID] as? UUID
            guard let id = requested ?? workspace.filePreviewModel.activeBufferID else { return }
            // 多窗口下通知会广播到所有工作区窗口：带入的 bufferID 只存在于来源窗口的模型里，
            // 非来源窗口直接忽略（避免对不属于自己的 id 触发一次空保存路径）。
            guard workspace.filePreviewModel.buffers.contains(where: { $0.id == id }) else { return }
            Task { await handleSave(id: id) }
        }
        .confirmationDialog(
            "文件较大，可能卡顿。继续打开？",
            isPresented: Binding(
                get: { largeFileConfirm != nil },
                set: { if !$0 { largeFileConfirm = nil } }),
            presenting: largeFileConfirm) { confirm in
                Button("继续") {
                    Task {
                        await workspace.filePreviewModel.open(
                            path: confirm.path, fileSize: confirm.size, mtime: confirm.mtime,
                            asPreview: confirm.asPreview)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { confirm in
                Text(byteSize(confirm.size))
            }
        .alert(
            "文件太大",
            isPresented: Binding(
                get: { blockedFile != nil },
                set: { if !$0 { blockedFile = nil } }),
            presenting: blockedFile) { blocked in
                Button("外部打开") {
                    Task { await downloadAndOpenExternally(blocked.path) }
                }
                Button("取消", role: .cancel) {}
            } message: { blocked in
                Text("该文件 \(byteSize(blocked.size))，超过 50 MB 上限。建议用外部编辑器。")
            }
        .modifier(AssistantBindingModifier(
            assistant: workspace.assistantModel,
            providers: providers,
            activeProviderIDString: activeProviderIDString))
        // .frame(minWidth:) 在 body 根（见上）。
    }

    private func serverChromeTitle(for server: ServerProfile) -> String {
        ServerChromeTitle.serverTitle(serverName: server.name, groupName: server.group)
    }

    /// 工作区窗口的命令项：主机（连接=当前工作区开新 tab）/ 最近文件 / 命令 / 设置深链。
    @MainActor
    private func workspaceCommandItems(server: ServerProfile) -> [CommandPaletteItem] {
        WorkspaceCommandPaletteFactory.items(
            profiles: profiles,
            workspace: workspace,
            actions: WorkspaceCommandPaletteFactory.Actions(
                openWelcome: { openWindow(id: "welcome") },
                openGroups: { openWindow(id: "groups") },
                openImport: { openWindow(id: "import") },
                openSettings: { openWindow(id: SettingsWindow.id) }))
    }

    /// 注入命令面板的异步文件搜索：query → 远程 find → 命令项（文件→预览、目录→进浏览器）。
    @MainActor
    private func workspaceFileSearch() -> (@MainActor (String) async -> [CommandPaletteItem]) {
        let workspace = self.workspace
        return { query in
            let browser = workspace.fileBrowserModel
            guard let sftp = browser.sftpProvider else { return [] }
            // SFTP 把 "." 解析为会话起始目录（通常是家目录）；失败回落当前浏览路径。
            let home = (try? await sftp.realPath(".")) ?? browser.currentPath
            let hits = (try? await RemoteFileSearch.search(query: query, home: home, provider: sftp)) ?? []
            return hits.map { WorkspaceCommandPaletteFactory.mapHitToItem($0, workspace: workspace) }
        }
    }

    // MARK: 大文件 / 保存 helpers（Spec 2A §1.5）

    /// 关闭一个文件标签；脏文件先弹「保存 / 不保存 / 取消」。⌘W 与标签 X 共用此入口。
    @MainActor
    private func requestCloseBuffer(_ id: UUID) {
        let model = workspace.filePreviewModel
        guard let buf = model.buffers.first(where: { $0.id == id }) else { return }
        guard buf.isDirty else {
            model.close(id, savingIfDirty: false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "是否保存对「\(buf.displayName)」的更改？"
        alert.informativeText = "如果不保存，你的更改将丢失。"
        alert.addButton(withTitle: "保存")        // .alertFirstButtonReturn
        alert.addButton(withTitle: "不保存")      // .alertSecondButtonReturn
        alert.addButton(withTitle: "取消")        // .alertThirdButtonReturn
        switch alert.runModal() {
        case .alertFirstButtonReturn:             // 保存
            Task { @MainActor in
                await handleSave(id: id)          // 既有流程，含远程 mtime 冲突检测与失败提示
                if let b = model.buffers.first(where: { $0.id == id }), !b.isDirty {
                    model.close(id, savingIfDirty: false)   // 仅保存成功才关
                }
            }
        case .alertSecondButtonReturn:            // 不保存
            model.close(id, savingIfDirty: false)
        default:                                  // 取消：什么都不做
            break
        }
    }

    /// ⌘W：按键盘焦点先关当前文件标签 / 终端聚焦窗格；都没有可关时才关窗口。
    @MainActor
    private func handleCloseShortcut(window: NSWindow) {
        let region = WorkspaceCloseShortcut.focusRegion(in: window)
        switch workspace.closeIntent(focusedRegion: region) {
        case .closeFileBuffer(let id):
            requestCloseBuffer(id)
        case .closeTerminalFocusedPane(let tabID):
            guard let tab = workspace.tabs.first(where: { $0.id == tabID }) else { return }
            if let pid = tab.focusedPaneID {
                if !tab.closePane(pid) { workspace.closeTab(tab.id) }   // 关聚焦窗格；最后一个窗格→关标签
            } else {
                workspace.closeTab(tab.id)
            }
        case .closeWindow:
            window.performClose(nil)
        }
    }

    private func byteSize(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    @MainActor
    private func handleSave(id: UUID) async {
        let result = await workspace.filePreviewModel.save(id)
        switch result {
        case .conflict(let remoteMtime):
            let alert = NSAlert()
            alert.messageText = "远程文件已变化"
            alert.informativeText = "远程已被另一处保存。"
            alert.addButton(withTitle: "保留我的（覆盖远程）")
            alert.addButton(withTitle: "用远程的（丢弃本地）")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // 强制覆盖：把 mtimeWhenLoaded 推到远程值绕过 conflict guard
                if let buf = workspace.filePreviewModel.buffers.first(where: { $0.id == id }) {
                    buf.mtimeWhenLoaded = remoteMtime
                }
                _ = await workspace.filePreviewModel.save(id)
            case .alertSecondButtonReturn:
                await workspace.filePreviewModel.reloadFromRemote(id)
            default: break
            }
        case .failed(let msg):
            let alert = NSAlert()
            alert.messageText = "保存失败"
            alert.informativeText = msg
            alert.runModal()
        case .saved, .noop: break
        }
    }

    @MainActor
    private func downloadAndOpenExternally(_ path: String) async {
        guard let sftp = workspace.fileBrowserModel.sftpProvider else { return }
        let basename = (path as NSString).lastPathComponent
        do {
            let data = try await sftp.download(remotePath: path)
            let dest = try ExternalFileStager.stage(data: data, suggestedName: basename)
            NSWorkspace.shared.open(dest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "下载失败"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

}

/// 全局 CommandGroup 通知（分屏 / 折叠 sidebar/inspector / 新建终端标签）的接收端：广播到所有
/// 打开的工作区窗口，用 `controlActiveState == .key` 守卫，只让前台 key 窗口响应（Fix #6）。
/// 抽成独立 ViewModifier —— 一串内联 `.onReceive` 会把本就庞大的 `workspaceBody` 推过类型检查上限。
/// 工作区快照防抖保存（500ms）+ SFTP 进入 `browsing` 后恢复上次会话的预览缓冲。
/// 抽成独立 ViewModifier，避免内联 .onChange 撑爆 `WorkspaceWindowView.body` 的类型检查预算。
private struct WorkspaceSnapshotAutosave: ViewModifier {
    let workspace: WorkspaceModel
    let windowID: WorkspaceWindowID
    @State private var saveTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: workspace.autosaveStructureSnapshot()) { _, _ in scheduleSave() }
            .onChange(of: workspace.assistantModel.input) { _, _ in scheduleSave() }
            .onChange(of: workspace.fileBrowserModel.state) { _, state in
                if case .browsing = state {
                    Task { await workspace.filePreviewModel.loadRestoredBuffersIfNeeded() }
                }
            }
            .onDisappear {
                saveTask?.cancel()
                let snapshot = workspace.snapshot()
                let store = WorkspaceStore(windowID: windowID)
                saveTask = Task {
                    await Task.detached(priority: .utility) {
                        try? store.save(snapshot)
                    }.value
                }
            }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let snapshot = workspace.snapshot()
            let store = WorkspaceStore(windowID: windowID)
            await Task.detached(priority: .utility) {
                try? store.save(snapshot)
            }.value
        }
    }
}

private struct WorkspaceGlobalCommandHandlers: ViewModifier {
    let workspace: WorkspaceModel
    let server: ServerProfile
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .splitFocusedPaneVertical)) { _ in
                guard controlActiveState == .key else { return }
                workspace.activeTab?.splitFocusedPane(direction: .vertical)
            }
            .onReceive(NotificationCenter.default.publisher(for: .splitFocusedPaneHorizontal)) { _ in
                guard controlActiveState == .key else { return }
                workspace.activeTab?.splitFocusedPane(direction: .horizontal)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleLeftSidebar)) { _ in
                guard controlActiveState == .key else { return }
                withAnimation(.easeInOut(duration: 0.18)) { workspace.toggleLeftSidebar() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleRightInspector)) { _ in
                guard controlActiveState == .key else { return }
                withAnimation(.easeInOut(duration: 0.18)) { workspace.toggleRightInspector() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newTerminalTab)) { _ in
                guard controlActiveState == .key else { return }
                workspace.openServer(profileID: server.id, title: server.name)
            }
    }
}

/// 消费 `QuickCommandInbox`：欢迎页「AI 介入」命令运行 → 露出 Agent 检视器并把命令预填进输入框
/// （用户复核后发送）。抽成独立 ViewModifier，避免内联 .task/.onChange 撑爆 `body` 类型检查。
/// 首开走 `.task`；窗口已开则靠 `onChange(serial)` 消费（仿 `ImportInbox`→`SSHConfigImportView`）。
private struct QuickCommandInboxConsumer: ViewModifier {
    let workspace: WorkspaceModel
    let server: ServerProfile

    func body(content: Content) -> some View {
        content
            .task(id: server.id) { consume() }
            .onChange(of: QuickCommandInbox.shared.serial) { _, _ in consume() }
    }

    @MainActor
    private func consume() {
        guard let command = QuickCommandInbox.shared.take(for: server.id) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            workspace.uiState.rightInspectorPresented = true
        }
        // 不覆盖用户在 Agent 输入框里正在写的内容：非空则换行追加。
        let existing = workspace.assistantModel.input
        workspace.assistantModel.input = existing.isEmpty
            ? command
            : existing + (existing.hasSuffix("\n") ? "" : "\n") + command
    }
}
