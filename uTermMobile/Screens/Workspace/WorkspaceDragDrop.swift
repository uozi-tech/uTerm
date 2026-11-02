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
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(accent, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.06)))
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

/// 整个工作区一个投放代理：位置换算成 `MDropTarget`，悬停时报给视图画高亮，松手时执行。
struct WorkspaceDropDelegate: DropDelegate {
    let resolve: (CGPoint) -> MDropTarget?
    let onHover: (MDropTarget?) -> Void
    let onDrop: (MDropTarget) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utermTabID])
    }

    func dropEntered(info: DropInfo) {
        onHover(resolve(info.location))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = resolve(info.location)
        onHover(target)
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        onHover(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = resolve(info.location)
        onHover(nil)
        guard let target else { return false }
        onDrop(target)
        return true
    }
}
