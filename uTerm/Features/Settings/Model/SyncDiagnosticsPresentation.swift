import Foundation
import UDesignKit

/// 「同步诊断」事件列表的排版与文案（macOS 设置 · 同步的弹窗与 iOS `SyncDiagnosticsSheet` 共用）。
///
/// 数据源是 `CloudKitSyncMonitor.recentEvents`（环形缓冲，新的在末尾）；列表新→旧展示，
/// 复制走 `CloudKitSyncMonitor.exportText()`（旧→新纯文本）。
nonisolated enum SyncDiagnosticsPresentation {
    /// 列表的一行：时间（`HH:mm:ss`，等宽灰字）+ 事件文本。
    struct Row: Identifiable, Equatable, Sendable {
        let id: UUID
        let time: String
        let text: String
    }

    static let title = String(localized: "同步诊断")
    static let copyButtonTitle = String(localized: "拷贝日志")
    static let emptyMessage = String(localized: "暂无同步事件。登录 iCloud 并让 uTerm 留在前台后，CloudKit 的 setup / import / export 事件会显示在这里。")

    /// 新→旧排列的行。
    static func rows(_ entries: [CloudKitSyncMonitor.Entry],
                     timeZone: TimeZone = .current) -> [Row] {
        entries.reversed().map { Row(id: $0.id, time: UFormat.time($0.date, timeZone: timeZone), text: $0.text) }
    }
}
