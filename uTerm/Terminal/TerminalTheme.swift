import SwiftUI
import AppKit
import SwiftTerm

enum TerminalTheme {
    static let backgroundColor = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)

    static func applyScrollback(to view: SwiftTerm.TerminalView, scrollback: Int) {
        guard let terminal = view.terminal else { return }
        let target = max(0, scrollback)
        if terminal.options.scrollback != target {
            terminal.changeScrollback(target > 0 ? target : nil)
        }
    }

    /// Subtle blue overlay used for normal mouse-drag selections.
    static let normalSelectionColor = NSColor(srgbRed: 0x26 / 255, green: 0x4F / 255, blue: 0x78 / 255, alpha: 0.5)

    /// Bright amber overlay used while a search overlay is open so the active
    /// match is unmistakable against any cell background. Mirrors VS Code's
    /// `terminal.findMatchBackground` (`#A07D27`).
    static let searchMatchColor = NSColor(srgbRed: 0xF1 / 255, green: 0xB5 / 255, blue: 0x3C / 255, alpha: 0.6)

    /// 浅色终端的选区底色。深色用上面的 `normalSelectionColor`（深蓝）；浅色用 VS Code
    /// 浅蓝 #ADD6FF —— 否则深蓝盖在「浅底 + 深字」上会把选中文字压成不可读。
    static let lightSelectionColor = NSColor(srgbRed: 0xAD / 255, green: 0xD6 / 255, blue: 0xFF / 255, alpha: 0.8)

    // MARK: spec 03 — settings-driven API

    /// Spec 03 主 entry：接收完整 settings 一次性 apply。
    ///
    /// 调用顺序保证 scheme 先于 cursor —— applyCursor 在 block 形态时
    /// 读 view.nativeBackgroundColor 作为 caretTextColor，需要 scheme
    /// 已生效。
    static func apply(to view: SwiftTerm.TerminalView, settings: TerminalSettings, dark: Bool) {
        let scheme = settings.colorScheme(dark: dark)
        applyFont(to: view, fontName: settings.fontName, fontSize: CGFloat(settings.fontSize))
        applyLineSpacing(to: view, lineSpacing: CGFloat(settings.lineHeight))
        applyColorScheme(to: view, scheme: scheme, dark: dark)
        applyCursor(to: view, scheme: scheme, shape: settings.cursorShape, blink: settings.cursorBlink)
        applyScrollback(to: view, scrollback: settings.scrollback)
        applyRoundedCorners(to: view)
    }

    /// 字体名 + 字号同时设定。
    static func applyFont(to view: SwiftTerm.TerminalView, fontName: String, fontSize: CGFloat) {
        let font = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
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
