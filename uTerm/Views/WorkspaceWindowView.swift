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
    @State private var saveTask: Task<Void, Never>?
    /// 大文件确认 / 阻断 sheet 的状态（Spec 2A §1.5 / §7）。
    @State private var largeFileConfirm: LargeFileConfirm?
    @State private var blockedFile: BlockedFile?
    @State private var palette = CommandPaletteModel()
    /// 用于把全局 CommandGroup 通知限定到当前 key window —— 多窗口下避免后台窗口
    /// 也被切换。`.controlActiveState` 在窗口为 key 时为 `.key`。
    @Environment(\.modelContext) private var modelContext
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

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
        VStack(spacing: 0) {
            // 自绘标题栏（替代系统 toolbar）：左「文件」开关 / 居中服务器名 + 状态
            // 胶囊 / 右 Agent 开关。彻底脱离系统 toolbar 及其 Liquid Glass。
            WorkspaceTitleBar(
                serverName: server.name,
                session: workspace.focusedTerminalSession(),
                onToggleSidebar: {
                    withAnimation(.easeInOut(duration: 0.18)) { workspace.toggleLeftSidebar() }
                },
                onToggleInspector: {
                    withAnimation(.easeInOut(duration: 0.18)) { workspace.toggleRightInspector() }
                },
                onOpenSettings: { openSettings() })

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
                    serverContext: "服务器：\(server.name)（\(server.displayEndpoint)）",
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
        .background(WorkspaceWindowChrome(serverName: server.name))
        // ⌘W：仅工作区窗口接管，按焦点先关内容、最后关窗口（见 handleCloseShortcut）。
        .background(WorkspaceCloseShortcutInstaller { window in
            handleCloseShortcut(window: window)
        })
        // host-key sheet 放在 NavigationSplitView 根，sidebar 折叠时也能弹（Fix #2）。
        // SFTPSidebar 不再自挂 sheet —— 二处同名 sheet 会互相抢占。
        .hostKeySheet(workspace.fileBrowserModel.hostKeyRelay)
        .commandPalette(model: palette) { workspaceCommandItems(server: server) }
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
            workspace.assistantModel.executor = try? WorkspaceCommandExecutorFactory.make(
                server: server, container: modelContext.container)
        }
        .onDisappear {
            workspace.dispose()
        }
        .onChange(of: workspace.snapshot()) { _, newSnapshot in
            saveTask?.cancel()
            let store = WorkspaceStore(windowID: windowID)
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                try? store.save(newSnapshot)
            }
        }
        .onChange(of: workspace.fileBrowserModel.state) { _, state in
            guard state == .browsing else { return }
            Task { await workspace.filePreviewModel.loadRestoredBuffersIfNeeded() }
        }
        // 全局 CommandGroup 通知会广播到所有打开的工作区窗口；用
        // controlActiveState == .key 守卫，只让前台窗口响应（Fix #6）。
        .onReceive(NotificationCenter.default.publisher(for: .splitFocusedPaneVertical)) { _ in
            guard controlActiveState == .key else { return }
            workspace.activeTab?.splitFocusedPane(direction: .vertical)
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
        // SFTPSidebar 文件 tap → 通知 → 在 PreviewArea 打开。Spec 2A §3.1。
        .onReceive(NotificationCenter.default.publisher(for: .openRemoteFile)) { note in
            guard controlActiveState == .key,
                  let info = note.userInfo,
                  let path = info["path"] as? String,
                  let size = info["size"] as? Int64 else { return }
            let mtime = info["mtime"] as? Date
            if size > 50 * 1024 * 1024 {
                blockedFile = BlockedFile(path: path, size: size)
            } else if size > 5 * 1024 * 1024 {
                largeFileConfirm = LargeFileConfirm(path: path, size: size, mtime: mtime)
            } else {
                Task { await workspace.filePreviewModel.open(path: path, fileSize: size, mtime: mtime) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .savePreviewBuffer)) { _ in
            guard controlActiveState == .key,
                  let id = workspace.filePreviewModel.activeBufferID else { return }
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
                            path: confirm.path, fileSize: confirm.size, mtime: confirm.mtime)
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

    /// 工作区窗口的命令项：主机（连接=当前工作区开新 tab）/ 最近文件 / 命令 / 设置深链。
    @MainActor
    private func workspaceCommandItems(server: ServerProfile) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // 主机：连接 = 在当前工作区开新 tab
        for p in profiles.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let id = p.id
            let name = p.name.isEmpty ? p.host : p.name
            items.append(CommandPaletteItem(
                id: "host.\(id.uuidString)", kind: .host,
                title: name, detail: "\(p.username)@\(p.host)",
                hint: "连接", group: p.group) {
                    workspace.openServer(profileID: id, title: name)
                })
        }

        // 文件（最近）：stat 取真实 size/mtime 后走既有 .openRemoteFile 大文件门
        for entry in workspace.filePreviewModel.recents {
            let path = entry.remotePath
            items.append(CommandPaletteItem(
                id: "file.\(path)", kind: .file,
                title: (path as NSString).lastPathComponent, detail: path,
                hint: "打开", group: "最近") {
                    let browser = workspace.fileBrowserModel
                    Task { @MainActor in
                        guard let sftp = browser.sftpProvider,
                              let stat = try? await sftp.stat(path) else { return }
                        NotificationCenter.default.post(
                            name: .openRemoteFile, object: nil,
                            userInfo: ["path": path, "size": stat.size, "mtime": stat.mtime])
                    }
                })
        }

        // 命令
        items.append(CommandPaletteItem(
            id: "cmd.splitPane", kind: .command,
            title: "新建终端窗格", detail: "在当前工作区分屏", hint: "⇧⌘D", group: nil) {
                workspace.activeTab?.splitFocusedPane(direction: .vertical)
            })
        items.append(CommandPaletteItem(
            id: "cmd.closeTab", kind: .command,
            title: "关闭当前 tab", detail: "", hint: "⌘W", group: nil) {
                if let id = workspace.activeTabID { workspace.closeTab(id) }
            })
        items.append(CommandPaletteItem(
            id: "cmd.newHost", kind: .command,
            title: "新建主机…", detail: "创建一台新服务器", hint: "↵", group: nil) {
                openWindow(id: "welcome")
            })

        items.append(CommandPaletteItem(
            id: "cmd.manageGroups", kind: .command,
            title: "管理分组…", detail: "新建 / 重命名 / 删除分组", hint: "↵", group: nil) {
                openWindow(id: "groups")
            })

        items.append(CommandPaletteItem(
            id: "cmd.importConfig", kind: .command,
            title: "导入 ~/.ssh/config", detail: "从本地 SSH config 批量导入", hint: "↵", group: nil) {
                openWindow(id: "import")
            })

        // 设置
        items.append(contentsOf: commandPaletteSettingsItems(openSettings: { openSettings() }))
        items.append(contentsOf: commandPaletteAccentItems())
        return items
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
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(basename)
        do {
            let data = try await sftp.download(remotePath: path)
            try data.write(to: dest)
            NSWorkspace.shared.open(dest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "下载失败"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

}

/// 把 SwiftData providers + @AppStorage activeProviderID 灌进 assistant model。
/// 拆成独立 modifier 是为了让 `workspaceBody` 主表达式不至于让编译器超时；
/// `[AIProvider]` 是 `@Model` class，非 `Equatable`，所以 onChange 用 `id` 列表比较。
private struct AssistantBindingModifier: ViewModifier {
    let assistant: AssistantModel
    let providers: [AIProvider]
    let activeProviderIDString: String

    func body(content: Content) -> some View {
        content
            .onAppear {
                assistant.providers = providers
                assistant.activeProviderID = UUID(uuidString: activeProviderIDString)
            }
            .onChange(of: providers.map(\.id)) { _, _ in
                assistant.providers = providers
            }
            .onChange(of: activeProviderIDString) { _, new in
                assistant.activeProviderID = UUID(uuidString: new)
            }
    }
}
