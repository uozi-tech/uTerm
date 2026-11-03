import SwiftUI
import SwiftData
import AppKit

/// 入口在 `UTermEntryPoint`：CLI 按需唤起被设置拒绝时要在任何属性初始化（Sparkle、
/// CloudKit、SwiftData）之前退出。
struct uTermApp: App {
    @NSApplicationDelegateAdaptor(UTermLifecycleDelegate.self) private var lifecycleDelegate
    @AppStorage("appearancePreference")
    private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue

    @AppStorage("appLanguage")
    private var appLanguageRaw: String = AppLanguage.system.rawValue

    /// `terminal-open` 需要从 App 层捕获开窗口动作（见 `installTerminalWindowOpener`）。
    @Environment(\.openWindow) private var openWindow

    @State private var appUpdater = AppUpdater()
    /// CloudKit 同步可观测器：订阅镜像事件，喂 AppLogger + 给「高级 › iCloud 同步」行实时状态。
    @State private var cloudKitSync = CloudKitSyncMonitor()
    /// 普通偏好：本机 UserDefaults 为准，经 iCloud KVS 跨设备保底，局域网同步另按快照传输。
    @State private var sharedPreferences = SharedPreferencesSync()
    @State private var lanSync: LANSyncCoordinator
    @State private var forwardingCoordinator: ForwardingCoordinator
    /// 全局端口转发的「启动自动化」编排器（App 级，注入 Welcome 与全局转发窗口）。
    @State private var globalForwarding: GlobalForwardingModel
    /// 应用级共享的 host-key 中转：启动序列与全局转发窗口共用一个，使首连主机的
    /// 信任弹窗能在任一可见窗口里解决 —— `.hostKeySheet` 同时挂在 Welcome（默认启动模式
    /// 常驻可见，承接启动期弹窗）与全局转发窗口（用户打开后亦可解决 / 重连）。
    @State private var launchRelay: HostKeyChallengeRelay
    /// 命令行接口（本机 IPC）的两级门禁开关。进程 init 即接上 `ControlServer`，
    /// 因此无窗口后台模式也能提供 run/SFTP/转发。
    @State private var controlSettings: ControlSettings
    @State private var backgroundSettings = BackgroundServiceSettings()
    /// 跨窗口终端会话注册表 —— CLI 的 `terminals` / `terminal-read` / `terminal-send`
    /// 的枚举面（P3 才真正登记，先注入让接线一次到位）。
    @State private var terminalRegistry: TerminalSessionRegistry
    /// 远控：配对过的手机接入本机已打开的终端。开关在 设置 › 远程控制，默认关闭。
    @State private var remoteSettings: RemoteControlSettings
    @State private var remoteServer: RemoteHostServer
    /// 配对审批面板。独立 NSPanel，无窗口的后台模式下也能弹。
    private let remotePairingPrompt: RemotePairingPrompt?
    private let remoteDesktopIndicator: RemoteDesktopIndicator?
    @State private var lockModel: AppLockModel
    /// 启动行为每个 app 进程只消费一次；显式重开 Welcome 时不再重复恢复会话。
    private let startupBehaviorGate = StartupBehaviorGate()
    /// 应用级服务（iCloud 同步监听 / 局域网同步 / 命令行接口 / 开窗入口）只安装一次。
    /// 挂在每个 Scene 上，谁先出现谁装 —— 见 `AppServicesGate` 的类型文档。
    private let appServicesGate = AppServicesGate()

