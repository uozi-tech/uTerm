import AgentKit
import SwiftData

enum AppModelContainer {
    static func make() -> ModelContainer {
        // `.automatic`：用户已登录 iCloud 时由 SwiftData 在后台持续镜像，未登录时自动退化为纯本地。
        // 这是保底同步通道；局域网同步是同网段下的手动快通道，两者写同一个本地容器。
        let config = ModelConfiguration(
            "uTerm",
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(
                for: ServerProfile.self, KnownHost.self, AIProvider.self, SSHKey.self,
                     ChatSession.self, ChatMessageRecord.self, ServerGroup.self,
                     ForwardingRule.self, QuickCommand.self, QuickCommandRun.self,
                configurations: config)
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }
}
