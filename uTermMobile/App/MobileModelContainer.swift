import AgentKit
import SwiftData

/// iOS/iPadOS 的本地 SwiftData 容器。跨设备复制由 LANSyncDataStore 负责。
enum MobileModelContainer {
    private static let types: [any PersistentModel.Type] = [
        ServerProfile.self, KnownHost.self, AIProvider.self, SSHKey.self,
        ChatSession.self, ChatMessageRecord.self, ServerGroup.self,
        ForwardingRule.self, QuickCommand.self, QuickCommandRun.self,
    ]

    static func make() -> ModelContainer {
        let schema = Schema(types)
        let local = ModelConfiguration("uTerm", schema: schema, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: local)
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }
}
