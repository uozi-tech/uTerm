import SwiftUI

/// 设置 · 通用 tab。已实现：
/// - 启动：启动行为 + 恢复终端会话（spec 02）
/// - 外观：主题（spec 05）+ 语言（spec 06，i18n 基础设施，文案翻译留后续子 spec）
/// - 更新：自动检查更新 + 立即检查（spec 07 in-app；EdDSA + appcast 待 07b）
struct GeneralSettingsView: View {
    @AppStorage("startupBehavior") private var startupBehaviorRaw: String = StartupBehavior.welcome.rawValue
    @AppStorage("restoreTerminalSession") private var restoreTerminalSession = true
    @AppStorage("appearancePreference") private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue
    @AppStorage("appLanguage") private var appLanguageRaw: String = AppLanguage.system.rawValue

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system },
            set: { appearancePreferenceRaw = $0.rawValue }
        )
    }

    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRaw) ?? .system },
            set: { appLanguageRaw = $0.rawValue }
        )
    }

    private var startupBehaviorBinding: Binding<StartupBehavior> {
        Binding(
            get: { StartupBehavior(rawValue: startupBehaviorRaw) ?? .welcome },
            set: { startupBehaviorRaw = $0.rawValue }
        )
    }

    @Environment(AppUpdater.self) private var appUpdater

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "启动") {
                SettingsRow(label: "启动时",
                            hint: "打开 uTerm 时首先展示的页面") {
                    UDSegmented(
                        selection: startupBehaviorBinding,
                        options: StartupBehavior.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: "恢复终端会话",
                            hint: "启动时重新加载上次工作区的标签与分屏布局") {
                    UDToggle($restoreTerminalSession)
                }
            }

            SettingsGroup(title: "外观") {
                SettingsRow(label: "主题",
                            hint: "立即生效。改主题影响 uTerm 窗口外观；终端配色独立，不受此设置影响。") {
                    UDSegmented(
                        selection: appearanceBinding,
                        options: AppearancePreference.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: "语言",
                            hint: "改语言后需重启 uTerm 生效。") {
                    UDSegmented(
                        selection: appLanguageBinding,
                        options: AppLanguage.allCases.map { ($0, $0.localizedLabel) })
                }
            }

            SettingsGroup(title: "更新") {
                SettingsRow(label: "自动检查更新") {
                    UDToggle(Binding(
                        get: { appUpdater.automaticallyChecksForUpdates },
                        set: { appUpdater.automaticallyChecksForUpdates = $0 }
                    ))
                }
                UpdateStatusPanel()
            }
        }
    }
}

/// 内联状态面板：左侧绿点 + 中间状态文字 + 右侧 "检查更新" 按钮。
/// 设计稿 GeneralTab "更新" 区组的信息条样式。
private struct UpdateStatusPanel: View {
    @Environment(AppUpdater.self) private var appUpdater

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(UD.success)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text)
                Text("当前版本 \(AppUpdater.currentVersionString)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(UD.text3)
            }

            Spacer()

            SettingsInlineButton(title: "检查更新", enabled: appUpdater.canCheckForUpdates) {
                appUpdater.checkForUpdates()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.025)))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(UD.border, lineWidth: 1)
        )
    }

    private var statusLine: String {
        if let date = appUpdater.lastUpdateCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "上次检查：\(formatter.localizedString(for: date, relativeTo: Date()))"
        } else {
            return "从未检查更新"
        }
    }
}
