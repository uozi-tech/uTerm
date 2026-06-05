import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

enum PaneHeaderButtonLayout {
    nonisolated static let hitWidth: CGFloat = 28
    nonisolated static let hitHeight: CGFloat = 22
    nonisolated static let iconSize: CGFloat = 11
    nonisolated static let cornerRadius: CGFloat = 5
}

/// 渲染一个 `PaneModel`：终端窗格按连接状态显示，文件窗格显示文件浏览内容。
struct PaneView: View {
    let pane: PaneModel
    /// 该窗格是否为所在标签的聚焦窗格（用于高亮）。
    let isFocused: Bool
    /// 当前标签的拖拽会话状态（所有窗格共享一份）。
    let dragState: PaneDragState
    /// Workspace 级拖拽源；tab/file/pane drag 都会登记到这里，drop 时同步消费。
    let workspaceDragSource: WorkspaceDragSource?
    /// 点击窗格时通知上层设置聚焦。
    let onFocus: () -> Void
    /// 窗格拖拽开始时通知 workspace 登记源。
    let onBeginPaneDrag: @MainActor @Sendable (_ sourcePane: UUID) -> Void
    /// 头部「分屏」按钮；方向由 `PaneView` 按窗格长宽比算出后传出。
    let onSplit: (SplitDirection) -> Void
    /// 拖拽落点：把 `source` 窗格按 `zone` 移到本窗格 / 与本窗格交换。
    let onMoveOrSwap: @MainActor @Sendable (_ source: UUID, _ zone: PaneDropZone) -> Void
    /// 标签落点：把 `sourceTab` 作为新窗格插到本窗格旁边。
    let onTabDrop: @MainActor @Sendable (_ sourceTab: UUID, _ zone: PaneDropZone) -> Void
    /// 文件 buffer 落点：把 `sourceBuffer` 作为新窗格插到本窗格旁边。
    let onFileDrop: @MainActor @Sendable (_ sourceBuffer: UUID, _ zone: PaneDropZone) -> Void
    /// Workspace 级同步 drop 入口。
    let onWorkspaceDrop: @MainActor @Sendable (_ zone: PaneDropZone) -> Bool
    /// 头部「关闭窗格」按钮。
    let onClose: () -> Void
    /// 是否渲染窗格头部（图标 + 服务器名 + 分屏 + 关闭）。
    /// 单窗格 tab 由 titlebar 上的 chip 表达标题，header 多余。
    let showsHeader: Bool

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [ServerProfile]

    @State private var paneSize: CGSize = .zero
    /// 窗格根视图的屏幕坐标探针；拖拽开始时用于计算抓取偏移。
    @State private var paneFrameProbe = ViewFrameProbe()

