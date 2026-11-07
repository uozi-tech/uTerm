import AppKit
import SwiftData
import SwiftUI
import UDesignKit
import UniformTypeIdentifiers

/// 设置 › 远程控制 › 公网接入：导入自建中继的配置、允许经公网接入、按设备放行、保持唤醒。
struct RemoteInternetGroup: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server
    @Environment(TerminalSessionRegistry.self) private var registry
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServerProfile.name) private var profiles: [ServerProfile]
    @State private var importingRelayConfig = false
    @State private var showsRelayCode = false
    @State private var showsAgentPrompt = false
    @State private var choosingManagedHost = false
    @State private var confirmingUpdate = false
    @State private var relayImportError: String?
    @State private var manager = RemoteRelayManager()
    /// 设置页之外（命令行）换了 / 导入了中继时也要刷新「装在哪台主机」。
    @State private var managedHostID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(title: "公网接入",
                          footer: String(localized: "打开后，这台 Mac 会注册到中继，允许的设备不在同一局域网也能连接。优先直连，打不通时经中继转发，内容都是端到端加密。Mac 睡眠时会从中继掉线，手机无法远程唤醒它；「保持唤醒」不让 Mac 闲置睡眠，合盖仍会睡眠。同一 Apple ID 的手机经 iCloud 钥匙串自动拿到中继配置，其他手机扫二维码或用「分享到我的设备」。")) {
                relayRow
                if server.relayConfig == nil, showsAgentPrompt {
                    RemoteRelayAgentPromptBlock(purpose: .deploy)
                        .settingsDivider(inset: nil)
                }
                if showsRelayCode, let url = server.relayConfig?.url {
                    SettingsCenteredBlock(caption: String(localized: "这份配置含成员密钥，二维码只给自己的设备扫。")) {
                        PairingQRCode(text: url.absoluteString)
                    }
                    .settingsDivider(inset: nil)
                }
                if let config = server.relayConfig {
                    relayManagementRows(config)
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
        .onAppear {
            refreshInternetAccess()
            reloadManagedHost()
            server.relayUpdates.refreshIfStale()
        }
        .onChange(of: server.relayConfig?.relayID) { _, _ in reloadManagedHost() }
        .alert("更新中继？", isPresented: $confirmingUpdate) {
            Button("更新") { startUpdate() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会在「\(managedHost?.name ?? "")」上下载新版本并重启中继。正在经中继的连接会断开几秒，之后自动重连。")
        }
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

    /// 中继：没配置时「导入配置」+「让 AI 部署」；配置后显示版本，其余动作收进更多菜单。
    @ViewBuilder private var relayRow: some View {
        if let config = server.relayConfig {
            SettingsListRow(icon: "server.rack", tint: UD.info,
                            title: String(localized: "中继服务器"),
                            subtitle: RemoteControlPresentation.relaySubtitle(config, version: server.relayUpdates.runningVersion)) {
                SettingsMoreMenu(items: [
                    UDMenuItem(label: String(localized: "测试连接"), systemImage: "stethoscope") {
                        Task { await manager.check(config, updates: server.relayUpdates) }
                    },
                    UDMenuItem(label: showsRelayCode ? String(localized: "收起二维码") : String(localized: "显示二维码"),
                               systemImage: "qrcode") { showsRelayCode.toggle() },
                    UDMenuItem(label: String(localized: "分享到我的设备…"), systemImage: "square.and.arrow.up") {
                        shareRelayLink(config)
                    },
                    UDMenuItem(label: String(localized: "导出配置文件…"), systemImage: "doc.badge.arrow.up") {
                        exportRelayConfig(config)
                    },
                    UDMenuItem(label: String(localized: "指定所在主机…"), systemImage: "link") {
                        choosingManagedHost.toggle()
                    },
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
                HStack(spacing: 8) {
                    UDButton(title: showsAgentPrompt ? "收起" : "让 AI 部署…", style: .secondary) {
                        showsAgentPrompt.toggle()
                    }
                    UDButton(title: "导入配置", style: .primary) { importingRelayConfig = true }
                }
            }
        }
    }

    /// 已配中继时：所在主机、版本与更新、测试结果。
    @ViewBuilder private func relayManagementRows(_ config: RemoteRelayConfig) -> some View {
        if choosingManagedHost {
            SettingsRow(label: "所在主机", hint: "中继装在哪台已保存的主机上。uTerm 用它来更新中继") {
                SettingsPicker(selection: Binding(get: { managedHostID }, set: { id in
                                   server.relayManagedHosts.set(id, for: config.relayID)
                                   managedHostID = id
                               }),
                               options: [(UUID?.none, String(localized: "不指定"))]
                                   + profiles.filter { !$0.sftpOnly }.map { (Optional($0.id), $0.name) },
                               menuWidth: 240)
            }
        }
        let updates = server.relayUpdates
        if updates.updateAvailable, let latest = updates.latestVersion {
            SettingsRow(label: String(localized: "有新版本 \(latest)"),
                        hint: RemoteControlPresentation.relayUpdateHint(running: updates.runningVersion, host: managedHost?.name)) {
                if managedHost != nil {
                    UDButton(title: "更新", style: .primary, isLoading: manager.updatePhase == .running) {
                        confirmingUpdate = true
                    }
                } else {
                    UDButton(title: showsAgentPrompt ? "收起" : "让 AI 更新…", style: .secondary) {
                        showsAgentPrompt.toggle()
                    }
                }
            }
            if managedHost == nil, showsAgentPrompt {
                RemoteRelayAgentPromptBlock(purpose: .update)
                    .settingsDivider(inset: nil)
            }
        }
        if let note = RemoteControlPresentation.relayUpdateNote(manager.updatePhase) {
            SettingsInlineNote(tone: note.tone, text: note.text)
        }
        if manager.isChecking {
            SettingsInlineNote(tone: .muted, text: String(localized: "正在测试连接…"))
        } else if let check = manager.lastCheck {
            ForEach(RemoteControlPresentation.relayCheckNotes(check), id: \.text) { note in
                SettingsInlineNote(tone: note.tone, text: note.text)
            }
        }
    }

    private var managedHost: ServerProfile? {
        managedHostID.flatMap { id in profiles.first { $0.id == id } }
    }

    private func reloadManagedHost() {
        managedHostID = server.relayConfig.flatMap { server.relayManagedHosts.host(for: $0.relayID) }
    }

    private func startUpdate() {
        guard let config = server.relayConfig, let host = managedHost else { return }
        Task {
            await manager.update(config, on: host, container: modelContext.container, registry: registry,
                                 updates: server.relayUpdates)
        }
    }

    /// AirDrop / 信息 / 隔空投送给自己的设备。链接含成员密钥，手机上的 uTerm 打开它会先确认再导入。
    private func shareRelayLink(_ config: RemoteRelayConfig) {
        guard let url = config.url, let window = NSApp.keyWindow, let view = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        let anchor = NSRect(x: view.bounds.maxX - 60, y: view.bounds.maxY - 120, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    private static let configEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private func exportRelayConfig(_ config: RemoteRelayConfig) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "uterm-relay.json"
        panel.allowedContentTypes = [.json]
        panel.message = String(localized: "这份文件含成员密钥，只发给自己的设备。")
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Self.configEncoder.encode(config) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            relayImportError = error.localizedDescription
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
