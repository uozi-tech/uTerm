import AppKit
import SwiftUI
import UDesignKit

/// 别的设备想加入你的设备组时单独弹的面板（组员一侧）：输入它屏幕上的 6 位数，或「拒绝」。
///
/// 输了以后组员这边当场不知道对错（要等那台设备回话），面板转成「正在核对…」，可以关掉、后台继续。
/// 输错了那台设备会换一个新数，面板再弹出来请你输新的。核对通过、请求没了（别的组员输对了、对方取消了）就自己关。
/// 和配对审批面板（`RemotePairingPrompt`）一样是独立的浮动面板，没开任何窗口也能弹。
/// 状态都在 `RemoteDeviceGroupService`（App 一直在后台读名册），这里只管显示。
@MainActor
final class RemoteDeviceGroupPrompt {
    private let service: RemoteDeviceGroupService
    private var panel: NSPanel?
    /// 面板此刻问的是哪台设备。换了就重开。
    private var shown: UUID?

    init(service: RemoteDeviceGroupService) {
        self.service = service
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = service.pendingRequest
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
        guard let request = service.pendingRequest else {
            close()
            return
        }
        if shown == request.id {
            resize()
            return
        }
        close()
        shown = request.id
        let hosting = NSHostingView(rootView: RemoteDeviceGroupPromptView(service: service, candidateID: request.id))
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

    /// 状态变了（输入框 ↔「正在核对」）内容高度跟着变：面板按新的高度改，顶边不动。
    private func resize() {
        guard let panel, let hosting = panel.contentView as? NSHostingView<RemoteDeviceGroupPromptView> else { return }
        let size = hosting.fittingSize
        guard size != panel.frame.size else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        shown = nil
    }
}

struct RemoteDeviceGroupPromptView: View {
    let service: RemoteDeviceGroupService
    let candidateID: UUID

    @State private var text = ""
    @State private var shakes = 0

    private var request: RemoteDeviceGroup.JoinRequest? {
        service.pendingRequest.flatMap { $0.id == candidateID ? $0 : nil }
    }

    var body: some View {
        if let request {
            content(request)
                .padding(20)
                .frame(width: 400)
                .background(UD.panel)
        }
    }

    private func content(_ request: RemoteDeviceGroup.JoinRequest) -> some View {
        let acceptsCode = RemoteDeviceGroupCopy.acceptsCode(request.status)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: settingsDeviceSymbol(for: request.candidate))
                    .font(.system(size: 22))
                    .foregroundStyle(UD.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.status == .verifying ? RemoteDeviceGroupCopy.verifyingTitle
                                                      : RemoteDeviceGroupCopy.requestTitle(request.candidate))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UD.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(RemoteDeviceGroupCopy.requestDetail(request))
                        .font(.system(size: 12))
                        .foregroundStyle(RemoteDeviceGroupCopy.isWarning(request.status) ? UD.danger : UD.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if acceptsCode {
                // 输满六位自动核对，不用再点按钮。上一个数没对上时描红，开始输新数就不红了。
                UCodeField(code: $text, length: RemoteGroupJoinCrypto.codeLength,
                           isError: isWrong(request.status) && text.isEmpty, shakes: shakes) { _ in
                    // 让最后一位显示出来再核对。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { submit(request) }
                }
            } else if request.status == .verifying {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                if acceptsCode {
                    UDButton(title: "拒绝", style: .secondary) { service.reject(request) }
                } else {
                    UDButton(title: "关闭", style: .secondary) { service.hidePrompt(request) }
                }
            }
        }
        // 输错后要输新数：清掉上一次的，晃一下。
        .onChange(of: request.status) { _, status in
            text = ""
            if isWrong(status) { shakes += 1 }
        }
    }

    private func isWrong(_ status: RemoteDeviceGroup.JoinRequest.Status) -> Bool {
        if case .wrongCode = status { return true }
        return false
    }

    private func submit(_ request: RemoteDeviceGroup.JoinRequest) {
        guard RemoteGroupJoinCrypto.normalizedCode(text) != nil else { return }
        if service.submit(text, for: request) { text = "" }
    }
}
