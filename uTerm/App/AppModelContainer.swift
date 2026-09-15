import AgentKit
import SwiftData

enum AppModelContainer {
    static func make() -> ModelContainer {
        // `.automatic`：用户已登录 iCloud 时由 SwiftData 在后台持续镜像，未登录时自动退化为纯本地。
        // iCloud 与 LAN 是两条独立同步通道；LAN 导入本地容器后的变化仍可被 CloudKit 镜像。
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
