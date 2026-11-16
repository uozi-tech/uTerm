import AppKit
import SwiftUI
import UDesignKit

/// 别的设备来确认这台 Mac 时单独弹的面板（「我的设备」）：先显示 6 位数请你在那台设备上输入，那边输对后改成
/// 问你「允许」。和配对审批面板（`RemotePairingPrompt`）一样是独立的浮动面板，没开任何窗口也能弹。
/// 状态都在 `RemoteSiblingService`（App 一直在后台读名册），这里只管显示。
@MainActor
final class RemoteSiblingPrompt {
    private let service: RemoteSiblingService
    private var panel: NSPanel?
    /// 面板此刻显示的是哪一次、哪一步（显示数字 / 问允许）。换了就重开，面板高度跟着内容走。
    private var shown: (voucher: UUID, verified: Bool)?

    init(service: RemoteSiblingService) {
        self.service = service
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = service.pendingIncoming
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
        guard let incoming = service.pendingIncoming else {
            close()
            return
        }
        if let shown, shown.voucher == incoming.voucher.id, shown.verified == incoming.verified { return }
        close()
        shown = (incoming.voucher.id, incoming.verified)
        let hosting = NSHostingView(rootView: RemoteSiblingPromptView(service: service))
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
        shown = nil
    }
}

private struct RemoteSiblingPromptView: View {
    let service: RemoteSiblingService

    var body: some View {
        if let incoming = service.pendingIncoming, let model = service.model {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 22))
                        .foregroundStyle(UD.accent)
                    Text(incoming.verified ? RemoteSiblingCopy.verifiedTitle(incoming.voucher)
                                           : RemoteSiblingCopy.incomingTitle(incoming.voucher))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UD.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !incoming.verified {
                    Text(RemotePairingCode.grouped(incoming.code))
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .foregroundStyle(UD.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                }
                Text(incoming.verified ? RemoteSiblingCopy.verifiedDetail(incoming.voucher)
                                       : RemoteSiblingCopy.incomingDetail(incoming.voucher))
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if incoming.verified {
                        UDButton(title: "不允许", style: .secondary) { model.dismissIncoming(incoming.voucher.id) }
                        UDButton(title: "允许", style: .primary) { model.acceptIncoming(incoming.voucher.id) }
                    } else {
                        UDButton(title: "拒绝", style: .secondary) { model.dismissIncoming(incoming.voucher.id) }
                    }
                }
            }
            .padding(20)
            .frame(width: 380)
            .background(UD.panel)
        }
    }
}
