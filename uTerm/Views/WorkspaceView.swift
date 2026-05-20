import SwiftUI

/// 终端工作区：顶部标签条 + 当前标签内容 + 底部状态栏。纯展示，
/// 持久化由承载它的 `WorkspaceWindowView` 负责。
struct WorkspaceView: View {
    let workspace: WorkspaceModel
    /// 上层提供「新建标签」入口；参数为所选窗格种类。
    let onNewTab: (PaneKindTag) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty {
                TabBarView(workspace: workspace, onNewTab: onNewTab)
                Divider()
            }
            if let tab = workspace.activeTab {
                TabContentView(tab: tab, onCloseTab: { workspace.closeTab(tab.id) })
            } else {
                ContentUnavailableView(
                    "未打开终端", systemImage: "terminal",
                    description: Text("点标签栏的 ＋ 新建标签"))
            }
            Divider()
            StatusBarView(workspace: workspace)
        }
    }
}
