import UDesignKit
// uTerm/Views/PreviewTabBar.swift
import SwiftUI
import UniformTypeIdentifiers

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
