import SwiftUI
import SwiftData

/// 工作区左 sidebar：SFTP 文件树。包装现有 `FileBrowserContent` 并负责
/// 连接生命周期与 host-key sheet。
struct SFTPSidebar: View {
    let model: FileBrowserModel
    let server: ServerProfile
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        // 铺 WS.bg 实色 —— 主动切断 NavigationSplitView 的 Liquid Glass sidebar
        // 材质（去玻璃改造）。窗口已被钉为 .darkAqua，故此处实色恒为深色。
        FileBrowserContent(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WS.bg)
            .task(id: server.id) {
                await model.connect(profile: server, modelContainer: modelContext.container)
            }
        // hostKeySheet 上移到 WorkspaceWindowView 根 —— 这样 sidebar 折叠时
        // TOFU 挑战仍能弹出（Fix #2）。
    }
}
