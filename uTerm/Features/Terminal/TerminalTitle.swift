import Foundation

/// shell 或程序用 OSC 0 / 2 设的标题怎么收（macOS / iOS 共用）。
enum TerminalTitle {
    /// 去掉首尾空白；剩下空串 = 程序把标题清掉了，返回 nil，调用方据此退回主机名。
    nonisolated static func normalize(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 标签上放的标题：标签宽度随标题撑开、组件不截断，shell 标题又常带整条路径，这里先截短；全文在悬停提示里。
    nonisolated static func clippedForTab(_ title: String) -> String {
        let limit = 28
        return title.count > limit ? "\(title.prefix(limit - 1))…" : title
    }
}
