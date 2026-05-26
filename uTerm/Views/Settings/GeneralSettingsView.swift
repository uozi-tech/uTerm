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
                SettingsRow(label: "语言",
                            hint: "改语言后需重启 uTerm 生效。") {
                    Picker("", selection: appLanguageBinding) {
                        ForEach(AppLanguage.allCases) { l in
                            Text(l.localizedLabel).tag(l)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }
            }

            SettingsGroup(title: "更新") {
                SettingsRow(label: "自动检查更新") {
                    Toggle("", isOn: Binding(
                        get: { appUpdater.automaticallyChecksForUpdates },
                        set: { appUpdater.automaticallyChecksForUpdates = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
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
                .fill(AppTheme.Palette.success)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text("当前版本 \(AppUpdater.currentVersionString)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.Palette.textMuted)
            }

            Spacer()

            Button("检查更新") {
                appUpdater.checkForUpdates()
            }
            .disabled(!appUpdater.canCheckForUpdates)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.Palette.bgRaised.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(AppTheme.Palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
