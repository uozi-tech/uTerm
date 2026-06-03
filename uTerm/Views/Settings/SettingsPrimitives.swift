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
                .foregroundStyle(AppTheme.Palette.textMuted)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
        }
    }
}

/// 设置行。左侧 label（可带 hint），右侧控件。最小高度 36，纵向 padding 4。
struct SettingsRow<Trailing: View>: View {
    let label: String
    let hint: String?
    @ViewBuilder let trailing: () -> Trailing

    init(label: String, hint: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.label = label
        self.hint = hint
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.Palette.textMuted)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing()
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
    }
}

// MARK: - 自适应表单控件
//
// 设计稿 `Segmented` / `Switch` 的自适应版本。`DarkFormControls` 里的同名
// `DarkSegmented` / `DarkSwitch` 钉死 `WS` 暗色 token，专供恒深色的工作区 /
// 新建服务器 / 密钥窗口；而 Settings 窗口随全局浅 / 深外观变化（且本 tab 正
// 是切外观的地方），故这里改用语义色，浅深两套都成立。替代原生
// `.pickerStyle(.segmented)` 与 `.toggleStyle(.switch)`。

/// 设计稿 `Segmented`：选中段填 accent + 白字、未选 textSecondary；外裹微底 + 细描边。
/// 段宽随内容自适应（非定宽），整体靠右对齐。
struct SettingsSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { opt in
                segment(opt.value, opt.label)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.Palette.border, lineWidth: 1))
    }

    @ViewBuilder
    private func segment(_ value: Value, _ label: String) -> some View {
        let isOn = value == selection
        Button {
            selection = value
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Color.white : AppTheme.Palette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? AppTheme.Palette.accent : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// 设计稿 `Switch`：32×18 胶囊，开 = accent，关 = 中性微底；白色滑块带柔阴影。
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AppTheme.Palette.accent : Color.primary.opacity(0.12))
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// 设计稿信息条里的次要按钮：h26、圆角 6、透明底 + 细描边、hover 微亮。
struct SettingsInlineButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(enabled ? AppTheme.Palette.textSecondary : AppTheme.Palette.textMuted)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering && enabled ? Color.primary.opacity(0.06) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AppTheme.Palette.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}
