import Foundation

/// shell 或程序用 OSC 0 / 2 设的标题怎么收（macOS / iOS 共用）。
enum TerminalTitle {
    /// 去掉首尾空白；剩下空串 = 程序把标题清掉了，返回 nil，调用方据此退回主机名。
    nonisolated static func normalize(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
