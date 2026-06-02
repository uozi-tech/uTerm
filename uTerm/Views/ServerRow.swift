// uTerm/Views/ServerRow.swift
import SwiftUI

/// Welcome 主列表的单行。avatar + name + endpoint + group tag + 置顶 ★。
/// 选中态：左 2px accent 竖条 + bgRaised 浅底；hover 走 hoverBackground。
struct ServerRow: View {
    let profile: ServerProfile
    let query: String
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(HighlightedText.attributed(profile.name, highlighting: query))
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .lineLimit(1)
                    if profile.isPinned {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.Palette.warning)
                    }
                }
                Text(HighlightedText.attributed(profile.displayEndpoint, highlighting: query))
                    .font(.caption)
                    .foregroundStyle(AppTheme.Palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            groupTag
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        // 选中态：左 2px accent 竖条 + 浅 bgRaised 底色（doc comment 承诺）。
        // 不用 bgSelected/bgSelectedInactive（系统语义色下二者有别，与 hover 仍会撞色）。
        // 非选中时 hover 走 .hoverBackground 反馈。
        .background(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(AppTheme.Palette.accent)
                    .frame(width: 2)
            }
        }
        .background(isSelected ? AppTheme.Palette.bgRaised : Color.clear)
        .hoverBackground(isActive: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture { onTap() }
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(AppTheme.Palette.bgRaised)
                .frame(width: 24, height: 24)
            if profile.isPinned {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Palette.warning)
            } else {
                Circle()
                    .fill(AppTheme.Palette.accent)
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private var groupTag: some View {
        if let g = profile.group, !g.isEmpty {
            Text(g)
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Palette.textMuted)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AppTheme.Palette.bgPanel))
        } else {
            Text("未分组")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Palette.textMuted)
                .frame(width: 36)
        }
    }

}
