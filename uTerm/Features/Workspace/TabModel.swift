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

    /// 新建一个只有单窗格的标签，窗格连 `rootServerProfileID`。
    init(id: UUID = UUID(), title: String, rootServerProfileID: UUID) {
        self.id = id
        self.title = title
        let pane = PaneModel(serverProfileID: rootServerProfileID)
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

    /// 对聚焦窗格分屏；新窗格连与聚焦窗格相同的服务器，并成为新的聚焦。
    func splitFocusedPane(direction: SplitDirection) {
        guard let focusedPane else { return }
        let newPane = PaneModel(serverProfileID: focusedPane.serverProfileID,
                                fileBuffer: focusedPane.fileBuffer)
        panes[newPane.id] = newPane
        root = root.splitting(paneID: focusedPane.id, direction: direction,
                              newPaneID: newPane.id, splitID: UUID())
        focusedPaneID = newPane.id
    }

    /// 在 `paneID` 处按 `direction` 分屏。终端窗格复制终端；文件窗格复制文件 buffer。
    func splitPane(_ paneID: UUID, direction: SplitDirection,
                   serverProfileID: UUID, newLeafFirst: Bool = false) {
        guard let sourcePane = panes[paneID] else { return }
        let newPane = PaneModel(serverProfileID: serverProfileID,
                                fileBuffer: sourcePane.fileBuffer)
        panes[newPane.id] = newPane
        root = root.splitting(paneID: paneID, direction: direction,
                              newPaneID: newPane.id, splitID: UUID(),
                              newLeafFirst: newLeafFirst)
        focusedPaneID = newPane.id
    }

    /// 在 `target` 的指定投放区插入一个新窗格。
    @discardableResult
    func insertPane(serverProfileID: UUID, toTarget target: UUID,
                    zone: PaneDropZone) -> Bool {
        insertPane(serverProfileID: serverProfileID, fileBuffer: nil,
                   toTarget: target, zone: zone)
    }

    /// 复制一个已有窗格并插入到 `target` 的指定投放区。用于同 tab 拖拽复制：
    /// 终端窗格复制服务器，文件窗格复制文件 buffer。
    @discardableResult
    func insertPane(copying sourcePane: PaneModel, toTarget target: UUID,
                    zone: PaneDropZone) -> Bool {
        insertPane(serverProfileID: sourcePane.serverProfileID,
                   fileBuffer: sourcePane.fileBuffer,
                   toTarget: target,
                   zone: zone)
    }

    /// 在 `target` 的指定投放区插入一个文件 buffer 窗格。
    @discardableResult
    func insertFilePane(_ buffer: FileBuffer, toTarget target: UUID,
                        zone: PaneDropZone) -> Bool {
        guard let targetPane = panes[target] else { return false }
        return insertPane(serverProfileID: targetPane.serverProfileID,
                          fileBuffer: buffer,
                          toTarget: target,
                          zone: zone)
    }

    @discardableResult
    private func insertPane(serverProfileID: UUID, fileBuffer: FileBuffer?,
                            toTarget target: UUID, zone: PaneDropZone) -> Bool {
        let direction: SplitDirection
        let newLeafFirst: Bool
        switch zone {
        case .leading:  direction = .horizontal; newLeafFirst = true
        case .trailing: direction = .horizontal; newLeafFirst = false
        case .top:      direction = .vertical;   newLeafFirst = true
        case .bottom:   direction = .vertical;   newLeafFirst = false
        case .center:   return false
        }
        guard panes[target] != nil else { return false }
        let newPane = PaneModel(serverProfileID: serverProfileID,
                                fileBuffer: fileBuffer)
        panes[newPane.id] = newPane
        root = root.splitting(paneID: target, direction: direction,
                              newPaneID: newPane.id, splitID: UUID(),
                              newLeafFirst: newLeafFirst)
        focusedPaneID = newPane.id
        return true
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

    /// 把 `source` 窗格移到 `target` 窗格的某一侧，重新分屏。
    /// `zone` 为 `.center` 时不处理（应改用 `swapPanes`）。
    func movePane(_ source: UUID, toTarget target: UUID, zone: PaneDropZone) {
        guard source != target,
              panes[source] != nil, panes[target] != nil else { return }
        let direction: SplitDirection
        let newLeafFirst: Bool
        switch zone {
        case .leading:  direction = .horizontal; newLeafFirst = true
        case .trailing: direction = .horizontal; newLeafFirst = false
        case .top:      direction = .vertical;   newLeafFirst = true
        case .bottom:   direction = .vertical;   newLeafFirst = false
        case .center:   return
        }
        guard let removed = root.removingLeaf(paneID: source) else { return }
        root = removed.splitting(paneID: target, direction: direction,
                                 newPaneID: source, splitID: UUID(),
                                 newLeafFirst: newLeafFirst)
        focusedPaneID = source
    }

    /// 交换两个窗格在布局树中的位置。聚焦不变。
    func swapPanes(_ a: UUID, _ b: UUID) {
        guard a != b, panes[a] != nil, panes[b] != nil else { return }
        root = root.swapping(a, b)
    }

    /// 关闭整个标签前调用：dispose 所有窗格。
    func disposeAll() {
        for pane in panes.values { pane.dispose() }
        panes.removeAll()
    }
}
