import SwiftUI

/// 递归渲染一个 `TabModel` 的布局树。
struct TabContentView: View {
    let tab: TabModel
    /// 关闭整个标签（关闭最后一个窗格时触发）。
    let onCloseTab: () -> Void
    /// 标签拖到当前 tab 的某个 pane 时触发。
    let onDropTab: @MainActor @Sendable (_ sourceTab: UUID, _ targetPane: UUID,
                                         _ zone: PaneDropZone) -> Void
    /// 文件 buffer 拖到当前 tab 的某个 pane 时触发。
    let onDropFile: @MainActor @Sendable (_ sourceBuffer: UUID, _ targetPane: UUID,
                                          _ zone: PaneDropZone) -> Void
    /// 文件 pane 中不可预览提示的下载入口。
    var onDownloadFile: ((FileBuffer, URL) async throws -> Void)? = nil
    /// 文件 pane 中 Markdown 图片加载入口。
    let onLoadMarkdownImage: MarkdownBufferImageLoader
    /// Workspace 级拖拽源。
    let workspaceDragSource: WorkspaceDragSource?
    /// 窗格拖拽开始时通知 workspace 登记源。
    let onBeginPaneDrag: @MainActor @Sendable (_ sourcePane: UUID) -> Void
    /// Workspace 级同步 drop 入口。
    let onDropDragSource: @MainActor @Sendable (_ targetPane: UUID,
                                                _ zone: PaneDropZone) -> Bool

    /// 当前标签的拖拽会话状态，所有窗格共享一份。拖拽全程鼠标按住，
    /// 切不了标签，故无需随 tab 重建。
    @State private var dragState = PaneDragState()

    var body: some View {
        // root 是单 leaf 时窗格头部由 titlebar chip 代为表达，隐藏 header。
        nodeView(tab.root, showsHeader: !tab.root.isSingleLeaf)
            // 拖拽幽灵层：跟随光标的浮动 NSPanel，读共享 dragState 的快照。
            // 处于工作区 NSWindow 视图树内，幽灵子面板能正确认领父窗口。
            .overlay { PaneDragGhostLayer(dragState: dragState) }
            .onChange(of: workspaceDragSource) { _, source in
                if source == nil, dragState.draggingPaneID == nil {
                    dragState.hover = nil
                }
            }
    }

    // Returns AnyView to break the opaque-type recursion that arises when a
    // @ViewBuilder `some View` function calls itself — the compiler cannot
    // resolve the self-referential concrete type at compile time.
    private func nodeView(_ node: LayoutNode, showsHeader: Bool) -> AnyView {
        switch node {
        case .leaf(let paneID):
            if let pane = tab.panes[paneID] {
                return AnyView(PaneView(
                    pane: pane,
                    isFocused: tab.focusedPaneID == paneID,
                    dragState: dragState,
                    workspaceDragSource: workspaceDragSource,
                    onFocus: { tab.focusedPaneID = paneID },
                    onBeginPaneDrag: onBeginPaneDrag,
                    onSplit: { direction in
                        tab.splitPane(paneID, direction: direction,
                                      serverProfileID: pane.serverProfileID)
                    },
                    onMoveOrSwap: { source, zone in
                        if zone == .center {
                            tab.swapPanes(source, paneID)
                        } else {
                            tab.movePane(source, toTarget: paneID, zone: zone)
                        }
                    },
                    onTabDrop: { sourceTab, zone in
                        onDropTab(sourceTab, paneID, zone)
                    },
                    onFileDrop: { sourceBuffer, zone in
                        onDropFile(sourceBuffer, paneID, zone)
                    },
                    onDownloadFile: onDownloadFile,
                    onLoadMarkdownImage: onLoadMarkdownImage,
                    onWorkspaceDrop: { zone in
                        onDropDragSource(paneID, zone)
                    },
                    onClose: {
                        if !tab.closePane(paneID) { onCloseTab() }
                    },
                    showsHeader: showsHeader))
            } else {
                return AnyView(Color.clear)   // 不应发生：树与 panes 映射不一致
            }
        case .split(let s):
            // split 节点忽略入参 showsHeader —— 子 leaf 一律带 header。
            return AnyView(SplitContainerView(
                direction: s.direction,
                fraction: s.fraction,
                onFractionChange: { tab.setFraction($0, splitID: s.id) },
                first: { nodeView(s.first, showsHeader: true) },
                second: { nodeView(s.second, showsHeader: true) }))
        }
    }
}
