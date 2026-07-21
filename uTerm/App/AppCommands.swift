import SwiftUI

/// 将所有 Scene 的系统“新建”入口统一成 Welcome 单实例窗口。
/// `Window` 的 `openWindow(id:)` 在窗口已存在时会将其带到前台，关闭后则重新创建。
struct NewWelcomeWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建窗口") {
                openWindow(id: "welcome")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}

extension Scene {
    /// 每个窗口 Scene 都应用同一份 `⌘N` 路由，避免焦点切换后退回系统默认建窗行为。
    func routesNewWindowToWelcome() -> some Scene {
        commands {
            NewWelcomeWindowCommands()
        }
    }
}

struct AppInfoCommands: Commands {
    let appUpdater: AppUpdater

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            AboutMenuButton()
            CheckForUpdatesMenuButton(appUpdater: appUpdater)
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

/// 应用菜单「检查更新…」——复用 Settings 里同一个 `AppUpdater`，
/// 走 Sparkle 默认 UI driver 弹窗报告结果。check 进行中时禁用防 double-click。
private struct CheckForUpdatesMenuButton: View {
    let appUpdater: AppUpdater

    var body: some View {
        Button("检查更新…") {
            appUpdater.checkForUpdates()
        }
        .disabled(!appUpdater.canCheckForUpdates)
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
