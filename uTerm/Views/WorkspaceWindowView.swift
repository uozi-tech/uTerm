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
        WorkspaceView(
            workspace: workspace,
            onNewTab: { kind in
                workspace.openServer(profileID: server.id, title: server.name, kind: kind)
            })
            .navigationTitle(server.name)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button("新建终端标签") {
                            workspace.openServer(profileID: server.id,
                                                 title: server.name, kind: .terminal)
                        }
                        Button("新建文件标签") {
                            workspace.openServer(profileID: server.id,
                                                 title: server.name, kind: .files)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("新建标签")
                }
                ToolbarItem(placement: .principal) {
                    if let tab = workspace.activeTab {
                        HStack(spacing: 6) {
                            Text(tab.title).font(.headline)
                            if let pane = tab.focusedPane,
                               case .terminal(let session) = pane.kind {
                                ConnectionStatusBadge(state: session.connectionState,
                                                      showsLabel: false)
                            }
                        }
                    }
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
}
