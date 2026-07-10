import SwiftUI

/// uTerm DesignKit 徽章原语合集 —— 小型标签 / 计数 / 状态点 / 键帽（设计稿
/// `Components.html` Badges & Keys）。
///
/// 纯展示组件：只读 `UD` token + 普通值输入，不依赖任何 domain model。
/// 一文件多原语，配合列表行 / 工具条 / 命令面板等场景拼装。

// MARK: - 分组芯片 GroupChip

/// 分组标签芯片（如「生产环境」「测试」）。淡灰 / tint 填充胶囊，无描边（v2）。
struct UDGroupChip: View {
    let label: String
    let tint: Color?

    init(_ label: String, tint: Color? = nil) {
        self.label = label
        self.tint = tint
    }

    var body: some View {
        Text(label)
            .font(UD.caption)
            .foregroundStyle(textColor)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.xs, style: .continuous)
                    .fill(fillColor)
            )
    }

    private var textColor: Color {
        tint ?? UD.text3
    }

    private var fillColor: Color {
        tint?.opacity(0.14) ?? UD.dyn(.white(0.055), .black(0.065))
    }
}

/// 可选择的分组标签芯片。用于表单里的分组快速填充；选中 = accent 14% 软底 + accent 文字
/// （「驾驶舱」样式），未选 = 淡灰填充；均无描边（v2）。
struct UDSelectableGroupChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(UD.caption)
                .foregroundStyle(selected ? UD.accentInk : UD.text3)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: UD.Radius.xs, style: .continuous)
                        .fill(selected ? UD.accentSoft : UD.dyn(.white(0.045), .black(0.055)))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 计数徽章 CountBadge

/// 计数小徽章（未读 / 数量）。`accent` 为高亮态（蓝软底）。
struct UDCountBadge: View {
    let count: String
    let accent: Bool

    init(_ count: String, accent: Bool = false) {
        self.count = count
        self.accent = accent
    }

    /// 便捷 `Int` 入口。
    init(_ count: Int, accent: Bool = false) {
        self.init(String(count), accent: accent)
    }

    var body: some View {
        Text(count)
            .font(UD.mono(10.5))
            .foregroundStyle(accent ? UD.accentInk : UD.text2)
            .padding(.horizontal, 5)
            .frame(minWidth: 18)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accent ? UD.accent.opacity(0.15)
                                 : UD.dyn(.white(0.06), .black(0.07)))
            )
    }
}

// MARK: - 主机状态点 HostDot

/// 主机 / 端点状态点（Ø8）。`pulse` 时外圈呼吸光晕。
struct UDHostDot: View {
    let color: Color
    let pulse: Bool

    init(color: Color = UD.accent, pulse: Bool = false) {
        self.color = color
        self.pulse = pulse
    }

    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size: CGFloat = 8

    var body: some View {
        ZStack {
            if pulse && !reduceMotion {
                Circle()
                    .fill(color)
                    .padding(-2)
                    .opacity(0.18)
                    .scaleEffect(animate ? 1.1 : 0.9)
                    .opacity(animate ? 0.0 : 0.18)
                    .animation(
                        .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                        value: animate
                    )
                    .onAppear { animate = true }
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 键帽 Kbd

/// 单个键帽（如 ⌘ / K / esc）。淡灰填充、无描边、无投影（v2 拍平）。
struct UDKbd: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(UD.monoKbd)
            .foregroundStyle(UD.text2)
            .padding(.horizontal, 5)
            .frame(minWidth: 18)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.xs, style: .continuous)
                    .fill(UD.dyn(.white(0.04), .black(0.055)))
            )
    }
}

// MARK: - 组合键 KeyCombo

/// 组合键序列（如 ⌘⇧N）。横排键帽。
struct UDKeyCombo: View {
    let keys: [String]

    init(_ keys: [String]) {
        self.keys = keys
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                UDKbd(key)
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: UD.Space.xxl) {
        HStack(spacing: UD.Space.md) {
            UDGroupChip("生产环境")
            UDSelectableGroupChip(label: "测试", selected: true) {}
            UDCountBadge(12)
            UDCountBadge(4, accent: true)
            UDCountBadge("99+")
        }
        HStack(spacing: UD.Space.lg) {
            UDHostDot()
            UDHostDot(pulse: true)
            UDHostDot(color: UD.success, pulse: true)
        }
        HStack(spacing: UD.Space.md) {
            UDKbd("⌘")
            UDKbd("K")
            UDKbd("↩")
            UDKbd("esc")
            UDKeyCombo(["⌘", "⇧", "N"])
        }
    }
    .padding(UD.Space.xxxl)
    .background(UD.bg)
}
