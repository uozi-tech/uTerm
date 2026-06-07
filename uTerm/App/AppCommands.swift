import SwiftUI

struct AppInfoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            AboutMenuButton()
        }
    }
}

/// 重绑 macOS「设置…」菜单项（⌘,）到自绘的设置 Window（取代 Settings 场景自带项）。
struct SettingsWindowCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            SettingsMenuButton()
        }
    }
}

private struct SettingsMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("设置…") { openWindow(id: SettingsWindow.id) }
            .keyboardShortcut(",", modifiers: .command)
    }
}

private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsTabSelection.key) private var selectedTab = SettingsTab.general.rawValue

    var body: some View {
        Button("关于 \(appName)") {
            selectedTab = SettingsTabSelection.aboutMenuTarget
            openWindow(id: SettingsWindow.id)
        }
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }
}
