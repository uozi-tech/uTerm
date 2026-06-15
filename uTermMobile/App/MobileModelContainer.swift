import SwiftData

/// iOS/iPadOS 的 SwiftData 容器。注册与 macOS (`AppModelContainer`) 完全一致的 `@Model` 全集，
/// 并启用 **CloudKit**（容器 `iCloud.com.uozi.uTerm`，与 macOS 共享同一 iCloud 数据库 → 主机 /
/// 密钥 / 分组 / 命令等跨设备同步）。
///
/// 无可用 iCloud 时（未登录的模拟器、未签名构建、未配 entitlement）`.automatic` 建容失败，
/// 回退本地存储，避免启动崩溃——签名 + 登录 iCloud 的真机才会真正同步。
enum MobileModelContainer {
    private static let types: [any PersistentModel.Type] = [
        ServerProfile.self, KnownHost.self, AIProvider.self, SSHKey.self,
        ChatSession.self, ChatMessageRecord.self, ServerGroup.self,
        ForwardingRule.self, QuickCommand.self, QuickCommandRun.self,
    ]

    /// 容器是否真正以 CloudKit 镜像建成（false = 回退到了纯本地存储，不会同步）。
    /// 仅在 `make()`（启动时一次）写入，之后只读——用于设置页如实展示同步状态。
    nonisolated(unsafe) private(set) static var usingCloudKit = false

    static func make() -> ModelContainer {
        let schema = Schema(types)
        // 优先 CloudKit（与 macOS 共享 iCloud.com.uozi.uTerm）。
        let cloud = ModelConfiguration("uTerm", schema: schema, cloudKitDatabase: .automatic)
        if let container = try? ModelContainer(for: schema, configurations: cloud) {
            usingCloudKit = true
            return container
        }
        // 回退：纯本地存储（CloudKit 不可用时仍可运行）。
        usingCloudKit = false
        let local = ModelConfiguration("uTerm", schema: schema, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: local)
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }
}
