import AppKit
import SwiftUI
import UDesignKit

/// 设置 › 远程控制 › 能力：允许打开本机终端（及辅助程序检查）、允许远程桌面（及屏幕录制 / 辅助功能
/// 两项系统授权、当前观看者）。两个开关各带缩进一级的子项，放在同一张卡片里。
struct RemoteCapabilitiesGroup: View {
    @Environment(RemoteControlSettings.self) private var settings
    @Environment(RemoteHostServer.self) private var server
    @Environment(\.openWindow) private var openWindow
    @State private var permissions = RemoteDesktopPermissionState()
    private let shell = LocalShellService.shared

    var body: some View {
        SettingsGroup(title: "能力",
                      footer: String(localized: "本机终端由 uTerm 内置的辅助程序启动（不受 App 沙盒限制，才能读写你的主目录），这台 Mac 上会同时打开对应的窗口，手机断开后窗口保留，可以继续使用。有设备查看屏幕时，屏幕顶部会持续显示提示，可随时断开。")) {
            SettingsRow(label: "允许打开本机终端",
                        hint: "配对过的设备可以在这台 Mac 上新开一个终端（你的登录 shell）") {
                UDToggle(Binding(get: { settings.isLocalShellEnabled }, set: { settings.isLocalShellEnabled = $0 }))
            }
            if settings.isLocalShellEnabled {
                // 正常时只显示状态；连不上才给「重试」（正常还放个「检查」按钮像是要用户做什么）。
                SettingsRow(label: "辅助程序", hint: helperHint) {
                    HStack(spacing: 10) {
                        helperStatus
                        if case .failed = shell.helperState {
                            UDButton(title: "重试", style: .secondary) { Task { await shell.checkHelper() } }
                        }
                    }
                }
                .settingsNested()
            }

            SettingsRow(label: "允许远程桌面",
                        hint: "查看这台 Mac 的屏幕；有「辅助功能」授权时还能操作鼠标和键盘") {
                UDToggle(Binding(get: { settings.isDesktopEnabled }, set: { settings.isDesktopEnabled = $0 }))
            }
            if settings.isDesktopEnabled {
                if permissions.isLoaded {
                    SettingsRow(label: "屏幕录制", hint: "查看屏幕必需；macOS 会定期要求重新确认") {
                        permissionControl(granted: permissions.screenCapture,
                                          request: permissions.requestScreenCapture,
                                          openSettings: RemoteDesktopPermissions.openScreenCaptureSettings)
                    }
                    .settingsNested()
                    SettingsRow(label: "辅助功能", hint: accessibilityHint) {
                        permissionControl(granted: permissions.postEvents,
                                          request: permissions.requestPostEvents,
                                          openSettings: RemoteDesktopPermissions.openAccessibilitySettings)
                    }
                    .settingsNested()
                    if !permissions.screenCapture || !permissions.postEvents {
                        SettingsRow(label: "授权后需重启 uTerm",
                                    hint: "在「系统设置」里打开开关后，要等 uTerm 重新启动才生效") {
                            UDButton(title: "重新启动", style: permissions.requestedThisRun ? .primary : .secondary) {
                                RemoteDesktopPermissions.relaunch()
                            }
                        }
                        .settingsNested()
                    }
                }
                SettingsRow(label: "允许传输声音",
                            hint: "查看屏幕时把这台 Mac 的声音传到手机，在手机上打开扬声器后才传输。沿用「屏幕录制」授权，不需要其他权限") {
                    UDToggle(Binding(get: { settings.isDesktopAudioEnabled },
                                     set: { settings.isDesktopAudioEnabled = $0 }))
                }
                .settingsNested()
                SettingsRow(label: "允许远程解锁",
                            hint: "Mac 锁屏时，配对过的设备能用登录密码解锁并进入帘幕（屏幕变黑、暂停本机键鼠和扬声器）；屏上弹出要触控 ID 或密码的验证框时，也能替它填入登录密码") {
                    UDToggle(Binding(get: { settings.isDesktopUnlockEnabled },
                                     set: { settings.isDesktopUnlockEnabled = $0 }))
                }
                .settingsNested()
                if let viewer = server.desktopViewer {
                    SettingsListRow(icon: settingsDeviceSymbol(for: viewer.deviceName), tint: UD.caution,
                                    title: viewer.deviceName,
                                    subtitle: viewerSubtitle(viewer)) {
                        UDButton(title: "断开", style: .danger) {
                            server.endDesktop(reason: "已在 Mac 上断开")
                        }
                    }
                    .settingsNested()
                }
            }
        }
        .task(id: settings.isLocalShellEnabled) {
            if settings.isLocalShellEnabled, shell.helperState == .unknown { await shell.checkHelper() }
        }
        // 授权查询要等 tccd，只在这一处、在后台查（见 RemoteDesktopPermissionState）。
        .task(id: settings.isDesktopEnabled) {
            guard settings.isDesktopEnabled else { return }
            permissions.agent = server.agent
            await permissions.refresh()
        }
        // 从系统设置切回来时刷新一次（在本进程里通常仍是未授权，要重启才生效，见 RemoteDesktopPermissions）。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard settings.isDesktopEnabled else { return }
            permissions.agent = server.agent
            Task { await permissions.refresh() }
        }
    }

    /// 远控进程在服务时，「辅助功能」要在系统设置里打开它那一项（不是 uTerm），这里点名。
    private var accessibilityHint: String {
        server.agent == nil
            ? String(localized: "控制鼠标和键盘；没有这项时手机只能查看")
            : String(localized: "控制鼠标和键盘；没有这项时手机只能查看。系统设置里要打开的是「uTerm 远程控制」")
    }

    private var helperHint: String {
        if case .failed(let reason) = shell.helperState { return reason }
        return String(localized: "用到时自动运行，不需要额外授权")
    }

    private func viewerSubtitle(_ viewer: RemoteHostServer.DesktopViewer) -> String {
        var action = viewer.isControlling ? String(localized: "正在控制") : String(localized: "正在查看")
        if viewer.hasAudio { action += String(localized: " · 含声音") }
        return viewer.canControl ? action : action + String(localized: " · 只能查看（没有「辅助功能」授权）")
    }

    @ViewBuilder private var helperStatus: some View {
        switch RemoteControlPresentation.helperDisplay(shell.helperState) {
        case .hidden:
            EmptyView()
        case .progress:
            ProgressView().controlSize(.small)
        case .badge(let symbol, let tone, let label):
            SettingsStatusLabel(symbol: symbol, tone: tone, text: label)
        }
    }

    /// 已授权：状态。未授权：状态 + 唯一的「授权」主按钮，「打开系统设置」「授权引导」收进更多菜单。
    @ViewBuilder
    private func permissionControl(granted: Bool, request: @escaping () -> Void,
                                   openSettings: @escaping () -> Void) -> some View {
        if granted {
            SettingsStatusLabel(symbol: "checkmark.circle.fill", tone: .success, text: String(localized: "已授权"))
        } else {
            HStack(spacing: 8) {
                SettingsStatusLabel(symbol: "exclamationmark.circle.fill", tone: .warning, text: String(localized: "未授权"))
                UDButton(title: "授权", style: .primary, action: request)
                SettingsMoreMenu(items: [
                    UDMenuItem(label: String(localized: "打开系统设置"), systemImage: "gearshape", action: openSettings),
                    UDMenuItem(label: String(localized: "打开授权引导"), systemImage: "questionmark.circle") {
                        openWindow(id: PermissionGuideWindow.id)
                    },
                ])
            }
        }
    }
}
