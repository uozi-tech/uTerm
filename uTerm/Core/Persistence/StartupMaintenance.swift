import Foundation
import SwiftData

/// 启动期跑一次的数据维护（滚动清理）。
///
/// 放在这里而不是挂在 Welcome 的 `.task` 上：后台启动模式下 Welcome 根本不出现，
/// 挂在它身上的维护就永远不跑 —— 与「保持连接」的转发被移出 Welcome 是同一个理由。
@MainActor
enum StartupMaintenance {
    static func run(container: ModelContainer, defaults: UserDefaults = .standard) {
        let context = container.mainContext
        QuickCommandStore(context: context).pruneExpiredRuns()

        let days = ChatHistoryStore.retentionDays(defaults: defaults)
        let removed = ChatHistoryStore(context: context).pruneExpiredSessions(days: days)
        if removed > 0 {
            AppLogger.info("清理过期会话 \(removed) 条（保留窗口 \(days) 天）", category: "sync")
        }
    }
}
