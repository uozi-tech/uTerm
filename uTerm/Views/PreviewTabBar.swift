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
        .frame(height: 30)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Palette.border).frame(height: 1)
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
                .font(.caption)
                .foregroundStyle(AppTheme.Palette.textMuted)
            Text(buffer.displayName)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isActive ? AppTheme.Palette.textPrimary
                                          : AppTheme.Palette.textSecondary)
            if buffer.isDirty {
                Circle()
                    .fill(AppTheme.Palette.warning)
                    .frame(width: 6, height: 6)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Palette.textMuted)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(
            // 活动 tab 用 controlBackgroundColor（=主预览区同色），视觉上跟下方主区无缝衔接；
            // 非活动 tab 留空，继承 TabBar 的 .regularMaterial。
            isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear
        )
        .overlay(alignment: .top) {
            // 顶部 1px accent 横线，VS Code Dark Modern 标示活动 tab 的方式
            if isActive {
                Rectangle().fill(AppTheme.Palette.accent).frame(height: 1)
            }
        }
        .hoverBackground(cornerRadius: 0, isActive: isActive)
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
