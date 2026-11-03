import SwiftUI

/// 主机详情底部抽屉（设计稿 `HostSheet`）：连接终端 / SFTP / 编辑。
struct HostSheet: View {
    let host: ServerProfile
    var groupColor: Color? = nil
    var onConnect: () -> Void
    var onSFTP: () -> Void
    var onEdit: () -> Void
    @Environment(\.mAccent) private var accent
    @State private var contentHeight: CGFloat = 380
    private static let maxContentHeight: CGFloat = 560

    private var statusColor: Color {
        guard let last = host.lastConnectedAt else { return M.text4 }
        return Date().timeIntervalSince(last) < 3600 ? M.success : M.caution
    }
    private var lastText: String { UTermFormat.relative(host.lastConnectedAt) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    MDot(color: groupColor ?? accent, size: 10)
                    Text(host.name).font(M.sans(23, weight: .bold)).tracking(-0.4).foregroundStyle(M.text).lineLimit(1)
                    Spacer(minLength: 6)
                    if let g = host.group, !g.isEmpty {
                        MGroupChip(g, tint: groupColor)
                    }
                }
                Text("\(host.username)@\(host.host):\(String(host.port))")
                    .font(M.mono(13.5)).foregroundStyle(M.text2).padding(.top, 5)

                metaGrid.padding(.top, 20)

                MBtn(title: "连接终端", icon: "term", kind: .primary, full: true, height: 52, action: onConnect)
                    .padding(.top, 22)
                HStack(spacing: 10) {
                    actionTile("folder-tag", "SFTP 文件", action: onSFTP)
                    actionTile("edit", "编辑", action: onEdit)
                }
                .padding(.top, 10)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 只认宽度已经定下来时量到的高度，且封顶：弹窗出现的第一轮布局里宽度可能还很窄，
            // 文字折行把内容量得极高，detent 跟着被设成接近整屏；之后量回正常高度，系统不一定
            // 把已经展开的抽屉收回去——这就是「有时候」弹窗很高（实机反馈，无固定复现条件）。
            // 本抽屉结构固定，正常高度在 400pt 上下。
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard size.width >= 200 else { return }
                contentHeight = min(size.height, Self.maxContentHeight)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // 理想高度 = 内容高度：常规宽度（iPhone Duo 展开、iPad）下系统把抽屉显示成表单弹窗、
        // 不认 `.height` detent，弹窗被撑到接近整屏、内容只占顶上一小块（实机反馈）。按内容
        // 贴合纵向尺寸（fitted），那里就是一张刚好包住内容的弹窗；紧凑宽度仍是底部抽屉，走 detent。
        .frame(idealHeight: contentHeight)
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        // 不透明抽屉底色：默认材质是半透明的，底部 home indicator 区会透出标签栏，显得有道「间隔」。
        .presentationBackground(M.canvas)
    }

    private var metaGrid: some View {
        let items: [(String, String, Bool)] = [
            ("端口", "\(host.port)", true),
            ("认证", host.authMethod == .privateKey ? "SSH 密钥" : "密码", false),
            ("上次连接", lastText, false),
            ("分组", host.group ?? "未分组", false),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                         spacing: 16) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.0.uppercased()).font(M.sans(11)).tracking(0.4).foregroundStyle(M.text4)
                    Text(item.1).font(item.2 ? M.mono(15) : M.sans(15)).foregroundStyle(M.text)
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
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(MPressStyle())
    }
}
