import SwiftUI

/// macOS Settings 窗口（⌘,）—— 5-tab TabView shell。
///
/// 完整实现：AI 服务商 + 关于。
/// 占位：通用 / 终端 / 高级 —— 由后续 spec 02-10 各自填充。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag("general")

            ProvidersSettingsView()
                .tabItem { Label("AI 服务商", systemImage: "sparkles") }
                .tag("providers")

            TerminalSettingsView()
                .tabItem { Label("终端", systemImage: "terminal") }
                .tag("terminal")

            AdvancedSettingsView()
                .tabItem { Label("高级", systemImage: "slider.horizontal.3") }
                .tag("advanced")

            AboutSettingsView()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 720, height: 480)
    }
}
