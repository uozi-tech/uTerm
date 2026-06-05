import SwiftUI
import SwiftData
import AppKit

@main
struct uTermApp: App {
    @AppStorage("appearancePreference")
    private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue

    @AppStorage("appLanguage")
    private var appLanguageRaw: String = AppLanguage.system.rawValue

    @State private var appUpdater = AppUpdater()
    @State private var lockModel: AppLockModel

    private var currentAppearance: AppearancePreference {
        AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    private var currentLocale: Locale? {
        (AppLanguage(rawValue: appLanguageRaw) ?? .system).locale
    }

    /// 启用 CloudKit 同步的 SwiftData 容器。`.automatic` 让 SwiftData
    /// 在用户已登录 iCloud 时自动后台同步，未登录时退化为纯本地。
    let modelContainer: ModelContainer = {
        let config = ModelConfiguration(
            "uTerm",
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(
                for: ServerProfile.self, KnownHost.self, AIProvider.self, SSHKey.self,
                     ChatSession.self, ChatMessageRecord.self,
                configurations: config)
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }()

    init() {
        // Spec 1 之前的单份 workspace.json 已不再使用 —— 启动时清掉。
        WorkspaceStore.purgeLegacyWorkspaceFile()
        // M5 单 anthropic-api-key keychain 条目已被 AIProvider 多 key 取代——清掉旧条目。
        AgentKeychain.purgeLegacy()
        // 启动即应用主题：读 UserDefaults（@AppStorage 此刻还不能保证可读 wrappedValue），
        // 写 NSApp.appearance，避免首帧用错外观闪一下。live 切换由 AppAppearanceSync 负责。
        let raw = UserDefaults.standard.string(forKey: "appearancePreference") ?? ""
        NSApplication.shared.appearance = (AppearancePreference(rawValue: raw) ?? .system).nsAppearance
        // 启动应用锁：读 requireAuthAtLaunch（键不存在视作 true，与 @AppStorage 默认对齐——
        // 同 appearancePreference，UserDefaults.bool 在缺键时返回 false 会误成「关」，故用 object as? Bool）。
        // 锁屏遮罩与首次验证由各 Scene 上的 .appLockGate(lockModel) 驱动。
        let requireAuth = (UserDefaults.standard.object(forKey: "requireAuthAtLaunch") as? Bool) ?? true
        _lockModel = State(initialValue: AppLockModel(
            authenticator: SystemBiometricAuthenticator(),
            requireAuthAtLaunch: requireAuth))
    }

    var body: some Scene {
        // 服务器管理 —— 单实例 Welcome 窗口。自动出现在「窗口」菜单，可重开。
        // 主题由 AppAppearanceSync 驱动（colorScheme env + NSApp.appearance 两路），
        // 不挂 .preferredColorScheme——原因见 AppearancePreference 类型文档。
        Window("uTerm", id: "welcome") {
            WelcomeView()
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
        }
        .modelContainer(modelContainer)

        // 密钥管理 —— 单实例独立窗口（设计稿 keys.jsx）。从 Welcome 工具栏或
        // 新建服务器表单的「打开密钥管理…」用 openWindow(id:"keys") 打开。
        Window("密钥管理", id: "keys") {
            KeyManagerView()
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
        }
        .modelContainer(modelContainer)

        // 工作区窗口 —— 每个绑定一台服务器，可多实例。
        WindowGroup(for: WorkspaceWindowID.self) { $windowID in
            WorkspaceWindowView(windowID: windowID)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
        }
        .modelContainer(modelContainer)
        // 自绘 Cursor 式标题栏：隐藏系统标题栏（红绿灯浮在内容上、内容铺满到顶），
        // 标题栏内容由 WorkspaceTitleBar 自绘。比在 NSWindow 上手动设
        // titlebarAppearsTransparent 可靠 —— 后者在 SwiftUI WindowGroup 下不稳定，
        // 会被系统不透明标题栏盖住（user 实测）。
        .windowStyle(.hiddenTitleBar)
        // 不挂 .windowResizability(.contentMinSize)：macOS 26 实测它把窗口
        // 整个禁止 resize（cursor 都不显示），跟文档说的"只限制 min"不符。
        // 单独写 .frame(minWidth:) on view body 已经能把 contentMinSize 推到
        // AppKit（已 probe 验证 NSWindow.contentMinSize=(1280, 772)），不必加这条。
        .commands {
            // 所有工作区级快捷键的唯一注册点 —— 工具栏按钮不再挂 .keyboardShortcut，
            // 避免双重注册导致的双触发 no-op（Fix #4 + #10）。
            CommandGroup(after: .newItem) {
                Button("新建终端标签") {
                    NotificationCenter.default.post(name: .newTerminalTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            // ⌘S 保存预览区当前 tab。Spec 2A §3 / T18。
            CommandGroup(after: .saveItem) {
                Button("保存") {
                    NotificationCenter.default.post(name: .savePreviewBuffer, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("水平分屏") {
                    NotificationCenter.default.post(name: .splitFocusedPaneVertical, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("显示/隐藏 SFTP") {
                    NotificationCenter.default.post(name: .toggleLeftSidebar, object: nil)
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("显示/隐藏 Agent") {
                    NotificationCenter.default.post(name: .toggleRightInspector, object: nil)
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
            }
        }

        // SFTP 独立窗口 —— 每个绑定一台服务器的纯文件浏览器，可多实例。
        WindowGroup(for: SFTPWindowID.self) { $sftpID in
            SFTPWindowView(windowID: sftpID)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
        }
        .modelContainer(modelContainer)
        // 同工作区窗口：隐藏系统标题栏，红绿灯浮在自绘 SFTPTitleBar 上、内容铺到顶。
        // 这一句是关键修复 —— 仅靠 WorkspaceWindowChrome 的 NSWindow.titlebarAppearsTransparent
        // 在 SwiftUI WindowGroup 下不稳定，会被系统不透明标题栏盖住（即「自定义 header 被遮挡」）。
        .windowStyle(.hiddenTitleBar)

        // Settings 窗口（⌘,）—— AI provider 配置面板。未来再加其它 tab。
        Settings {
            SettingsView()
                .modelContainer(modelContainer)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .environment(appUpdater)
        }
        .commands {
            AppInfoCommands()
        }
    }
}

struct AppInfoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            AboutMenuButton()
        }
    }
}

private struct AboutMenuButton: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTabSelection.key) private var selectedTab = SettingsTab.general.rawValue

    var body: some View {
        Button("关于 \(appName)") {
            selectedTab = SettingsTabSelection.aboutMenuTarget
            openSettings()
        }
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }
}

/// 让**所有**窗口（含已打开的、含 Settings）即时跟着主题偏好切——含切回「跟随系统」。
/// 两路并用、缺一不可：
///   1. `.environment(\.colorScheme,)` —— 驱动 SwiftUI 环境，让 chrome 的 `UD.dyn`
///      动态色**即时**重算配色（switching 的关键，详见 `body` 内注释）。
///   2. `NSApp.appearance`（onChange）—— 切系统 chrome：titlebar / 滚动条 / 系统控件 / 焦点环。
///
/// 为何不用 Scene 的 `.preferredColorScheme`（它一把抓上面两件事）：见 `AppearancePreference`
/// 类型文档——它会顺带写 per-window `NSWindow.appearance`，在「显式 → 跟随系统」切换上
/// 残留 override（白字白底）。`.environment(\.colorScheme,)` 只改环境值、不碰 NSWindow.appearance。
///
/// 初始值在 `uTermApp.init()` 里设；这里只负责用户在运行时改设置后的 live 同步。
/// `NSApp.appearance` 是 app 级全局状态，任一挂了本 modifier 的存活窗口接到
/// `onChange` 即可，新开的窗口自动跟随，无需逐窗口处理。
private struct AppAppearanceSync: ViewModifier {
    let preference: AppearancePreference
    /// 环境里来自窗口 `effectiveAppearance` 的 ambient colorScheme。`.system` 模式下
    /// 原样透传它（跟随系统），让 `.environment` 始终在场——切主题不改视图结构
    /// identity（否则 if/else 分支切换会重挂 content、丢状态）。
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        content
            // 「即时切换」的关键：chrome 的 `UD.dyn` 动态色按 `\.colorScheme` 环境
            // resolve（见 `UD.dyn`），改这个 env 会立刻让用到它的视图重算配色。
            // 而光改 `NSApp.appearance` 只更新窗口 `effectiveAppearance`（titlebar /
            // 滚动条 / 系统控件），**不会**及时把新 colorScheme 灌进 SwiftUI 环境，
            // 内容色因此滞后——这正是「颜色没有及时切换」的根因（c437e67 删掉
            // `.preferredColorScheme` 后只剩 `NSApp.appearance` 一路）。
            .environment(\.colorScheme, preference.colorScheme ?? systemScheme)
            .onChange(of: preference) { _, new in
                NSApplication.shared.appearance = new.nsAppearance
            }
    }
}

/// 条件性挂 `.environment(\.locale, _:)` 的 modifier：`.system` 模式下
/// 不挂任何修改，让 SwiftUI 走默认 `Locale.current`；其它模式下覆盖。
private struct LocaleOverride: ViewModifier {
    let locale: Locale?
    func body(content: Content) -> some View {
        if let locale {
            content.environment(\.locale, locale)
        } else {
            content
        }
    }
}