    private var currentAppearance: AppearancePreference {
        AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    private var currentLocale: Locale? {
        (AppLanguage(rawValue: appLanguageRaw) ?? .system).locale
    }

    /// SwiftData 容器。`.automatic` 让已登录 iCloud 的设备后台持续镜像（保底通道）；
    /// 同网段下 LANSyncDataStore 再做一次手动的最小增量合并（快通道）。
    let modelContainer: ModelContainer

    /// 本机 IPC 服务端。`ControlSettings.observe` 按主开关起停它（起停都幂等）。
    private let controlServer = ControlServer()

    init() {
        // 必须在创建 SwiftData 容器之前订阅：CloudKit 可能在容器初始化期间就发出 setup / import 事件。
        let sync = CloudKitSyncMonitor()
        sync.start()
        _cloudKitSync = State(initialValue: sync)
        modelContainer = AppModelContainer.make()

        let preferences = SharedPreferencesSync()
        _sharedPreferences = State(initialValue: preferences)
        let lan = LANSyncCoordinator(role: .sender, preferences: preferences,
                                     dataStore: LANSyncDataStore(container: modelContainer))
        lan.start()
        _lanSync = State(initialValue: lan)

        // uTerm 自己已有工作区/终端标签，禁用 macOS 把独立窗口再合并成系统 Tab。
        // 必须在任何 Scene 创建 NSWindow 前设置，才能阻止系统按用户偏好自动合并。
        NSWindow.allowsAutomaticWindowTabbing = false
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
        // Pull shared scalar preferences before the first scene body is evaluated.
        // This matters for stateful services such as AccentState, which initialize
        // from UserDefaults once rather than observing it continuously.
        preferences.start()

        // App.init runs before SwiftUI installs State storage. Bootstrap with local
        // references, then give the same instances to the scenes through State.
        let controlSettings = ControlSettings()
        let forwardingCoordinator = ForwardingCoordinator()
        let terminalRegistry = TerminalSessionRegistry()
        let globalForwarding = GlobalForwardingModel()
        let launchRelay = HostKeyChallengeRelay()
        _controlSettings = State(initialValue: controlSettings)
        _forwardingCoordinator = State(initialValue: forwardingCoordinator)
        _terminalRegistry = State(initialValue: terminalRegistry)
        _globalForwarding = State(initialValue: globalForwarding)
        _launchRelay = State(initialValue: launchRelay)
        let remoteSettings = RemoteControlSettings()
        let remoteServer = RemoteHostServer(registry: terminalRegistry,
                                            desktopEnvironment: .live(settings: remoteSettings))
        _remoteSettings = State(initialValue: remoteSettings)
        _remoteServer = State(initialValue: remoteServer)
        remotePairingPrompt = BackgroundLaunchMode.isRunningInTestHost ? nil : RemotePairingPrompt(server: remoteServer)
        remoteDesktopIndicator = BackgroundLaunchMode.isRunningInTestHost ? nil : RemoteDesktopIndicator(server: remoteServer)

        // IPC must exist even when no SwiftUI scene is visible. The opener is installed later,
        // because `openWindow` is a scene environment action; all headless operations are ready now.
        if !BackgroundLaunchMode.isRunningInTestHost {
            StartupMaintenance.run(container: modelContainer)
            // 技能链接直接指向 app 包内：升级后首次启动 / app 搬家后把旧链接改指过来，
            // 与命令行接口开没开无关（技能文档先读得到，接口没开时 utermctl 会照实报错）。
            SkillInstaller.reconcileOnLaunch()
            Self.startControlInterface(
                server: controlServer,
                settings: controlSettings,
                modelContainer: modelContainer,
                forwardingCoordinator: forwardingCoordinator,
                registry: terminalRegistry
            )
            LaunchForwardingBootstrap.start(
                modelContainer: modelContainer,
                model: globalForwarding,
                coordinator: forwardingCoordinator,
                relay: launchRelay
            )
            remoteServer.localShellOpener = .live(settings: remoteSettings, registry: terminalRegistry)
            remoteSettings.observe { settings in
                if settings.isEnabled { remoteServer.start() } else { remoteServer.stop() }
                if !settings.isDesktopEnabled { remoteServer.endDesktop(reason: "Mac 上关闭了远程桌面") }
            }
            let server = controlServer
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                server.stop()
                MainActor.assumeIsolated { remoteServer.stop() }
                Task { await ControlConnectionPool.shared.disconnectAll() }
            }
        }
    }

    /// 安装必须从 Scene 环境取得的开窗口入口。进程级 IPC、局域网同步与自动转发已经
    /// 在 init 启动；这里不承载后台服务 readiness。
    @MainActor
    private func bootstrapAppServices() {
        appServicesGate.install {
            installTerminalWindowOpener()
        }
    }

