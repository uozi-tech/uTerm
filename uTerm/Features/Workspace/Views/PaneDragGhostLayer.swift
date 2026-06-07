import SwiftUI

/// 工作区窗格拖拽幽灵的渲染层。挂在 `TabContentView` 的 `.overlay` 上，读取
/// `PaneDragState.paneDragPreview` 并把幽灵渲染到一个跟随光标的浮动 `NSPanel`。
struct PaneDragGhostLayer: View {
    let dragState: PaneDragState

    var body: some View {
        DragGhostWindowBridge(
            preview: dragState.paneDragPreview,
            shadowPadding: PaneGhostCard.shadowPadding
        ) { preview in
            // PaneGhostCard 自带 shadowPadding 留白与投影，无需在此再加 padding。
            PaneGhostCard(name: preview.name, paneSize: preview.paneSize)
        }
        .allowsHitTesting(false)
    }
}
