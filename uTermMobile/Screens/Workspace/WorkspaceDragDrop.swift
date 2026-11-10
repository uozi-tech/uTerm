import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// 工作区标签拖拽载荷（与 macOS 同一标识，登记在 `uTermMobile-Info.plist`）。
    nonisolated static let utermTabID = UTType(exportedAs: "com.uozi.uterm.tab-id")
}

/// 标签 id 装进 `NSItemProvider`：只给本进程看（`.ownProcess`），拖不到别的 app，
/// 也不是文本，落不进输入框。投放端直接读拖拽开始时记下的 id，不用异步解包。
enum WorkspaceTabDrag {
    nonisolated static func itemProvider(tabID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utermTabID.identifier,
                                            visibility: .ownProcess) { completion in
            completion(Data(tabID.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

/// 拖着标签松手会发生什么。
enum MDropTarget: Equatable {
    /// 停到工作区这一边（拆出新格，或整格换位），见 `MobileWorkspace.dock`。
    case edge(Edge)
    /// 并进这一格。
    case pane(UUID)
}

/// 拖着标签此刻会怎样（悬停时据此让位 / 画高亮，松手时执行）。
enum MTabDragAction: Equatable {
    /// 还在自己那一格的标签条里：只排序，挪到第 `index` 位。不分屏、不画高亮。
    case reorder(index: Int)
    /// 在另一格的标签条上：并进那一格，放在第 `index` 位。
    case insert(paneID: UUID, index: Int)
    /// 离开了标签条、进到格子区域：分屏 / 并入判定（`WorkspaceSplitGeometry.target`）。
    case split(MDropTarget)
}

/// 一格标签条在工作区坐标里的位置，以及条上各标签的位置（拖动判定用）。
struct MStripFrame: Equatable {
    var frame: CGRect
    var chips: [UUID: CGRect] = [:]
}

/// 标签条与标签的位置。不可观察：每次布局 / 滚动都会写，只在拖动判定时读，写它不该触发重绘。
@MainActor
final class WorkspaceStripFrames {
    var strips: [UUID: MStripFrame] = [:]
}

/// 拖动判定：手指还在标签条里（含上下各 `stripTolerance` 的容差）只排序；离开标签条进到格子区域才走分屏判定。
/// 标签条贴着工作区上沿、两端又挨着左右边，不先排除掉的话，在条里横着拖到头就会落进「停到左 / 右边」，
/// 一松手就分了屏（macOS 同一个问题见 uAppKit 1.9.5 `UPaneTabStripDropDelegate`）。
enum WorkspaceTabDragResolver {
    /// 标签条上下的容差：手指拖着走难免上下晃，晃出条外一点不该就变成分屏。
    static let stripTolerance: CGFloat = 20

    @MainActor
    static func action(at point: CGPoint, tabID: UUID, strips: [UUID: MStripFrame],
                       split: WorkspaceSplitGeometry, in workspace: MobileWorkspace,
                       stripHeight: CGFloat) -> MTabDragAction? {
        guard let source = workspace.paneIndex(containing: tabID) else { return nil }
        for pane in workspace.panes {
            guard let strip = strips[pane.id],
                  strip.frame.insetBy(dx: 0, dy: -stripTolerance).contains(point) else { continue }
            let index = insertionIndex(at: point.x, among: pane.tabIDs.filter { $0 != tabID }, chips: strip.chips)
            return pane.id == workspace.panes[source].id ? .reorder(index: index) : .insert(paneID: pane.id, index: index)
        }
        return split.target(at: point, tabID: tabID, in: workspace, stripHeight: stripHeight).map(MTabDragAction.split)
    }

    /// 落在第几位：数一数中线在手指左边的标签（被拖的那个不算）。被拖的标签让位挪动只会把别的标签推离手指，
    /// 所以位置不会来回跳。还没量到位置的标签按它在条上的先后算（排在已量到的后面）。
    static func insertionIndex(at x: CGFloat, among ids: [UUID], chips: [UUID: CGRect]) -> Int {
        ids.reduce(0) { count, id in
            guard let frame = chips[id] else { return count }
            return frame.midX < x ? count + 1 : count
        }
    }
}

/// 一次标签拖动：拎起时记下标签；进到工作区后在标签条里实时让位（被拖标签的原位留成空位，别的标签滑开）；
/// 离开标签条或取消就退回原位；松手执行。只有在标签条里松手才改顺序。
@MainActor
@Observable
final class WorkspaceTabDragTracker {
    /// 让位滑动：0.22s、不回弹的弹簧，与 macOS 标签条（uAppKit UPaneGroups）对齐。
    static let moveAnimation = Animation.spring(duration: 0.22, bounce: 0)

    /// 正在拖的标签（拎起时记下；投放判定要它）。
    private(set) var tabID: UUID?
    /// 拖进了工作区：它在标签条上的位置显示成空位。
    private(set) var isHovering = false
    /// 此刻松手会怎样；排序不画高亮，见 `splitTarget`。
    private(set) var action: MTabDragAction?
    /// 拖动开始时在哪一格的第几位：离开标签条 / 取消时退回这里。
    @ObservationIgnored private var origin: (pane: UUID, index: Int)?

    /// 要画的分屏 / 并入高亮。
    var splitTarget: MDropTarget? {
        switch action {
        case .split(let target): target
        case .insert(let paneID, _): .pane(paneID)
        case .reorder, nil: nil
        }
    }

    /// 是不是正被拖着、原位留空的那枚标签。
    func isPlaceholder(_ id: UUID) -> Bool { isHovering && tabID == id }

    func begin(_ id: UUID) {
        tabID = id
        isHovering = false
        action = nil
        origin = nil
    }

    /// 悬停位置变了。`move` 是标签条里让位滑动用的动画（「减弱动态效果」时传 nil）。
    func update(_ next: MTabDragAction?, in workspace: MobileWorkspace, move: Animation?) {
        guard let tabID else { return }
        if !isHovering {
            guard let pane = workspace.paneIndex(containing: tabID),
                  let index = workspace.panes[pane].tabIDs.firstIndex(of: tabID) else { return }
            origin = (workspace.panes[pane].id, index)
            isHovering = true
        }
        if case .reorder(let index) = next {
            withAnimation(move) { workspace.reorder(tabID, to: index) }
        } else {
            revert(in: workspace, move: move)
        }
        if action != next { action = next }
    }

    /// 松手。`land` 是空位恢复成标签的过渡。
    func drop(_ final: MTabDragAction?, in workspace: MobileWorkspace, move: Animation?, land: Animation?) {
        guard let tabID else { return }
        update(final, in: workspace, move: move)
        switch final {
        case .reorder:
            if let origin, workspace.panes.first(where: { $0.id == origin.pane })?.tabIDs.firstIndex(of: tabID) != origin.index {
                workspace.noteArrangedByHand(tabID)
            }
        case .insert(let paneID, let index):
            withAnimation(move) { workspace.move(tabID, toPane: paneID, at: index) }
            workspace.noteArrangedByHand(tabID)
        case .split(.edge(let edge)):
            workspace.dock(tabID, to: edge)
        case .split(.pane(let paneID)):
            workspace.move(tabID, toPane: paneID)
        case nil:
            break
        }
        finish(land: land)
    }

    /// 拖出工作区或取消：退回原位。
    func cancel(in workspace: MobileWorkspace, move: Animation?, land: Animation?) {
        guard tabID != nil else { return }
        revert(in: workspace, move: move)
        finish(land: land)
    }

    private func revert(in workspace: MobileWorkspace, move: Animation?) {
        guard let tabID, let origin, workspace.paneIndex(containing: tabID).map({ workspace.panes[$0].id }) == origin.pane
        else { return }
        withAnimation(move) { workspace.reorder(tabID, to: origin.index) }
    }

    private func finish(land: Animation?) {
        withAnimation(land) {
            isHovering = false
            action = nil
        }
        tabID = nil
        origin = nil
    }
}

/// 分屏几何：每格的矩形与分隔条位置。布局、拖分隔条、投放区判定共用一份，算法只有一处。
struct WorkspaceSplitGeometry {
    let size: CGSize
    let axis: Axis
    let rects: [CGRect]
    /// 分屏方向上的总长与第一格长度（分隔条在第一格之后，占 1pt）。
    let length: CGFloat
    let firstLength: CGFloat

    init(size: CGSize, paneCount: Int, preferredAxis: Axis?, fraction: CGFloat) {
        self.size = size
        axis = MobileWorkspace.effectiveAxis(preferred: preferredAxis, size: size)
        let horizontal = axis == .horizontal
        length = horizontal ? size.width : size.height
        firstLength = paneCount > 1 ? (length * fraction).rounded() : length
        var rects: [CGRect] = []
        for index in 0..<paneCount {
            let start = index == 0 ? 0 : firstLength + 1
            let extent = index == 0 ? firstLength : length - firstLength - 1
            rects.append(horizontal
                ? CGRect(x: start, y: 0, width: extent, height: size.height)
                : CGRect(x: 0, y: start, width: size.width, height: extent))
        }
        self.rects = rects
    }

    /// 边缘投放带占该方向的比例。
    static let edgeBand: CGFloat = 0.2

    /// 拖到 `point` 松手的结果；nil = 这里松手什么也不会变（不高亮、取消投放）。
    ///
    /// - 靠近工作区某条边（且这个方向放得下）→ 停到那一边。顶边从标签条下沿量起：
    ///   刚从标签条上拎起标签时手指就在顶上，不该一拎起来就亮「停到顶上」。
    /// - 否则落在哪一格就并进哪一格；就是它自己那一格则什么也不做。
    @MainActor
    func target(at point: CGPoint, tabID: UUID, in workspace: MobileWorkspace,
                stripHeight: CGFloat) -> MDropTarget? {
        guard let source = workspace.paneIndex(containing: tabID) else { return nil }
        if workspace.canDock(tabID), let edge = nearestEdge(to: point, stripHeight: stripHeight),
           !isAlready(paneAt: source, docked: edge, workspace: workspace) {
            return .edge(edge)
        }
        guard let index = rects.firstIndex(where: { $0.contains(point) }), index != source,
              index < workspace.panes.count else { return nil }
        return .pane(workspace.panes[index].id)
    }

    private func nearestEdge(to p: CGPoint, stripHeight: CGFloat) -> Edge? {
        var best: (edge: Edge, distance: CGFloat)?
        for edge in MobileWorkspace.dockableEdges(size: size) {
            let distance: CGFloat
            switch edge {
            case .leading: distance = p.x / size.width
            case .trailing: distance = 1 - p.x / size.width
            case .top:
                guard p.y > stripHeight else { continue }
                distance = (p.y - stripHeight) / size.height
            case .bottom: distance = 1 - p.y / size.height
            }
            if distance < Self.edgeBand, distance < (best?.distance ?? .infinity) {
                best = (edge, distance)
            }
        }
        return best?.edge
    }

    /// 它独占的那一格已经在这一边了：松手不会有任何变化。
    @MainActor
    private func isAlready(paneAt index: Int, docked edge: Edge, workspace: MobileWorkspace) -> Bool {
        guard workspace.isSplit, workspace.panes[index].tabIDs.count == 1 else { return false }
        let edgeAxis: Axis = edge == .leading || edge == .trailing ? .horizontal : .vertical
        let wantsFirst = edge == .leading || edge == .top
        return edgeAxis == axis && (index == 0) == wantsFirst
    }

    /// 投放高亮要盖的区域：停边 = 那一侧一半；并进 = 那一格。
    func highlightRect(for target: MDropTarget, panes: [MPane]) -> CGRect {
        switch target {
        case .edge(.leading): return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .edge(.trailing): return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .edge(.top): return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .edge(.bottom): return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        case .pane(let id):
            guard let i = panes.firstIndex(where: { $0.id == id }), i < rects.count else { return .zero }
            return rects[i]
        }
    }
}

/// 投放提示（对齐 macOS `PaneDropHighlight`）：停边 = 那一侧 4pt accent 条 + 10% 填充；
/// 并进 = 2pt 描边 + 6% 填充（只描边时「并进这一格」看起来像没选中）。
struct WorkspaceDropHighlight: View {
    let target: MDropTarget
    @Environment(\.mAccent) private var accent

    var body: some View {
        switch target {
        case .pane:
            RoundedRectangle(cornerRadius: MRadius.sm)
                .strokeBorder(accent, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: MRadius.sm).fill(accent.opacity(0.06)))
        case .edge(let edge):
            Rectangle().fill(accent.opacity(0.10))
                .overlay(alignment: alignment(edge)) {
                    Rectangle().fill(accent)
                        .frame(width: edge == .leading || edge == .trailing ? 4 : nil,
                               height: edge == .top || edge == .bottom ? 4 : nil)
                }
        }
    }

    private func alignment(_ edge: Edge) -> Alignment {
        switch edge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }
}

/// 整个工作区一个投放代理：位置换算成 `MTabDragAction`，悬停时报给视图（让位 / 高亮），松手时执行。
///
/// 在不会有任何变化的地方也回 `.move` 而不是 `.forbidden`：被拒的投放不走 `performDrop`，
/// 标签条里的空位就收不回来。松手时动作为 nil 即原样退回。
struct WorkspaceDropDelegate: DropDelegate {
    let resolve: (CGPoint) -> MTabDragAction?
    let onHover: (MTabDragAction?) -> Void
    let onDrop: (MTabDragAction?) -> Void
    /// 拖出工作区，或这次拖动被取消（UIKit 两种都报成离开）。
    let onExit: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utermTabID])
    }

    func dropEntered(info: DropInfo) {
        onHover(resolve(info.location))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onHover(resolve(info.location))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onExit()
    }

    func performDrop(info: DropInfo) -> Bool {
        onDrop(resolve(info.location))
        return true
    }
}
