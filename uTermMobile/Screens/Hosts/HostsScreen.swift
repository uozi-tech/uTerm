import UDesignKit
import SwiftUI
import SwiftData

private enum HostFilter: String, CaseIterable { case all, recent, group }

/// 主机标签：服务器列表（真实 SwiftData `ServerProfile`）。
/// 分段筛选（全部 / 最近 / 分组）；点卡片弹出详情抽屉，菜单可连接 / 文件 / 编辑 / 删除。
struct HostsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(MobileStore.self) private var store
    /// 可选：只为露出「会话 N」入口。单独挂主机页的探针 / 画廊不注入它。
    @Environment(MobileWorkspace.self) private var workspace: MobileWorkspace?
    @Environment(\.mAccent) private var accent

    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]
    @Query(sort: [SortDescriptor(\ServerGroup.sortOrder)]) private var groups: [ServerGroup]

    @State private var filter: HostFilter = .all
    @State private var inspecting: ServerProfile?
    @State private var editing: ServerProfile?
    @State private var creating = false
    @State private var pendingDelete: ServerProfile?

    /// 不超过这么多台时不用懒加载（为什么见 `MCardList.lazy`）。更多时卡片全部常驻太贵，仍走懒加载。
    static let eagerHostLimit = 120

    var body: some View {
        // 三个派生量在这里**各求一次**，往下传。
        //
        // 改前它们是三个计算属性，其中 `groupColorHexes` 由 `card(_:)` 逐行调用 ——
        // 每渲染一行就重建一次整张「组名 → hex」字典再解析一次十六进制，
        // 也就是 O(主机 × 分组)。`recent` 还没有截断，连过几千台的库会把整张表
        // 排序后全铺进非 lazy 的 `MCardList`。
        //
        // 这里**不做跨 body 的记忆化**：cache key 只能拿 `hosts.count` 之类的
        // O(1) 签名，而「改了某台主机的分组名」恰恰不改条数 —— 编辑表单一关
        // 分组就会停在旧值。派生量本来每次 body 也只需要一趟，跨 body 缓存
        // 换不来什么，却要拿正确性去赌。
        let groupColors = MGroupTint.colors(for: groups)
        let sections = ServerGrouping.grouped(hosts)
        let recent = ServerGrouping.recent(hosts)
        let lazy = hosts.count > Self.eagerHostLimit

        return MScreen(title: "主机", sub: "\(hosts.count) 台服务器",
                       maxContentWidth: M.gridContentWidth, pinsHeader: true, actions: {
            // 有会话开着（工作区收起了）时给一个回去的入口。系统工具栏按钮，底由系统画。
            if let workspace, !workspace.isEmpty {
                Button { store.showWorkspace = true } label: {
                    Label("会话 \(workspace.tabs.count)", systemImage: MGlyph.symbol("term"))
                        .labelStyle(.titleAndIcon)
                }
                .tint(accent)
                .accessibilityLabel(Text("回到 \(workspace.tabs.count) 个会话"))
            }
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

                RemoteMacSection()

                if hosts.isEmpty {
                    MEmptyState(icon: "server", title: "还没有主机",
                                message: "添加一台服务器即可开始连接终端、浏览文件或运行命令。",
                                actionTitle: "添加服务器", action: { creating = true })
                } else if filter == .recent {
                    // 宽屏（iPhone Duo 展开 / iPad / 横屏）一行排 2–3 张卡（MCardGrid 按宽度定列数），
                    // 窄屏仍是一列。分组标题在网格外，独占一行。
                    MCardList(alignment: .leading, lazy: lazy) {
                        sectionLabel("最近连接 · \(recent.count)")
                        if recent.isEmpty {
                            Text("还没有连接记录").font(M.sans(13)).foregroundStyle(M.text4)
                                .frame(maxWidth: .infinity).padding(.vertical, 24)
                        }
                        MCardGrid(lazy: lazy) {
                            ForEach(recent) { host in card(host, groupColors: groupColors) }
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    MCardList(alignment: .leading, lazy: lazy) {
                        ForEach(sections, id: \.name) { sec in
                            sectionLabel("\(sec.name) · \(sec.hosts.count)")
                            MCardGrid(lazy: lazy) {
                                ForEach(sec.hosts) { host in card(host, groupColors: groupColors) }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .animation(.mSwap, value: filter)
        }
        // 主机详情用自绘底部面板（MBottomPanel），不用 .sheet + 测量 detent（真机上「有时候很高」）。
        .mBottomPanel(item: $inspecting) { host in
            HostSheet(host: host,
                      groupColor: MGroupTint.color(for: host.group, colors: groupColors),
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
            .mSheetContentMargins()
        }
        .sheet(item: $editing) { host in
            HostFormSheet(host: host).presentationDragIndicator(.visible).mSheetContentMargins()
        }
        .alert("删除「\(pendingDelete?.name ?? "")」？",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
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
        Text(text.uppercased()).font(M.sans(12, weight: .semibold)).tracking(0.6).foregroundStyle(M.text3)
            // 组与组之间的留白（14 + 列表间距）大于卡片之间的 10–12pt，分组读得出来。
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
    }

    private func card(_ host: ServerProfile, groupColors: [String: Color]) -> some View {
        HostCard(host: host,
                 groupColor: MGroupTint.color(for: host.group, colors: groupColors),
                 onOpen: { inspecting = host },
                 onConnect: { store.openTerminal(host) },
                 onSFTP: { store.openSFTP(host) },
                 onEdit: { editing = host },
                 onDelete: { pendingDelete = host })
    }

    private func delete(_ host: ServerProfile) {
        // 先收掉这台主机开着的会话：标签强持着 `ServerProfile`，删掉以后再读它的属性会崩。
        if let workspace {
            let closed = workspace.closeSessions(ofHost: host.persistentModelID)
            if let req = store.connecting, let tabID = req.tabID, closed.contains(tabID) {
                store.connecting = nil
            }
            if workspace.isEmpty { store.showWorkspace = false }
        }
        // 钥匙串 secrets / 端口转发规则 / 跳板机悬空引用一并清理（改前漏了后三者）。
        ServerProfileStore(context: context).delete(host)
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

    /// 共享格式化器。**别改回「每行现建一个」**——这是逐行调用的。
    private var lastText: String { UTermFormat.relative(host.lastConnectedAt, fallback: "从未连接") }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(host.name).font(M.sans(16, weight: .semibold))
                                .foregroundStyle(M.text).lineLimit(1)
                            if host.isPinned { MIcon(name: "tag", size: 11, color: M.warning) }
                        }
                        Text(host.endpointWithPort)
                            .font(M.mono(12.5)).foregroundStyle(M.text3).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    MMenu {
                        Button { onConnect() } label: { Label("连接终端", systemImage: "terminal") }
                        Button { onSFTP() } label: { Label("浏览文件", systemImage: "folder") }
                        Button { onEdit() } label: { Label("编辑", systemImage: "pencil") }
                        Divider()
                        Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") }
                    } label: {
                        MIcon(name: "ellipsis", size: 18, color: M.text3)
                            .frame(width: M.minTarget, height: M.minTarget)
                            .contentShape(Rectangle())
                    }
                    .padding(.vertical, -5).padding(.trailing, -6)   // 命中区 44pt，不撑高卡片头
                    .accessibilityLabel(Text("更多操作"))
                }

                HStack(spacing: 6) {
                    MGroupChip(host.groupLabel, tint: groupColor)
                    MChip(text: host.authMethod.label, icon: "key", tone: .accent)
                    if host.sftpOnly { MChip(text: "仅 SFTP", icon: "folder") }
                    Spacer(minLength: 6)
                    // 窄屏（iPhone Duo 分屏 ≈ 330pt）让位给 chip：时间单行截断，chip 不折行。
                    Text(lastText).font(M.sans(11.5)).foregroundStyle(M.text3)
                        .lineLimit(1).layoutPriority(-1)
                }
            }
            .padding(14)
            .background(M.card)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.card))
        }
        .buttonStyle(MPressStyle())
        .mWatchesReachability(of: host)
        .mContextMenu {
            Button { onConnect() } label: { Label("连接终端", systemImage: "terminal") }
            Button { onSFTP() } label: { Label("浏览文件", systemImage: "folder") }
            Button { onEdit() } label: { Label("编辑", systemImage: "pencil") }
            Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") }
        }
    }

    /// 分组色色块 + 首字母，角标 = 在线状态（见 `MHostAvatar`）。
    private var avatar: some View {
        MHostAvatar(monogram: host.monogram,
                    tint: groupColor,
                    reachability: HostReachabilityMonitor.shared.entry(for: host))
    }
}
