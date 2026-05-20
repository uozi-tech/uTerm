import SwiftUI

/// 递归渲染一个 `TabModel` 的布局树。
struct TabContentView: View {
    let tab: TabModel
    /// 关闭整个标签（关闭最后一个窗格时触发）。
    let onCloseTab: () -> Void

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
                    onFocus: { tab.focusedPaneID = paneID },
                    onSplitHorizontal: {
                        tab.splitPane(paneID, direction: .horizontal,
                                      serverProfileID: pane.serverProfileID,
                                      kind: pane.kind.tag)
                    },
                    onSplitVertical: {
                        tab.splitPane(paneID, direction: .vertical,
                                      serverProfileID: pane.serverProfileID,
                                      kind: pane.kind.tag)
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
