import SwiftUI

/// 主机页顶部的「体验主机」卡：不用服务器，直接开一个模拟的终端 / 文件页。不受订阅限制。
struct DemoHostCard: View {
    var onTerminal: () -> Void
    var onFiles: () -> Void

    @Environment(\.mAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MIcon(name: "term", size: 18, color: accent, weight: .semibold)
                    .frame(width: HostAvatar.defaultSize, height: HostAvatar.defaultSize)
                    .background(accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.sm))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text("体验主机").font(M.sans(16, weight: .semibold)).foregroundStyle(M.text)
                        MChip(text: String(localized: "不联网"), tone: .accent)
                    }
                    Text("还没有服务器？先在这台模拟的 Linux 上试试终端和文件。")
                        .font(M.sans(12.5)).foregroundStyle(M.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                MBtn(title: String(localized: "打开终端"), icon: "term", kind: .tinted, full: true, height: 40,
                     action: onTerminal)
                MBtn(title: String(localized: "浏览文件"), icon: "folder", kind: .secondary, full: true, height: 40,
                     action: onFiles)
            }
        }
        .padding(14)
        .background(M.card)
        .clipShape(RoundedRectangle(cornerRadius: MRadius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("demo-host-card")
    }
}
