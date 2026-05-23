import SwiftUI

/// 递归渲染一个 `TabModel` 的布局树。
struct TabContentView: View {
    let tab: TabModel
    /// 关闭整个标签（关闭最后一个窗格时触发）。
    let onCloseTab: () -> Void

    /// 当前标签的拖拽会话状态，所有窗格共享一份。拖拽全程鼠标按住，
    /// 切不了标签，故无需随 tab 重建。
    @State private var dragState = PaneDragState()

    var body: some View {
        nodeView(tab.root)
    }

    // Returns AnyView to break the opaque-type recursion that arises when a
    // @ViewBuilder `some View` function calls itself — the compiler cannot
    // resolve the self-referential concrete type at compile time.
    private func nodeView(_ node: LayoutNode) -> AnyView {
        switch node {
        case .leaf(let paneID):
            if let pane = tab.panes[paneID] {
                return AnyView(PaneView(
                    pane: pane,
                    isFocused: tab.focusedPaneID == paneID,
                    dragState: dragState,
                    onFocus: { tab.focusedPaneID = paneID },
                    onSplit: { direction in
                        tab.splitPane(paneID, direction: direction,
                                      serverProfileID: pane.serverProfileID,
                                      kind: pane.kind.tag)
                    },
                    onMoveOrSwap: { source, zone in
                        if zone == .center {
                            tab.swapPanes(source, paneID)
                        } else {
                            tab.movePane(source, toTarget: paneID, zone: zone)
                        }
                    },
                    onClose: {
                        if !tab.closePane(paneID) { onCloseTab() }
                    }))
            } else {
                return AnyView(Color.clear)   // 不应发生：树与 panes 映射不一致
            }
        case .split(let s):
            return AnyView(SplitContainerView(
                direction: s.direction,
                fraction: s.fraction,
                onFractionChange: { tab.setFraction($0, splitID: s.id) },
                first: { nodeView(s.first) },
                second: { nodeView(s.second) }))
        }
    }
}
