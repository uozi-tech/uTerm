import SwiftUI
import AppKit

/// Draggable splitter between two panes. Updates the parent's `fraction`
/// binding live during the drag so panes (and the SwiftTerm views inside them)
/// reflow in real time — Metal-backed terminals + the readLoop coalescing in
/// `ProcessManager` make this cheap enough to stay smooth.
struct SplitterHandle: View {
    enum Orientation {
        case horizontal      // line is horizontal → drags vertically
        case vertical        // line is vertical → drags horizontally
    }

    let orientation: Orientation
    @Binding var fraction: Double
    let totalLength: CGFloat
    var minFraction: Double = 0.15
    var maxFraction: Double = 0.85

    @State private var dragStartFraction: Double?

    var body: some View {
        Rectangle()
            .fill(AppTheme.Palette.hitTestFill)
            .overlay(
                Rectangle()
                    .fill(dragStartFraction != nil ? WS.accent.opacity(0.6) : Color.clear)
                    .frame(
                        width: orientation == .vertical ? 1 : nil,
                        height: orientation == .horizontal ? 1 : nil
                    )
            )
            .frame(
                width: orientation == .vertical ? 6 : nil,
                height: orientation == .horizontal ? 6 : nil
            )
            .contentShape(Rectangle())
            .onHover { inside in
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
