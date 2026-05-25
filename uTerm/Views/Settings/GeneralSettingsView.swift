import SwiftUI

/// 设置 · 通用 tab。Spec 02 实现：启动行为 + 恢复终端会话。
///
/// 后续 spec 05（主题）+ spec 06（语言）+ spec 07（自动更新）将各自加入
/// 新的 SettingsGroup；本 spec 只覆盖"启动"区组。
struct GeneralSettingsView: View {
    @AppStorage("startupBehavior") private var startupBehaviorRaw: String = StartupBehavior.welcome.rawValue
    @AppStorage("restoreTerminalSession") private var restoreTerminalSession = true

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
        }
    }
}
