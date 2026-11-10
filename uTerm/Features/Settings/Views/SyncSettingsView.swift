import UDesignKit
import SwiftUI
import AppKit

/// 设置 · 同步：iCloud 状态与同步诊断、Mac 主动发起的局域网全量加密同步、AI 会话保留窗口
/// （原「高级」里的「同步」与「历史」两组）。状态图标 / 色调 / 文案与 iOS 共用
/// `SyncStatusPresentation` / `SyncDiagnosticsPresentation` / `ChatRetentionPresentation`。
struct SyncSettingsView: View {
    @AppStorage(ChatHistoryStore.retentionDaysKey)
    private var chatRetentionDays: Int = ChatHistoryStore.defaultRetentionDays
    /// Mac 作为局域网同步服务端，移动端通过 Bonjour 发现它。
    @Environment(LANSyncCoordinator.self) private var lanSync
    /// CloudKit 同步实时状态（uTermApp 注入；订阅 NSPersistentCloudKitContainer 事件）。
    @Environment(CloudKitSyncMonitor.self) private var sync
    @State private var showDiagnostics = false
    @State private var copiedCode = false

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: "同步", subtitle: String(localized: "iCloud 后台同步与局域网快速同步"))

            SettingsGroup(title: "iCloud") {
                SettingsRow(label: "iCloud 同步", hint: SyncStatusPresentation.cloudHint(loggedIn: loggedIntoiCloud)) {
                    let cloud = SyncStatusPresentation.cloud(syncStatus)
                    SettingsStatusLabel(symbol: cloud.symbol, tone: cloud.tone, text: syncStatus.label)
                }
                SettingsRow(label: "同步诊断",
                            hint: SyncStatusPresentation.diagnosticsSubtitle(status: syncStatus,
                                                                            lastError: sync.lastError)) {
                    UDButton(title: "查看事件…", style: .secondary) { showDiagnostics = true }
                }
            }

            SettingsGroup(title: "局域网",
                          footer: String(localized: "Mac 发现同一局域网里的 iPhone / iPad 后，点「发送同步」把全量数据发过去，对方确认后才开始传输。在 iPhone / iPad 的「局域网同步」里输入上面的配对码。")) {
                SettingsRow(label: "发送状态") {
                    let lan = SyncStatusPresentation.lan(lanSync.status)
                    SettingsStatusLabel(symbol: lan.symbol, tone: lan.tone, text: lanSync.status.label)
                }
                ForEach(lanSync.peers) { peer in
                    SettingsListRow(icon: settingsDeviceSymbol(for: peer.name), tint: UD.accent,
                                    title: peer.name, subtitle: String(localized: "已在局域网发现")) {
                        UDButton(title: "发送同步", style: .secondary, systemImage: "arrow.up.circle") {
                            lanSync.sendSync(to: peer)
                        }
                    }
                }
                SettingsRow(label: "配对码") {
                    HStack(spacing: 10) {
                        Text(lanSync.pairingCode)
                            .font(.system(size: 16, design: .monospaced).weight(.semibold))
                            .tracking(2)
                            .foregroundStyle(UD.text)
                            .textSelection(.enabled)
                        UDButton(title: copiedCode ? "已拷贝" : "拷贝", style: .secondary) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(lanSync.pairingCode, forType: .string)
                            copiedCode = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copiedCode = false
                            }
                        }
                    }
                }
            }

            SettingsGroup(title: "历史",
                          footer: ChatRetentionPresentation.footer(for: chatRetentionDays, platform: .macOS)) {
                SettingsRow(label: "AI 对话保留") {
                    SettingsNumberField(value: $chatRetentionDays, width: 72,
                                        minValue: 0, maxValue: 3_650, suffix: "天")
                }
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            SyncDiagnosticsView(sync: sync)
        }
    }

    // 先过「是否登录 iCloud」门，再叠 monitor.phase；mac 不做本地回退，容器恒为 CloudKit。
    private var loggedIntoiCloud: Bool { FileManager.default.ubiquityIdentityToken != nil }
    private var syncStatus: CloudKitSyncStatus { sync.status(loggedIn: loggedIntoiCloud) }
}
