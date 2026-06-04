// uTerm/Editor/EditorTheme.swift
import AppKit

/// 编辑器配色单点真相。**随 app 外观切换**：深 = VS Code Dark Modern，浅 = VS Code Light+。
/// 与 AppTheme.Palette 隔离 —— 编辑器色域闭环（17 token），混进全局会污染。
///
/// 实现：每个 token 是动态 `NSColor(name:dynamicProvider:)`，按当前绘制外观解析。
/// 因此所有 consumer（scrollView.backgroundColor / textColor / 文本 `.foregroundColor`
/// 属性 / gutter 在 draw() 内取色 / selection / caret）都随窗口 effectiveAppearance
/// **自动重解析**——AppKit 在外观变化时重绘视图、重算动态色，无需重跑高亮。
/// 唯一例外是 CAShapeLayer 的 CGColor 快照（见 `ActiveLineOverlay`，它自己重设）。
nonisolated enum EditorTheme {

    /// 把 (深 hex, 浅 hex)[+alpha] 合成随外观切换的动态 NSColor。
    /// 闭包只捕获 UInt32/CGFloat（Sendable），不捕获 NSColor —— Swift6 strict 安全。
    private static func dyn(_ darkHex: UInt32, _ lightHex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let h = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkHex : lightHex
            return NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255,
                           green: CGFloat((h >> 8) & 0xFF) / 255,
                           blue: CGFloat(h & 0xFF) / 255,
                           alpha: alpha)
        }
    }

    // MARK: 内容表面（深 VS Code Dark / 浅 VS Code Light）
    /// 编辑器内容背景。Dark Modern #1F1F1F / Light #FFFFFF。
    static let background = dyn(0x1F1F1F, 0xFFFFFF)
    /// 编辑器默认（未高亮）文字色。Dark #CCCCCC / Light #3B3B3B。
    static let foreground = dyn(0xCCCCCC, 0x3B3B3B)

    // MARK: 字体（与终端共用设置默认值）
    static let textFontName = TerminalSettings.defaultFontName
    static let textFontSize = CGFloat(TerminalSettings.defaultFontSize)

    static func textFont(fontName: String = textFontName,
                         fontSize: CGFloat = textFontSize) -> NSFont {
        NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    // MARK: 选中 / 光标 / 当前行
    static let selectionBg       = dyn(0x264F78, 0xADD6FF)            // 浅色用 VS Code 选区蓝
    static let caret             = dyn(0xAEAFAD, 0x000000)            // 浅色深 caret
    static let activeLineBg      = dyn(0xFFFFFF, 0x000000, 0.04)      // 深=白叠加 / 浅=黑叠加
    static let sameWordOutline   = dyn(0x575B61, 0xB5B5B5)
    static let findMatchBg       = dyn(0x613A14, 0xA8AC94)
    static let findMatchActiveBg = dyn(0xEA5C00, 0xEA5C00, 0.40)
    static let findMatchBorder   = dyn(0xF38518, 0xF38518)

    static func selectionBackground(dark: Bool) -> NSColor {
        var resolved = selectionBg
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            resolved = selectionBg.usingColorSpace(.sRGB) ?? selectionBg
        }
        return resolved
    }

    // MARK: 语法高亮（capture name → color）。浅色取 VS Code Light+ 值。
    static let synKeyword        = dyn(0xC586C0, 0x0000FF)
    static let synStorageType    = dyn(0x569CD6, 0x0000FF)
    static let synString         = dyn(0xCE9178, 0xA31515)
    static let synStringEscape   = dyn(0xD7BA7D, 0xEE0000)
    static let synNumber         = dyn(0xB5CEA8, 0x098658)
    static let synFunction       = dyn(0xDCDCAA, 0x795E26)
    static let synVariable       = dyn(0x9CDCFE, 0x001080)
    static let synConstant       = dyn(0x4FC1FF, 0x0070C1)
    static let synType           = dyn(0x4EC9B0, 0x267F99)
    static let synComment        = dyn(0x6A9955, 0x008000)
    static let synPunctuation    = dyn(0xD4D4D4, 0x000000)
    static let synDefault        = dyn(0xE8EAEF, 0x3B3B3B)

    /// tree-sitter capture name → 颜色。Track C 调。
    static func color(for capture: String) -> NSColor {
        // tree-sitter query captures commonly use dotted subtypes such as
        // `keyword.function` or `function.method`; keep the mapping semantic.
        if capture == "keyword" || capture.hasPrefix("keyword.") ||
            capture == "conditional" || capture == "repeat" ||
            capture == "storage.modifier" {
            return synKeyword
        }
        if capture == "storage.type" || capture == "boolean" ||
            capture == "constant.builtin.boolean" {
            return synStorageType
        }
        if capture == "string.escape" {
            return synStringEscape
        }
        if capture == "string" || capture.hasPrefix("string.") {
            return synString
        }
        if capture == "number" || capture.hasPrefix("number.") ||
            capture == "constant.numeric" {
            return synNumber
        }
        if capture == "function" || capture.hasPrefix("function.") {
            return synFunction
        }
        if capture == "variable" || capture.hasPrefix("variable.") {
            return synVariable
        }
        if capture == "property" || capture == "field" ||
            capture == "attribute" || capture == "tag.attribute" {
            return synVariable
        }
        if capture == "constant" || capture.hasPrefix("constant.") {
            return synConstant
        }
        if capture == "type" || capture.hasPrefix("type.") ||
            capture == "class" || capture == "interface" ||
            capture == "namespace" || capture == "module" {
            return synType
        }
        if capture == "comment" || capture.hasPrefix("comment.") {
            return synComment
        }
        if capture == "punctuation" || capture.hasPrefix("punctuation.") ||
            capture == "operator" {
            return synPunctuation
        }
        if capture == "tag.name" {
            return synStorageType
        }
        return synDefault
    }
}
