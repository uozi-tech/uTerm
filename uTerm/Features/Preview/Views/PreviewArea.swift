import UDesignKit
import SwiftUI
import UniformTypeIdentifiers

/// 工作区中央上半部的预览/编辑区。Spec 2A 真正动起来 ——
/// 多 tab、可编辑、按 FileKind 分派渲染。
struct PreviewArea: View {
    let model: FilePreviewModel
    /// Workspace 级拖拽源。PreviewArea 只消费文件 tab 拖拽，终端 tab/pane
    /// 仍交给 TerminalArea 自己处理。
    let workspaceDragSource: WorkspaceDragSource?
    let onBeginDrag: @MainActor @Sendable (_ bufferID: UUID) -> Void
    let onDropFileDragSource: @MainActor @Sendable (_ targetPanelID: UUID,
                                                     _ zone: PaneDropZone) -> Bool
    let onDropFileProviderPayload: @MainActor @Sendable (_ targetPanelID: UUID,
                                                         _ bufferID: UUID,
                                                         _ zone: PaneDropZone) -> Bool
    /// 请求关闭某 buffer（含脏文件确认，由上层提供）。
    let onRequestClose: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PreviewTabBar(model: model, onBeginDrag: onBeginDrag, onRequestClose: onRequestClose)
            previewBody
            PreviewStatusRow(model: model)
        }
        // 预览区底色对齐设计稿 = UD.bg（暗色 #101012）：空态 / 最近打开 / 图片棋盘
        // 边距等非编辑器区域都落在这层基底上。真实代码编辑器（CodeEditTextView）
        // 自带 EditorTheme.background 的 NSView 覆在其上，并在暗色下同样解析到 #101012。
        .background(UD.bg)
    }

    private var previewBody: some View {
        Group {
            if let root = model.panelRoot {
                nodeView(root, showsHeader: model.hasMultiplePanels)
            } else {
                PreviewBodyRouter(model: model)
            }
        }
    }

    private func nodeView(_ node: LayoutNode, showsHeader: Bool) -> AnyView {
        switch node {
        case .leaf(let panelID):
            return AnyView(PreviewPanelView(
                model: model,
                panelID: panelID,
                showsHeader: showsHeader,
                isFocused: model.focusedPanelID == panelID,
                workspaceDragSource: workspaceDragSource,
                onDropFile: { zone in onDropFileDragSource(panelID, zone) },
                onDropFileProviderPayload: { bufferID, zone in
                    onDropFileProviderPayload(panelID, bufferID, zone)
                }))
        case .split(let split):
            return AnyView(SplitContainerView(
                direction: split.direction,
                fraction: split.fraction,
                onFractionChange: { model.setPanelFraction($0, splitID: split.id) },
                first: { nodeView(split.first, showsHeader: true) },
                second: { nodeView(split.second, showsHeader: true) }))
        }
    }
}

private struct PreviewPanelView: View {
    let model: FilePreviewModel
    let panelID: UUID
    let showsHeader: Bool
    let isFocused: Bool
    let workspaceDragSource: WorkspaceDragSource?
    let onDropFile: @MainActor @Sendable (_ zone: PaneDropZone) -> Bool
    let onDropFileProviderPayload: @MainActor @Sendable (_ bufferID: UUID,
                                                         _ zone: PaneDropZone) -> Bool

    @State private var panelSize: CGSize = .zero
    @State private var hoverZone: PaneDropZone?

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { panelSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in panelSize = newSize }
            }
        )
        .overlay {
            if let hoverZone {
                PaneDropHighlight(zone: hoverZone)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    (isFocused && showsHeader) ? UD.accent : Color.clear,
                    lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectPanel(panelID) }
        .onDrop(of: [.utermFileBufferID],
                delegate: PreviewPanelDropDelegate(
                    bounds: CGRect(origin: .zero, size: panelSize),
                    hoverZone: $hoverZone,
                    onDrop: onDropFile,
                    onProviderDrop: onDropFileProviderPayload))
        .onChange(of: workspaceDragSource) { _, source in
            if source == nil {
                hoverZone = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let buffer = model.buffer(forPanel: panelID) {
            PreviewBufferBody(buffer: buffer, focusRequest: model.editorFocusRequest,
                              onDownload: { buffer, localURL in
                try await model.download(buffer, to: localURL)
            }, onLoadMarkdownImage: { source, buffer in
                try await model.loadMarkdownImage(source: source, referencedBy: buffer)
            })
        } else {
            EmptyBody(model: model)
        }
    }

    @ViewBuilder
    private var header: some View {
        if let buffer = model.buffer(forPanel: panelID) {
            HStack(spacing: 6) {
                Image(systemName: Self.icon(for: buffer.kind))
                    .font(UD.font(10.5))
                    .foregroundStyle(UD.text3)
                Text(buffer.displayName)
                    .font(UD.font(10.5))
                    .foregroundStyle(isFocused ? UD.text2 : UD.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(buffer.displayName)
                Spacer(minLength: 0)
                Button {
                    _ = model.closePanel(panelID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: PaneHeaderButtonLayout.iconSize))
                        .foregroundStyle(UD.text3)
                        .frame(width: PaneHeaderButtonLayout.hitWidth,
                               height: PaneHeaderButtonLayout.hitHeight)
                }
                .buttonStyle(.plain)
                .help("关闭窗格")
                .accessibilityLabel(Text("关闭窗格"))
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(UD.panel)
            .overlay(alignment: .bottom) {
                Rectangle().fill(UD.border).frame(height: 1)
            }
        }
    }

    private static func icon(for kind: FileKind) -> String {
        switch kind {
        case .code: return "doc.text"
        case .markdown: return "doc.richtext"
        case .image: return "photo"
        case .plainText: return "doc"
        }
    }
}

private struct PreviewPanelDropDelegate: DropDelegate {
    let bounds: CGRect
    @Binding var hoverZone: PaneDropZone?
    let onDrop: @MainActor @Sendable (_ zone: PaneDropZone) -> Bool
    let onProviderDrop: @MainActor @Sendable (_ bufferID: UUID,
                                              _ zone: PaneDropZone) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utermFileBufferID])
    }

    func dropEntered(info: DropInfo) {
        updateHover(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHover(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        hoverZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { hoverZone = nil }
        guard let zone = actionableZone(info) else {
            return false
        }
        if onDrop(zone) {
            return true
        }

        guard let provider = info.itemProviders(for: [.utermFileBufferID]).first else {
            return false
        }
        FileBufferDragPayload.load(from: provider) { bufferID in
            guard let bufferID else { return }
            Task { @MainActor in
                _ = onProviderDrop(bufferID, zone)
            }
        }
        return true
    }

    private func updateHover(_ info: DropInfo) {
        hoverZone = actionableZone(info)
    }

    private func actionableZone(_ info: DropInfo) -> PaneDropZone? {
        guard let zone = paneDropZone(at: info.location, in: bounds),
              zone != .center
        else {
            return nil
        }
        return zone
    }
}
