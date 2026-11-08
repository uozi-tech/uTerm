import AppKit
import SwiftUI
import UDesignKit

/// 有手机在看 / 控制这台 Mac 的屏幕时，屏幕顶部正中常驻一条指示：「×× 正在查看 / 控制这台 Mac · 断开」。
///
/// 做成独立的浮动 `NSPanel`（同 `RemotePairingPrompt` 的理由：uTerm 常以无窗口的后台模式运行）。
/// 所有桌面空间、全屏 app 之上都可见，不抢焦点；点「断开」立即结束桌面流。
/// 它本身也会被采进画面，手机上同样看得到——这正好让手机那头知道 Mac 上有提示。
@MainActor
final class RemoteDesktopIndicator {
    private let server: RemoteHostServer
    private var panel: NSPanel?
    private var shown: RemoteHostServer.DesktopViewer?

    init(server: RemoteHostServer) {
        self.server = server
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = server.desktopViewer
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.update()
                    self?.observe()
                }
            }
        }
        update()
    }

    private func update() {
        guard let viewer = server.desktopViewer else {
            close()
            return
        }
        guard viewer != shown else { return }
        show(viewer)
    }

    private func show(_ viewer: RemoteHostServer.DesktopViewer) {
        shown = viewer
        let server = self.server
        let content = RemoteDesktopIndicatorView(viewer: viewer) {
            server.endDesktop(reason: "已在 Mac 上断开")
        }
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = hosting
        panel.setContentSize(size)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            // 胶囊离菜单栏 8 点；面板上沿多出来的是阴影留白，可以伸进菜单栏那一条。
            let top = RemoteDesktopIndicatorView.shadowInsets.top
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height + top - 8))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 不用窗口阴影：系统给透明无边框窗口画阴影时会沿内容形状描一圈亮边（看起来就是描边）。
        // 阴影由 SwiftUI 自己画，见 `RemoteDesktopIndicatorView`。
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        return panel
    }

    private func close() {
        panel?.orderOut(nil)
        shown = nil
    }
}

struct RemoteDesktopIndicatorView: View {
    let viewer: RemoteHostServer.DesktopViewer
    let onDisconnect: () -> Void

    static let shadowRadius: CGFloat = 12
    static let shadowOffset: CGFloat = 4
    /// 阴影要在面板里淡完：面板按内容大小定，四周不留够，阴影会在窗口边上被截成一个矩形。
    /// 留 2.5 倍半径、再按偏移往下挪，最外一圈的不透明度才降到 1/255 以下（2 倍时还剩约 3/255，看得出来）。
    static let shadowSpread = shadowRadius * 2.5
    static let shadowInsets = EdgeInsets(top: shadowSpread - shadowOffset, leading: shadowSpread,
                                         bottom: shadowSpread + shadowOffset, trailing: shadowSpread)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: viewer.isControlling ? "hand.point.up.left.fill" : "eye.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(UD.danger))
            Text(viewer.isControlling ? "\(viewer.deviceName) 正在控制这台 Mac" : "\(viewer.deviceName) 正在查看这台 Mac 的屏幕")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(1)
            if viewer.hasAudio {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UD.text3)
                    .help("正在传输这台 Mac 的声音")
                    .accessibilityLabel("含声音")
            }
            Button("断开", action: onDisconnect)
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(UD.danger)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(UD.danger.opacity(0.12)))
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(UD.panel)
            .shadow(color: .black.opacity(0.16), radius: Self.shadowRadius, y: Self.shadowOffset))
        .fixedSize()
        .padding(Self.shadowInsets)
        .help(viewer.canControl ? "手机可以移动鼠标、点按与打字。点「断开」立即结束" : "手机只能查看，不能操作。点「断开」立即结束")
    }
}
