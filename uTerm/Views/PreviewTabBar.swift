// uTerm/Views/PreviewTabBar.swift
import SwiftUI
import UniformTypeIdentifiers

/// 预览区上沿的 tab 条 —— 一个 tab 一个 FileBuffer。
struct PreviewTabBar: View {
    let model: FilePreviewModel

    
    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.buffers) { buf in
                        PreviewTabChip(
                            buffer: buf,
                            isActive: model.activeBufferID == buf.id,
                            onSelect: { model.selectTab(buf.id) },
                            onClose:  { model.close(buf.id, savingIfDirty: true) })
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 36)
        .background(WS.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WS.border).frame(height: 1)
        }
    }
}

private struct PreviewTabChip: View {
    let buffer: FileBuffer
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundStyle(WS.text3)
            Text(buffer.displayName)
                .font(WS.mono(12))
                .lineLimit(1)
                .foregroundStyle(isActive ? WS.text : WS.text3)
            if buffer.isDirty {
                Circle()
                    .fill(WS.accent)
                    .frame(width: 6, height: 6)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(WS.text3)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(
            // 活动 tab 用编辑器正文同色（EditorTheme.background），与下方编辑器无缝
            // 衔接；非活动 tab 透明，露出 WS.panel 的 tab 条底。
            isActive ? Color(nsColor: EditorTheme.background) : Color.clear
        )
        .overlay(alignment: .top) {
            // 顶部 2px accent 横线（设计稿活动 tab 标示）。
            if isActive {
                Rectangle().fill(WS.accent).frame(height: 2)
            }
        }
        .hoverBackground(WS.rowHover, cornerRadius: 0, isActive: isActive)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }

    private var iconName: String {
        switch buffer.kind {
        case .code: return "doc.text"
        case .markdown: return "doc.richtext"
        case .image: return "photo"
        case .plainText: return "doc"
        }
    }
}
