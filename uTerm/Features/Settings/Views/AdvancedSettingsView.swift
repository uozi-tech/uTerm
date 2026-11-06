import UDesignKit
import SwiftUI
import AppKit

/// 设置 · 高级 tab。Spec 04 实现：
/// - SSH 连接：连接超时 / 主机密钥校验
/// - 同步：iCloud 状态 + Mac 主动发起的局域网全量加密同步
/// - 诊断：日志等级 / 显示日志
///
/// 砍掉的设计稿项：keepalive 与 SSH 压缩（Citadel/NIOSSH 不支持）、
/// 转发 / 代理 group（spec 08-10）、清空数据（用户取消）。
struct AdvancedSettingsView: View {
    @AppStorage(DefaultsKey.sshConnectTimeout) private var connectTimeout: Int = 30
    @AppStorage(DefaultsKey.sshHostKeyPolicy)  private var hostKeyPolicyRaw: String = SSHHostKeyPolicy.ask.rawValue
    @AppStorage(DefaultsKey.logLevel)          private var logLevelRaw: String = LogLevel.info.rawValue
    @AppStorage(DefaultsKey.sftpMaxConcurrentTransfers) private var maxConcurrentUploads: Int = 4
    @AppStorage(ChatHistoryStore.retentionDaysKey)
    private var chatRetentionDays: Int = ChatHistoryStore.defaultRetentionDays
    /// Mac 作为局域网同步服务端，移动端通过 Bonjour 发现它。
    @Environment(LANSyncCoordinator.self) private var lanSync
    /// CloudKit 同步实时状态（uTermApp 注入；订阅 NSPersistentCloudKitContainer 事件）。
    @Environment(CloudKitSyncMonitor.self) private var sync

    private var hostKeyPolicyBinding: Binding<SSHHostKeyPolicy> {
        $hostKeyPolicyRaw.rawValue(SSHHostKeyPolicy.self, default: .ask)
    }

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "SSH 连接") {
                SettingsRow(label: "连接超时",
                            hint: "建立 SSH 握手的最长等待秒数。改动只对下次连接生效。") {
                    SettingsNumberField(value: $connectTimeout, width: 80, minValue: 1, suffix: "秒")
                }
                SettingsRow(label: "主机密钥校验",
                            hint: hostKeyPolicyBinding.wrappedValue.settingsHint) {
                    UDSegmented(selection: hostKeyPolicyBinding,
                                options: SSHHostKeyPolicy.allCases.map { ($0, $0.localizedLabel) })
                }
            }

            SettingsGroup(title: "文件传输") {
                SettingsRow(label: "并发上传数",
                            hint: "SFTP 同时上传的文件数上限（1–64）。超出的文件排队，随槽位空出依次开始。改动对新开始的传输生效。") {
                    SettingsNumberField(value: $maxConcurrentUploads,
                                        width: 80, minValue: 1, maxValue: 64, suffix: "个")
                }
            }

            SettingsGroup(title: "历史") {
                SettingsRow(label: "会话保留",
                            hint: ChatRetentionPresentation.footer(for: chatRetentionDays, platform: .macOS)) {
                    SettingsNumberField(value: $chatRetentionDays, width: 80,
                                        minValue: 0, maxValue: 3_650, suffix: "天")
                }
            }

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

            SettingsGroup(title: "诊断") {
                SettingsRow(label: "日志等级",
                            hint: "运行时立即生效；低于此等级的日志不会写入系统日志。") {
                    UDSegmented(selection: $logLevelRaw.rawValue(LogLevel.self, default: .info),
                                options: LogLevel.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: "显示日志",
                            hint: "打开 Console.app；在 Subsystem 过滤栏输入下方文本可只看 uTerm 的日志。") {
                    VStack(alignment: .trailing, spacing: 6) {
                        UDButton(title: "打开 Console", style: .secondary, action: openConsole)
                        Text("com.uozi.uTerm")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(UD.text3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func openConsole() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(url)
    }

    // ─── iCloud 同步实时状态映射（先过「是否登录 iCloud」门，再叠 monitor.phase）──────
    private var loggedIntoiCloud: Bool { FileManager.default.ubiquityIdentityToken != nil }

    /// 文案与图标两端共用（`CloudKitSyncStatus`）；mac 不做本地回退，容器恒为 CloudKit。
    private var syncStatus: CloudKitSyncStatus { sync.status(loggedIn: loggedIntoiCloud) }
}
