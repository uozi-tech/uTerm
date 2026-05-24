import SwiftUI

/// macOS Settings 窗口（⌘,）。当前只有一个 tab：AI Providers。
/// 未来再加「外观」「快捷键」时挂到同一个 TabView。
struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettingsView()
                .tabItem {
                    Label("AI Providers", systemImage: "sparkles")
                }
                .tag("providers")
        }
        .frame(width: 720, height: 480)
    }
}
