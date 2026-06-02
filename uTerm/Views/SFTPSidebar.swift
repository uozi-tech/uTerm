import SwiftUI
import SwiftData

/// 工作区左 sidebar：SFTP 文件树。包装现有 `FileBrowserContent` 并负责
/// 连接生命周期与 host-key sheet。
struct SFTPSidebar: View {
    let model: FileBrowserModel
    let server: ServerProfile
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        // 不再覆盖 .background —— 让 NavigationSplitView 的 Liquid Glass
        // sidebar 材质透出，圆角/border 整圈才连贯（macOS 26）。
        FileBrowserContent(model: model)
            .task(id: server.id) {
                await model.connect(profile: server, modelContainer: modelContext.container)
            }
        // hostKeySheet 上移到 WorkspaceWindowView 根 —— 这样 sidebar 折叠时
        // TOFU 挑战仍能弹出（Fix #2）。
    }
}
