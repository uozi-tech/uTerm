// uTerm/Editor/EditorTheme.swift
import AppKit

/// 编辑器配色单点真相。VSCode Dark+ 对齐。
/// 与 AppTheme.Palette 隔离 —— 编辑器色域闭环（17 token），混进全局会污染。
nonisolated enum EditorTheme {

    // MARK: 内容表面（与 AppTheme.Palette 脱钩，钉死 VS Code Dark）
    /// 编辑器内容背景。VS Code Dark Modern editor.background。
    static let background = NSColor(srgbRed: 0x1F/255, green: 0x1F/255, blue: 0x1F/255, alpha: 1)
    /// 编辑器默认（未高亮）文字色。VS Code Dark Modern editor.foreground。
    static let foreground = NSColor(srgbRed: 0xCC/255, green: 0xCC/255, blue: 0xCC/255, alpha: 1)

    // MARK: 选中 / 光标 / 当前行
    static let selectionBg       = NSColor(red: 0x26/255, green: 0x4F/255, blue: 0x78/255, alpha: 1)
    static let caret             = NSColor(red: 0xAE/255, green: 0xAF/255, blue: 0xAD/255, alpha: 1)
    static let activeLineBg      = NSColor.white.withAlphaComponent(0.04)
    static let sameWordOutline   = NSColor(red: 0x57/255, green: 0x5B/255, blue: 0x61/255, alpha: 1)
    static let findMatchBg       = NSColor(red: 0x61/255, green: 0x3A/255, blue: 0x14/255, alpha: 1)
    static let findMatchActiveBg = NSColor(red: 0xEA/255, green: 0x5C/255, blue: 0x00/255, alpha: 0.40)
    static let findMatchBorder   = NSColor(red: 0xF3/255, green: 0x85/255, blue: 0x18/255, alpha: 1)

    // MARK: 语法高亮（capture name → color）
    static let synKeyword        = NSColor(red: 0xC5/255, green: 0x86/255, blue: 0xC0/255, alpha: 1)
    static let synStorageType    = NSColor(red: 0x56/255, green: 0x9C/255, blue: 0xD6/255, alpha: 1)
    static let synString         = NSColor(red: 0xCE/255, green: 0x91/255, blue: 0x78/255, alpha: 1)
    static let synStringEscape   = NSColor(red: 0xD7/255, green: 0xBA/255, blue: 0x7D/255, alpha: 1)
    static let synNumber         = NSColor(red: 0xB5/255, green: 0xCE/255, blue: 0xA8/255, alpha: 1)
    static let synFunction       = NSColor(red: 0xDC/255, green: 0xDC/255, blue: 0xAA/255, alpha: 1)
    static let synVariable       = NSColor(red: 0x9C/255, green: 0xDC/255, blue: 0xFE/255, alpha: 1)
    static let synConstant       = NSColor(red: 0x4F/255, green: 0xC1/255, blue: 0xFF/255, alpha: 1)
    static let synType           = NSColor(red: 0x4E/255, green: 0xC9/255, blue: 0xB0/255, alpha: 1)
    static let synComment        = NSColor(red: 0x6A/255, green: 0x99/255, blue: 0x55/255, alpha: 1)
    static let synPunctuation    = NSColor(red: 0xD4/255, green: 0xD4/255, blue: 0xD4/255, alpha: 1)
    static let synDefault        = NSColor(red: 0xE8/255, green: 0xEA/255, blue: 0xEF/255, alpha: 1)

    /// tree-sitter capture name → 颜色。Track C 调。
    static func color(for capture: String) -> NSColor {
        // 最长前缀匹配；按 VSCode Dark+ 语义
        switch capture {
        case "keyword", "keyword.control", "keyword.return", "keyword.operator",
             "conditional", "repeat", "storage.modifier":
            return synKeyword
        case "storage.type", "boolean", "constant.builtin.boolean":
            return synStorageType
        case "string", "string.regex":
            return synString
        case "string.escape":
            return synStringEscape
        case "number", "constant.numeric":
            return synNumber
        case "function", "function.method", "function.macro", "function.builtin":
            return synFunction
        case "variable", "variable.parameter":
            return synVariable
        case "property", "field", "attribute", "tag.attribute":
            return synVariable
        case "constant", "constant.builtin":
            return synConstant
        case "type", "type.builtin", "class", "interface", "namespace", "module":
            return synType
        case "comment", "comment.line", "comment.block":
            return synComment
        case "punctuation", "punctuation.bracket", "punctuation.delimiter", "operator":
            return synPunctuation
        case "tag.name":
            return synStorageType
        default:
            return synDefault
        }
    }
}
