import UDesignKit
import SwiftUI

/// 设置 · 外观：主题 / 强调色 / 语言（原在「通用」里）。三项都与 iOS 同步，语言只有 mac 有入口。
struct AppearanceSettingsView: View {
    @AppStorage(DefaultsKey.appearancePreference) private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue
    @AppStorage(DefaultsKey.appLanguage) private var appLanguageRaw: String = AppLanguage.system.rawValue

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: String(localized: "外观", comment: "设置分区"), subtitle: String(localized: "主题、强调色与界面语言"))

            SettingsGroup(title: String(localized: "外观", comment: "设置分区"),
                          footer: String(localized: "主题与强调色立即生效，终端配色随主题自动切换深 / 浅；语言重启 uTerm 后生效。")) {
                SettingsRow(label: String(localized: "主题", comment: "外观主题")) {
                    UDSegmented(
                        selection: $appearancePreferenceRaw.rawValue(AppearancePreference.self, default: .system),
                        options: AppearancePreference.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: String(localized: "强调色")) {
                    UDAccentSwatches.shared
                }
                SettingsRow(label: String(localized: "语言", comment: "界面语言")) {
                    SettingsPicker(
                        selection: $appLanguageRaw.rawValue(AppLanguage.self, default: .system),
                        options: AppLanguage.allCases.map { ($0, $0.localizedLabel) },
                        menuWidth: 160)
                }
            }
        }
        .onChange(of: appLanguageRaw) { _, raw in
            (AppLanguage(rawValue: raw) ?? .system).applyToBundleLocalization()
        }
    }
}
