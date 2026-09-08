import Foundation

/// 移动端共享的日期格式化器。
///
/// ## 别在行体里现建 `Formatter`
///
/// `DateFormatter` / `RelativeDateTimeFormatter` / `ByteCountFormatter` 的
/// 初始化都要走一遍 ICU（locale、日历、模板解析），是几十微秒级的开销 ——
/// 摊到一屏几十行、每次滚动都重建，就是实打实的掉帧。
/// macOS 端同一处方在 `WelcomeFormat` / `QuickCommandFormat` 里。
///
/// **为什么不直接用 macOS 的 `WelcomeFormat`**：它在
/// `Features/Welcome/Views/WelcomeComponents.swift` 里，而那个文件在
/// `uTermMobile` target 的 membership exception 清单里（整个 Welcome/Views
/// 都是 AppKit 专属），iOS 根本编不到；而且语义也不一样 ——
/// 移动端各处钉死 `zh_CN` 且用完整单位（「3 小时前」而非「3 小时」），
/// 「从未」的兜底文案还分两种（主机列表是「从未连接」）。
///
/// 全部 `@MainActor`：`DateFormatter` 家族非 Sendable，而调用方都是视图 body。
@MainActor
enum MFormat {

    // MARK: 相对时间（「3 小时前」）

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    /// `nil` → `fallback`，否则「刚刚 / 3 小时前 / 昨天」。
    static func relative(_ date: Date?, fallback: String = "从未") -> String {
        guard let date else { return fallback }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: 绝对时间

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// `2026-09-08`
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    /// `09-08 15:04`
    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }
    /// `15:04:32`
    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    // MARK: 字节数

    /// `ByteCountFormatter.string(fromByteCount:countStyle:)` 那个**类方法**
    /// 每次调用都会在内部现建一个 formatter —— SFTP 一屏 20 行就是 20 个。
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// `1.2 MB`
    static func bytes(_ count: Int64) -> String { byteFormatter.string(fromByteCount: count) }
}
