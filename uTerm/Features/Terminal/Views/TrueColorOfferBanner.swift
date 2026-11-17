import SwiftUI
import UDesignKit

/// 「这台主机的 Agent 只能显示 256 色」的提示。
///
/// 浮在终端右上角，不占窗格高度：高度一变就是一次 SIGWINCH，Claude Code 会整屏重绘。
struct TrueColorOfferBanner: View {
    let session: TerminalSession
    let offer: TrueColorOffer

    @State private var isConfirming = false

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .font(.system(size: 11.5, weight: .semibold))
        .buttonStyle(.udPlain)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(UD.overlay, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .udShadow(.sm)
        .padding(.top, 6)
        .padding(.trailing, 14)
        .frame(maxWidth: 460, alignment: .trailing)
        .alert("在这台主机启用真彩？", isPresented: $isConfirming) {
            Button("写入") { session.enableTrueColor() }
            Button("取消", role: .cancel) {}
        } message: {
            if case .available(let rcFile) = offer {
                Text("将往 \(rcFile) 添加一行，只影响从 uTerm 连入的会话：\n\n\(RemoteTrueColor.rcLine(forFile: rcFile))")
            }
        }
    }

    private var message: String {
        switch offer {
        case .available:
            String(localized: "这台主机上的 Agent 只能显示 256 色")
        case .enabled(let rcFile):
            String(localized: "已写入 \(rcFile)，新开的终端生效")
        case .failed(let reason):
            String(localized: "没有写入：\(reason)")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if case .available = offer {
            Button("启用真彩…") { isConfirming = true }
                .foregroundStyle(UD.accent)
            Button("不再询问") { session.dismissTrueColorOfferForHost() }
                .foregroundStyle(UD.text3)
        } else {
            Button("好") { session.closeTrueColorOffer() }
                .foregroundStyle(UD.accent)
        }
    }
}
