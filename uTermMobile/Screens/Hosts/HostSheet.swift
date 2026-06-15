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
    @State private var safeBottom: CGFloat = 0

    private var statusColor: Color {
        guard let last = host.lastConnectedAt else { return M.text4 }
        return Date().timeIntervalSince(last) < 3600 ? M.success : M.caution
    }
    private var lastText: String {
        guard let last = host.lastConnectedAt else { return "从未" }
        let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "zh_CN")
        return f.localizedString(for: last, relativeTo: Date())
    }

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
            // 测量内容真实高度 → 抽屉竖屏按内容贴合不留空白；横屏高度不足时滚动而非裁切。
            .background(GeometryReader { g in
                Color.clear.preference(key: HostSheetHeightKey.self, value: g.size.height)
            })
        }
        .scrollBounceBehavior(.basedOnSize)
        // `.height` detent 是整张抽屉高度，系统会从中扣掉底部安全区（Home 指示条）给内容留白。
        // 不把安全区加回 detent，内容就被顶上去、底部空出一条 ≈ 安全区高度的间隔——这正是要去掉的「间隔」。
        .background(GeometryReader { g in
            Color.clear.preference(key: HostSheetSafeKey.self, value: g.safeAreaInsets.bottom)
        })
        .onPreferenceChange(HostSheetHeightKey.self) { contentHeight = $0 }
        .onPreferenceChange(HostSheetSafeKey.self) { safeBottom = $0 }
        .presentationDetents([.height(contentHeight + safeBottom)])
        .presentationDragIndicator(.visible)
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
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(M.borderHi, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(MPressStyle())
    }
}

/// 抽屉内容真实高度的测量 key（用于按内容贴合 detent）。
private struct HostSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 380
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 抽屉底部安全区（Home 指示条）测量 key：加回 detent 以消除底部留白间隔。
private struct HostSheetSafeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
