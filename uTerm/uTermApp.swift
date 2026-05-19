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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .modelContainer(modelContainer)
    }
}
