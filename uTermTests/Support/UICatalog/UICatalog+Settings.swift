import AppKit
import SwiftData
import SwiftUI
@testable import uTerm

/// 设置窗口每一页。环境照 `SettingsPageSnapshotTests` 的夹具搭：一次性的设置存储、内存容器、
/// 不碰钥匙串的远控身份、不广播的远控服务。
@MainActor
extension UICatalog {
    static var settings: [UICatalogEntry] {
        SettingsView.sections.map { section in
            UICatalogEntry("设置/\(section.title)", source: "uTerm/Features/Settings/Views/SettingsView.swift",
                           symbol: "SettingsView", size: CGSize(width: 940, height: 680)) { stage in
                let s = try stage.session()
                s.defaults.set(section.rawValue, forKey: SettingsTabSelection.key)
                return UICatalogRender(settingsEnvironment(SettingsView(), s))
            }
        }
    }

    private static func settingsEnvironment(_ content: some View, _ s: UICatalogStage.Session) -> some View {
        let ctx = s.context
        for (i, sample) in [("Anthropic", ProviderKind.anthropic, "https://api.anthropic.com", "claude-sonnet-5-5"),
                            ("OpenAI", .openai, ProviderPreset.openAIBaseURL, "gpt-5"),
                            ("DeepSeek", .openai, "https://api.deepseek.com", "deepseek-v4-pro")].enumerated() {
            ctx.insert(AIProvider(name: sample.0, kind: sample.1, baseURL: sample.2, model: sample.3, sortOrder: i))
        }
        try? ctx.save()

        let lanSync = LANSyncCoordinator(
            role: .sender,
            preferences: SharedPreferencesSync(defaults: s.defaults, store: UICatalogKeyValueStore()),
            dataStore: LANSyncDataStore(container: s.container),
            defaults: s.defaults)
        let remoteSettings = RemoteControlSettings(defaults: s.defaults)
        let identity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        for (name, at) in [("我的 iPhone", 1_789_000_000.0), ("工作室 iPad Pro", 1_786_500_000.0)] {
            try? identity.trust(RemotePeer(id: UUID(), name: name, publicKey: Data(repeating: 7, count: 32),
                                           pairedAt: Date(timeIntervalSince1970: at)))
        }
        let remoteServer = RemoteHostServer(registry: TerminalSessionRegistry(), identity: identity,
                                            localName: "MacBook Pro", localID: UUID(), advertises: false)
        remoteSettings.isEnabled = true
        remoteSettings.isLocalShellEnabled = true
        remoteSettings.isDesktopEnabled = true
        remoteServer.relayConfig = RemoteRelayConfig(name: "relay-sz", host: "relay.example.invalid", port: 47310,
                                                     relayID: "catalog",
                                                     key: Data(repeating: 1, count: 32).base64EncodedString())

        return s.wrap(content)
            .environment(AppUpdater())
            .environment(lanSync)
            .environment(CloudKitSyncMonitor())
            .environment(remoteSettings)
            .environment(remoteServer)
            .environment(RemoteDeviceGroupService { _ in nil })
    }
}

/// 不碰真 iCloud KVS 的替身（同 `SettingsPageSnapshotTests` 里那个）。
final class UICatalogKeyValueStore: NSUbiquitousKeyValueStore {}