    /// `terminal-open` 的开窗口入口：`TerminalWindowID` 只能在 Scene 环境里开，
    /// 所以把 App 层的 `openWindow` 捕成闭包塞进注册表（与 `WelcomeView.handleConfigDrop`
    /// 里 `let open = openWindow` 同款写法）。返回的是**窗口** id，会话要等它自己注册上来。
    @MainActor
    private func installTerminalWindowOpener() {
        let open = openWindow
        terminalRegistry.openTerminalWindow = { serverID in
            UTermLifecycleDelegate.showGUI()
            let windowID = UUID()
            open(value: TerminalWindowID(id: windowID, serverID: serverID))
            return windowID
        }
        terminalRegistry.openLocalShellWindow = {
            UTermLifecycleDelegate.showGUI()
            let windowID = UUID()
            open(value: LocalShellWindowID(id: windowID))
            return windowID
        }
    }

    /// 把命令行接口的开关接到服务端起停上。
    ///
    /// `observe` 设置后立刻回调一次，所以开关本来就是开的话这里就把服务端起起来了。
    /// `start()` 返回非 nil 表示**不会自愈**的启动失败（目前只有 socket 路径超过
    /// `sun_path` 上限），写进 `startupError` 让设置页显示出来。
    @MainActor
    private static func startControlInterface(
        server: ControlServer,
        settings: ControlSettings,
        modelContainer: ModelContainer,
        forwardingCoordinator: ForwardingCoordinator,
        registry: TerminalSessionRegistry
    ) {
        let handler = ControlHandler.shared
        handler.attach(ControlHandler.Dependencies(
            settings: settings,
            modelContainer: modelContainer,
            forwardingCoordinator: forwardingCoordinator,
            pool: ControlConnectionPool.shared,
            registry: registry
        ))
        settings.observe { settings in
            if settings.isEnabled {
                settings.startupError = server.start()
            } else {
                server.stop()
                settings.startupError = nil
                // 关掉主开关必须连 CLI 自己持有的连接一起松开：`ControlConnectionPool`
                // 与窗口无关，没有这一步的话 socket 关了、SSH 连接却还挂着。
                Task { await ControlConnectionPool.shared.disconnectAll() }
            }
        }
    }

