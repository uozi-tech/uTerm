import AppKit
import SwiftUI
import UDesignKit

/// 远控配对审批：设备第一次连上来时，在 Mac 上弹一个浮动面板，请人输入那台设备上显示的 6 位核对码：
/// 输对就是允许，输错 `RemotePairingCopy.attempts` 次或点「拒绝」就拒绝。要人输入而不是看一眼点「一致」，
/// 才算真的核对过（中间人替换了公钥，两边的数就对不上）。
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
        // 弹出即成为 key 窗口，输码格子（第一响应者）直接收键、第一位高亮，不用先点一下面板。
        // 面板是 `.nonactivatingPanel`，`makeKey` 不会把 App 拉到前台。
        panel.orderFrontRegardless()
        panel.makeKey()
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

    @State private var text = ""
    @State private var attemptsLeft = RemotePairingCopy.attempts
    /// 上一次输的不对，还没开始输下一次：格子描红。
    @State private var wrong = false
    @State private var shakes = 0

    private var digits: String { text.filter(\.isNumber) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 22))
                    .foregroundStyle(UD.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RemotePairingCopy.panelTitle(request.deviceName))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UD.text)
                    Text(attemptsLeft < RemotePairingCopy.attempts ? RemotePairingCopy.panelWrong(attemptsLeft: attemptsLeft)
                                                                    : RemotePairingCopy.panelDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(attemptsLeft < RemotePairingCopy.attempts ? UD.danger : UD.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // 输满六位自动核对：对了就是「允许」，不用再点按钮。
            UCodeField(code: $text, isError: wrong, shakes: shakes) { _ in
                // 让最后一位显示出来再核对。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { check() }
            }
            HStack {
                Spacer()
                UDButton(title: "拒绝", style: .secondary, action: onReject)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(UD.panel)
        .onChange(of: text) { _, value in
            if !value.isEmpty { wrong = false }
        }
    }

    private func check() {
        guard digits.count == 6 else { return }
        if digits == request.code {
            onAllow()
            return
        }
        text = ""
        wrong = true
        shakes += 1
        attemptsLeft -= 1
        if attemptsLeft <= 0 { onReject() }
    }
}
