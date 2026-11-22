import SwiftUI

/// 设置 › 连接：进 `ConnectionSettingsScreen`（SSH 超时 / 主机密钥校验 / SFTP 并发，与 Mac 同步）。
struct SettingsConnectionSection: View {
    @AppStorage(DefaultsKey.sshConnectTimeout) private var connectTimeout = ConnectionPresentation.defaultTimeout
    @AppStorage(DefaultsKey.sshHostKeyPolicy) private var hostKeyPolicyRaw = SSHHostKeyPolicy.ask.rawValue

    private var summary: String {
        let policy = SSHHostKeyPolicy(rawValue: hostKeyPolicyRaw) ?? .ask
        return String(localized: "超时 \(ConnectionPresentation.timeoutLabel(connectTimeout)) · 密钥校验\(policy.localizedLabel)")
    }

    var body: some View {
        MInsetGroup(header: String(localized: "连接")) {
            NavigationLink { ConnectionSettingsScreen() } label: {
                MInsetRow(icon: "network", label: String(localized: "连接", comment: "设置项：SSH 连接"), sub: summary, chevron: true, last: true)
            }.buttonStyle(MRowStyle())
        }
    }
}
