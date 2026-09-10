import UDesignKit
import SwiftUI
import AppKit

/// 设置 · 高级 tab。Spec 04 实现：
/// - SSH 连接：连接超时 / 主机密钥校验
/// - 诊断：日志等级 / 显示日志
///
/// 砍掉的设计稿项：keepalive 与 SSH 压缩（Citadel/NIOSSH 不支持）、
/// 转发 / 代理 group（spec 08-10）、清空数据（用户取消）。
struct AdvancedSettingsView: View {
    @AppStorage("sshConnectTimeout") private var connectTimeout: Int = 30
    @AppStorage("sshHostKeyPolicy")  private var hostKeyPolicyRaw: String = SSHHostKeyPolicy.ask.rawValue
    @AppStorage("logLevel")          private var logLevelRaw: String = LogLevel.info.rawValue
    @AppStorage("sftpMaxConcurrentTransfers") private var maxConcurrentUploads: Int = 4
    /// CloudKit 同步实时状态（uTermApp 注入；订阅 NSPersistentCloudKitContainer 事件）。
    @Environment(CloudKitSyncMonitor.self) private var sync

    private var hostKeyPolicyBinding: Binding<SSHHostKeyPolicy> {
        Binding(
            get: { SSHHostKeyPolicy(rawValue: hostKeyPolicyRaw) ?? .ask },
            set: { hostKeyPolicyRaw = $0.rawValue }
        )
    }
    private var logLevelBinding: Binding<LogLevel> {
        Binding(
            get: { LogLevel(rawValue: logLevelRaw) ?? .info },
            set: { logLevelRaw = $0.rawValue }
        )
    }

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "SSH 连接") {
                SettingsRow(label: "连接超时",
                            hint: "建立 SSH 握手的最长等待秒数。改动只对下次连接生效。") {
                    SettingsNumberField(value: $connectTimeout, width: 80, minValue: 1, suffix: "秒")
                }
                SettingsRow(label: "主机密钥校验",
                            hint: hostKeyHint) {
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

            SettingsGroup(title: "诊断") {
                SettingsRow(label: "iCloud 同步", hint: syncHint) {
                    HStack(spacing: 6) {
                        Image(systemName: syncIcon)
                            .font(.system(size: 12))
                            .foregroundStyle(syncTint)
                        Text(syncLabel)
                            .font(.system(size: 12.5))
                            .foregroundStyle(UD.text2)
                    }
                }
                SettingsRow(label: "日志等级",
                            hint: "运行时立即生效；低于此等级的日志不会写入系统日志。") {
                    UDSegmented(selection: logLevelBinding,
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

    private var hostKeyHint: String {
        switch hostKeyPolicyBinding.wrappedValue {
        case .strict: return "未知 / 不匹配的主机密钥直接拒绝连接，不弹窗。"
        case .ask:    return "未知 / 不匹配时弹窗让你决定（默认 + 推荐）。"
        case .none:   return "⚠️ 不安全：未知 / 不匹配都静默信任。仅本地实验用。"
        }
    }

    private func openConsole() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(url)
    }

    // ─── iCloud 同步实时状态映射（先过「是否登录 iCloud」门，再叠 monitor.phase）──────
    private var loggedIntoiCloud: Bool { FileManager.default.ubiquityIdentityToken != nil }

    private var syncLabel: String {
        guard loggedIntoiCloud else { return "未登录 iCloud" }
        switch sync.phase {
        case .setup:     return "连接中…"
        case .importing: return "下载中…"
        case .exporting: return "上传中…"
        case .error:     return "同步出错"
        case .idle:      return sync.lastSyncedAt != nil ? "已同步" : "等待同步"
        }
    }

    private var syncIcon: String {
        guard loggedIntoiCloud else { return "person.crop.circle.badge.xmark" }
        switch sync.phase {
        case .setup:     return "arrow.triangle.2.circlepath"
        case .importing: return "icloud.and.arrow.down"
        case .exporting: return "icloud.and.arrow.up"
        case .error:     return "exclamationmark.icloud"
        case .idle:      return sync.lastSyncedAt != nil ? "checkmark.icloud" : "icloud"
        }
    }

    private var syncTint: Color {
        switch sync.phase {
        case .error:                          return .orange
        case .setup, .importing, .exporting:  return UD.accent
        case .idle:                           return UD.text3
        }
    }

    private var syncHint: String {
        if sync.phase == .error, let e = sync.lastError {
            return "最近一次同步出错：\(e)。完整日志见下方「显示日志」。"
        }
        return "主机 / 分组 / 密钥等数据通过 CloudKit，同步偏好通过 iCloud KVS 在设备间共享；后台进行，非即时。完整事件日志见下方「显示日志」。"
    }
}
