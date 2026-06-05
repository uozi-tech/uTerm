// uTerm/Views/ServerRow.swift
import SwiftUI

/// Welcome 主列表的单行（设计稿 Variant A · HostRow）。
///
/// 56pt 行高：品牌脉冲圆点 + 名称（13.5/medium）+ 等宽 endpoint，右侧是「上次
/// 连接」相对时间与描边分组 chip。选中态用半透明叠底（浅深自适应），不再画左侧竖条
/// —— 选中由更亮的底色 + 脉冲圆点 + 右侧详情面板共同表达。
struct ServerRow: View {
    let profile: ServerProfile
    let query: String
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            UDHostDot(pulse: isSelected)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(HighlightedText.attributed(profile.name, highlighting: query))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                    if profile.isPinned {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(UD.warning)
                    }
                }
                Text(HighlightedText.attributed(profile.displayEndpoint, highlighting: query))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(WelcomeFormat.relative(profile.lastConnectedAt))
                .font(.system(size: 11))
                .foregroundStyle(UD.text3)
                .lineLimit(1)

            UDGroupChip(groupLabel)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture { onTap() }
    }

    private var groupLabel: String {
        if let g = profile.group, !g.isEmpty { return g }
        return "未分组"
    }

    /// 选中 > hover > 透明。用 `Color.primary` 透明叠底，浅色下变深、深色下变浅，
    /// 与设计稿的 white-alpha 叠底等效且自适应外观设置。
    private var rowBackground: Color {
        if isSelected { return Color.primary.opacity(0.06) }
        if hover { return Color.primary.opacity(0.028) }
        return .clear
    }
}