    private var profile: ServerProfile? {
        profiles.first { $0.id == pane.serverProfileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { paneSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in paneSize = newSize }
            }
        )
        .background(ViewFrameReader(probe: paneFrameProbe))
        // 投放区高亮叠在整块窗格上 —— 与 .onDrop 的 bounds、paneSize 量测
        // 同一坐标系（包含头部，当 showsHeader 为 true 时），高亮位置才与
        // paneDropZone 的归类一致。
        .overlay {
            if let zone = dropHighlightZone {
                PaneDropHighlight(zone: zone)
            }
        }
        .overlay {
            if shouldCatchDrop {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onDrop(of: [.utermPaneID, .utermTabID],
                            delegate: paneDropDelegate)
            }
        }
        // 焦点蓝框：只在多窗格 tab（即显示 header 时）出现 —— 单窗格 tab 时
        // 整块区域就是唯一焦点，框纯是视觉噪声。
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    (isFocused && showsHeader) ? UD.accent : Color.clear,
                    lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onDrop(of: [.utermPaneID, .utermTabID],
                delegate: paneDropDelegate)
        .task(id: pane.id) { await connect() }
        .hostKeySheet(pane.hostKeyRelay)
    }

    private var paneDropDelegate: PaneDropDelegate {
        PaneDropDelegate(
            targetID: pane.id,
            dragState: dragState,
            bounds: CGRect(origin: .zero, size: paneSize),
            onDrop: onMoveOrSwap,
            onTabDrop: onTabDrop,
            onFileDrop: onFileDrop,
            workspaceDragSource: { workspaceDragSource },
            onWorkspaceDrop: onWorkspaceDrop)
    }

    /// 窗格头部条：拖拽手柄（图标 + 服务器名）+ 分屏 / 关闭控制。
    private var header: some View {
        HStack(spacing: 6) {
            // 图标 + 名称区域兼作拖拽手柄；尾部按钮在手柄之外，故按钮的
            // mouseDown 不会进入 .onDrag 的潜在拖拽态，保持可点。
            HStack(spacing: 6) {
                Image(systemName: headerIcon)
                    .font(UD.font(10.5))
                    .foregroundStyle(UD.text3)
                Text(headerTitle)
                    .font(UD.font(10.5))
                    .foregroundStyle(isFocused ? UD.text2 : UD.text3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onDrag {
                dragState.begin(paneID: pane.id, preview: makeDragPreview())
                onBeginPaneDrag(pane.id)
                return PaneDragPayload.itemProvider(paneID: pane.id)
            } preview: {
                // 让 AppKit 的拖拽图像不可见——可见幽灵由 PaneDragGhostLayer
                // 渲染（AppKit 的拖拽图像无法可靠控制尺寸）。
                Color.clear.frame(width: 1, height: 1)
            }
            HStack(spacing: 0) {
                PaneHeaderIconButton(systemName: "rectangle.split.2x1",
                                     help: "分屏") {
                    onSplit(autoSplitDirection)
                }
                PaneHeaderIconButton(systemName: "xmark",
                                     help: "关闭窗格",
                                     action: onClose)
            }
        }
        .font(UD.font(10.5))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(UD.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    /// 拖拽开始时捕获幽灵内容快照。
    private func makeDragPreview() -> PaneDragPreview {
        PaneDragPreview(
            name: profile?.name ?? "终端",
            paneSize: paneSize,
            grabOffset: grabOffset())
    }

    /// 抓取点相对窗格左上角的偏移；探针不可用时返回 nil（幽灵居中兜底）。
    private func grabOffset() -> CGSize? {
        guard let frame = paneFrameProbe.screenFrame else { return nil }
        return paneGrabOffset(mouse: NSEvent.mouseLocation, in: frame)
    }

    /// 按窗格当前长宽比选分屏方向：偏宽 → 左右分，偏高 → 上下分。
    private var autoSplitDirection: SplitDirection {
        paneSize.width >= paneSize.height ? .horizontal : .vertical
    }

    /// 当前应在本窗格上显示的投放区高亮；非拖拽悬停目标时为 nil。
    private var dropHighlightZone: PaneDropZone? {
        paneDropHighlightZone(
            paneID: pane.id,
            draggingPaneID: dragState.draggingPaneID,
            workspaceDragSource: workspaceDragSource,
            hover: dragState.hover)
    }

    private var shouldCatchDrop: Bool {
        if dragState.draggingPaneID != nil {
            return true
        }
        switch workspaceDragSource {
        case .pane, .tab:
            return true
        case .fileBuffer, nil:
            return false
        }
    }

    private var headerIcon: String { pane.fileBuffer == nil ? "terminal" : "doc.text" }

    private var headerTitle: String {
        pane.fileBuffer?.displayName ?? profile?.name ?? "终端"
    }

    @ViewBuilder
    private var content: some View {
        if let buffer = pane.fileBuffer {
            fileBufferBody(buffer)
        } else {
            switch pane.session.connectionState {
            case .idle, .connecting:
                VStack(spacing: 10) {
                    UDIndeterminateBar()
                        .frame(width: 140)
                    Text("正在连接…")
                        .font(UD.caption)
                        .foregroundStyle(UD.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected:
                TerminalHostView(terminalView: pane.session.terminalView)
            case .failed(let message):
                stateView(systemImage: "exclamationmark.triangle",
                          title: "连接失败", detail: message, action: "重试")
            case .disconnected:
                stateView(systemImage: "bolt.horizontal.circle",
                          title: "连接已断开", detail: "", action: "重新连接")
            }
        }
    }

    @ViewBuilder
    private func fileBufferBody(_ buffer: FileBuffer) -> some View {
        switch buffer.kind {
        case .code(let lang):
            CodeBody(buffer: buffer, language: LanguageDetector.grammarId(for: lang))
        case .markdown:
            MarkdownBody(buffer: buffer)
        case .image:
            ImageBody(buffer: buffer)
        case .plainText:
            CodeBody(buffer: buffer, language: "")
        }
    }

    private func connect() async {
        if let profile {
            await pane.connect(profile: profile, modelContainer: modelContext.container)
        } else {
            pane.markServerMissing()
        }
    }

    @ViewBuilder
    private func stateView(systemImage: String, title: String,
                           detail: String, action: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(UD.text3)
            Text(title).font(.headline).foregroundStyle(UD.text)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(UD.text3)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            if profile != nil {
                UDButton(title: action) { Task { await connect() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct PaneHeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: PaneHeaderButtonLayout.iconSize))
                .foregroundStyle(hover ? UD.text : UD.text3)
                .frame(width: PaneHeaderButtonLayout.hitWidth,
                       height: PaneHeaderButtonLayout.hitHeight)
                .background(
                    RoundedRectangle(cornerRadius: PaneHeaderButtonLayout.cornerRadius,
                                     style: .continuous)
                        .fill(hover ? UD.rowHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
