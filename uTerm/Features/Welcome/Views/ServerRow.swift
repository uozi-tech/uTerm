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
///
/// **渲染成本形态（见 `docs/scroll-perf-findings.md`「欢迎页服务器列表」）**：
/// 这一行曾经整个包在一个 plain `Button` 里、两个 `.help` 常驻、每行现建一个
/// `RelativeDateTimeFormatter`。2000 台档下每行的常驻平台视图与 tooltip 区域
/// 是挂载与 hitTest 的主项。现在三处都收掉了 —— 改动时请守住：
///
/// 1. **不要把行重新包进 `Button`**。点击走 `onTapGesture`，无障碍语义靠下面
///    手工补的 `accessibilityAction`（VoiceOver / 全键盘控制走的就是这条路）。
/// 2. **`.help` 只在悬停行挂**（`help(whenHovering:)`）。`NSToolTipManager`
///    每个滚动 tick 全量重算全窗 tooltip 区域，常驻 `.help` 是按行数收费的。
/// 3. **别在行体里现建 `Formatter`**。`WelcomeFormat` 里有共享实例。
struct ServerRow: View {
    let profile: ServerProfile
    let query: String
    let isSelected: Bool
    let groupColor: Color?
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            UDHostDot(color: groupColor ?? UD.accent, pulse: isSelected)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(HighlightedText.attributed(profile.name, highlighting: query))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(whenHovering: hover, profile.name)
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
                    .help(whenHovering: hover, profile.displayEndpoint)
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
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // 单击选中 / 双击连接。`TapGesture(count: 2)` 挂在前面：SwiftUI 会让
        // 双击优先，单击仍照常触发（与改前 `Button` + `simultaneousGesture` 同行为）。
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture { onTap() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name)，\(profile.displayEndpoint)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // 行不再是 `Button`，AX 的默认动作（VoiceOver ⌃⌥space / 全键盘控制）
        // 必须手工补回，否则整份列表在辅助功能下按不动。
        .accessibilityAction { onTap() }
        .accessibilityAction(named: Text("打开")) { onDoubleTap() }
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
