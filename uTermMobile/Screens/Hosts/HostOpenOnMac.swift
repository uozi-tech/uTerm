import SwiftUI

/// 主机详情里的「经 Mac 打开」：让一台配对过、此刻在线的 Mac 去连这台主机，手机接管它开出来的终端。
///
/// SSH 连接在 Mac 上，手机只是看着它：手机退到后台、断网、App 被系统结束，会话都在 Mac 上接着跑。
/// 适合装不了主机端保持进程的主机（不是 Linux、退出登录会清进程），或者本来就想让 Mac 上也留一个窗口。
/// 没有配对过的 Mac 在线时这一块不出现。
struct HostOpenOnMacRows: View {
    let host: ServerProfile
    /// 终端在 Mac 上开好了：调用方收起面板、接管它。
    var onOpened: (RemoteMacClient, UUID) -> Void

    @Environment(RemoteMacDirectory.self) private var directory: RemoteMacDirectory?
    @State private var openingMac: String?
    @State private var failure: String?

    var body: some View {
        if let directory, !host.sftpOnly {
            let macs = directory.macs.filter(\.isOnline)
            if !macs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(macs, id: \.id) { mac in
                        row(mac, in: directory)
                    }
                    if let failure {
                        Text(failure)
                            .font(M.sans(12.5)).foregroundStyle(M.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        Text("由 Mac 连接这台主机，手机退到后台或断网时会话留在 Mac 上")
                            .font(M.sans(12.5)).foregroundStyle(M.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func row(_ mac: RemoteMacDirectory.Mac, in directory: RemoteMacDirectory) -> some View {
        Button {
            open(on: mac, in: directory)
        } label: {
            HStack(spacing: 10) {
                MIcon(name: "mac", size: 17, color: M.text2)
                Text("经「\(mac.name)」打开")
                    .font(M.sans(14.5, weight: .medium)).foregroundStyle(M.text).lineLimit(1)
                Spacer(minLength: 6)
                if openingMac == mac.id { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(M.fillFaint)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.lg))
        }
        .buttonStyle(MPressStyle())
        .disabled(openingMac != nil)
    }

    private func open(on mac: RemoteMacDirectory.Mac, in directory: RemoteMacDirectory) {
        let client = directory.client(for: mac)
        let serverID = host.id
        openingMac = mac.id
        failure = nil
        Task {
            defer { openingMac = nil }
            do {
                onOpened(client, try await client.openHost(serverID: serverID))
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
