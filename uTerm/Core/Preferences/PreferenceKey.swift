import Foundation

/// 全部 `UserDefaults` / `@AppStorage` / iCloud KVS 键名的唯一出处（iOS 与 macOS 共用一份）。
///
/// **字符串值一个字都不能改**：已安装用户的设置就存在这些键下，跨设备同步（iCloud KVS、
/// 局域网快照）也按键名对齐——改了等于把用户设置清零、并让两端各说各话。
/// `PreferenceKeyTests` 把每个值钉死；`PreferenceKeyLintTests` 拦生产代码里新写的裸
/// `@AppStorage("…")`。新增键加在这里，再在用到的地方引用常量。
///
/// 两端共用同名设置时就是**同一个键**（如 `activeProviderID`、`agentSafety`、`appearancePreference`），
/// 默认值有意不同的见各常量注释（目前只有 `requireAuthAtLaunch`）。
nonisolated enum PreferenceKey {

    // MARK: - 跨设备同步（`SharedPreferencesSync` 的清单，iCloud KVS + 局域网）

    static let appearancePreference = "appearancePreference"
    static let appLanguage = "appLanguage"
    /// 读写在 UDesignKit 的 `AccentState`（共享包），这里只供同步清单引用。
    static let accentColor = "accentColor"
    static let startupBehavior = "startupBehavior"
    static let restoreTerminalSession = "restoreTerminalSession"
    static let sshConnectTimeout = "sshConnectTimeout"
    static let sshHostKeyPolicy = "sshHostKeyPolicy"
    static let logLevel = "logLevel"
    static let sftpMaxConcurrentTransfers = "sftpMaxConcurrentTransfers"
    static let terminalCursorShape = "terminalCursorShape"
    static let terminalCursorBlink = "terminalCursorBlink"
    static let terminalScrollback = "terminalScrollback"
    static let terminalCopyOnSelect = "terminalCopyOnSelect"
    /// Agent 里选中的模型服务（两端同一个键，空串 = 没选过）。
    static let activeProviderID = "activeProviderID"
    /// 「自然语言 → 执行」信任档位（两端同一个键）。
    static let agentSafety = "agentSafety"
    static let globalForwardingLaunchAtAppStart = "globalForwarding.launchAtAppStart.enabled"
    static let chatRetentionDays = "chatRetentionDays"

    /// iOS 早期版本的私有键，启动时由 `SharedPreferencesSync` 迁到 `activeProviderID` / `agentSafety` 后删除。
    static let legacyMobileAgentActiveProviderID = "mobileAgentActiveProviderID"
    static let legacyMobileAgentSafety = "mobileAgentSafety"

    /// 每个同步键的修改时间戳存在 `前缀 + 键名` 下（本机 UserDefaults 与 iCloud KVS 各一份）。
    static let syncModifiedPrefix = "lanSync.preferenceModified."

    // MARK: - 本机设置（刻意不跨设备同步）

    /// 「启动时要求验证身份」。缺键默认值**两端有意相反**：mac 开、iOS 关，见 `AppLockPreference.defaultValue`。
    static let requireAuthAtLaunch = "requireAuthAtLaunch"
    static let terminalQuitBehavior = "terminalQuitBehavior"
    static let settingsTabSelection = "settingsTabSelection"
    static let trueColorOfferDismissedHosts = "trueColorOfferDismissedHosts"
    static let externalOpenAppByExtension = "externalOpen.appByExtension"
    static let permissionGuidePresentedRevision = "permissionGuide.presentedRevision"

    static let localShellKeepsLANConnections = "localShellKeepsLANConnections"
    static let localShellRecentDirectories = "localShell.recentDirectories"

    static let controlEnabled = "control.enabled"
    static let controlAllowMutations = "control.allowMutations"
    static let controlLinkToLocalBin = "control.linkToLocalBin"

    static let backgroundLaunchAtLogin = "background.launchAtLogin"
    static let backgroundAllowOnDemandLaunch = "background.allowOnDemandLaunch"

    static let remoteEnabled = "remote.enabled"
    static let remoteDesktopEnabled = "remote.desktopEnabled"
    static let remoteLocalShellEnabled = "remote.localShellEnabled"
    static let remoteDeviceID = "remote.deviceID"
    /// iOS：用户点过「控制我的 Mac」之后才在启动时浏览（要「本地网络」授权）。
    static let remoteBrowseActivated = "remote.browseActivated"
    /// iOS：远程桌面里手机键盘上次用的输入语言。
    static let remoteDesktopKeyboardLanguage = "remote.desktop.keyboardLanguage"

    static let lanSyncDeviceID = "lanSync.deviceID"
    static let lanSyncHostPairingCode = "lanSync.hostPairingCode"
    static let lanSyncPairingCode = "lanSync.pairingCode"
    static let lanSyncReceiverActivated = "lanSync.receiverActivated"

    /// macOS SFTP 浏览器的排序 / 过滤偏好。
    /// 待接线：`FileBrowserModel.PrefKey` 仍写着同值的字面量（该文件本轮不动）。
    static let fileBrowserSortKey = "fileBrowser.sortKey"
    static let fileBrowserSortAscending = "fileBrowser.sortAscending"
    static let fileBrowserFoldersFirst = "fileBrowser.foldersFirst"
    static let fileBrowserShowHidden = "fileBrowser.showHidden"

    // MARK: - 调试开关（`defaults write` 手动设，界面上没有）

    static let sshTimingProbe = "sshTimingProbe"
    static let remoteDebugOpenDesktop = "RemoteDebugOpenDesktop"
    static let remoteDebugEndpoint = "RemoteDebugEndpoint"
    static let debugLayoutDiagnostics = "debug.layoutDiagnostics"

    // MARK: - 系统定义的键（键名属于 macOS，不是我们的设置）

    /// 系统设置「双击窗口标题栏以…」。
    static let appleActionOnDoubleClick = "AppleActionOnDoubleClick"
    /// AppKit 拖窗跨屏时按屏幕布局调整位置的开关，见 `WindowMoveBehavior`。
    static let screenLayoutAdjustOnWindowMove = "NSScreenLayoutAdjustOnWindowMove"
}
