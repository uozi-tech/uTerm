import Foundation

/// AI 会话保留窗口（`ChatHistoryStore.retentionDaysKey`，天，0 = 不清理）的档位与说明（两端共用）。
/// iOS 用预设菜单选档；mac 用数字框直接填天数，所以「不清理」的说法两端不同。
nonisolated enum ChatRetentionPresentation {
    /// 预设档。手机上敲数字既要弹键盘又要校验，而这本来就是个粗粒度选择。
    static let options: [(days: Int, label: String)] = [
        (0, "不清理"), (30, "30 天"), (90, "90 天"), (180, "180 天"), (365, "365 天"),
    ]

    /// 当前值的显示名：在预设里就用预设名，否则「N 天」（mac 上可以填任意天数）。
    static func label(for days: Int) -> String {
        options.first { $0.days == days }?.label ?? "\(days) 天"
    }

    static func footer(for days: Int, platform: SettingsPlatform) -> String {
        guard days > 0 else {
            switch platform {
            case .iOS: return "选「不清理」后对话会一直累积，并占用 iCloud 配额。"
            case .macOS: return "填 0 表示不清理。对话会一直累积，并占用 iCloud 配额。"
            }
        }
        let base = "超过该天数未更新的 AI 对话会在启动时清理，连同其中的消息。"
        switch platform {
        case .iOS: return base + "该设置与 Mac 同步。"
        case .macOS: return base + "快捷命令的执行日志固定保留 30 天。"
        }
    }
}
