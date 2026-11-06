import SwiftUI
import UDesignKit

/// 设置 › 远程控制 › 已配对的设备：扫码配对（开着远程控制时）与已信任设备列表（可撤销）。
struct RemotePairedDevicesGroup: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server

    var body: some View {
        SettingsGroup(title: "已配对的设备",
                      footer: String(localized: "同一 Apple ID 的手机打开 uTerm 主机页「我的 Mac」就会自动配对；其他手机扫码配对。撤销后这台设备要重新扫码才能连接，同一 Apple ID 也不会再自动配对。")) {
            if settings.isEnabled {
                SettingsListRow(icon: "qrcode", tint: UD.accent, title: String(localized: "扫码配对"),
                                subtitle: RemoteControlPresentation.pairingHint(hasInvitation: server.pairingInvitation != nil)) {
                    if server.pairingInvitation == nil {
                        UDButton(title: "显示二维码", style: .secondary) { _ = try? server.makePairingInvitation() }
                    } else {
                        UDButton(title: "收起", style: .secondary) { server.cancelPairingInvitation() }
                    }
                }
                if let invitation = server.pairingInvitation {
                    SettingsCenteredBlock(caption: String(localized: "在 iPhone / iPad 的 uTerm 主机页打开「我的 Mac › 扫码配对」扫这个二维码。")) {
                        PairingQRCode(text: invitation.url.absoluteString)
                    }
                    .settingsDivider(inset: nil)
                }
            }
            if server.trustedPeers.isEmpty {
                SettingsEmptyRow(symbol: "iphone.slash", text: String(localized: "还没有配对的设备"))
            } else {
                ForEach(server.trustedPeers) { peer in
                    let online = server.connectedDevices.contains(peer.name)
                    SettingsListRow(icon: settingsDeviceSymbol(for: peer.name),
                                    tint: online ? UD.success : UD.accent,
                                    title: peer.name,
                                    subtitle: subtitle(for: peer, online: online)) {
                        SettingsMoreMenu(items: [
                            UDMenuItem(label: String(localized: "撤销配对…"), systemImage: "xmark.circle", danger: true) {
                                server.revoke(peer.id)
                            },
                        ], help: String(localized: "撤销后这台设备要重新扫码才能连接，同一 Apple ID 也不会再自动配对"))
                    }
                }
            }
        }
    }

    private func subtitle(for peer: RemotePeer, online: Bool) -> String {
        let paired = peer.pairedAt.formatted(date: .abbreviated, time: .omitted)
        let state = online ? String(localized: "在线") : String(localized: "离线")
        return String(localized: "配对于 \(paired) · \(state)")
    }
}
