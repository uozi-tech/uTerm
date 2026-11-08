import Foundation

/// 全部 `UserDefaults` / `@AppStorage` / iCloud KVS 键名的唯一出处（iOS 与 macOS 共用一份）。
///
/// 不叫 `PreferenceKey`：那会在本模块里遮住 SwiftUI 的 `PreferenceKey` 协议。
///
/// **字符串值一个字都不能改**：已安装用户的设置就存在这些键下，跨设备同步（iCloud KVS、
/// 局域网快照）也按键名对齐——改了等于把用户设置清零、并让两端各说各话。
/// `DefaultsKeyTests` 把每个值钉死；`DefaultsKeyLintTests` 拦生产代码里新写的裸
/// `@AppStorage("…")`。新增键加在这里，再在用到的地方引用常量。
///
/// 两端共用同名设置时就是**同一个键**（如 `activeProviderID`、`agentSafety`、`appearancePreference`），
/// 默认值有意不同的见各常量注释（目前只有 `requireAuthAtLaunch`）。
nonisolated enum DefaultsKey {

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
    /// macOS：允许手机远程解锁锁屏并进入帘幕模式（需在远程桌面之上单独开）。
    static let remoteDesktopUnlockEnabled = "remote.desktopUnlockEnabled"
    static let remoteLocalShellEnabled = "remote.localShellEnabled"
    static let remoteDeviceID = "remote.deviceID"
    /// macOS：允许经公网（中继 / 打洞）接入。
    static let remoteInternetEnabled = "remote.internetEnabled"
    /// macOS：允许经公网接入的设备 ID。
    static let remoteInternetDevices = "remote.internetDevices"
    /// macOS：开着公网接入时保持唤醒。
    static let remoteKeepAwakeForInternet = "remote.keepAwakeForInternet"
    /// iOS：只走公网（网络诊断）。
    static let remoteInternetOnly = "remote.internetOnly"
    /// iOS：网络诊断的记录、备注、轮数与测试项。
    static let remotePathMatrixLog = "remote.pathMatrixLog"
    static let remoteIceProbeNote = "remote.iceProbeNote"
    static let remotePathMatrixRounds = "remote.pathMatrixRounds"
    /// 不测的路（存「跳过哪些」而不是「测哪些」：以后加了新路，默认就会测）。
    static let remotePathMatrixSkippedModes = "remote.pathMatrixSkippedModes"
    /// iOS：用户点过「控制我的 Mac」之后才在启动时浏览（要「本地网络」授权）。
    static let remoteBrowseActivated = "remote.browseActivated"
    /// iOS：远程桌面里手机键盘上次用的输入语言。
    static let remoteDesktopKeyboardLanguage = "remote.desktop.keyboardLanguage"
    /// macOS：控制另一台 Mac 时把系统快捷键（⌘Tab、⌘空格、⌘W…）也发过去。
    static let remoteDesktopSendSystemShortcuts = "remote.desktop.sendSystemShortcuts"
    /// macOS：中继 relayID → 装着它的已保存主机（ServerProfile.id），本机自己管，不同步。
    static let remoteRelayManagedHosts = "remote.relay.managedHosts"
    /// macOS：最近一次从 OSS 取到的中继最新版本与取的时间。
    static let remoteRelayLatestVersion = "remote.relay.latestVersion"
    static let remoteRelayLatestCheckedAt = "remote.relay.latestCheckedAt"
    /// macOS：已经为哪个中继新版本发过通知（每个版本只提醒一次）。
    static let remoteRelayNotifiedVersion = "remote.relay.notifiedVersion"
    /// macOS：还没被中继确认的成员证书吊销（中继 ID → 成员公钥），注册上中继时补发。
    static let remoteRelayPendingRevocations = "remote.relay.pendingRevocations"

    static let lanSyncDeviceID = "lanSync.deviceID"
    static let lanSyncHostPairingCode = "lanSync.hostPairingCode"
    static let lanSyncPairingCode = "lanSync.pairingCode"
    static let lanSyncReceiverActivated = "lanSync.receiverActivated"
    /// iOS：用户主动连过 SSH 主机，之后在线探测可以碰局域网地址（见 `LocalNetworkUse`）。
    static let localNetworkUsed = "localNetwork.used"

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
    /// iOS 调试：启动即对第一台在中继上的 Mac 跑 N 轮链路矩阵，结果打到标准输出。
    static let remoteDebugPathMatrix = "RemoteDebugPathMatrix"
    static let debugLayoutDiagnostics = "debug.layoutDiagnostics"

    // MARK: - 系统定义的键（键名属于 macOS，不是我们的设置）

    /// 系统设置「双击窗口标题栏以…」。
    static let appleActionOnDoubleClick = "AppleActionOnDoubleClick"
    /// AppKit 拖窗跨屏时按屏幕布局调整位置的开关，见 `WindowMoveBehavior`。
    static let screenLayoutAdjustOnWindowMove = "NSScreenLayoutAdjustOnWindowMove"
}
