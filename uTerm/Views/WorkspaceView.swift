import SwiftUI
import SwiftData

/// 终端工作区：顶部标签条 + 当前标签内容。负责持久化(变更保存)。
struct WorkspaceView: View {
    let workspace: WorkspaceModel
    /// 上层提供「新建标签」入口（弹服务器选择）。
    let onNewTab: () -> Void
    /// 把某服务器在新标签打开（窗格中心区拖放触发）。
    let onOpenServerInNewTab: @MainActor @Sendable (UUID) -> Void

    private let store = WorkspaceStore()
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty {
                TabBarView(workspace: workspace, onNewTab: onNewTab)
                Divider()
            }
            if let tab = workspace.activeTab {
                TabContentView(tab: tab, onOpenInNewTab: onOpenServerInNewTab,
                               onCloseTab: { workspace.closeTab(tab.id) })
            } else {
                ContentUnavailableView(
                    "未打开终端", systemImage: "terminal",
                    description: Text("从左侧选择一台服务器，或点标签栏的 ＋"))
            }
        }
        .onChange(of: workspace.snapshot()) { _, newSnapshot in
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                try? store.save(newSnapshot)
            }
        }
    }
}
