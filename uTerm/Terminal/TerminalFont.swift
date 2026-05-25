import Foundation
import AppKit

/// 终端字体下拉的可选值。UserDefaults key: `terminalFontName`（直接存 NSFont
/// 字体名 String），默认 `"Menlo"`。本 enum 用于 Settings UI 的 Picker；
/// TerminalTheme 实际加载字体时直接用 `NSFont(name: rawValue, size:)`
/// + monospacedSystemFont fallback，对未知 rawValue 容错。
enum TerminalFont: String, CaseIterable, Identifiable {
    case menlo  = "Menlo"
    case sfMono = "SF Mono"
    case monaco = "Monaco"

    var id: String { rawValue }
    var displayName: String { rawValue }
}
