import SwiftUI
import SwiftData

/// 一个工作区窗口：绑定单台服务器（由 `WorkspaceWindowID` 指定）。
/// 三栏布局：左 SFTPSidebar（NavigationSplitView 的 sidebar）/ 中 WorkspaceCenter
/// （NavigationSplitView 的 detail）/ 右 AgentSidebar（.inspector）。
struct WorkspaceWindowView: View {
    let windowID: WorkspaceWindowID?

    @Query private var profiles: [ServerProfile]
    @State private var workspace = WorkspaceModel()
    @State private var didRestore = false
    @State private var saveTask: Task<Void, Never>?
    /// 用于把全局 CommandGroup 通知限定到当前 key window —— 多窗口下避免后台窗口
    /// 也被切换。`.controlActiveState` 在窗口为 key 时为 `.key`。
    @Environment(\.controlActiveState) private var controlActiveState

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
    }

    @ViewBuilder
    private func workspaceBody(server: ServerProfile,
                               windowID: WorkspaceWindowID) -> some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { workspace.uiState.leftSidebarVisibility },
            set: { workspace.uiState.leftSidebarVisibility = $0 }
        )) {
            SFTPSidebar(model: workspace.fileBrowserModel, server: server)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
        } detail: {
            WorkspaceCenter(workspace: workspace, server: server)
                .inspector(isPresented: Binding(
                    get: { workspace.uiState.rightInspectorPresented },
                    set: { workspace.uiState.rightInspectorPresented = $0 }
                )) {
                    AgentSidebar(
                        model: workspace.assistantModel,
                        serverContext: "服务器：\(server.name)（\(server.displayEndpoint)）")
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
        }
        .navigationTitle(server.name)
        // 隐藏工具栏中央那颗自动渲染的标题胶囊 —— 服务器名在 .principal
        // 工具栏自渲染；保留 `.navigationTitle` 仅供窗口菜单/调度中心识别。
        .toolbar(removing: .title)
        .toolbar { workspaceToolbar(server: server) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(AppTheme.Palette.border).frame(height: 1)
                StatusBarView(workspace: workspace)
            }
        }
        .background(AppTheme.Palette.bgBase)
        // host-key sheet 放在 NavigationSplitView 根，sidebar 折叠时也能弹（Fix #2）。
        // SFTPSidebar 不再自挂 sheet —— 二处同名 sheet 会互相抢占。
        .hostKeySheet(workspace.fileBrowserModel.hostKeyRelay)
        .task {
            // 仅首次执行：载入本窗口的持久化布局，无则开一个默认终端标签。
            // 在原 workspace 实例上 mutate（不再替换实例）—— SFTPSidebar 的
            // .task(id: server.id) 持有的 fileBrowserModel 引用因此稳定，
            // 修复「快照恢复后 SFTP 永久停在 .connecting」的卡死（Fix #1）。
            guard !didRestore else { return }
            didRestore = true
            if let snapshot = WorkspaceStore(windowID: windowID).load() {
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
    }

    @ToolbarContentBuilder
    private func workspaceToolbar(server: ServerProfile) -> some ToolbarContent {
        // 工具栏按钮**不**再绑 keyboardShortcut —— 全靠 CommandGroup 一处注册
        // （Fix #4）。先前 toolbar 与 commands 同时挂同一快捷键导致每次按键
        // 触发两次 toggle，净 no-op。
        ToolbarItem(placement: .navigation) {
            Button { workspace.toggleLeftSidebar() } label: {
                Image(systemName: "sidebar.left")
            }
            .help("显示/隐藏 SFTP（⌘⌥1）")
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Text(server.name).font(.headline)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                if let session = workspace.focusedTerminalSession() {
                    ConnectionStatusBadge(state: session.connectionState)
                }
            }
        }

        ToolbarItem {
            Button {
                workspace.activeTab?.splitFocusedPane(direction: .horizontal)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("水平分屏（⌘D）")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { workspace.toggleRightInspector() } label: {
                Image(systemName: "sidebar.right")
            }
            .help("显示/隐藏 Agent（⌘⌥2）")
        }
    }
}
