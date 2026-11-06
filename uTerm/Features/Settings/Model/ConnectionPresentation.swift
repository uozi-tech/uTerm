import Foundation

/// 「连接」与「诊断」分区几项同步设置的默认值与 iOS 预设档（mac 用数字框直接填，iOS 用菜单选档）。
/// 默认值与 `SharedPreferencesSync` 清单里的一致（缺键时两端读到同一个数）。
nonisolated enum ConnectionPresentation {
    static let defaultTimeout = 30
    static let defaultSFTPConcurrency = 4

    /// SSH 握手超时的预设档（秒）。
    static let timeoutOptions = [10, 20, 30, 60, 120]
    /// SFTP 同时传输文件数的预设档。
    static let sftpConcurrencyOptions = [1, 2, 4, 8, 16]

    /// 超时的显示名。mac 上能填任意值，不在预设里的照样显示成「N 秒」。
    static func timeoutLabel(_ seconds: Int) -> String { "\(seconds) 秒" }

    static func sftpConcurrencyLabel(_ count: Int) -> String { "\(count) 个" }
}

extension LogLevel {
    /// 设置页「日志等级」的说明（两端同一句）。
    nonisolated static let settingsHint = "运行时立即生效；低于此等级的日志不会写入系统日志。"
}
