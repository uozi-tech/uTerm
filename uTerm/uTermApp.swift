import SwiftUI
import SwiftData

@main
struct uTermApp: App {
    /// 启用 CloudKit 同步的 SwiftData 容器。`.automatic` 让 SwiftData
    /// 在用户已登录 iCloud 时自动后台同步，未登录时退化为纯本地。
    let modelContainer: ModelContainer = {
        let config = ModelConfiguration(
            "uTerm",
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(for: ServerProfile.self, KnownHost.self, configurations: config)
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }()

    init() {
        // Spec 1 之前的单份 workspace.json 已不再使用 —— 启动时清掉。
        WorkspaceStore.purgeLegacyWorkspaceFile()
    }

    var body: some Scene {
        // 服务器管理 —— 单实例 Welcome 窗口。自动出现在「窗口」菜单，可重开。
        Window("uTerm", id: "welcome") {
            WelcomeView()
        }
        .modelContainer(modelContainer)

        // 工作区窗口 —— 每个绑定一台服务器，可多实例。
        WindowGroup(for: WorkspaceWindowID.self) { $windowID in
            WorkspaceWindowView(windowID: windowID)
                .frame(minWidth: 1280, minHeight: 720)
        }
        .modelContainer(modelContainer)
    }
}
