import SwiftUI

/// 终端工作区：当前标签内容 + 底部状态栏。标签条由
/// `WorkspaceWindowView` 通过 toolbar 的 chip 条呈现（Finder 式）。
/// 持久化由承载它的 `WorkspaceWindowView` 负责。
struct WorkspaceView: View {
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            if let tab = workspace.activeTab {
                TabContentView(tab: tab, onCloseTab: { workspace.closeTab(tab.id) })
            } else {
                ContentUnavailableView(
                    "未打开终端", systemImage: "terminal",
                    description: Text("点工具栏右侧的 ＋ 新建标签"))
            }
            Divider()
            StatusBarView(workspace: workspace)
        }
    }
}
