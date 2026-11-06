import UDesignKit
import SwiftUI

/// 设置 · 连接：SSH 握手超时 / 主机密钥校验 / SFTP 并发上传数（原「高级」的前两组）。
/// 三项都与 iOS 同步，iOS 在 设置 › 连接 里用预设档改同一组键。
///
/// 砍掉的设计稿项：keepalive 与 SSH 压缩（Citadel/NIOSSH 不支持）。
struct ConnectionSettingsView: View {
    @AppStorage(DefaultsKey.sshConnectTimeout) private var connectTimeout: Int = ConnectionPresentation.defaultTimeout
    @AppStorage(DefaultsKey.sshHostKeyPolicy)  private var hostKeyPolicyRaw: String = SSHHostKeyPolicy.ask.rawValue
    @AppStorage(DefaultsKey.sftpMaxConcurrentTransfers)
    private var maxConcurrentUploads: Int = ConnectionPresentation.defaultSFTPConcurrency

    private var hostKeyPolicyBinding: Binding<SSHHostKeyPolicy> {
        $hostKeyPolicyRaw.rawValue(SSHHostKeyPolicy.self, default: .ask)
    }

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: "连接", subtitle: String(localized: "SSH 握手与文件传输"))

            SettingsGroup(title: "SSH 连接", footer: hostKeyPolicyBinding.wrappedValue.settingsHint) {
                SettingsRow(label: "连接超时",
                            hint: "建立 SSH 握手的最长等待时间，对下次连接生效") {
                    SettingsNumberField(value: $connectTimeout, width: 72, minValue: 1, suffix: "秒")
                }
                SettingsRow(label: "主机密钥校验") {
                    SettingsPicker(selection: hostKeyPolicyBinding,
                                   options: SSHHostKeyPolicy.allCases.map { ($0, $0.localizedLabel) })
                }
            }

            SettingsGroup(title: "文件传输",
                          footer: String(localized: "超出的文件排队，随槽位空出依次开始。改动对新开始的传输生效。")) {
                SettingsRow(label: "并发上传数",
                            hint: "SFTP 同时上传的文件数上限（1–64）") {
                    SettingsNumberField(value: $maxConcurrentUploads,
                                        width: 72, minValue: 1, maxValue: 64, suffix: "个文件")
                }
            }
        }
    }
}
