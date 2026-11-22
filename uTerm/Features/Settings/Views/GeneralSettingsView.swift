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
    @AppStorage(DefaultsKey.editorAutoSave) private var editorAutoSave = true

    @Environment(AppUpdater.self) private var appUpdater

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: String(localized: "通用", comment: "设置分区"),
                               subtitle: appUpdater.isAvailable ? String(localized: "启动、文件与更新") : String(localized: "启动与文件"))

            SettingsGroup(title: String(localized: "启动", comment: "设置分组：App 启动行为")) {
                SettingsRow(label: String(localized: "启动时", comment: "设置项：App 启动时显示什么"),
                            hint: String(localized: "打开 uTerm 时首先展示的页面")) {
                    UDSegmented(
                        selection: $startupBehaviorRaw.rawValue(StartupBehavior.self, default: .welcome),
                        options: StartupBehavior.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: String(localized: "恢复终端会话"),
                            hint: String(localized: "启动时重新加载上次工作区的标签页与分屏布局")) {
                    UDToggle($restoreTerminalSession)
                }
            }

            SettingsGroup(title: String(localized: "文件", comment: "设置分组：远程文件的编辑")) {
                SettingsRow(label: String(localized: "自动保存", comment: "设置项：编辑远程文件后自动写回主机"),
                            hint: String(localized: "改了远程文件，停下一秒就写回主机。文件在你打开后被别处改过时不覆盖，等你决定；关掉后用 ⌘S 保存")) {
                    UDToggle($editorAutoSave)
                }
            }

            if appUpdater.isAvailable {
                updateGroup
            }
        }
    }

    /// 没配更新源的构建（公开仓库默认如此）没有这一组。
    private var updateGroup: some View {
        SettingsGroup(title: String(localized: "更新", comment: "设置分组：App 更新")) {
            SettingsRow(label: String(localized: "自动检查更新")) {
                UDToggle(Binding(
                    get: { appUpdater.automaticallyChecksForUpdates },
                    set: { appUpdater.automaticallyChecksForUpdates = $0 }
                ))
            }
            SettingsListRow(icon: "arrow.down.circle", tint: UD.accent,
                            title: "uTerm \(AppUpdater.currentVersionString)",
                            subtitle: lastCheckLine) {
                UDButton(title: String(localized: "检查更新"), style: .secondary) {
                    appUpdater.checkForUpdates()
                }
                .disabled(!appUpdater.canCheckForUpdates)
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
