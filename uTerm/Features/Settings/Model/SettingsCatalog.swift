import Foundation

/// 设置清单里的一项：哪一页、哪一组、什么控件、存在哪个键、跟不跟设备同步、哪端有入口。
///
/// 清单不驱动界面（两端视图各自手写），它是**对账表**：`SettingsCatalogTests` 拿它核对
/// 「同步键两端都有入口或写明了理由」「引用的键都在 `DefaultsKey` 里」，
/// 加设置时顺手在这里登记一行。
nonisolated struct SettingsItem: Identifiable, Sendable {
    enum Kind: Sendable {
        case toggle
        case choice
        case number
        case action
        case status
        case link
    }

    enum SyncScope: Sendable {
        /// 在 `SharedPreferencesSync` 清单里，经 iCloud KVS / 局域网同步。
        case synced
        /// 存在本机偏好里，刻意不同步。
        case local
        /// 不是偏好（动作、状态、跳转，或存在钥匙串 / SwiftData / 系统里）。
        case none
    }

    let id: String
    let section: SettingsSection
    let group: String
    let title: String
    let kind: Kind
    /// `DefaultsKey` 里的键；不是 UserDefaults 偏好时为 nil。
    let key: String?
    let syncScope: SyncScope
    let platforms: SettingsSection.Availability
}

