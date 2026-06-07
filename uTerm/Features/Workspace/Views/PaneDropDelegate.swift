import SwiftUI

/// 单个窗格的拖放代理。读 `DropInfo.location` 归类到 `PaneDropZone`，
/// 把悬停写进共享的 `PaneDragState.hover`；落点时回调 `onDrop`。
struct PaneDropDelegate: DropDelegate {
    let targetID: UUID
    let dragState: PaneDragState
    /// 窗格本地坐标系下的尺寸（原点为 0,0）。
    let bounds: CGRect
    /// 落点回调，参数为被拖拽窗格 id 与命中的投放区。
    let onDrop: @MainActor @Sendable (_ source: UUID, _ zone: PaneDropZone) -> Void
    /// 标签落点回调，参数为被拖拽标签 id 与命中的投放区。
    let onTabDrop: @MainActor @Sendable (_ sourceTab: UUID, _ zone: PaneDropZone) -> Void
    /// 文件 buffer 落点回调，参数为被拖拽 buffer id 与命中的投放区。
    let onFileDrop: @MainActor @Sendable (_ sourceBuffer: UUID, _ zone: PaneDropZone) -> Void
    /// Workspace 级同步拖拽源。存在时优先使用它分发 drop，provider 只作兜底。
    let workspaceDragSource: @MainActor @Sendable () -> WorkspaceDragSource?
    /// Workspace 级同步 drop 入口。
    let onWorkspaceDrop: @MainActor @Sendable (_ zone: PaneDropZone) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utermPaneID])
            || info.hasItemsConforming(to: [.utermTabID])
            || info.hasItemsConforming(to: [.utermFileBufferID])
    }

    func dropEntered(info: DropInfo) {
        updateHover(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHover(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // 仅当记录的悬停仍是自己时才清除——兄弟窗格的 dropEntered 可能
        // 已把记录替换掉了，再清会让高亮闪烁。
        if dragState.hover?.paneID == targetID {
            dragState.hover = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = paneDropZone(at: info.location, in: bounds) ?? .center
        let target = targetID
        let onDrop = onDrop
        // 立刻结束拖拽会话，让高亮在落点瞬间消失。end() 幂等。
        dragState.end()
        if workspaceDragSource() != nil {
            return onWorkspaceDrop(zone)
        }

        if let provider = info.itemProviders(for: [.utermPaneID]).first {
            PaneDragPayload.load(from: provider) { source in
                guard let source, source != target else { return }
                Task { @MainActor in
                    onDrop(source, zone)
                }
            }
            return true
        }

        if let provider = info.itemProviders(for: [.utermTabID]).first {
            let onTabDrop = onTabDrop
            TabDragPayload.load(from: provider) { sourceTab in
                guard let sourceTab else { return }
                Task { @MainActor in
                    onTabDrop(sourceTab, zone)
                }
            }
            return true
        }

        guard let provider = info.itemProviders(for: [.utermFileBufferID]).first else {
            return false
        }
        let onFileDrop = onFileDrop
        FileBufferDragPayload.load(from: provider) { sourceBuffer in
            guard let sourceBuffer else { return }
            Task { @MainActor in
                onFileDrop(sourceBuffer, zone)
            }
        }
        return true
    }

    private func updateHover(_ info: DropInfo) {
        if let zone = paneDropZone(at: info.location, in: bounds) {
            dragState.hover = DragHoverTarget(paneID: targetID, zone: zone)
        }
    }
}
