import UDesignKit
import SwiftUI

/// 设置 · 外观：主题 / 强调色 / 语言（原在「通用」里）。三项都与 iOS 同步，语言只有 mac 有入口。
struct AppearanceSettingsView: View {
    @AppStorage(DefaultsKey.appearancePreference) private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue
    @AppStorage(DefaultsKey.appLanguage) private var appLanguageRaw: String = AppLanguage.system.rawValue

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "外观") {
                SettingsRow(label: "主题",
                            hint: "立即生效。改主题影响 uTerm 窗口外观与终端配色（终端按主题自动切深/浅）。") {
                    UDSegmented(
                        selection: $appearancePreferenceRaw.rawValue(AppearancePreference.self, default: .system),
                        options: AppearancePreference.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: "强调色",
                            hint: "选中 / 按钮 / 高亮的主色，立即全局生效。") {
                    AccentSwatchPicker()
                }
                SettingsRow(label: "语言",
                            hint: "改语言后需重启 uTerm 生效。") {
                    UDSegmented(
                        selection: $appLanguageRaw.rawValue(AppLanguage.self, default: .system),
                        options: AppLanguage.allCases.map { ($0, $0.localizedLabel) })
                }
            }
        }
    }
}

/// 强调色色板：横排 5 个圆色板，当前选中显示 ✓。点选写 AccentState.shared.selected。
private struct AccentSwatchPicker: View {
    @Bindable private var accent = AccentState.shared
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focusedColor: AccentColor?

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AccentColor.allCases) { color in
                let isSelected = accent.selected == color
                let isFocused = focusedColor == color
                Circle()
                    .fill(color.base(dark: scheme == .dark).color())
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(isSelected ? 1 : 0)
                    )
                    // 键盘焦点环：focusable 时 accent 描边外扩 3pt（与圆色板区隔）。
                    .overlay(
                        Circle()
                            .strokeBorder(UD.accent, lineWidth: isFocused ? 2 : 0)
                            .padding(-3)
                    )
                    .contentShape(Circle())
                    .onTapGesture { accent.selected = color }
                    .focusable()
                    .focused($focusedColor, equals: color)
                    .help(color.label)
                    .accessibilityLabel(color.label)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("强调色")
    }
}

