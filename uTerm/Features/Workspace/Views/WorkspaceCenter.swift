import UDesignKit
import SwiftUI

/// 工作区中央列：上预览 / 下终端。原生 VSplitView 的分隔条无法染色、在暗色下
/// 渲染成刺眼黑线，故改为自绘：上下两半 spacing 0 紧贴（预览区底部状态条与终端
/// tab 条之间只剩一条 1px UD.border 线），可拖的 `SplitterHandle` 以 overlay +
/// `.position` 浮在接缝上、骑跨边界各 3px —— 不占布局高度，所以不会在状态条下方
/// 撑出一段「死空」把状态文字顶高（接缝两侧均为 UD.bg，死空无处藏身）。
/// fraction 直接回写 WorkspaceUIState.previewTerminalRatio 持久化（拖完即存）。
struct WorkspaceCenter: View {
    let workspace: WorkspaceModel
    let server: ServerProfile
    /// 请求关闭某文件 buffer（含脏文件确认，由 WorkspaceWindowView 提供）。
    let onRequestCloseBuffer: (UUID) -> Void

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let topHeight = max(0, total * workspace.uiState.previewTerminalRatio)
            let fractionBinding = Binding(
                get: { workspace.uiState.previewTerminalRatio },
                set: { workspace.uiState.previewTerminalRatio = $0 })

            VStack(spacing: 0) {
                PreviewArea(
                    model: workspace.filePreviewModel,
                    workspaceDragSource: workspace.dragSource,
                    onBeginDrag: { bufferID in
                        workspace.beginDrag(.fileBuffer(bufferID))
                    },
                    onDropFileDragSource: { targetPanelID, zone in
                        workspace.dropDragSource(ontoPreviewPanel: targetPanelID, zone: zone)
                    },
                    onDropFileProviderPayload: { targetPanelID, bufferID, zone in
                        workspace.dropFileBufferProviderPayload(bufferID,
                                                                ontoPreviewPanel: targetPanelID,
                                                                zone: zone)
                    },
                    onRequestClose: onRequestCloseBuffer)
                    .frame(height: topHeight)
                TerminalArea(workspace: workspace, server: server)
                    .frame(maxHeight: .infinity)
            }
            // 拖动条浮在接缝上：center 落在 y=topHeight，6px 高骑跨边界（上 3px 压在
            // 非交互的状态条底缘、下 3px 压在 tab 条顶缘），仅 1px 线可见。
            .overlay(alignment: .topLeading) {
                SplitterHandle(orientation: .horizontal,
                               fraction: fractionBinding,
                               totalLength: total)
                    .frame(width: geo.size.width)
                    .position(x: geo.size.width / 2, y: topHeight)
            }
        }
        .background(UD.bg)
    }
}
