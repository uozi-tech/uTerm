import SwiftUI
import UDesignKit

/// 设置 · 高级 · 远程控制：开关、监听状态、已信任的设备（可撤销）。
struct RemoteControlSettingsGroup: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server

    var body: some View {
        SettingsGroup(title: "远程控制") {
            SettingsRow(label: "允许手机远程控制终端",
                        hint: "打开后，同一局域网里配对过的 iPhone / iPad 可以接入这台 Mac 上已打开的终端，接入期间终端按手机的尺寸运行。第一次连接要在这台 Mac 上核对并允许。") {
                UDToggle(Binding(get: { settings.isEnabled }, set: { settings.isEnabled = $0 }))
            }
            if settings.isEnabled {
                SettingsRow(label: "状态", hint: connectedHint) {
                    HStack(spacing: 6) {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusTint)
                        Text(server.status.label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(UD.text)
                    }
                }
            }
            if server.trustedPeers.isEmpty {
                SettingsRow(label: "已配对的设备", hint: "还没有。在手机上打开 uTerm，主机页的「我的 Mac」里选这台 Mac 即可发起配对。") {
                    EmptyView()
                }
            } else {
                ForEach(server.trustedPeers) { peer in
                    SettingsRow(label: peer.name,
                                hint: "配对于 \(peer.pairedAt.formatted(date: .abbreviated, time: .shortened))") {
                        UDButton(title: "撤销", style: .secondary) {
                            server.revoke(peer.id)
                        }
                    }
                }
            }
        }
    }

    private var connectedHint: String? {
        server.connectedDevices.isEmpty ? nil : "已连接：\(server.connectedDevices.joined(separator: "、"))"
    }

    private var statusIcon: String {
        switch server.status {
        case .listening: return server.connectedDevices.isEmpty ? "dot.radiowaves.left.and.right" : "iphone.radiowaves.left.and.right"
        case .stopped: return "pause.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch server.status {
        case .listening: return UD.accent
        case .stopped: return UD.text2
        case .failed: return UD.danger
        }
    }
}
