import Foundation
import SwiftTerm

/// 把 `TerminalColorScheme` 与光标样式装进 SwiftTerm 视图（macOS / iOS 共用）。
///
/// 两端各自只负责「什么时候装」（mac 由 `TerminalTheme` 按设置变化，iOS 按日夜变化）和平台独有的
/// 部分（mac 的字体 / 圆角、iOS 的 `UIView.backgroundColor`）。
enum TerminalAppearance {
    /// 装配色：前景 / 背景 / 16 色 ANSI 表 / 选区底色 / 渲染期最低对比度。
    ///
    /// 会清掉 SwiftTerm 的属性与颜色缓存并整屏重绘，调用方要自己去重（只在配色真的变了才调）。
    static func applyColors(to view: SwiftTerm.TerminalView, scheme: TerminalColorScheme) {
        view.nativeBackgroundColor = scheme.backgroundColor
        view.nativeForegroundColor = scheme.foregroundColor
        view.installColors(scheme.ansiColors)
        view.selectedTextBackgroundColor = scheme.selectionColor
        // 渲染期最低对比度：服务器端按深色背景硬编码的 256 色 / 真彩色
        // （powerline prompt 等）不走 ANSI 16 色表，只能在渲染时钳制
        view.minimumContrastRatio = TerminalColorScheme.minimumContrastRatio
    }

    /// 只装光标的颜色：块光标填充色 + 块光标下字符的颜色（用终端底色，保证可读；非块形态交回 SwiftTerm）。
    /// 必须在 `applyColors` 之后调——块形态读 `view.nativeBackgroundColor`。
    static func applyCaretColors(to view: SwiftTerm.TerminalView,
                                 scheme: TerminalColorScheme,
                                 shape: TerminalCursorShape) {
        view.caretColor = scheme.cursorColor
        view.caretTextColor = (shape == .block) ? view.nativeBackgroundColor : nil
    }

    /// 光标颜色 + 形状 + 闪烁（DECSCUSR），并把这一样式记成终端的默认样式：程序发 `CSI 0 q` 或
    /// `reset` 时 SwiftTerm 回到 `defaultCursorStyle`，不设的话会回到 SwiftTerm 自带的闪烁块。
    ///
    /// 会盖掉程序自己设的光标（vim 插入模式的竖线），调用方只在设置变了 / 新建视图时调。
    static func applyCursor(to view: SwiftTerm.TerminalView,
                            scheme: TerminalColorScheme,
                            shape: TerminalCursorShape,
                            blink: Bool) {
        applyCaretColors(to: view, scheme: scheme, shape: shape)
        view.feed(text: "\u{1B}[\(shape.decscusrParameter(blink: blink)) q")
        let terminal = view.getTerminal()
        terminal.defaultCursorStyle = terminal.options.cursorStyle
    }
}
