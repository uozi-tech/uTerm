import UDesignKit
import SwiftUI
import AppKit

/// 自绘三栏布局（替代 NavigationSplitView + .inspector）：
/// `[文件 sidebar | 可拖分隔 | 中央 | 可拖分隔 | Agent inspector]`。
/// sidebar / inspector 可折叠（带动画）；列宽由 binding 持久化。
///
/// 分区方案 v3.2：三栏同在**一张主内容卡**里（调用方套 `.udCard()`），同为卡面色，
/// 栏间各一条 1pt 竖线（`ColumnResizer`，兼拖拽命中区）；收起的栏连同它的线一起消失，
/// 卡缘直接闭合。
///
/// 列宽几何约束（沿用旧 NavigationSplitView 的不等式，保证 center ≥ 480）：
///   sidebar.max(320) + inspector.max(420) + center.min(480) = 1220 ≤ windowMin(1280)。
struct WorkspaceColumns<Sidebar: View, Center: View, Inspector: View>: View {
    let sidebarVisible: Bool
    let inspectorVisible: Bool
    @Binding var sidebarWidth: Double
    @Binding var inspectorWidth: Double
    private let sidebar: Sidebar
    private let center: Center
    private let inspector: Inspector

    private let sidebarRange = 160.0...320.0
    private let inspectorRange = 220.0...420.0

    init(sidebarVisible: Bool,
         inspectorVisible: Bool,
         sidebarWidth: Binding<Double>,
         inspectorWidth: Binding<Double>,
         @ViewBuilder sidebar: () -> Sidebar,
         @ViewBuilder center: () -> Center,
         @ViewBuilder inspector: () -> Inspector) {
        self.sidebarVisible = sidebarVisible
        self.inspectorVisible = inspectorVisible
        self._sidebarWidth = sidebarWidth
        self._inspectorWidth = inspectorWidth
        self.sidebar = sidebar()
        self.center = center()
        self.inspector = inspector()
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                ColumnResizer(width: $sidebarWidth, range: sidebarRange, sign: 1)
            }

            center
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                ColumnResizer(width: $inspectorWidth, range: inspectorRange, sign: -1)
                inspector
                    .frame(width: inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 列间可拖分隔条（分区方案 v3.2 第 4 条）：卡内 1pt `UD.border` 竖线（两侧同为卡面色），
/// 线上骑一条 7pt 透明命中区（线两侧各 3pt），悬停 / 拖动时线转浅 accent（`UD.accentDivider`）。全局坐标拖动调
/// 列宽（`sign` = +1 左 sidebar 往右拖变宽 / −1 右 inspector 往右拖变窄），clamp 到 range。
///
/// `appearance: .gap` 用于两侧靠底色差分开的场合（SFTP 表格 | 检视器抬升块）：占一条 6pt
/// 卡面间隙、不画线，悬停浮出 2×24 的 `text4` 把手、拖动时转 accent（设计稿 `EdgeResizer`）。
struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let sign: Double
    var appearance: SplitterHandle.Appearance = .line

    @State private var startWidth: Double?
    @State private var hovering = false

    /// 画廊 / 测试用：非 nil 时分隔条一律按这个悬停状态画（合成鼠标事件点不稳 SwiftUI 的悬停）。App 里恒为 nil。
    static var catalogHot: Bool?

    @ViewBuilder
    private var indicator: some View {
        let hot = Self.catalogHot ?? (hovering || startWidth != nil)
        switch appearance {
        case .line:
            PaneDividerLine(axis: .vertical, hot: hot)
        case .gap:
            Capsule()
                .fill(startWidth != nil ? UD.accent : UD.text4)
                .frame(width: 2, height: 24)
                .opacity(hot ? 1 : 0)
                .frame(width: UD.Layout.wellGap)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        indicator
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(0.001))   // α>0 才接收鼠标
                    .frame(width: appearance == .line ? UD.Layout.dividerHitWidth : UD.Layout.wellGap)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                    .gesture(
                        // 全局坐标：分隔条自身随列宽移动，用 .local 会让 origin 在
                        // 光标下漂移、列宽抖动（同 SplitterHandle 的处理）。
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                if startWidth == nil { startWidth = width }
                                let base = startWidth ?? width
                                let delta = Double(value.translation.width) * sign
                                width = min(range.upperBound, max(range.lowerBound, base + delta))
                            }
                            .onEnded { _ in startWidth = nil }
                    )
                    .accessibilityLabel(Text("调整列宽"))
                    .accessibilityAddTraits(.allowsDirectInteraction)
            )
            // 悬停时的 3pt 线与 7pt 命中区都伸出布局的 1pt、压到两侧的栏上。排在它后面的栏（Code 标签页右边的终端、
            // 带底色的面板）会把伸过去那半边盖掉：标题行旁边 3pt、往下只剩 2pt，在标题行底下错一个台阶。
            // 提到兄弟视图之上，线从上到下一样宽（`CodeTabDividerTests`）。
            .zIndex(1)
    }
}

/// 卡内 1pt 分隔线本体（`UDPaneDivider` 加悬停态）：静息 `UD.border`，`hot` 时转浅 accent
/// （`UD.accentDivider`，accent 的 50%；实色太抢眼，2026-11-26）。只画线、不接收鼠标 —— 命中区由调用方叠。
struct PaneDividerLine: View {
    enum Axis { case vertical, horizontal }
    /// 悬停 / 拖动时线的粗细。
    static let hotThickness: CGFloat = 3
    let axis: Axis
    let hot: Bool

    var body: some View {
        Rectangle()
            .fill(UD.border)
            .frame(width: axis == .vertical ? 1 : nil,
                   height: axis == .horizontal ? 1 : nil)
            .frame(maxWidth: axis == .horizontal ? .infinity : nil,
                   maxHeight: axis == .vertical ? .infinity : nil)
            // 悬停 / 拖动时加粗到 3pt 并转浅 accent（1pt 太细、不像能拖，实机反馈）。只画在
            // overlay 里，布局仍按 1pt 算，两侧的栏不会跟着挤动。
            .overlay {
                if hot {
                    Rectangle()
                        .fill(UD.accentDivider)
                        .frame(width: axis == .vertical ? Self.hotThickness : nil,
                               height: axis == .horizontal ? Self.hotThickness : nil)
                }
            }
            .allowsHitTesting(false)
    }
}
