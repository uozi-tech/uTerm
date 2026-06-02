import SwiftUI
import SwiftData

/// 工作区中央下半部：终端区。
/// 顶部 TerminalTabBar + 当前活动 tab 的 TabContentView。无活动 tab 时
/// 渲染「新建终端标签」入口。
struct TerminalArea: View {
    let workspace: WorkspaceModel
    let server: ServerProfile

    var body: some View {
        VStack(spacing: 0) {
            TerminalTabBar(workspace: workspace) {
                workspace.openServer(profileID: server.id, title: server.name)
            }
            if let activeTab = workspace.activeTab {
                TabContentView(tab: activeTab, onCloseTab: {
                    workspace.closeTab(activeTab.id)
                })
                    .background(Color(nsColor: TerminalTheme.backgroundColor))
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(AppTheme.Palette.textMuted)
            Text("没有打开的终端标签")
                .font(.callout)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Button("新建终端标签") {
                workspace.openServer(profileID: server.id, title: server.name)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: TerminalTheme.backgroundColor))
    }
}
