import AppKit
import GhosttyTerminal

/// 把 uTerm 的终端设置翻成 Ghostty 配置（Mac）。
///
/// 本模块里有同名的 `TerminalColorScheme` / `TerminalTheme`，Ghostty 那边的类型一律写全模块名。
enum GhosttyTerminalConfig {

    /// 进程里所有 Ghostty 窗格共用一个 app（`ghostty_app_t`）。Ghostty 的测试夹具注明并行建 app 会 abort，
    /// 而且一个 app 一份字体 / 图集缓存，多窗格各建一个也是浪费。
    static let controller: GhosttyTerminal.TerminalController = {
        // 基础配置留空（Ghostty 自己的默认值），uTerm 的设置全走 `terminalConfiguration` 这一层：
        // 之后 `setTerminalConfiguration` 换的就是这一层，不会和基础层叠出两份 font-family。
        GhosttyTerminal.TerminalController(
            configSource: .none,
            theme: theme(),
            terminalConfiguration: base(settings: TerminalSettings.read()))
    }()

    /// 与外观无关的部分：字体、光标、历史、剪贴板、通知。
    static func base(settings: TerminalSettings) -> GhosttyTerminal.TerminalConfiguration {
        GhosttyTerminal.TerminalConfiguration { b in
            // 终端字体是 `NSFont.monospacedSystemFont(…, weight: .medium)`。Ghostty 按族名在 CoreText 里找字体，
            // 系统等宽的族名以点开头（`.AppleSystemUIFontMonospaced`），找不到会静默退回内置的 JetBrains Mono。
            // 先按族名给，再退到 SF Mono / Menlo：Ghostty 的 font-family 可以重复写，按顺序作为回退链。
            for family in fontFamilies() { b.withFontFamily(family) }
            b.withFontSize(Float(TerminalSettings.fontSize))
            b.withCustom("font-style", "Medium")
            b.withCursorStyle(cursorStyle(settings.cursorShape))
            b.withCursorStyleBlink(settings.cursorBlink)
            // 容器自己留内边距（`GhosttyContainerView.insets`），Ghostty 不再加。
            b.withWindowPaddingX(0)
            b.withWindowPaddingY(0)
            b.withCustom("window-padding-balance", "false")
            // 历史上限：行数用设置里的，字节上限按行数放宽；和影子终端同一个函数算（`TerminalScrollbackLimits`）。
            // 两个键都只对之后新建的 surface 生效。
            for item in TerminalScrollbackLimits(lines: settings.scrollback).ghosttyConfiguration {
                b.withCustom(item.key, item.value)
            }
            // OSC 52 只允许写、不允许读：远端程序不能读走 Mac 的剪贴板。
            b.withCustom("clipboard-read", "deny")
            b.withCustom("clipboard-write", "allow")
            // 取值是 none / clipboard（`false` 按文档是 none 的别名，但这个版本报 InvalidValue）。
            b.withCustom("copy-on-select", settings.copyOnSelect ? "clipboard" : "none")
            // 桌面通知（OSC 9 / 777）由影子终端的事件发（带「用户是否在看」的过滤，标签藏着时也收得到），
            // Ghostty 这边关掉，免得同一条通知发两次。
            b.withCustom("desktop-notifications", "false")
            b.withCustom("confirm-close-surface", "false")
            b.withCustom("shell-integration", "none")
            b.withCustom("cursor-click-to-move", "true")
            b.withCustom("mouse-hide-while-typing", "false")
            // 以下四项是迁移前的着色规则（iOS 试用第二轮逐格对比查出来的，见 docs/ghostty-eval/measure-ios.md M16）：
            // 256 色的 16–255 由 16 色按 CIELAB 生成；粗体的 0–7 号色用亮色；
            // dim 按 sRGB 和底色五五开混合。
            b.withCustom("palette-generate", "true")
            b.withCustom("bold-color", "bright")
            b.withCustom("alpha-blending", "native")
            b.withCustom("faint-opacity", "0.5")
        }
    }

    /// 深 / 浅两套配色：背景、前景、16 色、选区、光标、最低对比度。
    static func theme() -> GhosttyTerminal.TerminalTheme {
        GhosttyTerminal.TerminalTheme(light: colors(.vscodeLight), dark: colors(.vscodeDark))
    }

    static func colors(_ scheme: TerminalColorScheme) -> GhosttyTerminal.TerminalConfiguration {
        GhosttyTerminal.TerminalConfiguration { b in
            b.withBackground(hex(scheme.backgroundColor))
            b.withForeground(hex(scheme.foregroundColor))
            b.withSelectionBackground(hex(scheme.selectionColor))
            b.withSelectionForeground(hex(scheme.foregroundColor))
            b.withCursorColor(hex(scheme.cursorColor))
            // 块光标下的字用终端底色。
            b.withCursorText(hex(scheme.backgroundColor))
            for (index, color) in scheme.ansiColors.enumerated() {
                b.withPalette(index, color: color.hex)
            }
            // minimum-contrast：官方 Ghostty 达不到目标比时把前景换成纯黑或纯白；我们编的引擎带补丁 0022，
            // 保色相、只调明度（OKLCH），块字符也不豁免。
            b.withMinimumContrast(Double(TerminalColorScheme.minimumContrastRatio))
        }
    }

    static func cursorStyle(_ shape: TerminalCursorShape) -> GhosttyTerminal.TerminalCursorStyle {
        switch shape {
        case .block: .block
        case .underline: .underline
        case .bar: .bar
        }
    }

    /// 族名回退链。第一个是系统等宽字体的族名。
    static func fontFamilies() -> [String] {
        var out: [String] = []
        if let family = TerminalSettings.textFont().familyName { out.append(family) }
        for fallback in ["SF Mono", "Menlo"] where !out.contains(fallback) { out.append(fallback) }
        return out
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
