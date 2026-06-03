import SwiftUI

/// uTerm DesignKit 窗口红绿灯 —— macOS 三个标题栏圆点（关闭 / 最小化 / 缩放）。
///
/// 纯展示组件：不依赖任何 domain model。三色用 macOS 红绿灯**固定值**（非 `UD` token，
/// 因为这是系统约定的窗口控件配色，不随设计主题切换）：红 `#FF5F57` / 黄 `#FEBC2E`
/// / 绿 `#28C840`，每个圆点叠一圈 `rgba(0,0,0,0.25)` ~0.5px 内描边。
///
/// `hovered == true` 时各圆点中心显露字形（× / − / +，~8pt bold，`rgba(0,0,0,0.5)`），
/// 对齐 macOS 悬停态。任一 `onClose` / `onMinimize` / `onZoom` 提供时，对应圆点变为
/// `.plain` 样式 `Button`。
struct UDTrafficLights: View {
    /// 是否显露中心字形（macOS 悬停态）。
    var hovered: Bool = false

    var onClose: (() -> Void)? = nil
    var onMinimize: (() -> Void)? = nil
    var onZoom: (() -> Void)? = nil

    /// 圆点直径 Ø12。
    private static let diameter: CGFloat = 12
    /// 中心字形字号 ~8pt。
    private static let glyphSize: CGFloat = 8

    /// macOS 红绿灯固定色（非 token）。
    private static let red = UD.ColorSpec.hex(0xFF5F57).color()
    private static let yellow = UD.ColorSpec.hex(0xFEBC2E).color()
    private static let green = UD.ColorSpec.hex(0x28C840).color()
    /// 圆点内描边 / 字形色。
    private static let strokeColor = Color.black.opacity(0.25)
    private static let glyphColor = Color.black.opacity(0.5)

    var body: some View {
        HStack(spacing: UD.Space.sm) { // 8
            dot(fill: Self.red, glyph: "xmark", action: onClose)
            dot(fill: Self.yellow, glyph: "minus", action: onMinimize)
            dot(fill: Self.green, glyph: "plus", action: onZoom)
        }
    }

    @ViewBuilder
    private func dot(fill: Color, glyph: String, action: (() -> Void)?) -> some View {
        if let action {
            Button(action: action) { circle(fill: fill, glyph: glyph) }
                .buttonStyle(.plain)
        } else {
            circle(fill: fill, glyph: glyph)
        }
    }

    private func circle(fill: Color, glyph: String) -> some View {
        Circle()
            .fill(fill)
            .overlay(
                Circle().strokeBorder(Self.strokeColor, lineWidth: 0.5)
            )
            .overlay {
                if hovered {
                    Image(systemName: glyph)
                        .font(.system(size: Self.glyphSize, weight: .bold))
                        .foregroundStyle(Self.glyphColor)
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Circle())
    }
}

#Preview("UDTrafficLights") {
    VStack(alignment: .leading, spacing: UD.Space.xxl) {
        UDTrafficLights(hovered: false)
        UDTrafficLights(hovered: true)
    }
    .padding(UD.Space.xxxl)
    .background(UD.bg)
}
