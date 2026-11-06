import SwiftUI
import UDesignKit
import UniformTypeIdentifiers

/// 设置 › 远程控制 › 公网接入：导入自建中继的配置、允许经公网接入、按设备放行、保持唤醒。
struct RemoteInternetGroup: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server
    @State private var importingRelayConfig = false
    @State private var showsRelayCode = false
    @State private var relayImportError: String?

    var body: some View {
        SettingsGroup(title: "公网接入") {
            SettingsRow(label: "中继服务器", hint: RemoteControlPresentation.relayHint(server.relayConfig)) {
                HStack(spacing: 8) {
                    if server.relayConfig != nil {
                        UDButton(title: showsRelayCode ? "收起" : "二维码", style: .secondary) { showsRelayCode.toggle() }
                        UDButton(title: "移除", style: .secondary) {
                            settings.isInternetEnabled = false
                            server.clearRelayConfig()
                            showsRelayCode = false
                            refreshInternetAccess()
                        }
                    }
                    UDButton(title: server.relayConfig == nil ? "导入配置" : "更换", style: .secondary) {
                        importingRelayConfig = true
                    }
                }
            }
            if showsRelayCode, let url = server.relayConfig?.url {
                PairingQRCode(text: url.absoluteString)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            if server.relayConfig != nil {
                SettingsRow(label: "允许经公网接入",
                            hint: "打开后，这台 Mac 会注册到上面的中继，勾选的设备不在同一局域网也能连接。优先直连，打不通时经中继转发，内容都是端到端加密。") {
                    UDToggle(Binding(get: { settings.isInternetEnabled }, set: { settings.isInternetEnabled = $0 }))
                }
            }
            if server.relayConfig != nil, settings.isInternetEnabled {
                let relayState = server.relayLink?.state
                SettingsRow(label: "状态", hint: RemoteControlPresentation.relayStatusHint(relayState)) {
                    let status = RemoteControlPresentation.relayStatus(relayState)
                    HStack(spacing: 6) {
                        Image(systemName: status.symbol).foregroundStyle(status.tone.color)
                        Text(RemoteControlPresentation.relayStatusLabel(relayState))
                            .font(.system(size: 12.5)).foregroundStyle(UD.text)
                    }
                }
                ForEach(server.internetAccessCandidates) { peer in
                    SettingsRow(label: peer.name, hint: "允许这台设备经公网连接") {
                        UDToggle(Binding(
                            get: { settings.internetDevices.contains(peer.id) },
                            set: { allowed in
                                if allowed {
                                    settings.internetDevices.insert(peer.id)
                                } else {
                                    settings.internetDevices.remove(peer.id)
                                }
                            }))
                    }
                }
                SettingsRow(label: "保持唤醒",
                            hint: "Mac 睡眠时会从中继掉线，手机无法远程唤醒它。打开后不让 Mac 闲置睡眠；合盖仍会睡眠。") {
                    UDToggle(Binding(get: { settings.keepsAwakeForInternet }, set: { settings.keepsAwakeForInternet = $0 }))
                }
            }
        }
        .onAppear { refreshInternetAccess() }
        .fileImporter(isPresented: $importingRelayConfig, allowedContentTypes: [.json]) { result in
            importRelayConfig(result)
        }
        .alert("没能导入中继配置", isPresented: Binding(get: { relayImportError != nil },
                                                       set: { if !$0 { relayImportError = nil } })) {
            Button("好", role: .cancel) { relayImportError = nil }
        } message: {
            Text(relayImportError ?? "")
        }
    }

    private func refreshInternetAccess() {
        server.updateInternetAccess(enabled: settings.isEnabled && settings.isInternetEnabled,
                                    keepAwake: settings.keepsAwakeForInternet)
    }

    private func importRelayConfig(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let config = RemoteRelayConfig(importing: try Data(contentsOf: url)) else {
                relayImportError = "这不是 uterm-relay 的配置文件。请在服务器上运行 uterm-relay config 生成。"
                return
            }
            guard server.importRelayConfig(config) else {
                relayImportError = "保存到钥匙串失败。"
                return
            }
            refreshInternetAccess()
        } catch {
            relayImportError = error.localizedDescription
        }
    }
}
