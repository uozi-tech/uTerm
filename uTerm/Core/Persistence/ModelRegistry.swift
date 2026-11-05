import AgentKit
import SwiftData

/// SwiftData 容器注册的 `@Model` 全集——macOS `AppModelContainer`、iOS `MobileModelContainer`
/// 与测试夹具的唯一来源。
///
/// 漏注册的模型不进 schema，也就不会经 CloudKit 同步。新增 `@Model` 时加在这里，并跑
/// `make check-cloudkit-schema`：`scripts/check-cloudkit-schema.py` 解析的正是这个数组
/// （`types` 的字面量），改名 / 挪文件要同步改脚本里的 `REGISTRY_FILE`。
enum ModelRegistry {
    nonisolated static let types: [any PersistentModel.Type] = [
        ServerProfile.self, KnownHost.self, AIProvider.self, SSHKey.self,
        ChatSession.self, ChatMessageRecord.self, ServerGroup.self,
        ForwardingRule.self, QuickCommand.self, QuickCommandRun.self,
    ]
}
