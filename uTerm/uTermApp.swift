import SwiftUI
import SwiftData

@main
struct uTermApp: App {
    @AppStorage("appearancePreference")
    private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue

    @AppStorage("appLanguage")
    private var appLanguageRaw: String = AppLanguage.system.rawValue

    @State private var appUpdater = AppUpdater()

    private var preferredColorScheme: ColorScheme? {
        (AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system).colorScheme
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
                for: ServerProfile.self, KnownHost.self, AIProvider.self,
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
    }

    var body: some Scene {
        // 服务器管理 —— 单实例 Welcome 窗口。自动出现在「窗口」菜单，可重开。
        // `.preferredColorScheme(.dark)` 让 macOS titlebar / scroller /
        // 系统 material 都用暗变体，不与 AppTheme 冷灰蓝 token 撞色。
        Window("uTerm", id: "welcome") {
            WelcomeView()
                .preferredColorScheme(preferredColorScheme)
                .modifier(LocaleOverride(locale: currentLocale))
        }
        .modelContainer(modelContainer)

        // 工作区窗口 —— 每个绑定一台服务器，可多实例。
        WindowGroup(for: WorkspaceWindowID.self) { $windowID in
            WorkspaceWindowView(windowID: windowID)
                .frame(minWidth: 1280, minHeight: 720)
                .modifier(LocaleOverride(locale: currentLocale))
                .preferredColorScheme(preferredColorScheme)
        }
        .modelContainer(modelContainer)
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

        // Settings 窗口（⌘,）—— AI provider 配置面板。未来再加其它 tab。
        Settings {
            SettingsView()
                .modelContainer(modelContainer)
                .preferredColorScheme(preferredColorScheme)
                .modifier(LocaleOverride(locale: currentLocale))
                .environment(appUpdater)
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
