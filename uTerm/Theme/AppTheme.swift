import SwiftUI

/// uTerm 的语义化色彩 token 命名空间。所有 view 必须用 token 而非硬编码颜色。
/// 当前主题：VS Code Dark Modern（2023+），所有 hex 取自官方
/// `extensions/theme-defaults/themes/dark_modern.json`。未来若加浅色主题，
/// 在 Palette 上做条件分支。
///
/// 标 `nonisolated` 让 token 能在任意上下文读取（含单测）；Color 是 Sendable，
/// `Color(hex:)` 已声明为 nonisolated init，常量化静态属性跨线程安全。
enum AppTheme {
    enum Palette {
        // 背景层（按"亮度递增"排列）
        nonisolated static let bgPanel            = Color(hex: 0x181818)  // Sidebar / StatusBar / TitleBar / TabBar 底 / Aux
        nonisolated static let bgBase             = Color(hex: 0x1F1F1F)  // 主内容区 / 终端 / 代码预览 / 活动 tab（无缝）
        nonisolated static let bgRaised           = Color(hex: 0x2A2D2E)  // hover
        nonisolated static let bgSelectedInactive = Color(hex: 0x37373D)  // 失焦列表选中
        nonisolated static let bgSelected         = Color(hex: 0x04395E)  // 聚焦列表选中（蓝调）

        // 描边
        nonisolated static let border       = Color(hex: 0x2B2B2B)
        nonisolated static let borderStrong = Color(hex: 0x3B3B3B)

        // 文本
        nonisolated static let textPrimary   = Color(hex: 0xCCCCCC)
        nonisolated static let textSecondary = Color(hex: 0x9D9D9D)
        nonisolated static let textMuted     = Color(hex: 0x6E6E6E)

        // Accent（焦点 / 激活 stroke）
        nonisolated static let accent = Color(hex: 0x0078D4)

        // 状态色（对齐 VS Code gitDecoration / testing.icon*）
        nonisolated static let success = Color(hex: 0x73C991)   // 已连接
        nonisolated static let warning = Color(hex: 0xE2C08D)   // 连接中 / 重连（柔和米黄）
        nonisolated static let caution = Color(hex: 0xCC6633)   // 已断开（暖橙红，介于 warning / danger）
        nonisolated static let danger  = Color(hex: 0xF14C4C)   // 失败

        /// SwiftUI hit-test 需要一个 α>0 的填充才会接收鼠标事件；`Color.clear`
        /// 会漏事件给下层。这里给一个 α≈0 的近不可见填充，专用于"鼠标命中区"
        /// 的透明背景（如 SplitContainerView 的 splitter handle）。任何 view 都
        /// 不应在视觉上看到它——若看到了说明用错了。
        nonisolated static let hitTestFill = Color.white.opacity(0.001)
    }
}
