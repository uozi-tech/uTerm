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
    /// 请求关闭某文件**标签**（含脏文件确认，由 WorkspaceWindowView 提供）。
    let onRequestCloseTab: (UUID) -> Void

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let topHeight = WorkspaceCenterLayout.topHeight(
                total: total, ratio: workspace.uiState.previewTerminalRatio)
            let bounds = WorkspaceCenterLayout.fractionBounds(total: total)
            let fractionBinding = Binding(
                // 读的是**实际生效**的比例而不是存档值：存档可能来自更高的窗口 / 旧的
                // 纯比例 clamp，比现在的下限还小。拿它当拖拽起点，手柄要先空拖一段
                // 才开始动。
                get: { total > 0 ? Double(topHeight / total) : workspace.uiState.previewTerminalRatio },
                set: { workspace.uiState.previewTerminalRatio = $0 })

            VStack(spacing: 0) {
                // 预览区自己是一整套编辑组区域（标签拖拽 / 分屏 / 投放高亮都在
                // `UPaneGroupArea` 里），不再需要工作区级的拖拽源与投放回调。
                PreviewArea(model: workspace.filePreviewModel,
                            onRequestClose: onRequestCloseTab)
                    .frame(height: topHeight)
                TerminalArea(workspace: workspace, server: server)
                    .frame(maxHeight: .infinity)
            }
            // 拖动条浮在接缝上：center 落在 y=topHeight，6px 高骑跨边界（上 3px 压在
            // 非交互的状态条底缘、下 3px 压在 tab 条顶缘），仅 1px 线可见。
            .overlay(alignment: .topLeading) {
                SplitterHandle(orientation: .horizontal,
                               fraction: fractionBinding,
                               totalLength: total,
                               minFraction: bounds.lowerBound,
                               maxFraction: bounds.upperBound)
                    .frame(width: geo.size.width)
                    .position(x: geo.size.width / 2, y: topHeight)
            }
        }
        .background(UD.bg)
    }
}

/// 中央上下分栏的尺寸规则：两半各有一个**以 pt 计**的最小高度。
///
/// 以前只按比例 clamp（0.15…0.85），720pt 的最小窗口下预览区只剩 ~105pt，装不下
/// 「标签条 36 + 空态 + 状态条 22」。`UPaneGroupArea` 给每个组的外壳是定高 frame，
/// 里面的 VStack 装不下就整体居中溢出 —— 标签条被顶出窗口顶部、空态压到状态条
/// 下面。终端区拖到底、没有终端标签时同理。
nonisolated enum WorkspaceCenterLayout {
    /// 预览区：标签条 36 + 状态条 22 + 至少一行「最近打开」标题的正文。
    static let minPreviewHeight: CGFloat = 140
    /// 终端区：标签条 36 + 几行终端 / 空态的「新建终端标签」按钮。
    static let minTerminalHeight: CGFloat = 140

    /// 预览区实际高度：存档比例换算后夹进两半的最小高度之间。
    ///
    /// 窗口矮到两个下限加起来都放不下时（正常有 720pt 最小窗高，只会出现在
    /// GeometryReader 首帧之类的瞬态），各退到一半，保证 `lower <= upper`。
    static func topHeight(total: CGFloat, ratio: Double) -> CGFloat {
        guard total > 0 else { return 0 }
        let (lower, upper) = heightBounds(total: total)
        return min(max(total * CGFloat(ratio), lower), upper)
    }

    /// 拖动条可拖的比例区间，与 `topHeight` 同一套下限。
    static func fractionBounds(total: CGFloat) -> ClosedRange<Double> {
        guard total > 0 else { return 0.15...0.85 }
        let (lower, upper) = heightBounds(total: total)
        return Double(lower / total)...Double(upper / total)
    }

    private static func heightBounds(total: CGFloat) -> (lower: CGFloat, upper: CGFloat) {
        let lower = min(minPreviewHeight, total / 2)
        let upper = max(total - minTerminalHeight, total / 2)
        return (lower, upper)
    }
}
