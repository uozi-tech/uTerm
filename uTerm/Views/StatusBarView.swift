import SwiftUI
import SwiftData

/// 底部状态栏：聚焦窗格的状态（终端：连接状态 + 尺寸；文件：SFTP 状态 + 路径）；
/// 右侧窗格/标签计数。
struct StatusBarView: View {
    let workspace: WorkspaceModel

    @Query private var profiles: [ServerProfile]

    var body: some View {
        HStack(spacing: 12) {
            if let pane = workspace.activeTab?.focusedPane {
                paneStatus(pane)
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
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }

    @ViewBuilder
    private func paneStatus(_ pane: PaneModel) -> some View {
        switch pane.kind {
        case .terminal(let session):
            ConnectionStatusBadge(state: session.connectionState)
            Text(endpointText(for: pane))
                .font(.caption).foregroundStyle(.secondary)
            let size = session.currentProcessSize
            Text("\(Int(size.cols))×\(Int(size.rows))")
                .font(.caption).foregroundStyle(.secondary)
        case .files(let model):
            Image(systemName: "folder")
                .font(.caption).foregroundStyle(.secondary)
            Text(endpointText(for: pane))
                .font(.caption).foregroundStyle(.secondary)
            Text(model.currentPath)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
        }
    }

    private func endpointText(for pane: PaneModel) -> String {
        guard let profile = profiles.first(where: { $0.id == pane.serverProfileID }) else {
            return "服务器已删除"
        }
        return profile.displayEndpoint
    }
}
