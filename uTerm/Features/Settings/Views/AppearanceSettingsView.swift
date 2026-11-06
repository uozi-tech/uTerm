import UDesignKit
import SwiftUI

/// 设置 · 外观：主题 / 强调色 / 语言（原在「通用」里）。三项都与 iOS 同步，语言只有 mac 有入口。
struct AppearanceSettingsView: View {
    @AppStorage(DefaultsKey.appearancePreference) private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue
    @AppStorage(DefaultsKey.appLanguage) private var appLanguageRaw: String = AppLanguage.system.rawValue

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: "外观", subtitle: String(localized: "主题、强调色与界面语言"))

            SettingsGroup(title: "外观",
                          footer: String(localized: "主题与强调色立即生效，终端配色随主题自动切换深 / 浅；语言重启 uTerm 后生效。")) {
                SettingsRow(label: "主题") {
                    UDSegmented(
                        selection: $appearancePreferenceRaw.rawValue(AppearancePreference.self, default: .system),
                        options: AppearancePreference.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: "强调色") {
                    AccentSwatchPicker()
                }
                SettingsRow(label: "语言") {
                    UDSegmented(
                        selection: $appLanguageRaw.rawValue(AppLanguage.self, default: .system),
                        options: AppLanguage.allCases.map { ($0, $0.localizedLabel) })
                }
            }
        }
    }
}

/// 强调色色板：横排圆色板，当前选中外加 2pt 同色环。点选写 AccentState.shared.selected。
private struct AccentSwatchPicker: View {
    @Bindable private var accent = AccentState.shared
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focusedColor: AccentColor?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AccentColor.allCases) { color in
                let isSelected = accent.selected == color
                let isFocused = focusedColor == color
                let swatch = color.base(dark: scheme == .dark).color()
                Circle()
                    .fill(swatch)
                    .frame(width: 18, height: 18)
                    // 选中：外扩 3pt 的 2pt 同色环；键盘焦点：同位置的 accent 环（选中时已有环，不再叠）。
                    .overlay(
                        Circle()
                            .strokeBorder(isSelected ? swatch : UD.accent,
                                          lineWidth: isSelected || isFocused ? 2 : 0)
                            .padding(-4)
                    )
                    .padding(4)
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

