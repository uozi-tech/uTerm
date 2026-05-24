import SwiftUI

/// 可复用的 hover 背景修饰器 —— 鼠标悬停时切到 `activeColor`，离开归回 `baseColor`。
///
/// 用于列表行 / sidebar 行 / tab chip 等可点击元素的视觉反馈。`isActive` 为
/// true 时（如已选中 / active tab）跳过 hover 切换 —— 选中态优先级高于 hover。
private struct HoverBackground: ViewModifier {
    let activeColor: Color
    let baseColor: Color
    let cornerRadius: CGFloat
    let isPriorityActive: Bool

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(backgroundColor)
            )
            .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if isPriorityActive { return .clear }
        return isHovering ? activeColor : baseColor
    }
}

extension View {
    /// 给可点击行添加 hover 背景。`isActive` 为 true 时不渲染 hover bg（让外部
    /// 的 selected 样式独占）。
    func hoverBackground(_ active: Color = AppTheme.Palette.bgRaised,
                         base: Color = .clear,
                         cornerRadius: CGFloat = 0,
                         isActive: Bool = false) -> some View {
        modifier(HoverBackground(activeColor: active,
                                 baseColor: base,
                                 cornerRadius: cornerRadius,
                                 isPriorityActive: isActive))
    }
}
