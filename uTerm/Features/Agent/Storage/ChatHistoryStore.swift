import AgentKit
import Foundation
import SwiftData

/// AI 会话历史的滚动清理。
///
/// `QuickCommandRun` 一直有 30 天窗口，聊天历史却**从来没有任何清理**——只增不减。
/// 这不只是本地库体积：会话经 CloudKit 镜像，无界增长会一路吃掉 iCloud 配额。
///
/// 两点取舍：
/// - **按会话删，不按消息删。** 砍掉一段对话的前半截比整段删掉更难用，所以判定落在
///   `ChatSession.updatedAt` 上，消息由 `@Relationship(deleteRule: .cascade)` 带走。
/// - **窗口给得宽，且可关。** 终端里的对话常带着「上次是怎么修好的」这类信息，
///   删掉不可逆。默认 180 天，`chatRetentionDays = 0` 表示不清理。
/// 仿 `QuickCommandStore` / `GroupStore`：`@MainActor struct` 持 `ModelContext`，便于内存容器单测。
@MainActor
struct ChatHistoryStore {
    /// 会话保留窗口（天）的 UserDefaults 键。`0` = 不清理。
    nonisolated static let retentionDaysKey = PreferenceKey.chatRetentionDays
    /// 默认窗口。比执行日志的 30 天宽得多——对话的信息密度和可替代性都不一样。
    nonisolated static let defaultRetentionDays = 180

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// 读取当前窗口；缺键取默认值，`<= 0` 表示不清理。
    nonisolated static func retentionDays(defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: retentionDaysKey) as? Int ?? defaultRetentionDays
    }

    /// 给定参考时刻的过期临界点：`updatedAt` 早于此的会话视为过期。纯函数，便于单测边界。
    nonisolated static func expiryCutoff(now: Date = Date(), days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// 幂等；启动时跑一次。`days <= 0` 直接返回，一条都不删。
    /// 返回删除的会话数，便于日志与测试。
    @discardableResult
    func pruneExpiredSessions(now: Date = Date(), days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Self.expiryCutoff(now: now, days: days)
        let descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.updatedAt < cutoff })
        let expired = (try? context.fetch(descriptor)) ?? []
        guard !expired.isEmpty else { return 0 }
        for session in expired { context.delete(session) }
        try? context.save()
        return expired.count
    }
}
