import AppKit
import SwiftUI
import UDesignKit

/// 设置 › 远程控制 › 远程桌面：开关、屏幕录制与辅助功能两项系统授权、当前观看者。
struct RemoteDesktopGroup: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server
    @Environment(\.openWindow) private var openWindow
    @State private var permissions = RemoteDesktopPermissionState()

    var body: some View {
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
                if permissions.isLoaded, !permissions.screenCapture || !permissions.postEvents {
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
        // 授权查询要等 tccd，只在这一处、在后台查（见 RemoteDesktopPermissionState）。
        .task(id: settings.isDesktopEnabled) {
            if settings.isDesktopEnabled { await permissions.refresh() }
        }
        // 从系统设置切回来时刷新一次（在本进程里通常仍是未授权，要重启才生效，见 RemoteDesktopPermissions）。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard settings.isDesktopEnabled else { return }
            Task { await permissions.refresh() }
        }
    }

    @ViewBuilder
    private func permissionControl(granted: Bool, request: @escaping () -> Void,
                                   openSettings: @escaping () -> Void) -> some View {
        if !permissions.isLoaded {
            EmptyView()
        } else if granted {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(UD.success)
                Text("已授权").font(.system(size: 12.5)).foregroundStyle(UD.text)
            }
        } else {
            HStack(spacing: 8) {
                UDButton(title: "打开系统设置", style: .secondary, action: openSettings)
                UDButton(title: "授权", style: .primary, action: request)
            }
        }
    }
}
