import SwiftUI

/// 别的设备来确认这台设备时弹的单子（「我的设备」）：显示 6 位数请你在那台设备上输入，同时问你「允许」。
/// 点了「允许」单子就关，那边输对后后台自动记下（`RemoteSiblingDevices.acceptIncoming`）。
/// 挂在根视图上，不管你在哪一页都会弹。状态都在 `RemoteSiblingService`（App 在前台时一直在读名册）。
struct RemoteSiblingConfirmHandler: ViewModifier {
    @Environment(RemoteSiblingService.self) private var service

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { service.pendingIncoming != nil }, set: { _ in })) {
                RemoteSiblingConfirmSheet()
                    .presentationDetents([.medium])
                    .presentationBackground(M.canvas)
                    // 必须明确选一个：下滑关掉等于什么都没说，下一拍又会弹出来。
                    .interactiveDismissDisabled()
            }
    }
}

private struct RemoteSiblingConfirmSheet: View {
    @Environment(RemoteSiblingService.self) private var service
    @Environment(\.mAccent) private var accent

    var body: some View {
        if let incoming = service.pendingIncoming, let model = service.model {
            VStack(spacing: 16) {
                MIcon(name: incoming.voucher.isMac ? "mac" : "iphone", size: 28, color: accent)
                Text(RemoteSiblingCopy.incomingTitle(incoming.voucher))
                    .font(M.sans(18, weight: .bold)).foregroundStyle(M.text)
                    .multilineTextAlignment(.center)
                Text(RemotePairingCode.grouped(incoming.code))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .foregroundStyle(M.text)
                Text(RemoteSiblingCopy.incomingDetail(incoming.voucher))
                    .font(M.sans(13)).foregroundStyle(M.text3)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
                Button { model.acceptIncoming(incoming.voucher.id) } label: {
                    Text("允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button("拒绝", role: .cancel) { model.dismissIncoming(incoming.voucher.id) }
            }
            .padding(24)
        }
    }
}
