import Foundation

/// 用户可选的日志详细程度。UserDefaults key: `logLevel`。默认 `.info`。
///
/// `AppLogger` 在每个 log 调用前比较 priority；below-threshold 的 log
/// 直接 return（write-time gating）——底层 os.Logger 永远不会收到 low-priority 调用。
///
/// 注意：与 `OSLogType` 没有 1:1 映射（os 没有 warn 级别）。本 enum
/// 是 user-facing 4 档；映射到 OSLogType 时 `.warn` → `.error` + `[WARN]` 前缀。
enum LogLevel: String, CaseIterable, Identifiable {
    case error
    case warn
    case info
    case debug

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .error: return "Error"
        case .warn:  return "Warn"
        case .info:  return "Info"
        case .debug: return "Debug"
        }
    }

    /// 数字越大越详细。比较用：当前 setting priority >= 调用 level priority 才输出。
    var priority: Int {
        switch self {
        case .error: return 0
        case .warn:  return 1
        case .info:  return 2
        case .debug: return 3
        }
    }
}
