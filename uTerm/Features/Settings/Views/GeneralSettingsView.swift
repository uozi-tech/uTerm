import UDesignKit
import SwiftUI

/// 设置 · 通用：
/// - 启动：启动行为 + 恢复终端会话（spec 02）
/// - 更新：自动检查更新 + 立即检查（spec 07 in-app；EdDSA + appcast 待 07b）
///
/// 主题 / 强调色 / 语言在「外观」（`AppearanceSettingsView`），应用锁在「安全」（`SecuritySettingsView`）。
struct GeneralSettingsView: View {
    @AppStorage(DefaultsKey.startupBehavior) private var startupBehaviorRaw: String = StartupBehavior.welcome.rawValue
    @AppStorage(DefaultsKey.restoreTerminalSession) private var restoreTerminalSession = true

    @Environment(AppUpdater.self) private var appUpdater

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: "通用", subtitle: String(localized: "启动与更新"))

            SettingsGroup(title: "启动") {
                SettingsRow(label: "启动时",
                            hint: "打开 uTerm 时首先展示的页面") {
                    UDSegmented(
                        selection: $startupBehaviorRaw.rawValue(StartupBehavior.self, default: .welcome),
                        options: StartupBehavior.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: "恢复终端会话",
                            hint: "启动时重新加载上次工作区的标签页与分屏布局") {
                    UDToggle($restoreTerminalSession)
                }
            }

            SettingsGroup(title: "更新") {
                SettingsRow(label: "自动检查更新") {
                    UDToggle(Binding(
                        get: { appUpdater.automaticallyChecksForUpdates },
                        set: { appUpdater.automaticallyChecksForUpdates = $0 }
                    ))
                }
                SettingsListRow(icon: "arrow.down.circle", tint: UD.accent,
                                title: "uTerm \(AppUpdater.currentVersionString)",
                                subtitle: lastCheckLine) {
                    UDButton(title: "检查更新", style: .secondary) {
                        appUpdater.checkForUpdates()
                    }
                    .disabled(!appUpdater.canCheckForUpdates)
                }
            }
        }
    }

    private var lastCheckLine: String {
        if let date = appUpdater.lastUpdateCheckDate {
            return String(localized: "上次检查：\(UFormat.relative(date))")
        } else {
            return String(localized: "从未检查更新")
        }
    }
}
