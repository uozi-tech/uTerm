import UDesignKit
import SwiftUI
import SwiftData

private enum HostFilter: String, CaseIterable { case all, recent, group }

/// 主机标签：服务器列表（真实 SwiftData `ServerProfile`）。
/// 分段筛选（全部 / 最近 / 分组）；点卡片弹出详情抽屉，菜单可连接 / 文件 / 编辑 / 删除。
struct HostsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(MobileStore.self) private var store
    /// 可选：删主机时先收掉它的会话。单独挂主机页的探针 / 画廊不注入它。
    /// **别在 `body` 里读它的属性**：一读，工作区每次增减标签整页（全部主机卡片）都要重算，见 `WorkspaceReturnTracker`。
    @Environment(MobileWorkspace.self) private var workspace: MobileWorkspace?
    @Environment(\.mAccent) private var accent
    /// 可选：决定有主机时还显不显示体验卡。单独挂主机页的探针 / 画廊不注入它。
    @Environment(SubscriptionStore.self) private var subscriptions: SubscriptionStore?

    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]
    @Query(sort: [SortDescriptor(\ServerGroup.sortOrder)]) private var groups: [ServerGroup]

    @State private var filter: HostFilter = .all
    @State private var inspecting: ServerProfile?
    @State private var editing: ServerProfile?
    @State private var creating = false
    @State private var pendingDelete: ServerProfile?
    /// 工具栏「标签页 N」的 N（0 = 不显示）。由 `WorkspaceReturnTracker` 在工作区滑完之后才改，见那里。
    @State private var returnTabs = 0

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
        let groupColors = ServerGroupTint.colors(for: groups)
        let sections = ServerGrouping.grouped(hosts)
        let recent = ServerGrouping.recent(hosts)
        let lazy = hosts.count > Self.eagerHostLimit

        return MScreen(title: String(localized: "tab.hosts", defaultValue: "主机", comment: "底部标签与主机页标题（复数：Hosts）"),
                       sub: String(localized: "\(hosts.count) 台主机"),
                       maxContentWidth: M.gridContentWidth, pinsHeader: true, actions: {
            // 有会话开着（工作区收起了）时给一个回去的入口。系统工具栏按钮，底由系统画。
            if returnTabs > 0 {
                Button { store.showWorkspace = true } label: {
                    Label("标签页 \(returnTabs)", systemImage: MGlyph.symbol("term"))
                        .labelStyle(.titleAndIcon)
                }
                .tint(accent)
                .accessibilityLabel(Text("回到 \(returnTabs) 个标签页"))
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

                // 体验主机：没有主机时始终显示。有主机后只给没订阅的人留在「全部」里（同步来的主机要订阅才能连，
                // 体验主机是他们唯一能用的）；订阅了又有主机就不再显示。权益还没读出来时按已订阅算，免得卡片闪一下又消失。
                if hosts.isEmpty || (filter == .all && !(subscriptions?.isEntitled ?? false)) {
                    DemoHostCard(onTerminal: { store.openDemo(.terminal) }, onFiles: { store.openDemo(.sftp) })
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                }

                if hosts.isEmpty {
                    MEmptyState(icon: "server", title: String(localized: "还没有主机"),
                                message: String(localized: "添加一台主机，即可连接终端、浏览文件或运行命令。"),
                                actionTitle: String(localized: "添加主机"), action: { creating = true })
                } else if filter == .recent {
                    // 宽屏（iPhone Duo 展开 / iPad / 横屏）一行排 2–3 张卡（MCardGrid 按宽度定列数），
                    // 窄屏仍是一列。分组标题在网格外，独占一行。
                    MCardList(alignment: .leading, lazy: lazy) {
                        sectionLabel(String(localized: "最近连接 · \(recent.count)"))
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
        .background { WorkspaceReturnTracker(count: $returnTabs) }
        // 主机详情用自绘底部面板（MBottomPanel），不用 .sheet + 测量 detent（真机上「有时候很高」）。
        .mBottomPanel(item: $inspecting) { host in
            HostSheet(host: host,
                      groupColor: ServerGroupTint.color(for: host.group, colors: groupColors),
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
            Text("将一并删除该主机保存的密码 / 口令。此操作无法撤销。")
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
        HostCard(info: HostCardInfo(host),
                 groupColor: ServerGroupTint.color(for: host.group, colors: groupColors),
                 onOpen: { inspecting = host },
                 onConnect: { store.openTerminal(host) },
                 onSFTP: { store.openSFTP(host) },
                 onEdit: { editing = host },
                 onDelete: { pendingDelete = host })
            .equatable()
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

/// 主机页工具栏上「标签页 N」该显示几：工作区（标签增减、展开收起）只在这里读，`HostsScreen.body` 不读。
///
/// 工具栏一加 / 减按钮，系统就把整个主机页重新排版一遍（主机不多时卡片不懒加载，100 台就是 100 张卡片），
/// 主线程一次占掉 30–100 ms。改前按钮跟着工作区实时变：关掉最后一个标签、工作区往外滑的头一拍，和打开第一个
/// 标签、工作区滑进来的头一拍，都正好撞上这一下，滑动掉帧。工作区盖着主机页时按钮反正看不见，所以这里
/// 盖着的时候不动，等工作区滑走、停稳了再改。
private struct WorkspaceReturnTracker: View {
    @Binding var count: Int
    @Environment(MobileStore.self) private var store
    /// 可选：单独挂主机页的探针 / 画廊不注入它。
    @Environment(MobileWorkspace.self) private var workspace: MobileWorkspace?

    private struct Key: Equatable {
        var tabs: Int
        var workspaceVisible: Bool
    }

    var body: some View {
        // 正在关的标签（等工作区滑走才摘下）不算：关最后一个时按钮不先冒出来再消失。
        let key = Key(tabs: workspace?.remainingTabCount ?? 0, workspaceVisible: store.showWorkspace)
        Color.clear
            .task(id: key) {
                guard !key.workspaceVisible, count != key.tabs else { return }
                try? await Task.sleep(for: WorkspaceLayer.slideSettle)
                guard !Task.isCancelled else { return }
                count = key.tabs
            }
    }
}

/// 卡片要画的字段，由主机页从 `ServerProfile` 抄一份值。
///
/// 卡片不直接读 SwiftData 对象：iCloud 合并数据时 SwiftData 对每台主机都发「跳板机变了」，凡是读过这台主机
/// 任何一个字段的视图都跟着重算，不管读的是哪个字段、值变没变（Duo 回前台的头 1.4 秒里 22 张卡重算 480 次，
/// 2026-11-16 实测；把读跳板机的那一处挪进子视图也没用）。抄成值以后，主机页照样会被叫醒重算一遍，
/// 卡片按这份值判等，没变就不重算。
struct HostCardInfo: Equatable {
    let name: String
    let endpoint: String
    let monogram: String
    let groupLabel: String
    let authLabel: String
    let isPinned: Bool
    let sftpOnly: Bool
    let lastConnectedAt: Date?
    /// 在线探测的端点；走跳板机 / 没填地址时为 nil，不探也不画角标。
    let reachabilityKey: HostEndpointKey?

    init(_ host: ServerProfile) {
        name = host.name
        endpoint = host.endpointWithPort
        monogram = host.monogram
        groupLabel = host.groupLabel
        authLabel = host.authMethod.label
        isPinned = host.isPinned
        sftpOnly = host.sftpOnly
        lastConnectedAt = host.lastConnectedAt
        reachabilityKey = HostEndpointKey(host)
    }
}

/// 主机卡片（设计稿 `HostCard2`）。点击弹详情抽屉；菜单含连接 / 文件 / 编辑 / 删除。
///
/// 按「字段值 + 组色」判等（闭包不比）：主机页每次重算都给每张卡新建一套闭包，不判等的话每张卡都要跟着重算。
struct HostCard: View, Equatable {
    static func == (lhs: HostCard, rhs: HostCard) -> Bool {
        lhs.info == rhs.info && lhs.groupColor == rhs.groupColor
    }

    let info: HostCardInfo
    var groupColor: Color? = nil
    var onOpen: () -> Void
    var onConnect: () -> Void
    var onSFTP: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    /// 共享格式化器。**别改回「每行现建一个」**——这是逐行调用的。
    private var lastText: String { UTermFormat.relative(info.lastConnectedAt, fallback: String(localized: "从未连接")) }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(info.name).font(M.sans(16, weight: .semibold))
                                .foregroundStyle(M.text).lineLimit(1)
                            if info.isPinned { MIcon(name: "tag", size: 11, color: M.warning) }
                        }
                        Text(info.endpoint)
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
                            .contentShape(.hoverEffect, Circle())
                    }
                    .padding(.vertical, -5).padding(.trailing, -6)   // 命中区 44pt，不撑高卡片头
                    .accessibilityLabel(Text("更多操作"))
                }

                HStack(spacing: 6) {
                    MGroupChip(info.groupLabel, tint: groupColor)
                    MChip(text: info.authLabel, icon: "key", tone: .accent)
                    if info.sftpOnly { MChip(text: String(localized: "仅 SFTP"), icon: "folder") }
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
        .mContextMenu(preview: RoundedRectangle(cornerRadius: MRadius.card)) {
            Button { onConnect() } label: { Label("连接终端", systemImage: "terminal") }
            Button { onSFTP() } label: { Label("浏览文件", systemImage: "folder") }
            Button { onEdit() } label: { Label("编辑", systemImage: "pencil") }
            Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") }
        }
    }

    /// 分组色色块 + 首字母，角标 = 在线状态（见 `HostAvatar`）。
    private var avatar: some View {
        HostAvatar(monogram: info.monogram,
                   tint: groupColor,
                   reachability: info.reachabilityKey.map(HostReachabilityMonitor.shared.entry(for:)))
            .watchesReachability(of: info.reachabilityKey)
    }
}
