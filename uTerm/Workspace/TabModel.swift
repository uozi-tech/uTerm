import SwiftUI

/// 一个工作区标签：持有一棵 `LayoutNode` 布局树、窗格 id → `PaneModel` 映射、
/// 当前聚焦窗格。树是值类型，窗格模型在映射里。
@MainActor
@Observable
final class TabModel: Identifiable {
    let id: UUID
    var title: String
    private(set) var root: LayoutNode
    private(set) var panes: [UUID: PaneModel]
    var focusedPaneID: UUID?

    var focusedPane: PaneModel? {
        guard let id = focusedPaneID else { return nil }
        return panes[id]
    }

    /// 新建一个只有单窗格的标签，窗格连 `rootServerProfileID`、种类为 `kind`。
    init(id: UUID = UUID(), title: String, rootServerProfileID: UUID, kind: PaneKindTag) {
        self.id = id
        self.title = title
        let pane = PaneModel(serverProfileID: rootServerProfileID, kind: kind)
        self.root = .leaf(paneID: pane.id)
        self.panes = [pane.id: pane]
        self.focusedPaneID = pane.id
    }

    /// 用一棵已构建的树 + 窗格映射构造（持久化恢复用）。
    init(id: UUID = UUID(), title: String,
         root: LayoutNode, panes: [UUID: PaneModel]) {
        self.id = id
        self.title = title
        self.root = root
        self.panes = panes
        self.focusedPaneID = root.firstLeafID
    }

    /// 对聚焦窗格分屏；新窗格连与聚焦窗格相同的服务器、沿用其 kind，并成为新的聚焦。
    func splitFocusedPane(direction: SplitDirection) {
        guard let focusedPane else { return }
        let newPane = PaneModel(serverProfileID: focusedPane.serverProfileID,
                                kind: focusedPane.kind.tag)
        panes[newPane.id] = newPane
        root = root.splitting(paneID: focusedPane.id, direction: direction,
                              newPaneID: newPane.id, splitID: UUID())
        focusedPaneID = newPane.id
    }

    /// 在 `paneID` 处按 `direction` 分屏，新窗格连 `serverProfileID`、种类 `kind`。
    func splitPane(_ paneID: UUID, direction: SplitDirection,
                   serverProfileID: UUID, kind: PaneKindTag) {
        guard panes[paneID] != nil else { return }
        let newPane = PaneModel(serverProfileID: serverProfileID, kind: kind)
        panes[newPane.id] = newPane
        root = root.splitting(paneID: paneID, direction: direction,
                              newPaneID: newPane.id, splitID: UUID())
        focusedPaneID = newPane.id
    }

    /// 关闭一个窗格。返回 `false` 表示这是最后一个窗格（标签应被关闭）。
    @discardableResult
    func closePane(_ paneID: UUID) -> Bool {
        guard let newRoot = root.removingLeaf(paneID: paneID) else {
            return false
        }
        panes[paneID]?.dispose()
        panes[paneID] = nil
        root = newRoot
        if focusedPaneID == paneID {
            focusedPaneID = newRoot.firstLeafID
        }
        return true
    }

    func setFraction(_ fraction: Double, splitID: UUID) {
        root = root.settingFraction(fraction, splitID: splitID)
    }

    /// 关闭整个标签前调用：dispose 所有窗格。
    func disposeAll() {
        for pane in panes.values { pane.dispose() }
        panes.removeAll()
    }
}
