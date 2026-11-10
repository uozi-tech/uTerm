import GhosttyTerminal

// 本模块里有同名的 `TerminalColorScheme` / `TerminalTheme`，Ghostty 那边的类型一律写全模块名。

/// Ghostty 配置里两端都一样的那部分（Mac 的 `GhosttyTerminalConfig`、iOS 的 `GhosttyTerminalBridge.makeController` 都从这里起，
/// 平台再追加字体、字号、加粗、选中即复制、桌面通知这类各自的项）。
nonisolated enum TerminalGhosttyConfig {

    /// 两端共有的项：光标、留白、着色规则、剪贴板、回滚上限、按键绑定（最低对比度跟配色走，见 `colors`）。
    static func applyCommon(to b: inout GhosttyTerminal.TerminalConfiguration.Builder,
                            cursorShape: TerminalCursorShape, cursorBlink: Bool, scrollback: TerminalScrollbackLimits) {
        b.withCursorStyle(cursorStyle(cursorShape))
        b.withCursorStyleBlink(cursorBlink)
        // 不要内留白：网格从左上角排起（容器自己留边距，余下的不到一格留在右 / 下边）。远控钉尺寸按「行列数 × 格子」算视图大小，
        // 也靠这一条。
        b.withWindowPaddingX(0)
        b.withWindowPaddingY(0)
        // 着色规则（换引擎之前逐格对比定下来的，见 docs/ghostty-eval/measure-ios.md M16）：
        // - 256 色的 16–255 由 16 色 + 底色 / 前景按 CIELAB 生成；不开的话 Ghostty 用固定的 xterm 表，p10k 的 38;5;103 等
        //   颜色对不上，浅色下灰阶还是反的。
        b.withCustom("palette-generate", "true")
        // - 粗体的 0–7 号色用亮色。
        b.withCustom("bold-color", "bright")
        // - dim 按 sRGB（伽马空间）和底色五五开混合；默认的 linear-corrected 在线性空间混合，dim 字会亮一截。
        b.withCustom("alpha-blending", "native")
        b.withCustom("faint-opacity", "0.5")
        // OSC 52 由影子终端处理（标签藏着、surface 没建或放掉了时也要生效），surface 这边写、读都关掉，免得写两遍、回放进
        // surface 时把历史里的再写一遍；远端程序不能读走本机的剪贴板。只管程序发来的请求，用户自己的拷贝不受影响。
        b.withCustom("clipboard-read", "deny")
        b.withCustom("clipboard-write", "deny")
        // 回滚上限：与影子终端同一份（M4 的前提）。不设的话是 Ghostty 的默认 50 MB、不限行数。只对之后新建的 surface 生效。
        for item in scrollback.ghosttyConfiguration { b.withCustom(item.key, item.value) }
        // 按键绑定：Ghostty 的默认绑定全清，只留拷贝 / 粘贴 / 全选、自然文本编辑、翻回滚（清单与理由在 `TerminalKeyBindings`）。
        for item in TerminalKeyBindings.ghosttyConfiguration { b.withCustom(item.key, item.value) }
    }

    /// 深 / 浅两套配色（都来自 `TerminalColorScheme.resolve`），Ghostty 按视图的日夜自己切。
    ///
    /// 配色必须走 theme：controller 先装基础配置、再把 theme 叠上去；不传 theme 时用的是 GhosttyKit 自带的
    /// Alabaster / Afterglow，会把 background / foreground / palette / cursor-color 全部盖掉。
    static func theme() -> GhosttyTerminal.TerminalTheme {
        GhosttyTerminal.TerminalTheme(light: colors(TerminalColorScheme.resolve(dark: false)),
                                      dark: colors(TerminalColorScheme.resolve(dark: true)))
    }

    /// 一份配色：底色、前景、16 色、光标（块光标下的字用终端底色）、选区、最低对比度。
    static func colors(_ scheme: TerminalColorScheme) -> GhosttyTerminal.TerminalConfiguration {
        GhosttyTerminal.TerminalConfiguration { b in
            let background = TerminalRGB(scheme.backgroundColor).hex
            let foreground = TerminalRGB(scheme.foregroundColor).hex
            b.withBackground(background)
            b.withForeground(foreground)
            for (index, color) in scheme.ansiColors.prefix(16).enumerated() { b.withPalette(index, color: color.hex) }
            b.withCursorColor(TerminalRGB(scheme.cursorColor).hex)
            b.withCursorText(background)
            b.withSelectionBackground(TerminalRGB(scheme.selectionColor).hex)
            b.withSelectionForeground(foreground)
            // 最低对比度（WCAG 比值）。上游 Ghostty 判不过就直接换成黑 / 白；我们编的引擎带补丁 0022，保色相、只调明度（OKLCH），
            // 块字符也不豁免。深 / 浅两套各写一份。
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
}
