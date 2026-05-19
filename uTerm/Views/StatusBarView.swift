import SwiftUI
import SwiftData

/// 底部状态栏：聚焦窗格的连接状态、user@host、终端尺寸；右侧窗格/标签计数。
struct StatusBarView: View {
    let workspace: WorkspaceModel

    @Query private var profiles: [ServerProfile]

    var body: some View {
        HStack(spacing: 12) {
            if let pane = workspace.activeTab?.focusedPane {
                ConnectionStatusBadge(state: pane.session.connectionState)
                Text(endpointText(for: pane))
                    .font(.caption).foregroundStyle(.secondary)
                let size = pane.session.currentProcessSize
                Text("\(Int(size.cols))×\(Int(size.rows))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("无活动终端")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let tab = workspace.activeTab {
                Text("\(tab.root.leafCount) 窗格 · \(workspace.tabs.count) 标签")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
    }

    private func endpointText(for pane: PaneModel) -> String {
        guard let profile = profiles.first(where: { $0.id == pane.serverProfileID }) else {
            return "服务器已删除"
        }
        return profile.displayEndpoint
    }
}
