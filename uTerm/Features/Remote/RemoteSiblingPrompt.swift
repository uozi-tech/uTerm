import AppKit
import SwiftUI
import UDesignKit

/// 别的设备来确认这台 Mac 时单独弹的面板（「我的设备」）：显示 6 位数请你在那台设备上输入，同时问你「允许」。
/// 点了「允许」面板就关，那边输对后后台自动记下（`RemoteSiblingDevices.acceptIncoming`）。和配对审批面板（`RemotePairingPrompt`）一样是独立的浮动面板，没开任何窗口也能弹。
/// 状态都在 `RemoteSiblingService`（App 一直在后台读名册），这里只管显示。
@MainActor
final class RemoteSiblingPrompt {
    private let service: RemoteSiblingService
    private var panel: NSPanel?
    /// 面板此刻问的是哪台设备。换了就重开。
    private var shown: UUID?

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
        if shown == incoming.voucher.id { return }
        close()
        shown = incoming.voucher.id
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
                    Text(RemoteSiblingCopy.incomingTitle(incoming.voucher))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UD.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(RemotePairingCode.grouped(incoming.code))
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .foregroundStyle(UD.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                Text(RemoteSiblingCopy.incomingDetail(incoming.voucher))
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    UDButton(title: "拒绝", style: .secondary) { model.dismissIncoming(incoming.voucher.id) }
                    UDButton(title: "允许", style: .primary) { model.acceptIncoming(incoming.voucher.id) }
                }
            }
            .padding(20)
            .frame(width: 380)
            .background(UD.panel)
        }
    }
}
