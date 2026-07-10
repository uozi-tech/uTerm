import SwiftUI

/// uTerm DesignKit 度量 token —— 圆角 / 间距 / 阴影（设计稿 `kit-core.jsx`
/// RadiiSpacing + ElevationTokens）。
///
/// 圆角随容器尺寸递增；间距以 2 的倍数为节奏；阴影用实体投影（无玻璃 / 模糊），
/// 深色更重、浅色更轻，故 `udShadow` 随系统外观自适应。
///
/// 阴影调柔（组件视觉交接最终版）：**单层、低不透明度**，不再多层堆叠。
/// 设计稿 CSS 阴影含负 spread（如 `0 8 24 -12`）收紧投影，SwiftUI `.shadow` 无 spread，
/// 故以 `radius ≈ blur/2` 近似模糊半径、再适当压低不透明度补偿缺失的负 spread。
extension UD {
    /// 圆角 Radius。
    enum Radius {
        /// 4 —— 键帽 / 小图标钮。
        nonisolated static let xs: CGFloat = 4
        /// 6 —— 行 / 标签 / 列表项。
        nonisolated static let sm: CGFloat = 6
        /// 8 —— 按钮 / 输入框。
        nonisolated static let md: CGFloat = 8
        /// 10 —— 气泡 / 卡片 / 弹层。
        nonisolated static let lg: CGFloat = 10
        /// 12 —— 窗口 / 菜单栏面板。
        nonisolated static let xl: CGFloat = 12
    }

    /// 间距 Spacing（px）。节奏 4 6 8 10 12 14 18 24。
    enum Space {
        nonisolated static let xxs: CGFloat = 4
        nonisolated static let xs: CGFloat = 6
        nonisolated static let sm: CGFloat = 8
        nonisolated static let md: CGFloat = 10
        nonisolated static let lg: CGFloat = 12
        nonisolated static let xl: CGFloat = 14
        nonisolated static let xxl: CGFloat = 18
        nonisolated static let xxxl: CGFloat = 24
    }

    /// 阴影层级 Elevation。各级均为**单层**柔和投影（不再多层堆叠）。
    enum Shadow {
        /// 卡片 / 行悬停。设计稿 `--u-shadow-sm` `0 2 8 -4`。
        case sm
        /// 悬浮卡片（移动端白卡）：四周等宽（y=0）、淡且发散（user 定）。
        case card
        /// 下拉 / 菜单 / 弹层。设计稿 `--u-shadow-md` `0 8 24 -12`。
        case md
        /// 指标卡 / 菜单栏 / 对话框。设计稿 `--u-shadow-lg` `0 16 40 -16`。
        case lg
        /// 命令面板 / 浮动菜单专用投影（设计稿 `--u-menu-shadow` `0 12 32 -14`）。
        /// 单层柔和 drop shadow，且**不含**窗口级的 `0 0 0 1px` 描边环——浮层只配一条
        /// `UD.border` 细边即可，避免描边叠描边。
        case menu
    }

    /// 模态卡片投影色：暗夜保留浮层深度，日间保持扁平、无 box-shadow。
    nonisolated static let modalShadowColor = dyn(.black(0.6), .black(0))
}

/// 单条投影描述（SwiftUI `.shadow` 无 spread，故用 blur/2 近似设计稿的模糊半径）。
private struct UDShadowLayer {
    let opacity: Double
    let radius: CGFloat
    let y: CGFloat
}

private struct UDShadowModifier: ViewModifier {
    let level: UD.Shadow
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        layers.reduce(AnyView(content)) { view, layer in
            AnyView(view.shadow(color: .black.opacity(layer.opacity),
                                radius: layer.radius, x: 0, y: layer.y))
        }
    }

    /// 设计稿 CSS 投影 → SwiftUI 单层近似。
    /// `radius = blur/2`，`y = offsetY`，不透明度在设计稿值基础上略压低（补偿 SwiftUI
    /// 无负 spread 致投影偏满）。深色重、浅色轻。
    private var layers: [UDShadowLayer] {
        let dark = scheme == .dark
        switch level {
        case .sm:   // CSS 0 2 8 -4  · 深 0.40 / 浅 0.12
            return dark
                ? [UDShadowLayer(opacity: 0.34, radius: 4, y: 2)]
                : [UDShadowLayer(opacity: 0.10, radius: 4, y: 2)]
        case .card: // CSS 0 0 20 · 无偏移四周等宽，淡而发散
            return dark
                ? [UDShadowLayer(opacity: 0.22, radius: 10, y: 0)]
                : [UDShadowLayer(opacity: 0.06, radius: 10, y: 0)]
        case .md:   // CSS 0 8 24 -12 · 深 0.50 / 浅 0.14
            return dark
                ? [UDShadowLayer(opacity: 0.42, radius: 12, y: 8)]
                : [UDShadowLayer(opacity: 0.12, radius: 12, y: 8)]
        case .lg:   // CSS 0 16 40 -16 · 深 0.55 / 浅 0.18
            return dark
                ? [UDShadowLayer(opacity: 0.46, radius: 20, y: 16)]
                : [UDShadowLayer(opacity: 0.16, radius: 20, y: 16)]
        case .menu: // CSS 0 12 32 -14 · 深 0.55 / 浅 0.16
            return dark
                ? [UDShadowLayer(opacity: 0.46, radius: 16, y: 12)]
                : [UDShadowLayer(opacity: 0.14, radius: 16, y: 12)]
        }
    }
}

extension View {
    /// 套用 DesignKit 实体投影。随系统外观深 / 浅自适应。
    nonisolated func udShadow(_ level: UD.Shadow) -> some View {
        modifier(UDShadowModifier(level: level))
    }
}