    var body: some Scene {
        // 服务器管理 —— 单实例 Welcome 窗口。自动出现在「窗口」菜单，可重开。
        // 主题由 AppAppearanceSync 驱动（colorScheme env + NSApp.appearance 两路），
        // 不挂 .preferredColorScheme——原因见 AppearancePreference 类型文档。
        Window("uTerm", id: "welcome") {
            WelcomeView(startupBehaviorGate: startupBehaviorGate)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                // 注入转发协调器 + 全局自启编排器 + 共享 host-key 中转。
                // 自动转发由 App init 触发，Welcome 只承接需要用户确认的 host-key sheet。
                .environment(forwardingCoordinator)
                .environment(globalForwarding)
                .environment(launchRelay)
                .environment(controlSettings)
                .environment(backgroundSettings)
                .environment(terminalRegistry)
                .bootstrapsAppServices(bootstrapAppServices)
                .onReceive(NotificationCenter.default.publisher(for: .showWelcomeWindow)) { _ in
                    openWindow(id: "welcome")
                }
        }
        .modelContainer(modelContainer)
        // 自绘扁平 chrome：隐藏系统标题栏，红绿灯浮在自绘 WelcomeTitleBar 上、内容铺到顶。
        // 否则系统暗夜标题栏（更浅的灰）盖在设计稿底色 UD.bg 之上 —— 即「chrome 还是系统默认
        // 暗夜配色」的根因。与 workspace / SFTP 窗口一致。
        .windowStyle(.hiddenTitleBar)
        .routesNewWindowToWelcome()
        .commands { BackgroundLifecycleCommands() }

        // 密钥管理 —— 单实例独立窗口（设计稿 keys.jsx）。从 Welcome 工具栏或
        // 新建服务器表单的「打开密钥管理…」用 openWindow(id:"keys") 打开。
        Window("密钥管理", id: "keys") {
            KeyManagerView()
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .bootstrapsAppServices(bootstrapAppServices)
        }
        .modelContainer(modelContainer)
        // 同上：隐藏系统标题栏，让密钥管理窗口走自绘扁平 chrome（KeyManagerView 顶部自绘标题栏）。
        .windowStyle(.hiddenTitleBar)
        .routesNewWindowToWelcome()

        Window("分组管理", id: "groups") {
            GroupsManagerView()
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .bootstrapsAppServices(bootstrapAppServices)
        }
        .modelContainer(modelContainer)
        .windowStyle(.hiddenTitleBar)
        .routesNewWindowToWelcome()

        Window("导入 SSH 配置", id: "import") {
            SSHConfigImportView()
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .bootstrapsAppServices(bootstrapAppServices)
        }
        .modelContainer(modelContainer)
        .windowStyle(.hiddenTitleBar)
        .routesNewWindowToWelcome()

        // 工作区窗口 —— 每个绑定一台服务器，可多实例。
        WindowGroup(for: WorkspaceWindowID.self) { $windowID in
            WorkspaceWindowView(windowID: windowID)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .environment(forwardingCoordinator)
                .environment(controlSettings)
                .environment(terminalRegistry)
                .bootstrapsAppServices(bootstrapAppServices)
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
        .routesNewWindowToWelcome()
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
                Button("向下分屏") {
                    NotificationCenter.default.post(name: .splitFocusedPaneVertical, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("向右分屏") {
                    NotificationCenter.default.post(name: .splitFocusedPaneHorizontal, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

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
                .bootstrapsAppServices(bootstrapAppServices)
        }
        .modelContainer(modelContainer)
        // 同工作区窗口：隐藏系统标题栏，红绿灯浮在自绘 SFTPTitleBar 上、内容铺到顶。
        // 这一句是关键修复 —— 仅靠 WorkspaceWindowChrome 的 NSWindow.titlebarAppearsTransparent
        // 在 SwiftUI WindowGroup 下不稳定，会被系统不透明标题栏盖住（即「自定义 header 被遮挡」）。
        .windowStyle(.hiddenTitleBar)
        .routesNewWindowToWelcome()

        // 纯终端独立窗口 —— 每个绑定一台服务器的「终端 ⇄ Agent」窗口，可多实例。
        // 复用 WorkspaceModel 的多标签 + 分屏 + Agent，但不含 SFTP 侧栏 / 预览区。
        WindowGroup(for: TerminalWindowID.self) { $termID in
            TerminalWindowView(windowID: termID)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .environment(forwardingCoordinator)
                .environment(controlSettings)
                .environment(terminalRegistry)
                .bootstrapsAppServices(bootstrapAppServices)
        }
        .modelContainer(modelContainer)
        .windowStyle(.hiddenTitleBar)
        // 默认尺寸足够容纳 Agent 空状态（分组示例）不出现滚动；用户可自由缩放。
        .defaultSize(width: 1000, height: 720)
        .routesNewWindowToWelcome()

        // 本机终端窗口 —— 一个窗口一个登录 shell（由不带沙盒的辅助进程起），手机远控「新建终端」开的就是它。
        WindowGroup(for: LocalShellWindowID.self) { $shellID in
            LocalShellWindowView(windowID: shellID)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .environment(terminalRegistry)
                .bootstrapsAppServices(bootstrapAppServices)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 860, height: 560)
        .routesNewWindowToWelcome()

        // 端口转发独立窗口 —— 每个绑定一台服务器的转发规则管理器，可多实例。
        WindowGroup(for: PortForwardWindowID.self) { $pfID in
            PortForwardWindowView(windowID: pfID)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .environment(forwardingCoordinator)
                .environment(controlSettings)
                .environment(terminalRegistry)
                .bootstrapsAppServices(bootstrapAppServices)
        }
        .modelContainer(modelContainer)
        .windowStyle(.hiddenTitleBar)
        .routesNewWindowToWelcome()

        // 全局端口转发 —— 单实例跨主机统一管理面 + 应用级自启编排。从 Welcome 工具栏
        // 「全局转发」或命令面板用 openWindow(id:"global-forwarding") 打开。与单主机端口转发
        // 窗口共享同一份规则（SwiftData）与 forwardingCoordinator 运行态。
        Window("全局端口转发", id: "global-forwarding") {
            GlobalForwardingWindowView()
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .environment(forwardingCoordinator)
                .environment(globalForwarding)
                .environment(launchRelay)
                .environment(controlSettings)
                .environment(terminalRegistry)
                .bootstrapsAppServices(bootstrapAppServices)
        }
        .modelContainer(modelContainer)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 620)
        .routesNewWindowToWelcome()

        // 并行执行窗口 —— 一条快捷命令在其绑定的多台服务器上「广播」执行，可多实例
        //（按 commandID 去重）。Shell 广播网格 / AI 自然语言自愈两视图，标题栏可切。
        WindowGroup(for: ParallelRunWindowID.self) { $parallelID in
            ParallelRunWindowView(windowID: parallelID)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .bootstrapsAppServices(bootstrapAppServices)
        }
        .modelContainer(modelContainer)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)
        .routesNewWindowToWelcome()

        // 设置窗口（⌘,）—— AI provider 等配置面板。
        // 用普通 Window 而非 macOS `Settings` 场景：后者不可靠地忽略
        // `.windowStyle(.hiddenTitleBar)`、始终画系统标题栏，自绘 chrome 盖不住。
        // 普通 Window + hiddenTitleBar 与 Welcome / Keys / Groups 同构，
        // WorkspaceWindowChrome 才能真正接管标题栏。⌘, 由 SettingsWindowCommands 重绑。
        Window("设置", id: SettingsWindow.id) {
            SettingsView()
                .modelContainer(modelContainer)
                .environment(lanSync)
                .modifier(AppAppearanceSync(preference: currentAppearance))
                .modifier(LocaleOverride(locale: currentLocale))
                .appLockGate(lockModel)
                .environment(appUpdater)
                .environment(cloudKitSync)
                .environment(controlSettings)
                .environment(backgroundSettings)
                .environment(remoteSettings)
                .environment(remoteServer)
                .bootstrapsAppServices(bootstrapAppServices)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 480)   // 初始尺寸；内容用 minHeight 铺满，避免底部露出浅色窗底
        .routesNewWindowToWelcome()
        .commands {
            AppInfoCommands(appUpdater: appUpdater)
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
        .routesNewWindowToWelcome()
        .commands { DebugCommands() }
        #endif
    }
}

/// 应用级服务（局域网同步、命令行接口、`terminal-open` 的开窗入口）的
/// **一次性**安装闸门。
///
/// 这三样原本只挂在 Welcome 窗的 `.task` 里，而 Welcome 窗**不一定出现**：
/// 启动行为设成「上次会话 / 上次主机」时它会被 dismiss，macOS 恢复窗口状态时也
/// 可能只恢复工作区 / 终端窗口。那些情况下 `ControlSettings.observe` 从来没装上，
/// 用户在设置里打开命令行开关**什么都不发生、也没有任何报错**。
///
/// 改成挂在每个 Scene 的根视图上（`bootstrapsAppServices`），谁先出现谁装，
/// 由这个闸门保证只跑一次。
@MainActor
final class AppServicesGate {
    private(set) var hasInstalled = false

    /// 幂等安装：第一次真跑 `body` 并返回 true，之后一律 no-op 并返回 false。
    @discardableResult
    func install(_ body: () -> Void) -> Bool {
        guard !hasInstalled else { return false }
        hasInstalled = true
        body()
        return true
    }
}

private extension View {
    /// 应用级服务的启动钩子。挂在**每个** Scene 的根视图上，幂等性由
    /// `AppServicesGate` 负责，不要在这里再加条件。
    func bootstrapsAppServices(_ run: @escaping @MainActor () -> Void) -> some View {
        task { run() }
    }
}
