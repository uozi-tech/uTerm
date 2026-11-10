import AppKit
import SwiftUI
import UDesignKit

/// 远控配对审批：手机第一次连上来时，在 Mac 上弹一个浮动面板，显示设备名与 6 位核对码，
/// 由人点「允许 / 拒绝」。
///
/// 做成独立的 `NSPanel` 而不是某个场景里的 sheet：uTerm 常以无窗口的后台模式运行，
/// 那时根本没有可挂 sheet 的窗口。面板不阻塞主线程，终端照常刷新。
@MainActor
final class RemotePairingPrompt {
    private let server: RemoteHostServer
    private var panel: NSPanel?
    private var shownID: UUID?

    init(server: RemoteHostServer) {
        self.server = server
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = server.pairingRequests
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
        guard let request = server.pairingRequests.first else {
            close()
            return
        }
        guard request.id != shownID else { return }
        show(request)
    }

    private func show(_ request: RemoteHostServer.PairingRequest) {
        close()
        shownID = request.id
        let server = self.server
        let content = RemotePairingPanelView(
            request: request,
            onAllow: { server.approvePairing(request.id) },
            onReject: { server.rejectPairing(request.id) }
        )
        let hosting = NSHostingView(rootView: content)
        hosting.frame.size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        shownID = nil
    }
}

private struct RemotePairingPanelView: View {
    let request: RemoteHostServer.PairingRequest
    let onAllow: () -> Void
    let onReject: () -> Void

    private var spacedCode: String {
        RemotePairingCode.grouped(request.code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 22))
                    .foregroundStyle(UD.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("「\(request.deviceName)」请求远程控制终端")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UD.text)
                    Text("允许后，它可以接入这台 Mac 上已打开的终端，之后再连无需确认。")
                        .font(.system(size: 12))
                        .foregroundStyle(UD.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("核对码")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text2)
                Text(spacedCode)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(UD.text)
                    .textSelection(.enabled)
                Text("确认手机上显示的是同一组数字再允许。如果不一致，连接可能已被截获，应当拒绝。")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                UDButton(title: "拒绝", style: .secondary, action: onReject)
                UDButton(title: "允许", style: .primary, action: onAllow)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(UD.panel)
    }
}
