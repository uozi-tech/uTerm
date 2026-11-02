import UDesignKit
import SwiftUI
import SwiftData

/// 工作区左 sidebar：SFTP 文件树。包装现有 `FileBrowserContent` 并负责
/// 连接生命周期与 host-key sheet。
struct SFTPSidebar: View {
    let model: FileBrowserModel
    let server: ServerProfile
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        // 分区方案 v3.2：文件树是内容列表，并进主内容卡、与右侧预览 / 终端同为卡面色
        // （`UD.panel`），中间只隔一条 1pt 竖线 —— 不再自铺底色。
        FileBrowserContent(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UD.panel)
            .task(id: server.id) {
                await model.connect(profile: server, modelContainer: modelContext.container)
            }
        // hostKeySheet 上移到 WorkspaceWindowView 根 —— 这样 sidebar 折叠时
        // TOFU 挑战仍能弹出（Fix #2）。
    }
}
