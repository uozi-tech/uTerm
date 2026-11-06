import XCTest
@testable import uTerm

/// 把 `DefaultsKey` 每个常量的字符串值钉死。
///
/// 这些值是已安装用户设置的存储位置，也是 iCloud KVS / 局域网快照对齐两端的依据：
/// 改一个字符就等于把那项设置清零、断掉跨设备同步。**这里的期望值不许跟着改**——
/// 真要换键名，得在 `SharedPreferencesSync` 里写迁移（`legacyKeys`）并保留旧值。
@MainActor
final class DefaultsKeyTests: XCTestCase {

    /// (常量, 期望值)。新增常量时在这里补一行；`testEveryConstantIsPinned` 会数漏没漏。
    private static let pinned: [(actual: String, expected: String)] = [
        // 跨设备同步
        (DefaultsKey.appearancePreference, "appearancePreference"),
        (DefaultsKey.appLanguage, "appLanguage"),
        (DefaultsKey.accentColor, "accentColor"),
        (DefaultsKey.startupBehavior, "startupBehavior"),
        (DefaultsKey.restoreTerminalSession, "restoreTerminalSession"),
        (DefaultsKey.sshConnectTimeout, "sshConnectTimeout"),
        (DefaultsKey.sshHostKeyPolicy, "sshHostKeyPolicy"),
        (DefaultsKey.logLevel, "logLevel"),
        (DefaultsKey.sftpMaxConcurrentTransfers, "sftpMaxConcurrentTransfers"),
        (DefaultsKey.terminalCursorShape, "terminalCursorShape"),
        (DefaultsKey.terminalCursorBlink, "terminalCursorBlink"),
        (DefaultsKey.terminalScrollback, "terminalScrollback"),
        (DefaultsKey.terminalCopyOnSelect, "terminalCopyOnSelect"),
        (DefaultsKey.activeProviderID, "activeProviderID"),
        (DefaultsKey.agentSafety, "agentSafety"),
        (DefaultsKey.globalForwardingLaunchAtAppStart, "globalForwarding.launchAtAppStart.enabled"),
        (DefaultsKey.chatRetentionDays, "chatRetentionDays"),
        (DefaultsKey.legacyMobileAgentActiveProviderID, "mobileAgentActiveProviderID"),
        (DefaultsKey.legacyMobileAgentSafety, "mobileAgentSafety"),
        (DefaultsKey.syncModifiedPrefix, "lanSync.preferenceModified."),
        // 本机设置
        (DefaultsKey.requireAuthAtLaunch, "requireAuthAtLaunch"),
        (DefaultsKey.terminalQuitBehavior, "terminalQuitBehavior"),
        (DefaultsKey.settingsTabSelection, "settingsTabSelection"),
        (DefaultsKey.trueColorOfferDismissedHosts, "trueColorOfferDismissedHosts"),
        (DefaultsKey.externalOpenAppByExtension, "externalOpen.appByExtension"),
        (DefaultsKey.permissionGuidePresentedRevision, "permissionGuide.presentedRevision"),
        (DefaultsKey.localShellKeepsLANConnections, "localShellKeepsLANConnections"),
        (DefaultsKey.localShellRecentDirectories, "localShell.recentDirectories"),
        (DefaultsKey.controlEnabled, "control.enabled"),
        (DefaultsKey.controlAllowMutations, "control.allowMutations"),
        (DefaultsKey.controlLinkToLocalBin, "control.linkToLocalBin"),
        (DefaultsKey.backgroundLaunchAtLogin, "background.launchAtLogin"),
        (DefaultsKey.backgroundAllowOnDemandLaunch, "background.allowOnDemandLaunch"),
        (DefaultsKey.remoteEnabled, "remote.enabled"),
        (DefaultsKey.remoteDesktopEnabled, "remote.desktopEnabled"),
        (DefaultsKey.remoteLocalShellEnabled, "remote.localShellEnabled"),
        (DefaultsKey.remoteDeviceID, "remote.deviceID"),
        (DefaultsKey.remoteInternetEnabled, "remote.internetEnabled"),
        (DefaultsKey.remoteInternetDevices, "remote.internetDevices"),
        (DefaultsKey.remoteKeepAwakeForInternet, "remote.keepAwakeForInternet"),
        (DefaultsKey.remoteInternetOnly, "remote.internetOnly"),
        (DefaultsKey.remotePathMatrixLog, "remote.pathMatrixLog"),
        (DefaultsKey.remoteIceProbeNote, "remote.iceProbeNote"),
        (DefaultsKey.remotePathMatrixRounds, "remote.pathMatrixRounds"),
        (DefaultsKey.remotePathMatrixSkippedModes, "remote.pathMatrixSkippedModes"),
        (DefaultsKey.remoteBrowseActivated, "remote.browseActivated"),
        (DefaultsKey.remoteDesktopKeyboardLanguage, "remote.desktop.keyboardLanguage"),
        (DefaultsKey.lanSyncDeviceID, "lanSync.deviceID"),
        (DefaultsKey.lanSyncHostPairingCode, "lanSync.hostPairingCode"),
        (DefaultsKey.lanSyncPairingCode, "lanSync.pairingCode"),
        (DefaultsKey.lanSyncReceiverActivated, "lanSync.receiverActivated"),
        (DefaultsKey.localNetworkUsed, "localNetwork.used"),
        (DefaultsKey.fileBrowserSortKey, "fileBrowser.sortKey"),
        (DefaultsKey.fileBrowserSortAscending, "fileBrowser.sortAscending"),
        (DefaultsKey.fileBrowserFoldersFirst, "fileBrowser.foldersFirst"),
        (DefaultsKey.fileBrowserShowHidden, "fileBrowser.showHidden"),
        // 调试开关
        (DefaultsKey.sshTimingProbe, "sshTimingProbe"),
        (DefaultsKey.remoteDebugOpenDesktop, "RemoteDebugOpenDesktop"),
        (DefaultsKey.remoteDebugEndpoint, "RemoteDebugEndpoint"),
        (DefaultsKey.remoteDebugPathMatrix, "RemoteDebugPathMatrix"),
        (DefaultsKey.debugLayoutDiagnostics, "debug.layoutDiagnostics"),
        // 系统定义
        (DefaultsKey.appleActionOnDoubleClick, "AppleActionOnDoubleClick"),
        (DefaultsKey.screenLayoutAdjustOnWindowMove, "NSScreenLayoutAdjustOnWindowMove"),
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
        let source = try String(contentsOf: DefaultsKeyLintTests.repoRoot
            .appendingPathComponent("uTerm/Core/Preferences/DefaultsKey.swift"), encoding: .utf8)
        let declared = source.matches(of: /static let \w+ = "([^"]+)"/).map { String($0.output.1) }
        XCTAssertGreaterThan(declared.count, 40, "夹具失效：应能从键名表读到四十多个常量")
        XCTAssertEqual(Set(declared), Set(Self.pinned.map(\.expected)),
                       "DefaultsKey 与钉值表不一致：新增常量请在 pinned 里补一行")
        XCTAssertEqual(declared.count, Self.pinned.count)
    }

    /// 已经钉过的转发常量（老调用面）必须仍指向同一个键。
    func testForwardingConstantsMatchTable() {
        XCTAssertEqual(AppLockPreference.key, DefaultsKey.requireAuthAtLaunch)
        XCTAssertEqual(ChatHistoryStore.retentionDaysKey, DefaultsKey.chatRetentionDays)
        XCTAssertEqual(TerminalQuitPolicy.behaviorKey, DefaultsKey.terminalQuitBehavior)
        XCTAssertEqual(LocalShellNetworkPolicy.key, DefaultsKey.localShellKeepsLANConnections)
        XCTAssertEqual(SettingsTabSelection.key, DefaultsKey.settingsTabSelection)
        XCTAssertEqual(BinLinkInstaller.enabledDefaultsKey, DefaultsKey.controlLinkToLocalBin)
        XCTAssertEqual(PermissionGuideWindow.presentedRevisionKey, DefaultsKey.permissionGuidePresentedRevision)
        XCTAssertEqual(ControlSettings.Keys.enabled, DefaultsKey.controlEnabled)
        XCTAssertEqual(ControlSettings.Keys.allowMutations, DefaultsKey.controlAllowMutations)
        XCTAssertEqual(RemoteControlSettings.Keys.enabled, DefaultsKey.remoteEnabled)
        XCTAssertEqual(RemoteControlSettings.Keys.desktopEnabled, DefaultsKey.remoteDesktopEnabled)
        XCTAssertEqual(RemoteControlSettings.Keys.localShellEnabled, DefaultsKey.remoteLocalShellEnabled)
        XCTAssertEqual(RemoteControlSettings.Keys.internetEnabled, DefaultsKey.remoteInternetEnabled)
        XCTAssertEqual(RemoteControlSettings.Keys.internetDevices, DefaultsKey.remoteInternetDevices)
        XCTAssertEqual(RemoteControlSettings.Keys.keepAwakeForInternet, DefaultsKey.remoteKeepAwakeForInternet)
        XCTAssertEqual(BackgroundServiceSettings.Keys.launchAtLogin, DefaultsKey.backgroundLaunchAtLogin)
        XCTAssertEqual(BackgroundServiceSettings.Keys.allowOnDemandLaunch, DefaultsKey.backgroundAllowOnDemandLaunch)
        XCTAssertEqual(ExternalAppPreference.defaultsKey, DefaultsKey.externalOpenAppByExtension)
    }
}
