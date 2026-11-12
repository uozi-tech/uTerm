import AppKit
import SwiftUI
import UDesignKit

/// 设置 › 远程控制 › 已配对的设备：扫码配对（开着远程控制时）与已信任设备列表（可撤销）。
struct RemotePairedDevicesGroup: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server
    /// 正在改名的设备与输入框里的字。
    @State private var renaming: RemotePeer?
    @State private var renameText = ""

    var body: some View {
        SettingsGroup(title: "已配对的设备",
                      footer: String(localized: "配对过的设备才能连接这台 Mac，同一 Apple ID 的也要配对一次。撤销后这台设备要重新配对。")) {
            if settings.isEnabled {
                SettingsListRow(icon: "qrcode", tint: UD.accent, title: String(localized: "扫码配对"),
                                subtitle: RemoteControlPresentation.pairingHint(hasInvitation: server.pairingInvitation != nil)) {
                    if server.pairingInvitation == nil {
                        UDButton(title: "显示二维码", style: .secondary) { server.showPairingInvitation() }
                    } else {
                        HStack(spacing: 8) {
                            UDButton(title: "拷贝链接", style: .secondary) {
                                guard let invitation = server.pairingInvitation else { return }
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(invitation.url.absoluteString, forType: .string)
                            }
                            UDButton(title: "收起", style: .secondary) { server.cancelPairingInvitation() }
                        }
                    }
                }
                if let invitation = server.pairingInvitation {
                    SettingsCenteredBlock(caption: RemoteControlPresentation.invitationCaption(relayName: invitation.relay?.name)) {
                        PairingQRCode(text: invitation.url.absoluteString)
                    }
                    .settingsDivider(inset: nil)
                }
            }
            if server.trustedPeers.isEmpty {
                SettingsEmptyRow(symbol: "iphone.slash", text: String(localized: "还没有配对的设备"))
            } else {
                ForEach(server.trustedPeers) { peer in
                    let online = server.connectedPeerIDs.contains(peer.id)
                    SettingsListRow(icon: settingsDeviceSymbol(for: peer),
                                    tint: online ? UD.success : UD.accent,
                                    title: peer.displayName,
                                    subtitle: subtitle(for: peer, online: online)) {
                        SettingsMoreMenu(items: [
                            UDMenuItem(label: String(localized: "重命名…"), systemImage: "pencil") {
                                renameText = peer.displayName
                                renaming = peer
                            },
                            UDMenuItem(label: String(localized: "撤销配对…"), systemImage: "xmark.circle", danger: true) {
                                server.revoke(peer.id)
                            },
                        ], help: String(localized: "撤销后这台设备要重新配对才能连接"))
                    }
                }
            }
        }
        .alert("重命名设备", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(renaming?.name ?? "", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let peer = renaming { try? server.rename(peer.id, to: renameText) }
                renaming = nil
            }
        } message: {
            Text("只改这台 Mac 上显示的名称；留空则恢复为设备上报的名称。")
        }
    }

    /// 手机只在真的用着（远控面板 / 终端 / 桌面）时才和 Mac 保持连接，没连接不等于「离线」，
    /// 所以只在有连接时标「已连接」，平时只显示配对日期。
    /// 照系统「设置 › Apple 账户」的设备列表：标题是名字，副标题先写机型（与标题相同则省掉），几台同款也分得开。
    private func subtitle(for peer: RemotePeer, online: Bool) -> String {
        let paired = peer.pairedAt.formatted(date: .abbreviated, time: .omitted)
        var parts = [peer.modelDetail, String(localized: "配对于 \(paired)")].compactMap(\.self)
        if online { parts.append(String(localized: "已连接")) }
        return parts.joined(separator: " · ")
    }
}
