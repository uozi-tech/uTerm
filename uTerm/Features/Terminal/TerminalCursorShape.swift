import Foundation

/// 终端光标形状。UserDefaults key: `terminalCursorShape`。默认 `.block`。
/// 与 `terminalCursorBlink: Bool` 共同决定 DECSCUSR 参数。
nonisolated enum TerminalCursorShape: String, CaseIterable, Identifiable, Sendable {
    case block
    case underline
    case bar

    var id: String { rawValue }

    /// 在设计稿 segmented control 中显示的标签（含 ASCII 预览字符）。
    var localizedLabel: String {
        switch self {
        case .block:     return String(localized: "█ 块", comment: "光标形状：块")
        case .underline: return String(localized: "_ 下划线", comment: "光标形状：下划线")
        case .bar:       return String(localized: "| 竖线", comment: "光标形状：竖线")
        }
    }

    /// DECSCUSR (CSI Ps SP q) 的 Ps 值。设计意图与 xterm/iTerm 一致：
    /// blink 时奇数 (1/3/5)，steady 时偶数 (2/4/6)。
    func decscusrParameter(blink: Bool) -> Int {
        switch self {
        case .block:     return blink ? 1 : 2
        case .underline: return blink ? 3 : 4
        case .bar:       return blink ? 5 : 6
        }
    }
}
