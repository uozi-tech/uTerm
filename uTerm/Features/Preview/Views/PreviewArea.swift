import AppKit
import SwiftUI
import UDesignKit
import UniformTypeIdentifiers
import UPaneGroups

/// 工作区中央上半部的预览/编辑区 = 共享组件 `UPaneGroupArea`（uAppKit
/// `UPaneGroups`）的 uTerm 装配层：载荷是 `FileBuffer`，面板内容是既有的那套按
/// `FileKind` 分派的正文视图，空组占位是「最近打开」。
///
/// 改造前这里是「一条全局标签栏 + 一棵面板树，每个面板一个标题头」；现在是 VS Code
/// 的编辑组模型 —— 分屏的叶子是**组**，每组自带标签条，全区域唯一一个活动组。
/// 分屏树摊平定位、按 `tab.id` 定身份的面板保活、按下即激活的 NSEvent 探针、
/// 五区拖放与投放高亮、活动态三档，全部在组件里。
struct PreviewArea: View {
    let model: FilePreviewModel
    /// 请求关闭某标签（含脏文件确认，由上层提供）。参数是**标签** id，不是 buffer id。
    let onRequestClose: (UUID) -> Void

    /// 标签条高度。沿用改造前预览区的 36pt（与下方终端标签条同高）。
    private static let stripHeight: CGFloat = 36

    var body: some View {
        // 焦点请求与「每个标签所在组的标签顺序」都在**区域这一层**读掉、捕获进闭包。
        // 两者都是 @Observable 状态：若放进 chip / 面板自己的 body，所有已挂载的
        // chip 与面板都会挂在它们上面，任意一次切标签、改脏标记都要全体重算
        // （uTable 实测：每挂一个面板多 60ms，开/关任意标签都要付）。
        let focusRequest = model.editorFocusRequest
        let closeScopes = closeScopesByTab()
        VStack(spacing: 0) {
            UPaneGroupArea(
                model: model.panes,
                // 复用既有的文件拖拽类型：终端区的窗格投放代理认这个类型，
                // 「预览标签拖进终端窗格」这条既有路径靠它活着。载荷内容从
                // buffer id 变成了标签 id，解析走 `buffer(forDragPayloadID:)`。
                dragType: .utermFileBufferID,
                stripHeight: Self.stripHeight,
                // 不画活动组焦点框：焦点已经由标签条表达（全工作区唯一的 accent 顶条），
                // 再套一圈蓝框是同一件事说两遍。与 uTable 及终端区保持一致。
                showsActiveGroupRing: false,
                descriptor: Self.descriptor(for:),
                content: { tab, _ in
                    PreviewPaneBody(model: model, buffer: tab.payload,
                                    focusRequest: focusRequest)
                },
                emptyGroup: { _ in EmptyBody(model: model) },
                onRequestClose: { onRequestClose($0.id) },
                tabMenu: { tab in
                    PreviewTabContextMenu(
                        buffer: tab.payload,
                        isTransient: tab.isTransient,
                        targetTabID: tab.id,
                        orderedTabIDs: closeScopes[tab.id] ?? [tab.id],
                        onKeepOpen: { model.keepTab(tab.id) },
                        onRequestClose: onRequestClose)
                })
            PreviewStatusRow(model: model)
        }
        // 预览区底色对齐设计稿 = UD.bg（暗色 #101012）：空态 / 最近打开 / 图片棋盘
        // 边距等非编辑器区域都落在这层基底上。真实代码编辑器（CodeEditTextView）
        // 自带 EditorTheme.background 的 NSView 覆在其上，并在暗色下同样解析到 #101012。
        .background(UD.bg)
    }

    /// `[标签 id: 它所在组的标签顺序]`。右键菜单的「关闭其他 / 关闭右侧」按**本组**
    /// 算（VS Code 语义；改造前只有一条全局标签条，两者等价）。
    ///
    /// 在这里一次算完：菜单闭包在 chip 的 body 里求值，若让它自己去读 `panes.allTabs`，
    /// 每个 chip 都会挂在整棵组树上。数组是 COW，一组只有一份存储。
    private func closeScopesByTab() -> [UUID: [UUID]] {
        var out: [UUID: [UUID]] = [:]
        for groupID in model.panes.groupIDs {
            guard let group = model.panes.groups[groupID] else { continue }
            let ids = group.tabs.map(\.id)
            for id in ids { out[id] = ids }
        }
        return out
    }

    /// 一枚 chip 怎么画。**在每个 chip 自己的 body 里求值**（组件保证），不在标签条
    /// 里先算成数组 —— 否则任一文件的 `isDirty` 一变，整条标签条连同所有 chip 重算。
    private static func descriptor(for tab: UPaneTab<FileBuffer>) -> UPaneTabDescriptor {
        let buffer = tab.payload
        return UPaneTabDescriptor(
            title: buffer.displayName,
            icon: .system(icon(for: buffer.kind)),
            isDirty: buffer.isDirty,
            // 面板标题头没了（标题并进 chip），完整路径改由悬停提示给出。
            help: buffer.remotePath)
    }

    static func icon(for kind: FileKind) -> String {
        switch kind {
        case .code: return "doc.text"
        case .markdown: return "doc.richtext"
        case .image: return "photo"
        case .plainText: return "doc"
        }
    }
}

/// 一个已挂载面板的正文。
///
/// 保活取 `.allTabs`，所以**所有**打开的文件都挂着编辑器；`EditorFocusRequest`
/// 因此必须过 `ActivePaneGate`，否则隐藏面板里的编辑器也会去抢窗口 first responder。
/// gate 为 nil 表示宿主只挂活动面板（终端区的文件窗格走这条），视作活动。
private struct PreviewPaneBody: View {
    let model: FilePreviewModel
    let buffer: FileBuffer
    let focusRequest: EditorFocusRequest?

    @Environment(\.activePaneGate) private var activePaneGate

    var body: some View {
        let isActive = activePaneGate?.isActive ?? true
        PreviewBufferBody(
            buffer: buffer,
            focusRequest: isActive ? focusRequest : nil,
            onDownload: { buffer, localURL in
                try await model.download(buffer, to: localURL)
            },
            onLoadMarkdownImage: { source, buffer in
                try await model.loadMarkdownImage(source: source, referencedBy: buffer)
            })
    }
}
