import AgentKit
import SwiftData

enum AppModelContainer {
    static func make() -> ModelContainer {
        let config = ModelConfiguration(
            "uTerm",
            cloudKitDatabase: .none
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
