// uTerm/Views/ServerRow.swift
import SwiftUI

/// Welcome 主列表的单行。avatar + name + endpoint + group tag + 相对时间 + 置顶 ★。
/// 选中态左侧 2px accent 竖条。
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
            Text(relativeTime(profile.lastConnectedAt))
                .font(.caption)
                .foregroundStyle(AppTheme.Palette.textMuted)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(isSelected ? AppTheme.Palette.bgSelected : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(AppTheme.Palette.accent).frame(width: 2)
                    .padding(.vertical, 4)
            }
        }
        // 选中态走 bgSelected；非选中态 hover 给 bgRaised 反馈。
        // 老版本每行尾 0.5px border 在选中下与 bgSelected 撞色显得"双线"，已去除。
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
            Text("—")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Palette.textMuted.opacity(0.5))
                .frame(width: 36)
        }
    }

    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
