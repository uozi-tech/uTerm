import SwiftUI
import AppKit
import SwiftTerm

enum TerminalTheme {
    static let backgroundColor = NSColor(srgbRed: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)

    static func applyScrollback(to view: SwiftTerm.TerminalView, scrollback: Int) {
        guard let terminal = view.terminal else { return }
        let target = max(0, scrollback)
        if terminal.options.scrollback != target {
            terminal.changeScrollback(target > 0 ? target : nil)
        }
    }

    /// Mouse-drag selection colors mirror the editor so terminal and editor
    /// panes read as one text surface.
    static let normalSelectionColor = EditorTheme.selectionBackground(dark: true)

    /// Bright amber overlay used while a search overlay is open so the active
    /// match is unmistakable against any cell background. Mirrors VS Code's
    /// `terminal.findMatchBackground` (`#A07D27`).
    static let searchMatchColor = NSColor(srgbRed: 0xF1 / 255, green: 0xB5 / 255, blue: 0x3C / 255, alpha: 0.6)

    /// 浅色终端的选区底色。与编辑器同用 VS Code Light+ 选区蓝。
    static let lightSelectionColor = EditorTheme.selectionBackground(dark: false)

    // MARK: spec 03 — settings-driven API

    /// Spec 03 主 entry：接收完整 settings 一次性 apply。
    ///
    /// 调用顺序保证 scheme 先于 cursor —— applyCursor 在 block 形态时
    /// 读 view.nativeBackgroundColor 作为 caretTextColor，需要 scheme
    /// 已生效。
    static func apply(to view: SwiftTerm.TerminalView, settings: TerminalSettings, dark: Bool) {
        applyFont(to: view, font: TerminalSettings.textFont())
        applyLineSpacing(to: view, lineSpacing: CGFloat(TerminalSettings.lineHeight))
        applyLook(to: view, settings: settings, dark: dark)
        applyScrollback(to: view, scrollback: settings.scrollback)
        applyRoundedCorners(to: view)
    }

    /// 配色和光标由这几项决定。
    struct Look: Equatable {
        let dark: Bool
        let cursorShape: TerminalCursorShape
        let cursorBlink: Bool
    }

    /// 只在变了才装配色和光标：这里每次 SwiftUI 更新都会走到，而装一次配色要清掉属性缓存并整屏重绘，
    /// 光标形状还会盖掉程序自己设的（vim 插入模式的竖线）。
    private static func applyLook(to view: SwiftTerm.TerminalView, settings: TerminalSettings, dark: Bool) {
        let look = Look(dark: dark, cursorShape: settings.cursorShape, cursorBlink: settings.cursorBlink)
        let copyable = view as? CopyableTerminalView
        if let copyable, copyable.appliedLook == look { return }
        copyable?.appliedLook = look
        let scheme = settings.colorScheme(dark: dark)
        applyColorScheme(to: view, scheme: scheme, dark: dark)
        applyCursor(to: view, scheme: scheme, shape: settings.cursorShape, blink: settings.cursorBlink)
    }

    /// 字体 + 字号同时设定。
    static func applyFont(to view: SwiftTerm.TerminalView, font: NSFont) {
        if view.font != font {
            view.font = font
        }
    }

    /// 行距（SwiftTerm 的 lineSpacing，默认 1.0；范围 1.0-2.0）。
    static func applyLineSpacing(to view: SwiftTerm.TerminalView, lineSpacing: CGFloat) {
        if view.lineSpacing != lineSpacing {
            view.lineSpacing = lineSpacing
        }
    }

    /// 应用 scheme：bg / fg / installColors / 保留 selection color。
    static func applyColorScheme(to view: SwiftTerm.TerminalView, scheme: TerminalColorScheme, dark: Bool) {
        view.nativeBackgroundColor = scheme.backgroundColor
        view.nativeForegroundColor = scheme.foregroundColor
        view.installColors(scheme.ansiColors)
        // 选区底色随外观切：深色深蓝 / 浅色浅蓝，保证选中文字在两种底上都可读
        view.selectedTextBackgroundColor = dark ? normalSelectionColor : lightSelectionColor
        // 渲染期最低对比度：服务器端按深色背景硬编码的 256 色 / 真彩色
        // （powerline prompt 等）不走 ANSI 16 色表，只能在渲染时钳制
        view.minimumContrastRatio = TerminalColorScheme.minimumContrastRatio
    }

    /// 光标形状 + 闪烁。注意：caller 必须先 applyColorScheme，因为
    /// block 形态读 view.nativeBackgroundColor 作 caretTextColor。
    static func applyCursor(to view: SwiftTerm.TerminalView,
                             scheme: TerminalColorScheme,
                             shape: TerminalCursorShape,
                             blink: Bool) {
        view.caretColor = scheme.cursorColor
        view.caretTextColor = (shape == .block) ? view.nativeBackgroundColor : nil
        view.feed(text: "\u{1B}[\(shape.decscusrParameter(blink: blink)) q")
        // 程序发 `CSI 0 q` 或 `reset` 时回到这里。`applyLook` 只在设置变了才走到，不能指望它再装一次。
        let terminal = view.getTerminal()
        terminal.defaultCursorStyle = terminal.options.cursorStyle
    }

    /// 圆角设置抽离出来：原 `apply(to:fontSize:scrollback:)` 内联了
    /// `wantsLayer = true; layer.cornerRadius = 8 ...`，本 spec 提到
    /// 同一段，单独成方法便于新 entry 复用。
    static func applyRoundedCorners(to view: SwiftTerm.TerminalView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer?.masksToBounds = true
    }
}
