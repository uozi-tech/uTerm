import UDesignKit
import SwiftUI
import AppKit

/// 设置 · 诊断：日志等级（与 iOS 同步）/ 打开 Console 看 uTerm 的日志（原「高级」的最后一组）。
struct DiagnosticsSettingsView: View {
    @AppStorage(DefaultsKey.logLevel) private var logLevelRaw: String = LogLevel.info.rawValue

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: "诊断", subtitle: String(localized: "日志等级与系统日志"))

            SettingsGroup(title: "日志",
                          footer: String(localized: "在 Console.app 的 Subsystem 过滤栏输入 com.uozi.uTerm，可只看 uTerm 的日志。")) {
                SettingsRow(label: "日志等级", hint: LogLevel.settingsHint) {
                    UDSegmented(selection: $logLevelRaw.rawValue(LogLevel.self, default: .info),
                                options: LogLevel.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsListRow(icon: "doc.text.magnifyingglass", tint: UD.text2,
                                title: String(localized: "显示日志"),
                                subtitle: "com.uozi.uTerm", subtitleStyle: .monospaced) {
                    UDButton(title: "打开 Console", style: .secondary, action: openConsole)
                }
            }
        }
    }

    private func openConsole() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(url)
    }
}
