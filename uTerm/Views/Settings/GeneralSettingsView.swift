import SwiftUI

/// 设置 · 通用 tab。已实现：
/// - 启动：启动行为 + 恢复终端会话（spec 02）
/// - 外观：主题（spec 05）
///
/// 待实现：语言（spec 06）+ 自动检查更新（spec 07）。落地后各自加入新的 SettingsGroup。
struct GeneralSettingsView: View {
    @AppStorage("startupBehavior") private var startupBehaviorRaw: String = StartupBehavior.welcome.rawValue
    @AppStorage("restoreTerminalSession") private var restoreTerminalSession = true
    @AppStorage("appearancePreference") private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system },
            set: { appearancePreferenceRaw = $0.rawValue }
        )
    }

    private var startupBehaviorBinding: Binding<StartupBehavior> {
        Binding(
            get: { StartupBehavior(rawValue: startupBehaviorRaw) ?? .welcome },
            set: { startupBehaviorRaw = $0.rawValue }
        )
    }

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "启动") {
                SettingsRow(label: "启动时",
                            hint: "打开 uTerm 时首先展示的页面") {
                    Picker("", selection: startupBehaviorBinding) {
                        ForEach(StartupBehavior.allCases) { b in
                            Text(b.localizedLabel).tag(b)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }
                SettingsRow(label: "恢复终端会话",
                            hint: "启动时重新加载上次工作区的标签与分屏布局") {
                    Toggle("", isOn: $restoreTerminalSession)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsGroup(title: "外观") {
                SettingsRow(label: "主题",
                            hint: "立即生效。改主题影响 uTerm 窗口外观；终端配色独立，不受此设置影响。") {
                    Picker("", selection: appearanceBinding) {
                        ForEach(AppearancePreference.allCases) { p in
                            Text(p.localizedLabel).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }
            }
        }
    }
}
