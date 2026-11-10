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
            // Ghostty 的 font-family 可以重复写，按顺序作为回退链（见 `fontFamilies()`）。
            for family in fontFamilies() { b.withFontFamily(family) }
            b.withFontSize(Float(TerminalSettings.fontSize))
            // 字重靠 font-style 选（族里叫 Medium 的那一款）。试过不管用的两种写法：`font-variation = wght=484` 无效；
            // 族名写成 `.AppleSystemUIFontMonospaced-Medium` 会找不到字体。
            b.withCustom("font-style", "Medium")
            // Ghostty 默认不做 macOS 的字体平滑加粗，笔画比 CoreGraphics 画的细一截。打开 font-thicken、强度给 0
            // （最轻的一档），英文回到迁移前的粗细。同一段文字并排渲染量的墨量（白底、同一块区域里的深色像素）：
            //   换引擎之前（CoreGraphics 画）英文 1044；Ghostty 不加粗时英文 902；
            //   回退链里显式写上 PingFang SC 之后中文稳定在 1098；
            //   再加 thicken（强度 0）：中文 1268 / 英文 1042 / 粗体 1151。
            // 回归用例 `GhosttyFontRenderingTests` 读画出来的像素核这几样。
            b.withFontThicken(true)
            b.withFontThickenStrength(0)
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
            // OSC 52 由影子终端处理（`TerminalSession.installShadowClipboardHandler`：标签藏着、surface 没建时也要生效），
            // surface 这边写、读都关掉，免得写两遍；远端程序不能读走 Mac 的剪贴板。
            b.withCustom("clipboard-read", "deny")
            b.withCustom("clipboard-write", "deny")
            // 取值是 none / clipboard（`false` 按文档是 none 的别名，但这个版本报 InvalidValue）。
            b.withCustom("copy-on-select", settings.copyOnSelect ? "clipboard" : "none")
            // 桌面通知（OSC 9 / 777）由影子终端的事件发（带「用户是否在看」的过滤，标签藏着时也收得到），
            // Ghostty 这边关掉，免得同一条通知发两次。
            b.withCustom("desktop-notifications", "false")
            b.withCustom("confirm-close-surface", "false")
            b.withCustom("shell-integration", "none")
            b.withCustom("cursor-click-to-move", "true")
            b.withCustom("mouse-hide-while-typing", "false")
            // 按键绑定：Ghostty 的默认绑定全清，只留拷贝 / 粘贴 / 全选、自然文本编辑、翻回滚（清单与理由在共享的
            // `TerminalKeyBindings`）。uTerm 的快捷键归主菜单和 SwiftUI 管，其余组合发给程序。
            for item in TerminalKeyBindings.ghosttyConfiguration {
                b.withCustom(item.key, item.value)
            }
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

    /// 族名回退链：系统等宽字体（`.AppleSystemUIFontMonospaced`）→ Menlo → PingFang SC。
    ///
    /// - PingFang SC 必须显式写上。不写时汉字走 Ghostty 的自动回退（按字去 CoreText 里找），落到哪一款、什么字重
    ///   不同次运行不稳定（同一份配置重启后中文时粗时细），落到 UI Text 变体时全角标点还贴在格子左边；
    ///   写上以后汉字固定用苹方、跟着 font-style 取 Medium，全角标点按苹方的排法（「 的墨迹在两格的右半边）。
    /// - Menlo 只是占位，不起兜底作用：`font-style = Medium` 对链里每个族名都生效，Menlo 没有 Medium 这一款，
    ///   按「Menlo + Medium」找不到、这一格被跳过。不要紧：系统等宽在 macOS 上总取得到（有 Medium），链的第一格从不落空
    ///   （`GhosttyFontRenderingTests` 核着）。留着它不影响画面（有没有 Menlo 逐像素相同）。
    /// - 不写 SF Mono：它不是系统自带的（要单独装），没装的机器上取不到，白占一格回退。
    static func fontFamilies() -> [String] {
        var out: [String] = []
        if let family = TerminalSettings.textFont().familyName { out.append(family) }
        for fallback in ["Menlo", "PingFang SC"] where !out.contains(fallback) { out.append(fallback) }
        return out
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
