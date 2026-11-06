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
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "公网接入",
                          footer: String(localized: "打开后，这台 Mac 会注册到中继，允许的设备不在同一局域网也能连接。优先直连，打不通时经中继转发，内容都是端到端加密。Mac 睡眠时会从中继掉线，手机无法远程唤醒它；「保持唤醒」不让 Mac 闲置睡眠，合盖仍会睡眠。")) {
                relayRow
                if showsRelayCode, let url = server.relayConfig?.url {
                    SettingsCenteredBlock(caption: String(localized: "这份配置含成员密钥，二维码只给自己的设备扫。")) {
                        PairingQRCode(text: url.absoluteString)
                    }
                    .settingsDivider(inset: nil)
                }
                if server.relayConfig != nil {
                    SettingsRow(label: "允许经公网接入", hint: "不在同一局域网的设备也能连接") {
                        UDToggle(Binding(get: { settings.isInternetEnabled }, set: { settings.isInternetEnabled = $0 }))
                    }
                }
                if server.relayConfig != nil, settings.isInternetEnabled {
                    let relayState = server.relayLink?.state
                    SettingsRow(label: "中继状态", hint: RemoteControlPresentation.relayStatusHint(relayState)) {
                        let status = RemoteControlPresentation.relayStatus(relayState)
                        SettingsStatusLabel(symbol: status.symbol, tone: status.tone,
                                            text: RemoteControlPresentation.relayStatusLabel(relayState))
                    }
                    SettingsRow(label: "保持唤醒", hint: "公网接入期间不让 Mac 闲置睡眠") {
                        UDToggle(Binding(get: { settings.keepsAwakeForInternet }, set: { settings.keepsAwakeForInternet = $0 }))
                    }
                }
            }

            if server.relayConfig != nil, settings.isInternetEnabled {
                SettingsGroup(title: "允许经公网连接的设备",
                              footer: String(localized: "配对过、或在同一 Apple ID 名册里的设备不会自动获得公网权限，要在这里逐台打开。")) {
                    if server.internetAccessCandidates.isEmpty {
                        SettingsEmptyRow(symbol: "iphone.slash", text: String(localized: "还没有可以放行的设备"))
                    }
                    ForEach(server.internetAccessCandidates) { peer in
                        let allowed = settings.internetDevices.contains(peer.id)
                        SettingsListRow(icon: settingsDeviceSymbol(for: peer.name),
                                        tint: allowed ? UD.accent : UD.text3,
                                        title: peer.name,
                                        subtitle: allowed ? String(localized: "可经公网连接") : String(localized: "仅限局域网")) {
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

    /// 中继：没配置时一个「导入配置」主按钮；配置后只留一个更多菜单（二维码 / 更换 / 移除）。
    @ViewBuilder private var relayRow: some View {
        if let config = server.relayConfig {
            SettingsListRow(icon: "server.rack", tint: UD.info,
                            title: String(localized: "中继服务器"),
                            subtitle: "\(config.name) · \(config.endpointDescription)") {
                SettingsMoreMenu(items: [
                    UDMenuItem(label: showsRelayCode ? String(localized: "收起二维码") : String(localized: "显示二维码"),
                               systemImage: "qrcode") { showsRelayCode.toggle() },
                    UDMenuItem(label: String(localized: "更换配置…"), systemImage: "arrow.triangle.2.circlepath") {
                        importingRelayConfig = true
                    },
                    .divider(),
                    UDMenuItem(label: String(localized: "移除中继"), systemImage: "trash", danger: true) {
                        settings.isInternetEnabled = false
                        server.clearRelayConfig()
                        showsRelayCode = false
                        refreshInternetAccess()
                    },
                ])
            }
        } else {
            SettingsListRow(icon: "server.rack", tint: UD.text3,
                            title: String(localized: "中继服务器"),
                            subtitle: RemoteControlPresentation.relayHint(nil)) {
                UDButton(title: "导入配置", style: .primary) { importingRelayConfig = true }
            }
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
