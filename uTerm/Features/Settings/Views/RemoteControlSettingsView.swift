import SwiftUI
import UDesignKit

/// 设置 · 远程控制：总开关与监听状态、本机终端、远程桌面（开关 + 两项系统授权）、公网接入、
/// 已配对的设备（可撤销）。从「高级」里拆出来单独成页：项多、而且都是要用户明确打开的权限。
/// 各组在同目录的 `Remote*Group.swift` 里；状态文案与图标在共享的 `RemoteControlPresentation`。
struct RemoteControlSettingsView: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "远程控制") {
                SettingsRow(label: "允许手机远程控制",
                            hint: "打开后，同一局域网里配对过的 iPhone / iPad 可以接入这台 Mac 上已打开的终端，接入期间终端按手机的尺寸运行。登录同一 Apple ID（并打开 iCloud 钥匙串）的设备自动配对，其他设备扫码配对。") {
                    UDToggle(Binding(get: { settings.isEnabled }, set: { settings.isEnabled = $0 }))
                }
                if settings.isEnabled {
                    SettingsRow(label: "状态",
                                hint: RemoteControlPresentation.connectedHint(server.connectedDevices)) {
                        let status = RemoteControlPresentation.serverStatus(
                            server.status, hasConnectedDevices: !server.connectedDevices.isEmpty)
                        HStack(spacing: 6) {
                            Image(systemName: status.symbol)
                                .foregroundStyle(status.tone.color)
                            Text(server.status.label)
                                .font(.system(size: 12.5))
                                .foregroundStyle(UD.text)
                        }
                    }
                }
            }
            if settings.isEnabled {
                RemoteLocalShellGroup()
                RemoteDesktopGroup()
                RemoteInternetGroup()
            }
            RemotePairedDevicesGroup()
        }
    }
}
