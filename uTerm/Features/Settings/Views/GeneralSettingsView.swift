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
