import SwiftUI

/// 整个终端工作区：有序标签 + 当前活动标签。
@MainActor
@Observable
final class WorkspaceModel {
    private(set) var tabs: [TabModel] = []
    var activeTabID: UUID?

    init() {}

    /// 从持久化快照重建工作区。
    init(snapshot: WorkspaceSnapshot) {
        for tabSnap in snapshot.tabs {
            var panes: [UUID: PaneModel] = [:]
            let root = Self.buildNode(tabSnap.layout, into: &panes)
            tabs.append(TabModel(title: tabSnap.title, root: root, panes: panes))
        }
        if let idx = snapshot.activeTabIndex, tabs.indices.contains(idx) {
            activeTabID = tabs[idx].id
        } else {
            activeTabID = tabs.first?.id
        }
    }

    var activeTab: TabModel? { tabs.first { $0.id == activeTabID } }

    /// 新开一个标签连指定服务器、种类为 `kind`，并设为活动标签。
    @discardableResult
    func openServer(profileID: UUID, title: String, kind: PaneKindTag) -> TabModel {
        let tab = TabModel(title: title, rootServerProfileID: profileID, kind: kind)
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].disposeAll()
        tabs.remove(at: idx)
        if activeTabID == id {
            activeTabID = tabs.indices.contains(idx) ? tabs[idx].id
                : tabs.indices.contains(idx - 1) ? tabs[idx - 1].id
                : tabs.first?.id
        }
    }

    /// 把某标签移到 `toIndex`（`toIndex` 即目标标签槽位）。
    func moveTab(fromID: UUID, toIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == fromID }) else { return }
        let clamped = max(0, min(toIndex, tabs.count - 1))
        guard from != clamped else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: clamped)
    }

    // MARK: 快照

    func snapshot() -> WorkspaceSnapshot {
        let tabSnaps = tabs.map { tab in
            TabSnapshot(title: tab.title,
                        layout: Self.nodeSnapshot(tab.root, panes: tab.panes))
        }
        let activeIdx = tabs.firstIndex { $0.id == activeTabID }
        return WorkspaceSnapshot(tabs: tabSnaps, activeTabIndex: activeIdx)
    }

    private static func nodeSnapshot(_ node: LayoutNode,
                                     panes: [UUID: PaneModel]) -> NodeSnapshot {
        switch node {
        case .leaf(let paneID):
            let pane = panes[paneID]
            return .leaf(serverProfileID: pane?.serverProfileID ?? UUID(),
                         kind: pane?.kind.tag ?? .terminal)
        case .split(let s):
            return .split(direction: s.direction, fraction: s.fraction,
                          first: nodeSnapshot(s.first, panes: panes),
                          second: nodeSnapshot(s.second, panes: panes))
        }
    }

    private static func buildNode(_ snap: NodeSnapshot,
                                  into panes: inout [UUID: PaneModel]) -> LayoutNode {
        switch snap {
        case .leaf(let serverProfileID, let kind):
            let pane = PaneModel(serverProfileID: serverProfileID, kind: kind)
            panes[pane.id] = pane
            return .leaf(paneID: pane.id)
        case .split(let direction, let fraction, let first, let second):
            return .split(SplitNode(
                id: UUID(), direction: direction, fraction: fraction,
                first: buildNode(first, into: &panes),
                second: buildNode(second, into: &panes)))
        }
    }
}
