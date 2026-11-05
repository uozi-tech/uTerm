import AppKit
import CoreImage.CIFilterBuiltins
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
                            hint: "打开后，同一局域网里配对过的 iPhone / iPad 可以接入这台 Mac 上已打开的终端，接入期间终端按手机的尺寸运行。登录同一 Apple ID（并打开 iCloud 钥匙串）的设备自动配对，其他设备扫码配对。") {
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

    // MARK: - 已配对的设备

    private var pairedDevicesGroup: some View {
        SettingsGroup(title: "已配对的设备") {
            if settings.isEnabled {
                SettingsRow(label: "扫码配对",
                            hint: server.pairingInvitation == nil
                                ? "不同 Apple ID 的 iPhone / iPad 用这个配对：在手机 uTerm 主机页「我的 Mac › 扫码配对」扫二维码。"
                                : "二维码 10 分钟内有效，只能用一次。") {
                    if server.pairingInvitation == nil {
                        UDButton(title: "显示二维码", style: .secondary) { _ = try? server.makePairingInvitation() }
                    } else {
                        UDButton(title: "收起", style: .secondary) { server.cancelPairingInvitation() }
                    }
                }
                if let invitation = server.pairingInvitation {
                    PairingQRCode(text: invitation.url.absoluteString)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            if server.trustedPeers.isEmpty {
                SettingsRow(label: "还没有", hint: "同一 Apple ID 的手机打开 uTerm 主机页「我的 Mac」就会自动配对；其他手机扫上面的二维码。") {
                    EmptyView()
                }
            } else {
                ForEach(server.trustedPeers) { peer in
                    SettingsRow(label: peer.name,
                                hint: "配对于 \(peer.pairedAt.formatted(date: .abbreviated, time: .shortened))") {
                        UDButton(title: "撤销", style: .secondary) {
                            server.revoke(peer.id)
                        }
                        .help("撤销后这台设备要重新扫码才能连接，同一 Apple ID 也不会再自动配对")
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

/// 扫码配对的二维码：深色模块落在白底上（扫码要求），四周留出静区。
private struct PairingQRCode: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 196, height: 196)
                .padding(14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("扫码配对的二维码")
        }
    }

    private static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
