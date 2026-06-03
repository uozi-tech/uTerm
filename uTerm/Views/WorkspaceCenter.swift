import SwiftUI

/// 工作区中央列：上预览 / 下终端，VSplitView 可拖。比例通过 WorkspaceUIState
/// 持久化（VSplitView 不暴露 binding，本期用 idealHeight 近似默认 2:1；
/// 用户拖完后的写回 uiState 留待后续 polish）。
struct WorkspaceCenter: View {
    let workspace: WorkspaceModel
    let server: ServerProfile

    var body: some View {
        VSplitView {
            PreviewArea(model: workspace.filePreviewModel)
                .frame(minHeight: 120,
                       idealHeight: idealPreviewHeight)
            TerminalArea(workspace: workspace, server: server)
                .frame(minHeight: 200,
                       idealHeight: idealTerminalHeight)
        }
        .background(WS.bg)
    }

    // 默认比例 0.667，参考总高 720 → preview ≈ 480 / terminal ≈ 240，
    // 双方都满足各自的 minHeight (120 / 200)。Fix #3：之前用 480 作参考时
    // terminal=160 < minHeight 200 → VSplitView 强制下限，比例被静默忽略。
    private var idealPreviewHeight: CGFloat { 720 * workspace.uiState.previewTerminalRatio }
    private var idealTerminalHeight: CGFloat { 720 * (1 - workspace.uiState.previewTerminalRatio) }
}
