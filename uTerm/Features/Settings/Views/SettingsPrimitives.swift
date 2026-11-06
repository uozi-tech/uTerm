import UDesignKit
import SwiftUI

/// 设置 tab 的滚动容器。外边距 + 区组之间 28pt spacing。
///
/// 用法：
///     SettingsScroll {
///         SettingsGroup(title: "启动") { ... }
///         SettingsGroup(title: "外观") { ... }
///     }
struct SettingsScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                content()
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 设置区组。上方 ALL-CAPS 灰字标题（10.5pt 字距 0.6），下方内容堆叠 4pt 间距。
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(UD.text3)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
        }
    }
}

/// 设置行。左侧 label（可带 hint、可带图标），右侧控件。最小高度 36，纵向 padding 4。
struct SettingsRow<Trailing: View>: View {
    /// hint 的排版：普通说明文字，或可选中的等宽文本（路径、地址这类要复制的值）。
    enum HintStyle {
        case text
        case monospaced
    }

    let label: String
    let hint: String?
    let icon: String?
    let hintStyle: HintStyle
    @ViewBuilder let trailing: () -> Trailing

    init(label: String, hint: String? = nil, icon: String? = nil, hintStyle: HintStyle = .text,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.label = label
        self.hint = hint
        self.icon = icon
        self.hintStyle = hintStyle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: icon == nil ? 16 : 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(UD.text2)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(UD.text)
                if let hint {
                    hintText(hint)
                }
            }
            Spacer()
            // 把行 label 关联到右侧控件——UDToggle / UDSegmented / Slider 等
            // 无内建 label，VoiceOver 借此念出「<标签> 开关 / 选择」而非孤立的「开/关」。
            trailing()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func hintText(_ hint: String) -> some View {
        switch hintStyle {
        case .text:
            Text(hint)
                .font(.system(size: 11.5))
                .foregroundStyle(UD.text3)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        case .monospaced:
            Text(hint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(UD.text3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 自适应表单控件
//
// 分段控制 / 开关已迁移到 DesignKit `UDSegmented` / `UDToggle`（深 / 浅动态，
// 设计稿 Forms 段规格）。本文件保留 SettingsScroll/Group/Row、SettingsNumberField
// 等布局原语；次要按钮直接用 `UDButton(style: .secondary)`。

/// 设置行里的整数输入框。外观对齐 DesignKit 输入框，但改用语义色 token（Settings
/// 窗口随全局浅 / 深外观变化），focus 时加 accent 描边。供需要精确数值、不便用滑块
/// 的设置项直接键入。`minValue` 在提交时钳下界（默认 0），`suffix` 可在框右侧附单位。
struct SettingsNumberField: View {
    @Binding var value: Int
    var width: CGFloat = 110
    var minValue: Int = 0
    var maxValue: Int = .max
    var suffix: String? = nil

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("", value: Binding(
                get: { value },
                set: { value = min(maxValue, max(minValue, $0)) }
            ), format: .number)
                .textFieldStyle(.plain)
                .focused($focused)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(UD.text)
                .padding(.horizontal, 12)
                .frame(width: width, height: 32)
                .background(RoundedRectangle(cornerRadius: 7).fill(UD.inputBg))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? UD.accent : .clear, lineWidth: 1))
                .animation(.easeOut(duration: 0.15), value: focused)
                .accessibilityValue(suffix.map { "\(value) \($0)" } ?? "\(value)")
            if let suffix {
                Text(suffix)
                    .font(.system(size: 13))
                    .foregroundStyle(UD.text3)
            }
        }
    }
}

extension SettingsTone {
    /// 共享状态色调在 macOS 设置页上的颜色。`warning` 沿用系统橙（与之前各页一致）。
    var color: Color {
        switch self {
        case .muted:   return UD.text3
        case .neutral: return UD.text2
        case .active:  return UD.accent
        case .warning: return .orange
        case .success: return UD.success
        case .danger:  return UD.danger
        }
    }
}
