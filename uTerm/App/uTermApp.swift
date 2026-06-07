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
    @State private var forwardingCoordinator = ForwardingCoordinator()
    @State private var lockModel: AppLockModel

    private var currentAppearance: AppearancePreference {
        AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    private var currentLocale: Locale? {
        (AppLanguage(rawValue: appLanguageRaw) ?? .system).locale
    }

    /// 启用 CloudKit 同步的 SwiftData 容器。`.automatic` 让 SwiftData
    /// 在用户已登录 iCloud 时自动后台同步，未登录时退化为纯本地。
    let modelContainer: ModelContainer = AppModelContainer.make()

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
        // 自绘扁平 chrome：隐藏系统标题栏，红绿灯浮在自绘 WelcomeTitleBar 上、内容铺到顶。
        // 否则系统暗夜标题栏（更浅的灰）盖在设计稿 #101012 之上 —— 即「chrome 还是系统默认
        // 暗夜配色」的根因。与 workspace / SFTP 窗口一致。
        .windowStyle(.hiddenTitleBar)

        // 密钥管理 —— 单实例独立窗口（设计稿 keys.jsx）。从 Welcome 工具栏或
        // 新建服务器表单的「打开密钥管理…」用 openWindow(id:"keys") 打开。
        Window("密钥管理", id: "keys") {
            KeyManagerView()
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
        }
        .modelContainer(modelContainer)
        // 同上：隐藏系统标题栏，让密钥管理窗口走自绘扁平 chrome（KeyManagerView 顶部自绘标题栏）。
        .windowStyle(.hiddenTitleBar)

        Window("分组管理", id: "groups") {
            GroupsManagerView()
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
        }
        .modelContainer(modelContainer)
        .windowStyle(.hiddenTitleBar)

        Window("导入 SSH 配置", id: "import") {
            SSHConfigImportView()
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
        }
        .modelContainer(modelContainer)
        .windowStyle(.hiddenTitleBar)

        // 工作区窗口 —— 每个绑定一台服务器，可多实例。
        WindowGroup(for: WorkspaceWindowID.self) { $windowID in
            WorkspaceWindowView(windowID: windowID)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .environment(forwardingCoordinator)
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

        // 端口转发独立窗口 —— 每个绑定一台服务器的转发规则管理器，可多实例。
        WindowGroup(for: PortForwardWindowID.self) { $pfID in
            PortForwardWindowView(windowID: pfID)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .environment(forwardingCoordinator)
        }
        .modelContainer(modelContainer)
        .windowStyle(.hiddenTitleBar)

        // 设置窗口（⌘,）—— AI provider 等配置面板。
        // 用普通 Window 而非 macOS `Settings` 场景：后者不可靠地忽略
        // `.windowStyle(.hiddenTitleBar)`、始终画系统标题栏，自绘 chrome 盖不住。
        // 普通 Window + hiddenTitleBar 与 Welcome / Keys / Groups 同构，
        // WorkspaceWindowChrome 才能真正接管标题栏。⌘, 由 SettingsWindowCommands 重绑。
        Window("设置", id: SettingsWindow.id) {
            SettingsView()
                .modelContainer(modelContainer)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .environment(appUpdater)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 480)   // 初始尺寸；内容用 minHeight 铺满，避免底部露出浅色窗底
        .commands {
            AppInfoCommands()
            SettingsWindowCommands()
        }

        #if DEBUG
        // 仅 DEBUG：Tweaks 调试窗口 + 顶部「Debug」菜单（⌃⌘T 打开）。
        // 不挂 .appLockGate / .modelContainer —— 调试窗口免锁，且不直接查询 SwiftData。
        Window("Tweaks", id: "tweaks") {
            TweaksWindow()
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
        }
        .windowStyle(.hiddenTitleBar)
        .commands { DebugCommands() }
        #endif
    }
}