nonisolated enum SettingsCatalog {
    private typealias Item = SettingsItem

    static let items: [SettingsItem] = [
        // MARK: 通用（mac）
        Item(id: "general.startupBehavior", section: .general, group: "启动", title: "启动时",
             kind: .choice, key: DefaultsKey.startupBehavior, syncScope: .synced, platforms: .macOS),
        Item(id: "general.restoreTerminalSession", section: .general, group: "启动", title: "恢复终端会话",
             kind: .toggle, key: DefaultsKey.restoreTerminalSession, syncScope: .synced, platforms: .macOS),
        // Sparkle 自己存 `SUEnableAutomaticChecks`，不在 DefaultsKey 表里。
        Item(id: "general.autoUpdate", section: .general, group: "更新", title: "自动检查更新",
             kind: .toggle, key: nil, syncScope: .none, platforms: .macOS),
        Item(id: "general.checkForUpdates", section: .general, group: "更新", title: "检查更新",
             kind: .action, key: nil, syncScope: .none, platforms: .macOS),

        // MARK: 外观
        Item(id: "appearance.theme", section: .appearance, group: "外观", title: "主题",
             kind: .choice, key: DefaultsKey.appearancePreference, syncScope: .synced, platforms: .both),
        Item(id: "appearance.accent", section: .appearance, group: "外观", title: "强调色",
             kind: .choice, key: DefaultsKey.accentColor, syncScope: .synced, platforms: .both),
        Item(id: "appearance.language", section: .appearance, group: "外观", title: "语言",
             kind: .choice, key: DefaultsKey.appLanguage, syncScope: .synced, platforms: .macOS),

        // MARK: 终端
        Item(id: "terminal.cursorShape", section: .terminal, group: "光标", title: "形状",
             kind: .choice, key: DefaultsKey.terminalCursorShape, syncScope: .synced, platforms: .macOS),
        Item(id: "terminal.cursorBlink", section: .terminal, group: "光标", title: "闪烁",
             kind: .toggle, key: DefaultsKey.terminalCursorBlink, syncScope: .synced, platforms: .macOS),
        Item(id: "terminal.scrollback", section: .terminal, group: "行为", title: "历史行数",
             kind: .number, key: DefaultsKey.terminalScrollback, syncScope: .synced, platforms: .macOS),
        Item(id: "terminal.copyOnSelect", section: .terminal, group: "行为", title: "选中即复制",
             kind: .toggle, key: DefaultsKey.terminalCopyOnSelect, syncScope: .synced, platforms: .macOS),
        Item(id: "terminal.quitBehavior", section: .terminal, group: "行为", title: "退出 uTerm 时",
             kind: .choice, key: DefaultsKey.terminalQuitBehavior, syncScope: .local, platforms: .macOS),
        Item(id: "terminal.localShellKeepsLAN", section: .terminal, group: "行为",
             title: "重启时保住本机终端的局域网连接",
             kind: .toggle, key: DefaultsKey.localShellKeepsLANConnections, syncScope: .local, platforms: .macOS),
        // iOS 终端外观固定，只读展示。
        Item(id: "terminal.mobileFont", section: .terminal, group: "终端", title: "字体",
             kind: .status, key: nil, syncScope: .none, platforms: .iOS),
        Item(id: "terminal.mobileFontSize", section: .terminal, group: "终端", title: "字号",
             kind: .status, key: nil, syncScope: .none, platforms: .iOS),
        Item(id: "terminal.mobileCursor", section: .terminal, group: "终端", title: "光标",
             kind: .status, key: nil, syncScope: .none, platforms: .iOS),

        // MARK: 模型服务（列表在 SwiftData，Key 在钥匙串）
        Item(id: "providers.list", section: .providers, group: "模型服务", title: "模型服务",
             kind: .link, key: nil, syncScope: .none, platforms: .both),

        // MARK: 连接
        Item(id: "connection.timeout", section: .connection, group: "SSH 连接", title: "连接超时",
             kind: .number, key: DefaultsKey.sshConnectTimeout, syncScope: .synced, platforms: .both),
        Item(id: "connection.hostKeyPolicy", section: .connection, group: "SSH 连接", title: "主机密钥校验",
             kind: .choice, key: DefaultsKey.sshHostKeyPolicy, syncScope: .synced, platforms: .both),
        Item(id: "connection.sftpConcurrency", section: .connection, group: "文件传输", title: "并发上传数",
             kind: .number, key: DefaultsKey.sftpMaxConcurrentTransfers, syncScope: .synced, platforms: .both),

        // MARK: 安全
        // 键两端相同，缺键默认值有意相反（mac 开 / iOS 关），本机设置不同步。两端开启前都先验证一次（`AppLockToggleModel`）。
        Item(id: "security.appLock", section: .security, group: "安全", title: "启动时验证身份",
             kind: .toggle, key: DefaultsKey.requireAuthAtLaunch, syncScope: .local, platforms: .both),
        Item(id: "security.sshKeys", section: .security, group: "安全", title: "SSH 密钥",
             kind: .link, key: nil, syncScope: .none, platforms: .both),
        Item(id: "security.hostGroups", section: .security, group: "安全", title: "主机分组",
             kind: .link, key: nil, syncScope: .none, platforms: .both),
        // mac 的「SSH 密钥」「主机分组」「已知主机指纹」是打开管理窗口的按钮。
        Item(id: "security.knownHosts", section: .security, group: "安全", title: "已知主机指纹",
             kind: .link, key: nil, syncScope: .none, platforms: .both),
        Item(id: "security.forwardingRules", section: .security, group: "安全", title: "端口转发规则",
             kind: .status, key: nil, syncScope: .none, platforms: .iOS),

        // MARK: 同步
        Item(id: "sync.icloud", section: .sync, group: "同步", title: "iCloud 同步",
             kind: .status, key: nil, syncScope: .none, platforms: .both),
        Item(id: "sync.diagnostics", section: .sync, group: "同步", title: "同步诊断",
             kind: .link, key: nil, syncScope: .none, platforms: .both),
        Item(id: "sync.lanSend", section: .sync, group: "同步", title: "局域网发送",
             kind: .action, key: nil, syncScope: .none, platforms: .macOS),
        Item(id: "sync.lanReceive", section: .sync, group: "局域网接收", title: "接收状态",
             kind: .status, key: nil, syncScope: .none, platforms: .iOS),
        Item(id: "sync.hostPairingCode", section: .sync, group: "同步", title: "配对码",
             kind: .status, key: DefaultsKey.lanSyncHostPairingCode, syncScope: .local, platforms: .macOS),
        Item(id: "sync.pairingCode", section: .sync, group: "局域网接收", title: "配对码",
             kind: .link, key: DefaultsKey.lanSyncPairingCode, syncScope: .local, platforms: .iOS),
        Item(id: "sync.chatRetention", section: .sync, group: "历史", title: "会话保留",
             kind: .choice, key: DefaultsKey.chatRetentionDays, syncScope: .synced, platforms: .both),

        // MARK: 远程控制
        Item(id: "remote.enabled", section: .remote, group: "远程控制", title: "允许手机远程控制",
             kind: .toggle, key: DefaultsKey.remoteEnabled, syncScope: .local, platforms: .macOS),
        Item(id: "remote.localShell", section: .remote, group: "本机终端", title: "允许打开本机终端",
             kind: .toggle, key: DefaultsKey.remoteLocalShellEnabled, syncScope: .local, platforms: .macOS),
        Item(id: "remote.desktop", section: .remote, group: "远程桌面", title: "允许远程桌面",
             kind: .toggle, key: DefaultsKey.remoteDesktopEnabled, syncScope: .local, platforms: .macOS),
        Item(id: "remote.relayConfig", section: .remote, group: "公网接入", title: "中继服务器",
             kind: .action, key: nil, syncScope: .none, platforms: .macOS),
        Item(id: "remote.internet", section: .remote, group: "公网接入", title: "允许经公网接入",
             kind: .toggle, key: DefaultsKey.remoteInternetEnabled, syncScope: .local, platforms: .macOS),
        Item(id: "remote.internetDevices", section: .remote, group: "公网接入", title: "允许经公网连接的设备",
             kind: .toggle, key: DefaultsKey.remoteInternetDevices, syncScope: .local, platforms: .macOS),
        Item(id: "remote.keepAwake", section: .remote, group: "公网接入", title: "保持唤醒",
             kind: .toggle, key: DefaultsKey.remoteKeepAwakeForInternet, syncScope: .local, platforms: .macOS),
        Item(id: "remote.pairing", section: .remote, group: "已配对的设备", title: "扫码配对",
             kind: .action, key: nil, syncScope: .none, platforms: .macOS),
        Item(id: "remote.pairedDevices", section: .remote, group: "已配对的设备", title: "已配对的设备",
             kind: .status, key: nil, syncScope: .none, platforms: .macOS),
        Item(id: "remote.networkDiagnostics", section: .remote, group: "远程控制", title: "网络诊断",
             kind: .link, key: nil, syncScope: .none, platforms: .iOS),
        // 读写经 `RemoteMacDirectory.internetOnly`（切换即断开重连），本机开发者选项。
        Item(id: "remote.internetOnly", section: .remote, group: "远程控制", title: "只走公网",
             kind: .toggle, key: DefaultsKey.remoteInternetOnly, syncScope: .local, platforms: .iOS),

        // MARK: 命令行与技能（mac）
        Item(id: "cli.enabled", section: .cli, group: "命令行接口", title: "启用命令行接口",
             kind: .toggle, key: DefaultsKey.controlEnabled, syncScope: .local, platforms: .macOS),
        Item(id: "cli.allowMutations", section: .cli, group: "命令行接口", title: "允许执行命令与写入",
             kind: .toggle, key: DefaultsKey.controlAllowMutations, syncScope: .local, platforms: .macOS),
        Item(id: "cli.socket", section: .cli, group: "命令行接口", title: "接口地址",
             kind: .status, key: nil, syncScope: .none, platforms: .macOS),
        Item(id: "cli.launchAtLogin", section: .cli, group: "后台服务", title: "登录后在后台启动",
             kind: .toggle, key: DefaultsKey.backgroundLaunchAtLogin, syncScope: .local, platforms: .macOS),
        Item(id: "cli.onDemandLaunch", section: .cli, group: "后台服务", title: "允许 CLI 按需启动",
             kind: .toggle, key: DefaultsKey.backgroundAllowOnDemandLaunch, syncScope: .local, platforms: .macOS),
        Item(id: "cli.skills", section: .cli, group: "AI 技能", title: "安装技能",
             kind: .action, key: nil, syncScope: .none, platforms: .macOS),
        Item(id: "cli.binLink", section: .cli, group: "AI 技能", title: "同时链接到 ~/.local/bin/utermctl",
             kind: .toggle, key: DefaultsKey.controlLinkToLocalBin, syncScope: .local, platforms: .macOS),

        // MARK: 诊断
        Item(id: "diagnostics.logLevel", section: .diagnostics, group: "诊断", title: "日志等级",
             kind: .choice, key: DefaultsKey.logLevel, syncScope: .synced, platforms: .both),
        Item(id: "diagnostics.console", section: .diagnostics, group: "诊断", title: "显示日志",
             kind: .action, key: nil, syncScope: .none, platforms: .macOS),
        // 仅 Debug 构建可见。
        Item(id: "diagnostics.layout", section: .diagnostics, group: "调试", title: "布局诊断",
             kind: .toggle, key: DefaultsKey.debugLayoutDiagnostics, syncScope: .local, platforms: .iOS),

        // MARK: 关于
        Item(id: "about.version", section: .about, group: "关于", title: "版本",
             kind: .status, key: nil, syncScope: .none, platforms: .both),
    ]

    /// 同步清单里**没有两端入口**的键 → 理由。`SettingsCatalogTests` 要求每个同步键要么在清单里
    /// 两端都有入口，要么在这里写明为什么没有。
    static let syncedKeyExemptions: [String: String] = [
        DefaultsKey.terminalCursorShape: "iOS 终端外观固定（稳定块光标），不读这个键",
        DefaultsKey.terminalCursorBlink: "iOS 终端不闪烁光标，不读这个键",
        DefaultsKey.terminalScrollback: "iOS 终端的回滚缓冲区不可配，不读这个键",
        DefaultsKey.terminalCopyOnSelect: "iOS 靠长按选择与系统菜单复制，没有「选中即复制」",
        DefaultsKey.appLanguage: "mac 专属：iOS 跟随系统语言（系统设置里按 App 改）",
        DefaultsKey.startupBehavior: "mac 专属：启动时打开欢迎窗还是上次主机",
        DefaultsKey.restoreTerminalSession: "mac 专属：恢复工作区的标签与分屏",
        DefaultsKey.globalForwardingLaunchAtAppStart: "mac 专属：端口转发只在 mac 上跑，开关在全局端口转发窗口里",
        DefaultsKey.activeProviderID: "在 Agent 输入区的模型菜单里选，不在设置页",
        DefaultsKey.agentSafety: "在 Agent 输入区的信任档位里选，不在设置页",
    ]
}
