import XCTest
@testable import uTerm

/// 把 `PreferenceKey` 每个常量的字符串值钉死。
///
/// 这些值是已安装用户设置的存储位置，也是 iCloud KVS / 局域网快照对齐两端的依据：
/// 改一个字符就等于把那项设置清零、断掉跨设备同步。**这里的期望值不许跟着改**——
/// 真要换键名，得在 `SharedPreferencesSync` 里写迁移（`legacyKeys`）并保留旧值。
@MainActor
final class PreferenceKeyTests: XCTestCase {

    /// (常量, 期望值)。新增常量时在这里补一行；`testEveryConstantIsPinned` 会数漏没漏。
    private static let pinned: [(actual: String, expected: String)] = [
        // 跨设备同步
        (PreferenceKey.appearancePreference, "appearancePreference"),
        (PreferenceKey.appLanguage, "appLanguage"),
        (PreferenceKey.accentColor, "accentColor"),
        (PreferenceKey.startupBehavior, "startupBehavior"),
        (PreferenceKey.restoreTerminalSession, "restoreTerminalSession"),
        (PreferenceKey.sshConnectTimeout, "sshConnectTimeout"),
        (PreferenceKey.sshHostKeyPolicy, "sshHostKeyPolicy"),
        (PreferenceKey.logLevel, "logLevel"),
        (PreferenceKey.sftpMaxConcurrentTransfers, "sftpMaxConcurrentTransfers"),
        (PreferenceKey.terminalCursorShape, "terminalCursorShape"),
        (PreferenceKey.terminalCursorBlink, "terminalCursorBlink"),
        (PreferenceKey.terminalScrollback, "terminalScrollback"),
        (PreferenceKey.terminalCopyOnSelect, "terminalCopyOnSelect"),
        (PreferenceKey.activeProviderID, "activeProviderID"),
        (PreferenceKey.agentSafety, "agentSafety"),
        (PreferenceKey.globalForwardingLaunchAtAppStart, "globalForwarding.launchAtAppStart.enabled"),
        (PreferenceKey.chatRetentionDays, "chatRetentionDays"),
        (PreferenceKey.legacyMobileAgentActiveProviderID, "mobileAgentActiveProviderID"),
        (PreferenceKey.legacyMobileAgentSafety, "mobileAgentSafety"),
        (PreferenceKey.syncModifiedPrefix, "lanSync.preferenceModified."),
        // 本机设置
        (PreferenceKey.requireAuthAtLaunch, "requireAuthAtLaunch"),
        (PreferenceKey.terminalQuitBehavior, "terminalQuitBehavior"),
        (PreferenceKey.settingsTabSelection, "settingsTabSelection"),
        (PreferenceKey.trueColorOfferDismissedHosts, "trueColorOfferDismissedHosts"),
        (PreferenceKey.externalOpenAppByExtension, "externalOpen.appByExtension"),
        (PreferenceKey.permissionGuidePresentedRevision, "permissionGuide.presentedRevision"),
        (PreferenceKey.localShellKeepsLANConnections, "localShellKeepsLANConnections"),
        (PreferenceKey.localShellRecentDirectories, "localShell.recentDirectories"),
        (PreferenceKey.controlEnabled, "control.enabled"),
        (PreferenceKey.controlAllowMutations, "control.allowMutations"),
        (PreferenceKey.controlLinkToLocalBin, "control.linkToLocalBin"),
        (PreferenceKey.backgroundLaunchAtLogin, "background.launchAtLogin"),
        (PreferenceKey.backgroundAllowOnDemandLaunch, "background.allowOnDemandLaunch"),
        (PreferenceKey.remoteEnabled, "remote.enabled"),
        (PreferenceKey.remoteDesktopEnabled, "remote.desktopEnabled"),
        (PreferenceKey.remoteLocalShellEnabled, "remote.localShellEnabled"),
        (PreferenceKey.remoteDeviceID, "remote.deviceID"),
        (PreferenceKey.remoteBrowseActivated, "remote.browseActivated"),
        (PreferenceKey.remoteDesktopKeyboardLanguage, "remote.desktop.keyboardLanguage"),
        (PreferenceKey.lanSyncDeviceID, "lanSync.deviceID"),
        (PreferenceKey.lanSyncHostPairingCode, "lanSync.hostPairingCode"),
        (PreferenceKey.lanSyncPairingCode, "lanSync.pairingCode"),
        (PreferenceKey.lanSyncReceiverActivated, "lanSync.receiverActivated"),
        (PreferenceKey.fileBrowserSortKey, "fileBrowser.sortKey"),
        (PreferenceKey.fileBrowserSortAscending, "fileBrowser.sortAscending"),
        (PreferenceKey.fileBrowserFoldersFirst, "fileBrowser.foldersFirst"),
        (PreferenceKey.fileBrowserShowHidden, "fileBrowser.showHidden"),
        // 调试开关
        (PreferenceKey.sshTimingProbe, "sshTimingProbe"),
        (PreferenceKey.remoteDebugOpenDesktop, "RemoteDebugOpenDesktop"),
        (PreferenceKey.remoteDebugEndpoint, "RemoteDebugEndpoint"),
        (PreferenceKey.debugLayoutDiagnostics, "debug.layoutDiagnostics"),
        // 系统定义
        (PreferenceKey.appleActionOnDoubleClick, "AppleActionOnDoubleClick"),
        (PreferenceKey.screenLayoutAdjustOnWindowMove, "NSScreenLayoutAdjustOnWindowMove"),
    ]

