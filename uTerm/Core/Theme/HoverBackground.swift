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
    func hoverBackground(_ active: Color = UD.panelHi,
                         base: Color = .clear,
                         cornerRadius: CGFloat = 0,
                         isActive: Bool = false) -> some View {
        modifier(HoverBackground(activeColor: active,
                                 baseColor: base,
                                 cornerRadius: cornerRadius,
                                 isPriorityActive: isActive))
    }
}

/// 小尺寸图标按钮（toolbar / 路径栏 / tab 栏 +）的 hover 反馈：静止时图标走
/// `textSecondary`，hover 时图标提亮到 `textPrimary` 并叠一层 `bgSelected` 圆角底。
///
/// 比单用 `hoverBackground` 明显 —— 半透明 Liquid Glass sidebar 上仅靠实色背景
/// 切换几乎看不出（hover 用的 bgRaised 压在同色调玻璃上对比极小）。这里两手抓：
/// 背景升一档到对比更大的 `bgSelected`，再叠图标提亮这个可靠的第二信号。
///
/// 注意：用此修饰器的按钮，其图标 **不要** 自己再设 `.foregroundStyle`——否则子级
/// 显式色会盖掉这里随 hover 切换的色，图标就不会提亮。
private struct IconButtonHover: ViewModifier {
    let cornerRadius: CGFloat

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isHovering ? UD.text
                                        : UD.text2)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovering ? UD.rowSelected : .clear)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// 给小尺寸图标按钮添加「提亮图标 + 圆角底」的 hover 反馈。见 `IconButtonHover`。
    /// 用于 toolbar / 路径栏里 22pt 级别的图标按钮，hover 信号比 `hoverBackground`
    /// 更明确。
    func iconButtonHover(cornerRadius: CGFloat = 4) -> some View {
        modifier(IconButtonHover(cornerRadius: cornerRadius))
    }
}

/// `IconButtonHover` 的工作区（WS）版：用恒深色 `WS` 令牌而非随系统外观的
/// `AppTheme.Palette`。给钉死深色的工作区窗口内的小图标按钮（如 SFTP 侧边栏头部）
/// 用，让整块视图统一在一套配色系统里。静止图标走 `UD.text2`，hover 提亮到
/// `UD.text` 并叠一层 `UD.panelHover` 圆角底。同样：用此修饰器的按钮图标 **不要**
/// 自己再设 `.foregroundStyle`。
private struct WSIconButtonHover: ViewModifier {
    let cornerRadius: CGFloat

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isHovering ? UD.text : UD.text2)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovering ? UD.panelHover : .clear)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// `iconButtonHover` 的 WS 令牌版，给工作区深色视图内的小图标按钮用。
    func wsIconButtonHover(cornerRadius: CGFloat = 6) -> some View {
        modifier(WSIconButtonHover(cornerRadius: cornerRadius))
    }
}
