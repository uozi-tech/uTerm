import SwiftUI
import SwiftData

/// 一个工作区窗口：绑定单台服务器（由 `WorkspaceWindowID` 指定），
/// 承载标签工作区 + 右侧 inspector。持久化按窗口分文件。
struct WorkspaceWindowView: View {
    enum InspectorPanel { case assistant }

    let windowID: WorkspaceWindowID?

    @Query private var profiles: [ServerProfile]
    @State private var workspace = WorkspaceModel()
    @State private var didRestore = false
    @State private var inspectorPanel: InspectorPanel?
    @State private var assistantModel = AssistantModel()
    @State private var saveTask: Task<Void, Never>?

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
        WorkspaceView(workspace: workspace)
            .navigationTitle(server.name)
            // 隐藏工具栏中央那颗自动渲染的标题胶囊 —— 同样的信息已在标签栏 +
            // StatusBarView 中呈现；保留 `.navigationTitle` 仅供「窗口」菜单 /
            // 调度中心识别窗口。
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    WorkspaceTitlebarTabs(
                        workspace: workspace,
                        onNewTab: { kind in
                            workspace.openServer(profileID: server.id,
                                                 title: server.name, kind: kind)
                        })
                }
                ToolbarItem {
                    Button {
                        splitFocusedPane(direction: .horizontal)
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .keyboardShortcut("d", modifiers: .command)
                    .help("水平分屏（⌘D）")
                }
                ToolbarItem {
                    Button {
                        toggleInspector(.assistant)
                    } label: { Image(systemName: "sparkles") }
                    .help("AI 助手")
                }
            }
            .inspector(isPresented: Binding(
                get: { inspectorPanel != nil },
                set: { if !$0 { inspectorPanel = nil } }
            )) {
                inspectorContent(server: server)
                    .inspectorColumnWidth(min: 260, ideal: 340, max: 520)
            }
            .task {
                // 仅首次执行：载入本窗口的持久化布局，无则开一个默认终端标签。
                // `didRestore` 是 `WorkspaceWindowView` 的 @State —— 瞬态 re-render
                // 不会重置它，故即便 `.task` 因视图重建再次触发也只恢复一次。
                guard !didRestore else { return }
                didRestore = true
                if let snapshot = WorkspaceStore(windowID: windowID).load() {
                    workspace = WorkspaceModel(snapshot: snapshot)
                } else {
                    workspace.openServer(profileID: server.id, title: server.name, kind: .terminal)
                }
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
            // 全局 CommandMenu 是 app 级的，无法直达某个窗口；用通知做转发。
            // 所有打开的工作区窗口都会订阅，但 workspace.activeTab 是窗口本地的
            // ——前台窗口正常分屏，背景窗口因 activeTab 仍指向自己的活动 tab
            // 也会被静默分屏。区分前台需读 NSWindow.isKeyWindow，本期不做。
            .onReceive(NotificationCenter.default.publisher(for: .splitFocusedPaneVertical)) { _ in
                splitFocusedPane(direction: .vertical)
            }
    }

    @ViewBuilder
    private func inspectorContent(server: ServerProfile) -> some View {
        switch inspectorPanel {
        case .assistant:
            AssistantView(
                serverContext: "服务器：\(server.name)（\(server.displayEndpoint)）",
                model: assistantModel)
        case nil:
            EmptyView()
        }
    }

    /// 点击工具栏按钮：已是当前面板则关闭，否则切到该面板。
    private func toggleInspector(_ panel: InspectorPanel) {
        inspectorPanel = (inspectorPanel == panel) ? nil : panel
    }

    /// 对当前活动 tab 的聚焦窗格分屏。toolbar 按钮（⌘D）与
    /// CommandMenu 的「垂直分屏」（⇧⌘D）共用此入口；无活动 tab 时静默 no-op。
    private func splitFocusedPane(direction: SplitDirection) {
        workspace.activeTab?.splitFocusedPane(direction: direction)
    }
}
