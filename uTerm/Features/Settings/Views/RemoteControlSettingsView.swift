import AppKit
import SwiftUI
import UDesignKit

/// 设置 · 远程控制：总开关与监听状态、本机终端、远程桌面（开关 + 两项系统授权）、已配对的设备（可撤销）。
/// 从「高级」里拆出来单独成页：项多、而且都是要用户明确打开的权限。
struct RemoteControlSettingsView: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server
    @State private var permissions = RemoteDesktopPermissionState()
    @Environment(\.openWindow) private var openWindow
    private let shell = LocalShellService.shared

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "远程控制") {
                SettingsRow(label: "允许手机远程控制",
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
            }
            if settings.isEnabled {
                localShellGroup
                desktopGroup
            }
            pairedDevicesGroup
        }
    }

    // MARK: - 本机终端

    private var localShellGroup: some View {
        SettingsGroup(title: "本机终端") {
            SettingsRow(label: "允许打开本机终端",
                        hint: "打开后，配对过的设备可以在这台 Mac 上新开一个终端（你的登录 shell），这台 Mac 上也会弹出对应的窗口，断开后留着可以接着用。") {
                UDToggle(Binding(get: { settings.isLocalShellEnabled }, set: { settings.isLocalShellEnabled = $0 }))
            }
            if settings.isLocalShellEnabled {
                SettingsRow(label: "辅助程序", hint: helperHint) {
                    HStack(spacing: 8) {
                        helperStatus
                        UDButton(title: "检查", style: .secondary) { Task { await shell.checkHelper() } }
                    }
                }
                .task { if shell.helperState == .unknown { await shell.checkHelper() } }
            }
        }
    }

    @ViewBuilder private var helperStatus: some View {
        switch shell.helperState {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(UD.success)
                Text("正常").font(.system(size: 12.5)).foregroundStyle(UD.text)
            }
        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UD.danger)
                Text("连不上").font(.system(size: 12.5)).foregroundStyle(UD.text)
            }
        }
    }

    private var helperHint: String {
        switch shell.helperState {
        case .failed(let reason): return reason
        default: return "本机终端由 uTerm 内置的辅助程序启动（不受 App 沙盒限制，才能读写你的主目录），用到时自动运行，不需要额外授权。"
        }
    }

    // MARK: - 远程桌面

    private var desktopGroup: some View {
        SettingsGroup(title: "远程桌面") {
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
                    SettingsRow(label: "不清楚怎么开？", hint: "授权引导里逐项说明每个权限的用途和打开方法。") {
                        UDButton(title: "打开授权引导", style: .secondary) {
                            openWindow(id: PermissionGuideWindow.id)
                        }
                    }
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

    // MARK: - 已配对的设备

    private var pairedDevicesGroup: some View {
        SettingsGroup(title: "已配对的设备") {
            if server.trustedPeers.isEmpty {
                SettingsRow(label: "还没有", hint: "在手机上打开 uTerm，主机页的「我的 Mac」里选这台 Mac 即可发起配对。") {
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

    // MARK: - 状态

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
