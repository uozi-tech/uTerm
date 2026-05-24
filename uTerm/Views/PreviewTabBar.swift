// uTerm/Views/PreviewTabBar.swift
import SwiftUI
import UniformTypeIdentifiers

/// 预览区上沿的 tab 条 —— 一个 tab 一个 FileBuffer。
struct PreviewTabBar: View {
    let model: FilePreviewModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.buffers) { buf in
                        PreviewTabChip(
                            buffer: buf,
                            isActive: model.activeBufferID == buf.id,
                            onSelect: { model.selectTab(buf.id) },
                            onClose:  { model.close(buf.id, savingIfDirty: true) })
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
        .frame(height: 30)
        .background(AppTheme.Palette.bgPanel)
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
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: 5).fill(AppTheme.Palette.bgSelected)
                }
            }
        )
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle().fill(AppTheme.Palette.accent).frame(width: 2)
                    .padding(.vertical, 3)
            }
        }
        .hoverBackground(cornerRadius: 5, isActive: isActive)
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
