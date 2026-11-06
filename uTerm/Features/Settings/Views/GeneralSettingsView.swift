import UDesignKit
import SwiftUI

/// 设置 · 通用 tab。已实现：
/// - 启动：启动行为 + 恢复终端会话（spec 02）
/// - 外观：主题（spec 05）+ 语言（spec 06，i18n 基础设施，文案翻译留后续子 spec）
/// - 更新：自动检查更新 + 立即检查（spec 07 in-app；EdDSA + appcast 待 07b）
struct GeneralSettingsView: View {
    @AppStorage(DefaultsKey.startupBehavior) private var startupBehaviorRaw: String = StartupBehavior.welcome.rawValue
    @AppStorage(DefaultsKey.restoreTerminalSession) private var restoreTerminalSession = true
    @AppStorage(AppLockPreference.key) private var requireAuthAtLaunch = AppLockPreference.defaultValue
    @AppStorage(DefaultsKey.appearancePreference) private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue
    @AppStorage(DefaultsKey.appLanguage) private var appLanguageRaw: String = AppLanguage.system.rawValue

    @Environment(AppUpdater.self) private var appUpdater

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "启动") {
                SettingsRow(label: "启动时",
                            hint: "打开 uTerm 时首先展示的页面") {
                    UDSegmented(
                        selection: $startupBehaviorRaw.rawValue(StartupBehavior.self, default: .welcome),
                        options: StartupBehavior.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: "恢复终端会话",
                            hint: "启动时重新加载上次工作区的标签与分屏布局") {
                    UDToggle($restoreTerminalSession)
                }
                SettingsRow(label: "启动时验证身份",
                            hint: "下次启动 uTerm 时要求 Touch ID 或登录密码 · 改动下次启动生效") {
                    UDToggle($requireAuthAtLaunch)
                }
            }

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

            UDButton(title: "检查更新", style: .secondary) {
                appUpdater.checkForUpdates()
            }
            .disabled(!appUpdater.canCheckForUpdates)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 7).fill(UD.fillFaint))
    }

    private var statusLine: String {
        if let date = appUpdater.lastUpdateCheckDate {
            return "上次检查：\(UFormat.relative(date))"
        } else {
            return "从未检查更新"
        }
    }
}
