import SwiftUI
import SwiftData

/// 工作区左 sidebar：SFTP 文件树。包装现有 `FileBrowserContent` 并负责
/// 连接生命周期与 host-key sheet。
struct SFTPSidebar: View {
    let model: FileBrowserModel
    let server: ServerProfile
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(AppTheme.Palette.border).frame(height: 1)
            FileBrowserContent(model: model)
        }
        .background(AppTheme.Palette.bgPanel)
        .task(id: server.id) {
            await model.connect(profile: server, modelContainer: modelContext.container)
        }
        // hostKeySheet 上移到 WorkspaceWindowView 根 —— 这样 sidebar 折叠时
        // TOFU 挑战仍能弹出（Fix #2）。
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(AppTheme.Palette.accent)
            Text("SFTP")
                .font(.headline)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(AppTheme.Palette.bgPanel)
    }
}
