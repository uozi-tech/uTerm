import SwiftUI
import SwiftData

private enum HostFilter: String, CaseIterable { case all, recent, group }

/// 主机标签：服务器列表（真实 SwiftData `ServerProfile`）。
/// 分段筛选（全部 / 最近 / 分组）；点卡片弹出详情抽屉，菜单可连接 / 文件 / 编辑 / 删除。
struct HostsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(MobileStore.self) private var store
    @Environment(\.mAccent) private var accent

    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]
    @Query(sort: [SortDescriptor(\ServerGroup.sortOrder)]) private var groups: [ServerGroup]

    @State private var filter: HostFilter = .all
    @State private var inspecting: ServerProfile?
    @State private var editing: ServerProfile?
    @State private var creating = false
    @State private var pendingDelete: ServerProfile?

    /// 按分组保序归类（首次出现顺序）。
    private var grouped: [(name: String, hosts: [ServerProfile])] {
        var order: [String] = []
        var map: [String: [ServerProfile]] = [:]
        for h in hosts {
            let g = (h.group?.isEmpty == false ? h.group! : "未分组")
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(h)
        }
        return order.map { (name: $0, hosts: map[$0] ?? []) }
    }
    private var recent: [ServerProfile] {
        hosts.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }
    /// 组名 → colorHex 映射（对齐 macOS `ServerList.groupColorHexes`）。
    private var groupColorHexes: [String: String] {
        Dictionary(groups.map { ($0.name, $0.colorHex) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        MScreen(title: "主机", sub: "\(hosts.count) 台服务器", actions: {
            MRoundBtn(icon: "search") { store.showPalette = true }
            MRoundBtn(icon: "plus", filled: true) { creating = true }
        }) {
            VStack(spacing: 12) {
                Picker("筛选", selection: $filter) {
                    Text("全部").tag(HostFilter.all)
                    Text("最近").tag(HostFilter.recent)
                    Text("分组").tag(HostFilter.group)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if hosts.isEmpty {
                    MEmptyState(icon: "server", title: "还没有主机",
                                message: "添加一台服务器即可开始连接终端、浏览文件或运行命令。",
                                actionTitle: "添加服务器", action: { creating = true })
                } else if filter == .recent {
                    MCardList(alignment: .leading) {
                        sectionLabel("最近连接 · \(recent.count)")
                        if recent.isEmpty {
                            Text("还没有连接记录").font(M.sans(13)).foregroundStyle(M.text4)
                                .frame(maxWidth: .infinity).padding(.vertical, 24)
                        }
                        ForEach(recent) { host in card(host) }
                    }
                    .padding(.horizontal, 16)
                } else {
                    MCardList(alignment: .leading) {
                        ForEach(grouped, id: \.name) { sec in
                            sectionLabel("\(sec.name) · \(sec.hosts.count)")
                            ForEach(sec.hosts) { host in card(host) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .animation(.mSwap, value: filter)
        }
        .sheet(item: $inspecting) { host in
            HostSheet(host: host,
                      groupColor: MGroupTint.color(for: host.group, in: groupColorHexes),
                      onConnect: { inspecting = nil; store.openTerminal(host) },
                      onSFTP: { inspecting = nil; store.openSFTP(host) },
                      onEdit: { inspecting = nil; let h = host
                          DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editing = h } })
        }
        .sheet(isPresented: $creating) {
            // 新建主机保存后自动连接（sftpOnly → 文件浏览，否则 → 终端），走连接中页。
            // 延后到 sheet 关闭后再呈现中转页覆盖层，避免与 sheet dismiss 同帧冲突。
            HostFormSheet(host: nil) { newHost in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    store.requestConnect(newHost, kind: newHost.sftpOnly ? .sftp : .terminal)
                }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $editing) { host in
            HostFormSheet(host: host).presentationDragIndicator(.visible)
        }
        .confirmationDialog("删除「\(pendingDelete?.name ?? "")」？",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除主机", role: .destructive) { if let h = pendingDelete { delete(h) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将一并删除该主机保存的密码 / 口令。此操作不可撤销。")
        }
        .onChange(of: store.requestNewServer) { _, newVal in
            if newVal { creating = true; store.requestNewServer = false }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(M.sans(12, weight: .semibold)).tracking(0.6).foregroundStyle(M.text4)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    private func card(_ host: ServerProfile) -> some View {
        HostCard(host: host,
                 groupColor: MGroupTint.color(for: host.group, in: groupColorHexes),
                 onOpen: { inspecting = host },
                 onConnect: { store.openTerminal(host) },
                 onSFTP: { store.openSFTP(host) },
                 onEdit: { editing = host },
                 onDelete: { pendingDelete = host })
    }

    private func delete(_ host: ServerProfile) {
        let keychain = KeychainStore()
        try? keychain.delete(profileID: host.id, kind: .password)
        try? keychain.delete(profileID: host.id, kind: .passphrase)
        context.delete(host)
        try? context.save()
        pendingDelete = nil
    }
}

/// 主机卡片（设计稿 `HostCard2`）。点击弹详情抽屉；菜单含连接 / 文件 / 编辑 / 删除。
struct HostCard: View {
    let host: ServerProfile
    var groupColor: Color? = nil
    var onOpen: () -> Void
    var onConnect: () -> Void
    var onSFTP: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    @Environment(\.mAccent) private var accent

    private var statusColor: Color {
        guard let last = host.lastConnectedAt else { return M.text4 }
        return Date().timeIntervalSince(last) < 3600 ? M.success : M.caution
    }
    private var lastText: String {
        guard let last = host.lastConnectedAt else { return "从未连接" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return f.localizedString(for: last, relativeTo: Date())
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            MDot(color: groupColor ?? accent, size: 8)
                            Text(host.name).font(M.sans(16, weight: .semibold))
                                .foregroundStyle(M.text).lineLimit(1)
                            if host.isPinned { MIcon(name: "tag", size: 11, color: M.warning) }
                        }
                        Text("\(host.username)@\(host.host):\(String(host.port))")
                            .font(M.mono(12.5)).foregroundStyle(M.text3).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Menu {
                        Button { onConnect() } label: { Label("连接终端", systemImage: "terminal") }
                        Button { onSFTP() } label: { Label("浏览文件", systemImage: "folder") }
                        Button { onEdit() } label: { Label("编辑", systemImage: "pencil") }
                        Divider()
                        Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") }
                    } label: {
                        MIcon(name: "ellipsis", size: 18, color: M.text3).frame(width: 34, height: 34)
                    }
                }

                HStack(spacing: 6) {
                    MGroupChip(host.group?.isEmpty == false ? host.group! : "未分组", tint: groupColor)
                    MChip(text: host.authMethod == .privateKey ? "SSH 密钥" : "密码", icon: "key", tone: .accent)
                    if host.sftpOnly { MChip(text: "仅 SFTP", icon: "folder") }
                    Spacer()
                    Text(lastText).font(M.sans(11.5)).foregroundStyle(M.text4)
                }
            }
            .padding(14)
            .background(M.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .udShadow(.card)
        }
        .buttonStyle(MPressStyle())
        .contextMenu {
            Button { onConnect() } label: { Label("连接终端", systemImage: "terminal") }
            Button { onSFTP() } label: { Label("浏览文件", systemImage: "folder") }
            Button { onEdit() } label: { Label("编辑", systemImage: "pencil") }
            Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") }
        }
    }

    private var avatar: some View {
        Text(String(host.name.prefix(1)).uppercased())
            .font(M.mono(16, weight: .semibold)).foregroundStyle(accent)
            .frame(width: 38, height: 38)
            .background(accent.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}
