import SwiftUI
import UDesignKit

/// 窗格右上角的「正在被手机接管」指示条：说明终端为什么按别的尺寸显示，并能就地断开。
struct RemoteControlBadge: View {
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
            Button("断开", action: onDisconnect)
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(UD.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(UD.panel))
        .overlay(Capsule().strokeBorder(UD.border, lineWidth: 1))
        .help("终端正按 \(deviceName) 的尺寸运行；断开后恢复按窗格大小")
    }
}
