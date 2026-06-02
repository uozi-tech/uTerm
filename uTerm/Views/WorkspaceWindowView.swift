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
    /// 用于把全局 CommandGroup 通知限定到当前 key window —— 多窗口下避免后台窗口
    /// 也被切换。`.controlActiveState` 在窗口为 key 时为 `.key`。
    @Environment(\.controlActiveState) private var controlActiveState

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
            NavigationSplitView(columnVisibility: Binding(
                get: { workspace.uiState.leftSidebarVisibility },
                set: { workspace.uiState.leftSidebarVisibility = $0 }
            )) {
                SFTPSidebar(model: workspace.fileBrowserModel, server: server)
                    // 列宽几何约束（2026-05 final round）：
                    //   sidebar.max(240) + detail.min(480) + inspector.max(360) = 1080
                    //   再加 splitter ≈ 1085pt < windowMinWidth(1280) — 留 ~195pt
                    //   缓冲应对 chrome / Liquid Glass 渲染。
                    // 这条不等式保证：无论用户怎么拖 sidebar / inspector splitter，
                    // 永远不会出现 sum(列宽) > 窗口宽 的 overflow 裁切。
                    // max 从 300 收到 240：拖宽空间 80pt 仍够看较长文件名；
                    // 收得更紧能给 detail 更大保底（之前 max=300 时 detail 只剩 ~500pt）。
                    .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 240)
            } detail: {
                WorkspaceCenter(workspace: workspace, server: server)
                    // detail 显式声明 minWidth(480)：sidebar/inspector 拖到 max 时
                    // detail 仍至少保留 480pt 渲染 terminal/preview，不被挤到 0。
                    // 不声明的话 SwiftUI 给 detail = 0 让 sidebar/inspector 的
                    // 内容溢出到 detail 区域 —— 那就是 user 看到的"被遮挡"。
                    .frame(minWidth: 480)
                    .inspector(isPresented: Binding(
                        get: { workspace.uiState.rightInspectorPresented },
                        set: { workspace.uiState.rightInspectorPresented = $0 }
                    )) {
                        AgentSidebar(
                            model: workspace.assistantModel,
                            serverContext: "服务器：\(server.name)（\(server.displayEndpoint)）",
                            activeProviderIDString: $activeProviderIDString)
                            // inspector.max 从 480 收到 360：上一轮 max 太宽，
                            // sidebar(300) + inspector(480) = 780pt 占 1280pt 窗口
                            // 一大半，detail 只剩 ~500pt。
                            // 收到 360 之后 sum(240+360+480) = 1080 ≤ 1280-chrome，
                            // 永远不会出现 overflow 裁切。
                            .inspectorColumnWidth(min: 220, ideal: 280, max: 360)
                    }
            }
            // status bar 作为 NavigationSplitView 的兄弟节点（而非 safeAreaInset）—
            // safeAreaInset 在 NavigationSplitView 的 detail 列里不可靠传递，
            // SwiftTerm NSView 会渲染到 inset 区域下面，挡住末行（issue 反馈）。
            Rectangle().fill(AppTheme.Palette.border).frame(height: 1)
            StatusBarView(workspace: workspace)
        }
        .navigationTitle(server.name)
        // 隐藏工具栏中央那颗自动渲染的标题胶囊 —— 服务器名在 .principal
        // 工具栏自渲染；保留 `.navigationTitle` 仅供窗口菜单/调度中心识别。
        .toolbar(removing: .title)
        .toolbar { workspaceToolbar(server: server) }
        // toolbar 背景留给系统 —— macOS 26 的 Liquid Glass sidebar 需要
        // 顶部透明、内容从 toolbar 下方延伸过去，圆角/border 才整圈连贯。
        // 强制 bgPanel + .visible 会在 sidebar 顶部封一道平板，把玻璃切断。
        .background(Color(nsColor: .windowBackgroundColor))
        // host-key sheet 放在 NavigationSplitView 根，sidebar 折叠时也能弹（Fix #2）。
        // SFTPSidebar 不再自挂 sheet —— 二处同名 sheet 会互相抢占。
        .hostKeySheet(workspace.fileBrowserModel.hostKeyRelay)
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
        }
        // 窗口关闭时释放资源（Fix #8）。WorkspaceModel.dispose 关闭 SFTP 会话
        // 与所有终端 session。SwiftUI 在 view 离开层级时调 onDisappear，
        // 而正常 re-render 不会触发，故此处是安全的窗口生命周期挂点。
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
        // 全局 CommandGroup 通知会广播到所有打开的工作区窗口；用
        // controlActiveState == .key 守卫，只让前台窗口响应（Fix #6）。
        .onReceive(NotificationCenter.default.publisher(for: .splitFocusedPaneVertical)) { _ in
            guard controlActiveState == .key else { return }
            workspace.activeTab?.splitFocusedPane(direction: .vertical)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleLeftSidebar)) { _ in
            guard controlActiveState == .key else { return }
            workspace.toggleLeftSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleRightInspector)) { _ in
            guard controlActiveState == .key else { return }
            workspace.toggleRightInspector()
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

    // MARK: 大文件 / 保存 helpers（Spec 2A §1.5）

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

    @ToolbarContentBuilder
    private func workspaceToolbar(server: ServerProfile) -> some ToolbarContent {
        // 工具栏按钮**不**再绑 keyboardShortcut —— 全靠 CommandGroup 一处注册
        // （Fix #4）。先前 toolbar 与 commands 同时挂同一快捷键导致每次按键
        // 触发两次 toggle，净 no-op。
        //
        // 左 sidebar toggle 按钮**不**手动加 —— NavigationSplitView 绑了
        // columnVisibility 后 macOS 会自动注入一颗系统按钮，再加自定义会重复
        // （issue：截图里两颗 sidebar 图标）。⌘⌥1 由 CommandGroup 提供。

        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Text(server.name).font(.headline)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                if let session = workspace.focusedTerminalSession() {
                    ConnectionStatusBadge(state: session.connectionState)
                }
            }
            // 系统给 .principal 的胶囊外壳贴边渲染文字，左右各留一点呼吸空间。
            .padding(.horizontal, 10)
        }

        // 分屏按钮删了 —— ⌘⇧D 在 uTermApp 的 CommandGroup 里挂着，
        // 工具栏长期占位且不常用。

        ToolbarItem(placement: .primaryAction) {
            Button { workspace.toggleRightInspector() } label: {
                Image(systemName: "sparkles")
            }
            .help("显示/隐藏 Agent（⌘⌥2）")
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
