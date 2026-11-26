import UPaneTree
import UDesignKit
import SwiftUI
import AppKit

/// Draggable splitter between two panes. Updates the parent's `fraction`
/// binding live during the drag so panes (and the terminal views inside them)
/// reflow in real time — Metal-backed terminals + the readLoop coalescing in
/// `ProcessManager` make this cheap enough to stay smooth.
///
/// 两种外观（分区方案 v3）：
/// - `.line`：卡内两块同底色区域之间的 1pt `UD.border` 线（如工作区的预览 | 终端），命中区
///   7pt 骑在线上，悬停 / 拖动时线转 accent；
/// - `.gap`：两个凹槽之间的 6pt 卡面间隙（终端分屏窗格），静息态什么都不画，悬停浮出
///   2×24 的 `text4` 把手，拖动时把手转 accent（设计稿 `pane-split.jsx`）。
struct SplitterHandle: View {
    enum Orientation {
        case horizontal      // line is horizontal → drags vertically
        case vertical        // line is vertical → drags horizontally
    }

    enum Appearance {
        case line
        case gap
    }

    let orientation: Orientation
    @Binding var fraction: Double
    let totalLength: CGFloat
    var minFraction: Double = 0.15
    var maxFraction: Double = 0.85
    var appearance: Appearance = .gap

    @State private var dragStartFraction: Double?
    @State private var hovering = false

    /// 命中区厚度：`.line` 7pt（线两侧各 3pt），`.gap` 就是 6pt 间隙本身。
    private var hitThickness: CGFloat {
        appearance == .line ? UD.Layout.dividerHitWidth : UD.Layout.wellGap
    }

    var body: some View {
        Rectangle()
            .fill(AppTheme.Palette.hitTestFill)
            .overlay { indicator }
            .frame(
                width: orientation == .vertical ? hitThickness : nil,
                height: orientation == .horizontal ? hitThickness : nil
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    (orientation == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                // Global coordinate space, not `.local`: this handle repositions
                // itself as `fraction` changes, and a `.local` drag measures
                // translation relative to the moving view — so each step shifts
                // the origin under the cursor and the fraction oscillates,
                // making the adjacent panes jitter. Global coordinates stay
                // fixed while the handle moves, so translation accumulates cleanly.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartFraction == nil {
                            dragStartFraction = fraction
                        }
                        let start = dragStartFraction ?? fraction
                        let rawDelta = orientation == .vertical ? value.translation.width : value.translation.height
                        let unclamped = start + Double(rawDelta) / Double(totalLength)
                        fraction = min(max(unclamped, minFraction), maxFraction)
                    }
                    .onEnded { _ in
                        dragStartFraction = nil
                    }
            )
            .accessibilityLabel(Text(orientation == .vertical ? "调整左右窗格宽度" : "调整上下窗格高度"))
            .accessibilityAddTraits(.allowsDirectInteraction)
    }

    @ViewBuilder
    private var indicator: some View {
        let dragging = dragStartFraction != nil
        switch appearance {
        case .line:
            PaneDividerLine(axis: orientation == .vertical ? .vertical : .horizontal,
                            hot: dragging || hovering)
        case .gap:
            Capsule()
                .fill(dragging ? UD.accent : UD.text4)
                .frame(width: orientation == .vertical ? 2 : 24,
                       height: orientation == .vertical ? 24 : 2)
                .opacity(dragging || hovering ? 1 : 0)
                .animation(UDPaneDividerHighlight.animation, value: dragging || hovering)
        }
    }
}

/// 按 `SplitNode` 方向布局两个子视图，中间一条可拖动分隔条。
struct SplitContainerView<First: View, Second: View>: View {
    let direction: SplitDirection
    let fraction: Double
    /// 分隔条拖动时回调新的比例。
    let onFractionChange: (Double) -> Void
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second

    var body: some View {
        GeometryReader { geo in
            let total = direction == .horizontal ? geo.size.width : geo.size.height
            let firstLen = total * fraction
            let bindingFraction = Binding(
                get: { fraction }, set: { onFractionChange($0) })
            if direction == .horizontal {
                HStack(spacing: 0) {
                    first().frame(width: max(0, firstLen))
                    SplitterHandle(orientation: .vertical,
                                   fraction: bindingFraction, totalLength: total)
                    second().frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    first().frame(height: max(0, firstLen))
                    SplitterHandle(orientation: .horizontal,
                                   fraction: bindingFraction, totalLength: total)
                    second().frame(maxHeight: .infinity)
                }
            }
        }
    }
}
