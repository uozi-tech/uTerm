import UDesignKit
// uTerm/Views/PreviewTabBar.swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum PreviewTabCloseScope {
    case selected
    case others
    case tabsToRight
    case all
}

/// 根据右键命中的标签和当前顺序生成关闭队列。保持为纯值逻辑，便于覆盖边界条件，
/// 具体关闭仍交给上层的未保存确认流程。
nonisolated enum PreviewTabMenuPlanner {
    static func closeTargets(
        for scope: PreviewTabCloseScope,
        targetID: UUID,
        orderedIDs: [UUID]
    ) -> [UUID] {
        guard let targetIndex = orderedIDs.firstIndex(of: targetID) else { return [] }

        switch scope {
        case .selected:
            return [targetID]
        case .others:
            return orderedIDs.filter { $0 != targetID }
        case .tabsToRight:
            let nextIndex = orderedIDs.index(after: targetIndex)
            return Array(orderedIDs[nextIndex...])
        case .all:
            return orderedIDs
        }
    }
}

/// 预览区上沿的 tab 条 —— 一个 tab 一个 FileBuffer。
/// chip 用 DesignKit `UDPreviewTab`；激活底色传编辑器正文色以与下方编辑器无缝衔接。
struct PreviewTabBar: View {
    let model: FilePreviewModel
    let onBeginDrag: @MainActor @Sendable (_ bufferID: UUID) -> Void
    /// 请求关闭某 buffer（含脏文件确认，由上层提供）。
    let onRequestClose: (UUID) -> Void

    static let tabBarBackgroundColor = EditorTheme.background

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(model.buffers.enumerated()), id: \.element.id) { index, buf in
                        UDPreviewTab(
                            name: buf.displayName,
                            active: model.activeBufferID == buf.id,
                            first: index == 0,
                            dirty: buf.isDirty,
                            transient: model.isPreviewTab(buf.id),
                            systemImage: Self.icon(for: buf.kind),
                            activeBackground: Color(nsColor: EditorTheme.background),
                            onSelect: { model.selectTab(buf.id) },
                            onDoubleTap: { model.keepTab(buf.id) },   // 双击 tab：预览转正
                            onClose:  { onRequestClose(buf.id) })
                            .frame(maxHeight: .infinity)
                            // 选中态供 VoiceOver 念读；脏标记并入文件名标签。
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(Text(buf.isDirty ? "\(buf.displayName)（未保存）" : buf.displayName))
                            .accessibilityAddTraits(
                                model.activeBufferID == buf.id ? [.isButton, .isSelected] : .isButton)
                            .contextMenu {
                                PreviewTabContextMenu(
                                    buffer: buf,
                                    isPreview: model.isPreviewTab(buf.id),
                                    orderedBufferIDs: model.buffers.map(\.id),
                                    onKeepOpen: { model.keepTab(buf.id) },
                                    onRequestClose: onRequestClose)
                            }
                            .onDrag {
                                onBeginDrag(buf.id)
                                return FileBufferDragPayload.itemProvider(bufferID: buf.id)
                            } preview: {
                                Label(buf.displayName, systemImage: Self.icon(for: buf.kind))
                                    .font(.callout)
                                    .padding(6)
                                    .foregroundStyle(UD.text2)
                            }
                    }
                }
                .frame(maxHeight: .infinity)
                .accessibilityElement(children: .contain)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 36)
        .background(Color(nsColor: Self.tabBarBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
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

private struct PreviewTabContextMenu: View {
    let buffer: FileBuffer
    let isPreview: Bool
    let orderedBufferIDs: [UUID]
    let onKeepOpen: () -> Void
    let onRequestClose: (UUID) -> Void

    var body: some View {
        if isPreview {
            Button(action: onKeepOpen) {
                Label("保留标签页", systemImage: "pin")
            }
            Divider()
        }

        Button { close(.selected) } label: {
            Label("关闭", systemImage: "xmark")
        }
        Button { close(.others) } label: {
            Label("关闭其他标签页", systemImage: "xmark.square")
        }
        .disabled(targets(for: .others).isEmpty)
        Button { close(.tabsToRight) } label: {
            Label("关闭右侧标签页", systemImage: "arrow.right.to.line")
        }
        .disabled(targets(for: .tabsToRight).isEmpty)
        Button { close(.all) } label: {
            Label("关闭所有标签页", systemImage: "xmark.rectangle")
        }

        Divider()

        Button { Self.copy(buffer.displayName) } label: {
            Label("拷贝文件名", systemImage: "doc.on.clipboard")
        }
        Button { Self.copy(buffer.remotePath) } label: {
            Label("拷贝路径", systemImage: "doc.on.doc")
        }
    }

    private func targets(for scope: PreviewTabCloseScope) -> [UUID] {
        PreviewTabMenuPlanner.closeTargets(
            for: scope,
            targetID: buffer.id,
            orderedIDs: orderedBufferIDs)
    }

    private func close(_ scope: PreviewTabCloseScope) {
        for id in targets(for: scope) {
            onRequestClose(id)
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
