import UDesignKit
import SwiftUI

/// 设置 · 同步：iCloud 状态、Mac 主动发起的局域网全量加密同步、AI 会话保留窗口
/// （原「高级」里的「同步」与「历史」两组）。状态图标 / 色调 / 文案与 iOS 共用
/// `SyncStatusPresentation` / `ChatRetentionPresentation`。
struct SyncSettingsView: View {
    @AppStorage(ChatHistoryStore.retentionDaysKey)
    private var chatRetentionDays: Int = ChatHistoryStore.defaultRetentionDays
    /// Mac 作为局域网同步服务端，移动端通过 Bonjour 发现它。
    @Environment(LANSyncCoordinator.self) private var lanSync
    /// CloudKit 同步实时状态（uTermApp 注入；订阅 NSPersistentCloudKitContainer 事件）。
    @Environment(CloudKitSyncMonitor.self) private var sync

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "同步") {
                SettingsRow(label: "iCloud 同步", hint: SyncStatusPresentation.cloudHint(loggedIn: loggedIntoiCloud)) {
                    let cloud = SyncStatusPresentation.cloud(syncStatus)
                    HStack(spacing: 6) {
                        Image(systemName: cloud.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(cloud.tone.color)
                        Text(syncStatus.label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(UD.text2)
                    }
                }
                SettingsRow(label: "局域网发送", hint: "Mac 发现移动设备后主动发送全量数据，移动端确认后才会传输。") {
                    let lan = SyncStatusPresentation.lan(lanSync.status)
                    HStack(spacing: 6) {
                        Image(systemName: lan.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(lan.tone.color)
                        Text(lanSync.status.label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(UD.text2)
                    }
                }
                if !lanSync.peers.isEmpty {
                    SettingsRow(label: "移动设备", hint: "选择已发现的 iPhone / iPad，发送前会在移动端再次确认。") {
                        UDButton(title: "发送同步", style: .secondary, systemImage: "arrow.up.circle") {
                            lanSync.sendSync()
                        }
                    }
                }
                SettingsRow(label: "配对码", hint: "在 iPhone / iPad 的局域网同步中输入此 6 位代码。") {
                    Text(lanSync.pairingCode)
                        .font(.system(size: 14, design: .monospaced).weight(.semibold))
                        .foregroundStyle(UD.text)
                        .textSelection(.enabled)
                }
            }

            SettingsGroup(title: "历史") {
                SettingsRow(label: "会话保留",
                            hint: ChatRetentionPresentation.footer(for: chatRetentionDays, platform: .macOS)) {
                    SettingsNumberField(value: $chatRetentionDays, width: 80,
                                        minValue: 0, maxValue: 3_650, suffix: "天")
                }
            }
        }
    }

    // 先过「是否登录 iCloud」门，再叠 monitor.phase；mac 不做本地回退，容器恒为 CloudKit。
    private var loggedIntoiCloud: Bool { FileManager.default.ubiquityIdentityToken != nil }
    private var syncStatus: CloudKitSyncStatus { sync.status(loggedIn: loggedIntoiCloud) }
}
