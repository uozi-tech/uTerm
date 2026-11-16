import SwiftUI
import UDesignKit

/// 设置 · 远程控制：总开关与监听状态、能力（本机终端 / 远程桌面及其授权）、公网接入与放行的设备、
/// 已配对的设备（可撤销）。从「高级」里拆出来单独成页：项多、而且都是要用户明确打开的权限。
/// 各组在同目录的 `Remote*Group.swift` 里；状态文案与图标在 `RemoteControlPresentation`。
struct RemoteControlSettingsView: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: "远程控制", subtitle: String(localized: "让 iPhone、iPad 接入这台 Mac"))

            SettingsGroup(title: "远程控制",
                          footer: String(localized: "打开后，同一局域网里配对过的设备可以接入这台 Mac 上已打开的终端，接入期间终端按对方的尺寸运行。每台设备第一次连接都要配对，同一 Apple ID 本身不算数：在这台 Mac 上核对 6 位数字后点「允许」、扫二维码，或由同一个人已配对的设备替它开通。")) {
                SettingsRow(label: "允许手机远程控制") {
                    UDToggle(Binding(get: { settings.isEnabled }, set: { settings.isEnabled = $0 }))
                }
                if settings.isEnabled {
                    SettingsRow(label: "状态",
                                hint: RemoteControlPresentation.connectedHint(server.connectedDevices)) {
                        let status = RemoteControlPresentation.serverStatus(
                            server.status, hasConnectedDevices: !server.connectedDevices.isEmpty)
                        SettingsStatusLabel(symbol: status.symbol, tone: status.tone, text: server.status.label)
                    }
                }
            }
            if settings.isEnabled {
                RemoteCapabilitiesGroup()
                RemoteInternetGroup()
            }
            RemotePairedDevicesGroup()
            RemoteMyDevicesGroup()
        }
    }
}
