import SwiftUI
import UDesignKit

/// 设置 › 远程控制 › 已配对的设备：扫码配对（开着远程控制时）与已信任设备列表（可撤销）。
struct RemotePairedDevicesGroup: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server

    var body: some View {
        SettingsGroup(title: "已配对的设备") {
            if settings.isEnabled {
                SettingsRow(label: "扫码配对",
                            hint: RemoteControlPresentation.pairingHint(hasInvitation: server.pairingInvitation != nil)) {
                    if server.pairingInvitation == nil {
                        UDButton(title: "显示二维码", style: .secondary) { _ = try? server.makePairingInvitation() }
                    } else {
                        UDButton(title: "收起", style: .secondary) { server.cancelPairingInvitation() }
                    }
                }
                if let invitation = server.pairingInvitation {
                    PairingQRCode(text: invitation.url.absoluteString)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            if server.trustedPeers.isEmpty {
                SettingsRow(label: "还没有", hint: "同一 Apple ID 的手机打开 uTerm 主机页「我的 Mac」就会自动配对；其他手机扫上面的二维码。") {
                    EmptyView()
                }
            } else {
                ForEach(server.trustedPeers) { peer in
                    SettingsRow(label: peer.name,
                                hint: "配对于 \(peer.pairedAt.formatted(date: .abbreviated, time: .shortened))") {
                        UDButton(title: "撤销", style: .secondary) {
                            server.revoke(peer.id)
                        }
                        .help("撤销后这台设备要重新扫码才能连接，同一 Apple ID 也不会再自动配对")
                    }
                }
            }
        }
    }
}
