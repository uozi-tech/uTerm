import UDesignKit
// uTerm/Views/ServerRow.swift
import SwiftUI

enum ServerRowLayout {
    /// Welcome 主列表行内容到选中/焦点背景边界的四周内边距。
    nonisolated static let contentPadding: CGFloat = UD.Space.xl
}

enum ServerGroupBadgeTint {
    nonisolated static func color(for groupName: String?, in groupColorHexes: [String: String]) -> Color? {
        guard let groupName, !groupName.isEmpty,
              let colorHex = groupColorHexes[groupName] else { return nil }
        let rgb = groupHexRGB(colorHex)
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

/// Welcome 主列表的单行（设计稿 Variant A · HostRow）。
///
/// 等边内距：品牌脉冲圆点 + 名称（13.5/medium）+ 等宽 endpoint，右侧是「上次
/// 连接」相对时间与描边分组 chip。选中态用半透明叠底（浅深自适应），不再画左侧竖条
/// —— 选中由更亮的底色 + 脉冲圆点 + 右侧详情面板共同表达。
struct ServerRow: View {
    let profile: ServerProfile
    let query: String
    let isSelected: Bool
    let groupColor: Color?
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                UDHostDot(color: groupColor ?? UD.accent, pulse: isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(HighlightedText.attributed(profile.name, highlighting: query))
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(UD.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(profile.name)
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
                        .truncationMode(.middle)
                        .help(profile.displayEndpoint)
                }

                Spacer(minLength: 6)

                Text(WelcomeFormat.relative(profile.lastConnectedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)

                UDGroupChip(groupLabel, tint: groupColor)
            }
            .padding(ServerRowLayout.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap() })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name)，\(profile.displayEndpoint)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
