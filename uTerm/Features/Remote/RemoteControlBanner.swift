import SwiftUI
import UDesignKit
import UPaneGroups

/// 终端窗格的内容：有设备接管时，窗格顶上多一条接管状态条。
///
/// 状态条占窗格自己的高度、不盖在终端上：接管期间终端钉在手机的行列数，
/// 能显示多少就显示多少，浮层只会再挡掉一块本来就可能显示不全的内容。
struct RemoteControlledTerminal: View {
    let session: TerminalSession
    /// 分屏时只有活动组的前台标签算活动。没有这个门的宿主只挂活动标签，挂着就是活动。
    @Environment(\.activePaneGate) private var activePaneGate

    var body: some View {
        VStack(spacing: 0) {
            if let controller = session.remoteController {
                RemoteControlBanner(deviceName: controller) {
                    session.remoteDisconnect?()
                }
            }
            TerminalHostView(terminalView: session.terminalView,
                             isActive: activePaneGate?.isActive ?? true)
        }
    }
}

/// 「正在被手机接管」状态条：说明终端为什么按别的尺寸显示，并能就地断开。
struct RemoteControlBanner: View {
    let deviceName: String
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UD.accent)
            Text("\(deviceName) 正在接管")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("断开", action: onDisconnect)
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(UD.accent)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(UD.accentSoft)
        .help("终端正按 \(deviceName) 的尺寸运行；断开后恢复按窗格大小")
    }
}
