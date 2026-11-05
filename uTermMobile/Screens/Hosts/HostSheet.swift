import SwiftUI

/// 主机详情底部面板（设计稿 `HostSheet`）：连接终端 / SFTP / 编辑。由 `mBottomPanel` 呈现。
struct HostSheet: View {
    let host: ServerProfile
    var groupColor: Color? = nil
    var onConnect: () -> Void
    var onSFTP: () -> Void
    var onEdit: () -> Void

    private var lastText: String { UTermFormat.relative(host.lastConnectedAt) }

    var body: some View {
        // 呈现在 MBottomPanel 里（HostsScreen 的 mBottomPanel）：面板高度就是这块内容的高度，
        // 不再用 .sheet + 测量出来的 .height detent（「有时候很高」的根源，见 MBottomPanel）。
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                MHostAvatar(monogram: host.monogram,
                            tint: groupColor,
                            reachability: HostReachabilityMonitor.shared.entry(for: host),
                            size: 40)
                Text(host.name).font(M.sans(23, weight: .bold)).tracking(-0.4).foregroundStyle(M.text).lineLimit(1)
                Spacer(minLength: 6)
                if let g = host.group, !g.isEmpty {
                    MGroupChip(g, tint: groupColor)
                }
            }
            Text("\(host.username)@\(host.host):\(String(host.port))")
                .font(M.mono(13.5)).foregroundStyle(M.text2).lineLimit(1).padding(.top, 5)

            metaGrid.padding(.top, 20)

            MBtn(title: "连接终端", icon: "term", kind: .primary, full: true, height: 52, action: onConnect)
                .padding(.top, 22)
            HStack(spacing: 10) {
                actionTile("folder-tag", "SFTP 文件", action: onSFTP)
                actionTile("edit", "编辑", action: onEdit)
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mWatchesReachability(of: host)
    }

    private var metaGrid: some View {
        let items: [(String, String, Bool)] = [
            ("端口", "\(host.port)", true),
            ("认证", host.authMethod == .privateKey ? "SSH 密钥" : "密码", false),
            ("上次连接", lastText, false),
            ("分组", host.group ?? "未分组", false),
        ]
        // 用 Grid 而不是 LazyVGrid：懒加载容器的格子不跟父视图的滑入转场走，面板还在往上滑时
        // 这几格文字就先停在了终点（实机反馈「弹窗还没弹完字体就出来了」）。只有四格，不需要懒加载。
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 16) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(items[(row * 2)..<(row * 2 + 2)], id: \.0) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.0.uppercased()).font(M.sans(11)).tracking(0.4).foregroundStyle(M.text4)
                            Text(item.1).font(item.2 ? M.mono(15) : M.sans(15)).foregroundStyle(M.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func actionTile(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                MIcon(name: icon, size: 18, color: M.text2)
                Text(label).font(M.sans(13, weight: .medium)).foregroundStyle(M.text)
            }
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(M.fillFaint)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.lg))
        }.buttonStyle(MPressStyle())
    }
}
