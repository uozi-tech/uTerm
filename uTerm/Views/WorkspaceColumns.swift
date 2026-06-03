import SwiftUI
import AppKit

/// 自绘三栏布局（替代 NavigationSplitView + .inspector）：
/// `[文件 sidebar | 可拖分隔 | 中央 | 可拖分隔 | Agent inspector]`。
/// sidebar / inspector 可折叠（带动画）；列宽由 binding 持久化。
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

/// 列间可拖分隔条：1px UD.border 实线 + 10px 透明命中区；全局坐标拖动调列宽
/// （`sign` = +1 左 sidebar 往右拖变宽 / −1 右 inspector 往右拖变窄），clamp 到 range。
struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let sign: Double

    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(UD.border)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(0.001))   // α>0 才接收鼠标
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
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
            )
    }
}
