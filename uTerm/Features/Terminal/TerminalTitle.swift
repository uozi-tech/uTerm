import Foundation

/// shell 或程序用 OSC 0 / 2 设的标题怎么收（macOS / iOS 共用）。
enum TerminalTitle {
    /// 去掉首尾空白和开头的状态符号；剩下空串 = 程序把标题清掉了，返回 nil，调用方据此退回主机名。
    nonisolated static func normalize(_ title: String) -> String? {
        let trimmed = stripStatusGlyph(title.trimmingCharacters(in: .whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Claude Code、Codex 这类程序把运行状态画进标题开头（`◐ 修登录页`、`✳ 修登录页`、盲文转圈 `⠋ …`）。
    /// 标签上已经有状态圆点，这个符号重复了；它又多半落在回退字体里，和别的标签的文字对不齐。只认「符号 + 空格」打头。
    nonisolated static func stripStatusGlyph(_ title: String) -> String {
        guard let first = title.unicodeScalars.first, isStatusGlyph(first) else { return title }
        let rest = title.unicodeScalars.dropFirst()
        guard let space = rest.first, space == " " else { return title }
        return String(String.UnicodeScalarView(rest.dropFirst()))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func isStatusGlyph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2800...0x28FF: true          // 盲文点阵：各家 spinner
        case 0x25D0...0x25D3: true          // ◐ ◑ ◒ ◓
        case 0x25CB, 0x25CF, 0x25C9: true   // ○ ● ◉
        case 0x2722...0x273D: true          // ✢ ✳ ✶ ✻ ✽ 等星形
        case 0x00B7: true                   // ·
        default: false
        }
    }

    /// 标签上放的标题：标签宽度随标题撑开、组件不截断，shell 标题又常带整条路径，这里先截短；全文在悬停提示里。
    nonisolated static func clippedForTab(_ title: String) -> String {
        let limit = 28
        return title.count > limit ? "\(title.prefix(limit - 1))…" : title
    }
}
