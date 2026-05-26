import SwiftUI

/// uTerm 的语义化色彩 token 命名空间。所有 view 必须用 token 而非硬编码颜色。
///
/// 主题：
/// - 深色：VS Code Dark Modern（2023+），hex 来自 `extensions/theme-defaults/themes/dark_modern.json`
/// - 浅色：VS Code Light Modern（2023+），hex 来自 `extensions/theme-defaults/themes/light_modern.json`
///
/// Spec 05 起所有 color token 改为 `Color.adaptive(light:dark:)`——OS appearance 改时
/// NSColor 自动重新 resolve，SwiftUI hierarchy 自动重绘；callsite 0 改动。
///
/// 标 `nonisolated` 让 token 能在任意上下文读取（含单测）；Color 是 Sendable，
/// `Color.adaptive` 已声明为 nonisolated static 工厂，常量化静态属性跨线程安全。
enum AppTheme {
    enum Palette {
        // 背景层（按"亮度递增"排列）
        // light source: editor.background / sideBar.background / list.hoverBackground
        nonisolated static let bgPanel = Color.adaptive(
            light: 0xF8F8F8,  // light_modern sideBar.background
            dark:  0x181818   // dark_modern sideBar.background
        )
        nonisolated static let bgBase = Color.adaptive(
            light: 0xFFFFFF,  // light_modern editor.background
            dark:  0x1F1F1F   // dark_modern editor.background
        )
        nonisolated static let bgRaised = Color.adaptive(
            light: 0xE8E8E8,  // light_modern list.hoverBackground
            dark:  0x2A2D2E   // dark_modern list.hoverBackground
        )
        // bgSelected / bgSelectedInactive 当前同色（中性灰）—— 见 spec 01 注释。
        nonisolated static let bgSelectedInactive = Color.adaptive(
            light: 0xE8E8E8,  // 浅色用 hover 同色
            dark:  0x37373D   // dark_modern list.inactiveSelectionBackground
        )
        nonisolated static let bgSelected = Color.adaptive(
            light: 0xE8E8E8,
            dark:  0x37373D
        )

        // 描边
        // light source: panel.border / contrastBorder
        nonisolated static let border = Color.adaptive(
            light: 0xDDDDDD,  // light_modern panel.border
            dark:  0x2B2B2B
        )
        nonisolated static let borderStrong = Color.adaptive(
            light: 0xBBBBBB,
            dark:  0x3B3B3B
        )

        // 文本
        // light source: editor.foreground (#3B3B3B) / descriptionForeground
        nonisolated static let textPrimary = Color.adaptive(
            light: 0x3B3B3B,
            dark:  0xCCCCCC
        )
        nonisolated static let textSecondary = Color.adaptive(
            light: 0x6E6E6E,
            dark:  0x9D9D9D
        )
        nonisolated static let textMuted = Color.adaptive(
            light: 0x9D9D9D,
            dark:  0x6E6E6E
        )

        // Accent（焦点 / 激活 stroke）
        // light source: focusBorder (#005FB8)
        nonisolated static let accent = Color.adaptive(
            light: 0x005FB8,
            dark:  0x0078D4
        )

        // 状态色（对齐 VS Code gitDecoration / testing.icon*）
        nonisolated static let success = Color.adaptive(
            light: 0x388A34,  // light_modern gitDecoration 等
            dark:  0x73C991
        )
        nonisolated static let warning = Color.adaptive(
            light: 0xBF8803,
            dark:  0xE2C08D
        )
        nonisolated static let caution = Color.adaptive(
            light: 0xC26622,
            dark:  0xCC6633
        )
        nonisolated static let danger = Color.adaptive(
            light: 0xE51400,
            dark:  0xF14C4C
        )

        /// SwiftUI hit-test 需要一个 α>0 的填充才会接收鼠标事件；`Color.clear`
        /// 会漏事件给下层。这里给一个 α≈0 的近不可见填充，专用于"鼠标命中区"
        /// 的透明背景（如 SplitContainerView 的 splitter handle）。任何 view 都
        /// 不应在视觉上看到它——若看到了说明用错了。
        ///
        /// 浅 / 深一致：alpha 0.001 的 white 在两边都看不见。
        nonisolated static let hitTestFill = Color.white.opacity(0.001)
    }
}
