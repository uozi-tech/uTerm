import Foundation
import os

/// 项目的全局日志入口。包 `os.Logger`，按用户选的 `LogLevel` 做
/// write-time gating（below-threshold 直接 return，省字符串构造成本）。
///
/// 用法（任意源文件）：
///
///     AppLogger.info("Connected to \(host)")
///     AppLogger.error("SSH handshake failed: \(err)")
///
/// 类别：subsystem 固定 `cn.uozi.uTerm`；category 由 caller 指定（默认 `"app"`）。
///
/// 性能：每次调用读一次 UserDefaults。预期调用频率远低于 1k/s；若未来变高
/// 可加 in-process cache + AppStorage observer。
enum AppLogger {
    private static let subsystem = "cn.uozi.uTerm"

    /// 测试钩子：传 nil 使用 `.info` 默认值（不读 UserDefaults）；
    /// 生产代码应传入 `currentSettingRaw()` 以反映实际设置。
    /// 调用方读 setting 一次后传入；避免 gating 与 dispatch 之间的 race。
    internal static func shouldLog(_ callLevel: LogLevel, currentSetting raw: String?) -> Bool {
        let current = LogLevel(rawValue: raw ?? LogLevel.info.rawValue) ?? .info
        // priority: error=0, warn=1, info=2, debug=3
        // 当前 setting priority >= 调用 level priority 才输出
        return current.priority >= callLevel.priority
    }

    private static func currentSettingRaw() -> String? {
        UserDefaults.standard.string(forKey: "logLevel")
    }

    private static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    static func error(_ message: @autoclosure () -> String, category: String = "app") {
        guard shouldLog(.error, currentSetting: currentSettingRaw()) else { return }
        logger(category: category).error("\(message(), privacy: .public)")
    }

    static func warn(_ message: @autoclosure () -> String, category: String = "app") {
        guard shouldLog(.warn, currentSetting: currentSettingRaw()) else { return }
        // os.Logger 没有 warn 级别；用 error 级别但 message 加 [WARN] 前缀。
        logger(category: category).error("[WARN] \(message(), privacy: .public)")
    }

    static func info(_ message: @autoclosure () -> String, category: String = "app") {
        guard shouldLog(.info, currentSetting: currentSettingRaw()) else { return }
        logger(category: category).info("\(message(), privacy: .public)")
    }

    static func debug(_ message: @autoclosure () -> String, category: String = "app") {
        guard shouldLog(.debug, currentSetting: currentSettingRaw()) else { return }
        logger(category: category).debug("\(message(), privacy: .public)")
    }
}
