import SwiftUI
import UDesignKit

/// 设置 · 高级 · 远程控制：开关、监听状态、本机终端（开关 + 后台辅助程序状态）、远程桌面（开关 + 两项系统授权）、
/// 已信任的设备（可撤销）。
struct RemoteControlSettingsGroup: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server
    @State private var permissions = RemoteDesktopPermissionState()

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
            if settings.isEnabled {
                localShellRows
                desktopRows
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

    // MARK: - 本机终端

    @ViewBuilder private var localShellRows: some View {
        let shell = LocalShellService.shared
        SettingsRow(label: "允许打开本机终端",
                    hint: "打开后，配对过的设备可以在这台 Mac 上新开一个终端（你的登录 shell），这台 Mac 上也会弹出对应的窗口。终端由 uTerm 的后台辅助程序启动，第一次打开时 macOS 会提示「已添加后台项目」。") {
            UDToggle(Binding(get: { settings.isLocalShellEnabled }, set: { settings.isLocalShellEnabled = $0 }))
        }
        if settings.isLocalShellEnabled {
            SettingsRow(label: "后台辅助程序", hint: shell.lastError ?? localShellHint(shell.status)) {
                switch shell.status {
                case .enabled:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(UD.success)
                        Text("已启用").font(.system(size: 12.5)).foregroundStyle(UD.text)
                    }
                case .requiresApproval:
                    UDButton(title: "打开登录项设置", style: .primary) { shell.openLoginItemsSettings() }
                case .notRegistered, .notFound:
                    UDButton(title: "重新注册", style: .secondary) { shell.register() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                shell.refresh()
            }
        }
    }

    private func localShellHint(_ status: LocalShellService.Status) -> String? {
        switch status {
        case .enabled: return nil
        case .requiresApproval: return "需要在 系统设置 › 通用 › 登录项与扩展 里打开 uTerm 的后台项目"
        case .notFound: return "这份 uTerm 里缺少辅助程序，请重新安装"
        case .notRegistered: return "还没注册"
        }
    }

    // MARK: - 远程桌面

    @ViewBuilder private var desktopRows: some View {
        SettingsRow(label: "允许远程桌面",
                    hint: "打开后，配对过的设备可以查看这台 Mac 的屏幕；有「辅助功能」授权时还能操作鼠标和键盘。有设备在看时，屏幕顶部会一直显示提示，可随时断开。") {
            UDToggle(Binding(get: { settings.isDesktopEnabled }, set: { settings.isDesktopEnabled = $0 }))
        }
        if settings.isDesktopEnabled {
            SettingsRow(label: "屏幕录制", hint: "看屏幕必需。macOS 会定期请你重新确认。") {
                permissionControl(granted: permissions.screenCapture,
                                  request: permissions.requestScreenCapture,
                                  openSettings: RemoteDesktopPermissions.openScreenCaptureSettings)
            }
            SettingsRow(label: "控制鼠标和键盘（辅助功能）", hint: "没有这项授权时，手机只能查看，不能操作。") {
                permissionControl(granted: permissions.postEvents,
                                  request: permissions.requestPostEvents,
                                  openSettings: RemoteDesktopPermissions.openAccessibilitySettings)
            }
            if !permissions.screenCapture || !permissions.postEvents {
                SettingsRow(label: "授权后需重启 uTerm",
                            hint: "在系统设置里打开开关后，macOS 要等 uTerm 重新启动才让授权生效。") {
                    UDButton(title: "重新启动", style: permissions.requestedThisRun ? .primary : .secondary) {
                        RemoteDesktopPermissions.relaunch()
                    }
                }
            }
            if let viewer = server.desktopViewer {
                SettingsRow(label: viewer.isControlling ? "\(viewer.deviceName) 正在控制" : "\(viewer.deviceName) 正在查看",
                            hint: viewer.canControl ? nil : "只能查看（没有辅助功能授权）") {
                    UDButton(title: "断开", style: .danger) {
                        server.endDesktop(reason: "已在 Mac 上断开")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func permissionControl(granted: Bool, request: @escaping () -> Void,
                                   openSettings: @escaping () -> Void) -> some View {
        if granted {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(UD.success)
                Text("已授权").font(.system(size: 12.5)).foregroundStyle(UD.text)
            }
        } else {
            HStack(spacing: 8) {
                UDButton(title: "打开系统设置", style: .secondary, action: openSettings)
                UDButton(title: "授权", style: .primary, action: request)
            }
            // 从系统设置切回来时刷新一次（在本进程里通常仍是未授权，要重启才生效，见 RemoteDesktopPermissions）。
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                permissions.refresh()
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
