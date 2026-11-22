import SwiftUI

/// 设置 › 诊断：日志等级（与 Mac 同步，共享的 `AppLogger` 在 iOS 上同样按它过滤）。
/// Debug 构建另有「布局诊断」开关。
struct SettingsDiagnosticsSection: View {
    @AppStorage(DefaultsKey.logLevel) private var logLevelRaw = LogLevel.info.rawValue

    private var logLevel: Binding<LogLevel> {
        $logLevelRaw.rawValue(LogLevel.self, default: .info)
    }

    var body: some View {
        MInsetGroup(header: String(localized: "诊断"), footer: LogLevel.settingsHint) {
            MInsetRow(icon: "diag", label: String(localized: "日志等级"), last: true,
                      trailing: AnyView(
                          MMenu {
                              ForEach(LogLevel.allCases) { level in
                                  Button(level.localizedLabel) { logLevel.wrappedValue = level }
                              }
                          } label: {
                              HStack(spacing: 4) {
                                  Text(logLevel.wrappedValue.localizedLabel)
                                      .font(M.sans(15)).foregroundStyle(M.text2)
                                  MIcon(name: "chev-down", size: 11, color: M.text4)
                              }
                          }))
        }
        #if DEBUG
        DebugLayoutDiagnosticsGroup()
        #endif
    }
}

#if DEBUG
/// 仅 Debug 构建：布局诊断浮层开关（见 MLayoutDiagnostics）。
private struct DebugLayoutDiagnosticsGroup: View {
    @AppStorage(MLayoutDiagnostics.key) private var layoutDiagnostics = false

    var body: some View {
        MInsetGroup(header: String(localized: "调试"), footer: String(localized: "在屏幕左下角显示安全区、状态栏保留区与终端视图几何，供截图排查布局。仅 Debug 构建可见。")) {
            MInsetRow(label: String(localized: "布局诊断"), last: true,
                      trailing: AnyView(MSwitch(on: $layoutDiagnostics)))
        }
    }
}
#endif
