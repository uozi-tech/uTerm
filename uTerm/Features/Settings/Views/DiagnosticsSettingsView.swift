import UDesignKit
import SwiftUI
import AppKit

/// 设置 · 诊断：日志等级（与 iOS 同步）/ 打开 Console 看 uTerm 的日志（原「高级」的最后一组）。
struct DiagnosticsSettingsView: View {
    @AppStorage(DefaultsKey.logLevel) private var logLevelRaw: String = LogLevel.info.rawValue

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "诊断") {
                SettingsRow(label: "日志等级", hint: LogLevel.settingsHint) {
                    UDSegmented(selection: $logLevelRaw.rawValue(LogLevel.self, default: .info),
                                options: LogLevel.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: "显示日志",
                            hint: "打开 Console.app；在 Subsystem 过滤栏输入下方文本可只看 uTerm 的日志。") {
                    VStack(alignment: .trailing, spacing: 6) {
                        UDButton(title: "打开 Console", style: .secondary, action: openConsole)
                        Text("com.uozi.uTerm")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(UD.text3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func openConsole() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(url)
    }
}
