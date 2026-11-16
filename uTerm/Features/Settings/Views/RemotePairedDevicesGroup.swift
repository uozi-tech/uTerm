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
                      footer: String(localized: "配对过的设备才能连接这台 Mac：在这里扫码或审批，或者打开上面的开关，由同一个人已配对的设备替它开通。同一 Apple ID 本身不算数。撤销后这台设备要重新配对。")) {
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
            SettingsRow(label: String(localized: "允许已配对的设备开通主人的其它设备"),
                        hint: String(localized: "比如配对过的 iPhone 可以替同一个人的 iPad 开通，不用再到这台 Mac 上配对。新设备只能拿到 iPhone 已有的权限，每次开通都会通知你。")) {
                UDToggle(Binding(get: { settings.isDeviceVouchingEnabled }, set: { settings.isDeviceVouchingEnabled = $0 }))
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
                        SettingsMoreMenu(items: menuItems(for: peer), help: String(localized: "撤销后这台设备要重新配对才能连接"))
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

    private func menuItems(for peer: RemotePeer) -> [UDMenuItem] {
        var items = [
            UDMenuItem(label: String(localized: "重命名…"), systemImage: "pencil") {
                renameText = peer.displayName
                renaming = peer
            },
            UDMenuItem(label: String(localized: "撤销配对…"), systemImage: "xmark.circle", danger: true) {
                server.revoke(peer.id)
            },
        ]
        // 同一个人的几台设备（经担保添加的）可以一起撤掉。
        let family = server.familyMembers(of: peer.id)
        if family.count > 1 {
            items.append(UDMenuItem(label: String(localized: "撤销同一组的 \(family.count) 台设备…"),
                                    systemImage: "xmark.circle.fill", danger: true) {
                server.revokeFamily(of: peer.id)
            })
        }
        return items
    }

    /// 手机只在真的用着（远控面板 / 终端 / 桌面）时才和 Mac 保持连接，没连接不等于「离线」，
    /// 所以只在有连接时标「已连接」，平时只显示配对日期。
    /// 照系统「设置 › Apple 账户」的设备列表：标题是名字，副标题先写机型（与标题相同则省掉），几台同款也分得开。
    private func subtitle(for peer: RemotePeer, online: Bool) -> String {
        let paired = peer.pairedAt.formatted(date: .abbreviated, time: .omitted)
        var parts = [peer.modelDetail, String(localized: "配对于 \(paired)")].compactMap(\.self)
        if let vouch = server.peerVouches[peer.id] {
            if vouch.isFromDeviceGroup(hostID: server.localID) {
                parts.append(String(localized: "由设备组添加"))
            } else {
                let voucher = server.trustedPeers.first { $0.id == vouch.vouchedBy }?.displayName ?? vouch.voucherName
                parts.append(String(localized: "由「\(voucher)」添加"))
            }
        }
        if online { parts.append(String(localized: "已连接")) }
        return parts.joined(separator: " · ")
    }
}
