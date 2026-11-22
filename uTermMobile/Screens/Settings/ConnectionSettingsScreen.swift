import SwiftUI

/// 设置 › 连接：SSH 握手超时 / 主机密钥校验 / SFTP 并发传输。与 Mac 的「连接」页是同一组同步键，
/// 共享代码（`SSHClientFactory` / `FileBrowserModel`）在 iOS 上同样读它们。
/// 手机上不弹数字键盘，用预设档菜单（档位在共享的 `ConnectionPresentation`）；Mac 上填过的
/// 非预设值照样显示。
struct ConnectionSettingsScreen: View {
    @AppStorage(DefaultsKey.sshConnectTimeout) private var connectTimeout = ConnectionPresentation.defaultTimeout
    @AppStorage(DefaultsKey.sshHostKeyPolicy) private var hostKeyPolicyRaw = SSHHostKeyPolicy.ask.rawValue
    @AppStorage(DefaultsKey.sftpMaxConcurrentTransfers)
    private var sftpConcurrency = ConnectionPresentation.defaultSFTPConcurrency

    private var hostKeyPolicy: Binding<SSHHostKeyPolicy> {
        $hostKeyPolicyRaw.rawValue(SSHHostKeyPolicy.self, default: .ask)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                MInsetGroup(header: String(localized: "SSH 连接"), footer: String(localized: "等待 SSH 连接建立的最长时间，修改后对新连接生效。")) {
                    MInsetRow(label: String(localized: "连接超时"), last: true,
                              trailing: AnyView(menu(current: ConnectionPresentation.timeoutLabel(connectTimeout)) {
                                  ForEach(ConnectionPresentation.timeoutOptions, id: \.self) { seconds in
                                      Button(ConnectionPresentation.timeoutLabel(seconds)) { connectTimeout = seconds }
                                  }
                              }))
                }
                MInsetGroup(header: String(localized: "主机密钥"), footer: hostKeyPolicy.wrappedValue.settingsHint) {
                    MInsetRow(label: String(localized: "主机密钥校验"), last: true,
                              trailing: AnyView(menu(current: hostKeyPolicy.wrappedValue.localizedLabel) {
                                  ForEach(SSHHostKeyPolicy.allCases) { policy in
                                      Button(policy.localizedLabel) { hostKeyPolicy.wrappedValue = policy }
                                  }
                              }))
                }
                MInsetGroup(header: String(localized: "文件传输"),
                            footer: String(localized: "SFTP 同时传输的文件数上限，超出的排队依次开始。以上设置与 Mac 同步。")) {
                    MInsetRow(label: String(localized: "并发传输"), last: true,
                              trailing: AnyView(menu(current: ConnectionPresentation.sftpConcurrencyLabel(sftpConcurrency)) {
                                  ForEach(ConnectionPresentation.sftpConcurrencyOptions, id: \.self) { count in
                                      Button(ConnectionPresentation.sftpConcurrencyLabel(count)) { sftpConcurrency = count }
                                  }
                              }))
                }
            }
            .padding(.top, 12)
        }
        .background(M.canvas)
        .navigationTitle("连接")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func menu<Items: View>(current: String, @ViewBuilder items: () -> Items) -> some View {
        MMenu {
            items()
        } label: {
            HStack(spacing: 4) {
                Text(current).font(M.sans(15)).foregroundStyle(M.text2)
                MIcon(name: "chev-down", size: 11, color: M.text4)
            }
        }
    }
}