    func testKeyValuesArePinned() {
        for (actual, expected) in Self.pinned {
            XCTAssertEqual(actual, expected, "偏好键名被改了：会丢掉已安装用户的设置、断开跨设备同步")
        }
    }

    func testKeyValuesAreUnique() {
        let values = Self.pinned.map(\.actual)
        let duplicates = Dictionary(grouping: values, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(duplicates.isEmpty, "两个常量指向同一个键：\(duplicates.sorted())")
    }

    /// 表里每个 `static let` 都要在上面钉住，漏一个就等于那个键没人看着。
    func testEveryConstantIsPinned() throws {
        let source = try String(contentsOf: PreferenceKeyLintTests.repoRoot
            .appendingPathComponent("uTerm/Core/Preferences/PreferenceKey.swift"), encoding: .utf8)
        let declared = source.matches(of: /static let \w+ = "([^"]+)"/).map { String($0.output.1) }
        XCTAssertGreaterThan(declared.count, 40, "夹具失效：应能从键名表读到四十多个常量")
        XCTAssertEqual(Set(declared), Set(Self.pinned.map(\.expected)),
                       "PreferenceKey 与钉值表不一致：新增常量请在 pinned 里补一行")
        XCTAssertEqual(declared.count, Self.pinned.count)
    }

    /// 已经钉过的转发常量（老调用面）必须仍指向同一个键。
    func testForwardingConstantsMatchTable() {
        XCTAssertEqual(AppLockPreference.key, PreferenceKey.requireAuthAtLaunch)
        XCTAssertEqual(ChatHistoryStore.retentionDaysKey, PreferenceKey.chatRetentionDays)
        XCTAssertEqual(TerminalQuitPolicy.behaviorKey, PreferenceKey.terminalQuitBehavior)
        XCTAssertEqual(LocalShellNetworkPolicy.key, PreferenceKey.localShellKeepsLANConnections)
        XCTAssertEqual(SettingsTabSelection.key, PreferenceKey.settingsTabSelection)
        XCTAssertEqual(BinLinkInstaller.enabledDefaultsKey, PreferenceKey.controlLinkToLocalBin)
        XCTAssertEqual(PermissionGuideWindow.presentedRevisionKey, PreferenceKey.permissionGuidePresentedRevision)
        XCTAssertEqual(ControlSettings.Keys.enabled, PreferenceKey.controlEnabled)
        XCTAssertEqual(ControlSettings.Keys.allowMutations, PreferenceKey.controlAllowMutations)
        XCTAssertEqual(RemoteControlSettings.Keys.enabled, PreferenceKey.remoteEnabled)
        XCTAssertEqual(RemoteControlSettings.Keys.desktopEnabled, PreferenceKey.remoteDesktopEnabled)
        XCTAssertEqual(RemoteControlSettings.Keys.localShellEnabled, PreferenceKey.remoteLocalShellEnabled)
        XCTAssertEqual(BackgroundServiceSettings.Keys.launchAtLogin, PreferenceKey.backgroundLaunchAtLogin)
        XCTAssertEqual(BackgroundServiceSettings.Keys.allowOnDemandLaunch, PreferenceKey.backgroundAllowOnDemandLaunch)
        XCTAssertEqual(ExternalAppPreference.defaultsKey, PreferenceKey.externalOpenAppByExtension)
    }
}
