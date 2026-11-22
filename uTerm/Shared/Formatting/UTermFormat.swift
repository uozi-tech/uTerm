import Foundation
import UDesignKit

/// `UFormat`（uAppKit 的统一数字 / 时间渲染层）没覆盖、uTerm 自己要的几种写法。
///
/// 与 `UFormat` 同一套约定：纯函数、与系统 locale 无关（公历 + 24 小时制 + 手工拼接，
/// 不经过任何 `DateFormatter`），先舍入再选档。macOS / iOS 两端共用（本文件不在
/// `uTermMobile` 的 membership exception 清单里）。
nonisolated enum UTermFormat {

    // MARK: - 相对时间

    /// `nil` → `fallback`（「从未」/「从未连接」），否则走 `UFormat.relative`
    /// （「刚刚 / 3 分钟前 / 昨天 / 09-28」）。
    static func relative(_ date: Date?, fallback: String = String(localized: "从未", comment: "相对时间：从未发生过"),
                         now: Date = Date()) -> String {
        guard let date else { return fallback }
        return UFormat.relative(date, now: now)
    }

    // MARK: - 日期

    /// 只要日期：「2026-09-28」（`UFormat.dateTimeMinutes` 的定宽前 10 位）。
    static func date(_ date: Date, timeZone: TimeZone = .current) -> String {
        String(UFormat.dateTimeMinutes(date, timeZone: timeZone).prefix(10))
    }

    // MARK: - 日志时间戳

    /// 执行日志的时间戳：「今天 13:05」/「昨天 13:05」/「09-28 13:05」/ 跨年「2025-09-28 13:05」。
    static func logTimestamp(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = timeZone
        let stamp = UFormat.dateTimeMinutes(date, timeZone: timeZone)   // "2026-09-28 13:05"
        let hm = String(stamp.suffix(5))
        let dayDiff = g.dateComponents([.day], from: g.startOfDay(for: date), to: g.startOfDay(for: now)).day ?? 0
        if dayDiff == 0 { return String(localized: "今天 \(hm)", comment: "日志时间戳，hm 为「13:05」") }
        if dayDiff == 1 { return String(localized: "昨天 \(hm)", comment: "日志时间戳，hm 为「13:05」") }
        if g.component(.year, from: date) == g.component(.year, from: now) {
            return String(stamp.dropFirst(5))                            // "09-28 13:05"
        }
        return stamp
    }

    // MARK: - 时长

    /// 运行时长（uptime）：「47d 16h」/「3h 05m」/「12m」。按 `uptime` 惯例向下取整，
    /// 不带秒——状态栏 3 秒一拍，秒位只会来回跳。一小时起交给 `UFormat.duration`，
    /// 先截到整分（满一天截到整点）再传，保住向下取整。
    static func uptime(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return UFormat.placeholder }
        let s = Int64(min(seconds, 1e15))
        if s < 3600 { return "\(s / 60)m" }
        return UFormat.duration(wholeSeconds: s < 86_400 ? s - s % 60 : s - s % 3600)
    }

    /// 传输剩余时间：「剩余 42 s」/「剩余 2m 06s」/「剩余 1h 02m」，与其他耗时同一套
    /// `UFormat` 写法。先把总秒数舍入再选档，不会出现「剩余 60 秒」。
    static func eta(remainingBytes: Int64, bytesPerSecond: Double) -> String {
        if remainingBytes <= 0 { return String(localized: "即将完成", comment: "传输剩余时间") }
        guard bytesPerSecond > 0, bytesPerSecond.isFinite else { return UFormat.placeholder }
        let seconds = Double(remainingBytes) / bytesPerSecond
        if seconds < 1 { return String(localized: "即将完成", comment: "传输剩余时间") }
        guard seconds < 1e9 else { return UFormat.placeholder }
        let duration = UFormat.duration(wholeSeconds: Int64(seconds.rounded(.toNearestOrAwayFromZero)))
        return String(localized: "剩余 \(duration)", comment: "传输剩余时间，duration 如「2m 06s」")
    }

    /// 传输速率「1.20 MB/s」；速率还没测出来（≤0）时给占位「—」。
    static func transferRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0, bytesPerSecond.isFinite else { return UFormat.placeholder }
        return UFormat.bytes(Int64(bytesPerSecond.rounded(.toNearestOrAwayFromZero))) + "/s"
    }

    // MARK: - 进度

    /// 进度百分比：向下取整并钳到 0…1——没传完之前永远不显示「100%」，
    /// 文件在传输中变大（done > total）也不会显示「103%」。
    static func progressFraction(done: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    static func progress(_ fraction: Double) -> String {
        guard fraction.isFinite else { return UFormat.placeholder }
        let clamped = min(1, max(0, fraction))
        // +1e-9 吸收二进制误差：0.29 * 100 = 28.999…，直接向下取整会得 28%。
        return UFormat.percent((clamped * 100 + 1e-9).rounded(.down) / 100)
    }
}
