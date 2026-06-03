import SwiftUI

/// uTerm DesignKit 度量 token —— 圆角 / 间距 / 阴影（设计稿 `kit-core.jsx`
/// RadiiSpacing + ElevationTokens）。
///
/// 圆角随容器尺寸递增；间距以 2 的倍数为节奏；阴影用实体投影（无玻璃 / 模糊），
/// 深色更重、浅色更轻，故 `udShadow` 随系统外观自适应。
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

    /// 阴影层级 Elevation。
    enum Shadow {
        /// 卡片 / 行悬停。
        case sm
        /// 下拉 / 菜单 / 弹层。
        case md
        /// 指标卡 / 菜单栏 / 对话框。
        case lg
    }
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

    /// 设计稿 CSS 投影 → SwiftUI 近似（radius ≈ blur/2）。深色重、浅色轻。
    private var layers: [UDShadowLayer] {
        let dark = scheme == .dark
        switch level {
        case .sm:
            return dark
                ? [UDShadowLayer(opacity: 0.45, radius: 6, y: 4)]
                : [UDShadowLayer(opacity: 0.08, radius: 3, y: 1)]
        case .md:
            return dark
                ? [UDShadowLayer(opacity: 0.40, radius: 6, y: 4),
                   UDShadowLayer(opacity: 0.60, radius: 16, y: 10)]
                : [UDShadowLayer(opacity: 0.08, radius: 4, y: 2),
                   UDShadowLayer(opacity: 0.14, radius: 12, y: 8)]
        case .lg:
            return dark
                ? [UDShadowLayer(opacity: 0.50, radius: 9, y: 6),
                   UDShadowLayer(opacity: 0.72, radius: 30, y: 16)]
                : [UDShadowLayer(opacity: 0.10, radius: 6, y: 4),
                   UDShadowLayer(opacity: 0.20, radius: 24, y: 18)]
        }
    }
}

extension View {
    /// 套用 DesignKit 实体投影。随系统外观深 / 浅自适应。
    nonisolated func udShadow(_ level: UD.Shadow) -> some View {
        modifier(UDShadowModifier(level: level))
    }
}
