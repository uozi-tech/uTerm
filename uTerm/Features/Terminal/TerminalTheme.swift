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
    /// panes read as one text surface. 值取终端真正装进视图的 `TerminalColorScheme.selectionColor`，
    /// `EditorThemeTests` 核对它与 `EditorTheme.selectionBg` 一致。
    static let normalSelectionColor = TerminalColorScheme.vscodeDark.selectionColor

    /// Bright amber overlay used while a search overlay is open so the active
    /// match is unmistakable against any cell background. Mirrors VS Code's
    /// `terminal.findMatchBackground` (`#A07D27`).
    static let searchMatchColor = NSColor(srgbRed: 0xF1 / 255, green: 0xB5 / 255, blue: 0x3C / 255, alpha: 0.6)

    /// 浅色终端的选区底色。与编辑器同用 VS Code Light+ 选区蓝。
    static let lightSelectionColor = TerminalColorScheme.vscodeLight.selectionColor

    // MARK: spec 03 — settings-driven API

    /// Spec 03 主 entry：接收完整 settings 一次性 apply。
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
        // 配色先于光标：块光标读 view.nativeBackgroundColor 作 caretTextColor。
        TerminalAppearance.applyColors(to: view, scheme: scheme)
        TerminalAppearance.applyCursor(to: view, scheme: scheme,
                                       shape: settings.cursorShape, blink: settings.cursorBlink)
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
