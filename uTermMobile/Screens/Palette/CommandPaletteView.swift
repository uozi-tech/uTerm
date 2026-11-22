import SwiftUI
import SwiftData

/// 命令面板（设计稿 `CommandPalette` / ⌘K）：跨主机 / 命令 / 密钥 / 分组的全局搜索。
/// 由根视图通过 `store.showPalette` 以全屏覆盖呈现，覆盖所有标签。
struct CommandPaletteView: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.mAccent) private var accent

    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]
    @Query(sort: [SortDescriptor(\QuickCommand.sortOrder)]) private var commands: [QuickCommand]
    @Query(sort: [SortDescriptor(\SSHKey.createdAt, order: .reverse)]) private var keys: [SSHKey]
    @Query(sort: [SortDescriptor(\ServerGroup.sortOrder)]) private var groups: [ServerGroup]

    @State private var q = ""
    /// 系统搜索栏是否处于激活态（激活 = 聚焦 + 弹键盘）。打开面板时置 true 自动聚焦；
    /// 用户点搜索栏的「取消」退出激活 = 关面板（与改前自绘头的「取消」一致）。
    @State private var searching = false
    /// 派生结果的记忆盒（见 `PaletteMemo`）。`@State` 里放引用类型：改它的
    /// 字段不会触发 SwiftUI 失效，正是缓存要的语义。
    @State private var memo = PaletteMemo()

    // MARK: filtering
    private var query: String { q.trimmingCharacters(in: .whitespaces).lowercased() }

    var body: some View {
        // **一次求值，往下传。**
        //
        // 改前这里是 `fHosts` / `fCommands` / `fKeys` / `fGroups` 四个计算属性
        // 外加 `empty`：`empty` 里把四个各求一遍，body 里 `if !fHosts.isEmpty` +
        // `ForEach(fHosts)` 又各求一遍 —— **每一次击键至少八趟四张表的 filter**，
        // 而 `TextField` 的每次输入都会让 body 重跑（还常常不止一次）。
        // 分组那一行的 `memberCount(_:)` 更是 O(分组 × 主机)。
        let r = memo.results(query: query, hosts: hosts, commands: commands,
                             keys: keys, groups: groups)

        return NavigationStack {
            VStack(spacing: 0) {
                if r.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if r.showNewHost {
                                cap(String(localized: "动作", comment: "命令面板分组：操作"))
                                row(icon: "plus", title: String(localized: "新建主机…"), detail: String(localized: "添加一台 SSH 主机"), tinted: true) {
                                    close(); store.tab = .hosts; store.requestNewServer = true
                                }
                            }
                            if !r.hosts.isEmpty {
                                cap(String(localized: "主机", comment: "命令面板分组"))
                                ForEach(r.hosts) { h in
                                    row(icon: "server", title: h.name, detail: h.displayEndpoint,
                                        hint: String(localized: "连接", comment: "命令面板：连接这台主机"), tinted: true, mono: true) { connect(h) }
                                }
                            }
                            if !r.commands.isEmpty {
                                cap(String(localized: "命令", comment: "命令面板分组：快捷命令"))
                                ForEach(r.commands) { c in
                                    row(icon: c.aiAssisted ? "spark" : "bolt",
                                        title: c.name,
                                        detail: c.aiAssisted && !c.intent.isEmpty ? c.intent : c.command) {
                                        close(); store.tab = .commands
                                    }
                                }
                            }
                            if !r.keys.isEmpty {
                                cap(String(localized: "密钥", comment: "命令面板分组：SSH 密钥"))
                                ForEach(r.keys) { k in
                                    row(icon: "key", title: k.name, detail: k.typeLabel, mono: true) {
                                        close(); store.tab = .settings
                                    }
                                }
                            }
                            if !r.groups.isEmpty {
                                cap(String(localized: "分组", comment: "命令面板分组：主机分组"))
                                ForEach(r.groups) { g in
                                    row(icon: "tag", title: g.name, detail: String(localized: "\(g.members) 台主机")) {
                                        close(); store.tab = .settings
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 24)
                        .mReadableColumn()
                    }
                }
            }
            // 整屏一个工作面：导航栏 / 搜索栏与结果同底色。
            .background(M.surface)
            .navigationTitle("命令面板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(M.surface, for: .navigationBar)
            .toolbar {
                // 搜索激活时搜索栏自带「取消」（点它即关面板），这里收起，免得 iPhone Duo 侧边列
                // 与搜索栏各一个 ×。只在搜索未激活（打开动画那一下、或激活失败）时兜底。
                if !searching {
                    ToolbarItem(placement: .topBarLeading) {
                        MToolbarCloseButton(action: close)
                    }
                }
            }
            // 系统搜索栏（导航栏下方的抽屉位，常显）：宽控件，iPhone Duo 上留在原位；
            // 关闭钮是标准工具栏项，随系统挪到侧边列。
            .searchable(text: $q, isPresented: $searching,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("搜索主机、命令、密钥、分组…"))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search) { if let h = r.hosts.first { connect(h) } }
            // 退出搜索（点搜索栏「取消」）即关面板。只认「激活 → 未激活」这一跳，首帧的 false 不算。
            .onChange(of: searching) { was, now in if was && !now { close() } }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { searching = true } }
    }

    // MARK: pieces
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("没有匹配「\(q)」的结果").font(M.sans(15)).foregroundStyle(M.text3)
            Text("试试主机名、命令名或密钥名").font(M.mono(12.5)).foregroundStyle(M.text4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 80)
    }

    private func cap(_ text: String) -> some View {
        Text(text.uppercased()).font(M.sans(11, weight: .semibold)).tracking(0.6)
            .foregroundStyle(M.text3)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 5)
    }

    private func row(icon: String, title: String, detail: String, hint: String = "",
                     tinted: Bool = false, mono: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                MIcon(name: icon, size: 16, color: tinted ? accent : M.text2)
                    .frame(width: 32, height: 32)
                    .background(tinted ? accent.opacity(0.14) : M.button)
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    highlight(title).font(M.sans(15)).foregroundStyle(M.text).lineLimit(1)
                    Text(detail).font(mono ? M.mono(12.5) : M.sans(12.5))
                        .foregroundStyle(M.text3).lineLimit(1)
                }
                Spacer(minLength: 6)
                if !hint.isEmpty { Text(hint).font(M.sans(12)).foregroundStyle(M.text3) }
                MIcon(name: "chev", size: 13, color: M.text4, weight: .semibold)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(MRowStyle())
        // 按压高亮与行内图标块同心：图标块距行上下边 9pt
        .clipShape(RoundedRectangle(cornerRadius: MRadius.concentric(MRadius.sm, inset: 9)))
    }

    /// 标题里匹配子串高亮（设计稿 `Hi`）。
    private func highlight(_ text: String) -> Text {
        guard !query.isEmpty, let r = text.range(of: q.trimmingCharacters(in: .whitespaces),
                                                 options: .caseInsensitive) else {
            return Text(text)
        }
        return Text(String(text[text.startIndex..<r.lowerBound]))
            + Text(String(text[r])).foregroundColor(accent).bold()
            + Text(String(text[r.upperBound...]))
    }

    // MARK: actions
    private func connect(_ h: ServerProfile) { close(); store.openTerminal(h) }
    private func close() { store.showPalette = false }
}

// MARK: - 派生结果

/// 面板一次求值的全部结果。
struct PaletteResults {
    var hosts: [ServerProfile] = []
    var commands: [QuickCommand] = []
    var keys: [SSHKey] = []
    var groups: [PaletteGroupHit] = []
    var showNewHost = false

    var isEmpty: Bool {
        hosts.isEmpty && commands.isEmpty && keys.isEmpty && groups.isEmpty && !showNewHost
    }
}

/// 分组命中：把「台数」和组名一起带出来，行体不必再去扫主机表。
struct PaletteGroupHit: Identifiable {
    let id: PersistentIdentifier
    let name: String
    let members: Int
}

/// 面板派生结果的记忆盒。
///
/// **为什么这里敢缓存、`HostsScreen` 不敢**：面板是个只读的全屏覆盖层，
/// 打开期间没有任何编辑入口，四张表只可能在打开 / 关闭之间变。所以
/// 「query + 四张表的条数」这个 O(1) 签名足够；而主机列表的编辑表单
/// 恰恰能在不改条数的前提下改分组名，那里就不能这么缓存。
///
/// 缓存要挡的是 SwiftUI 一次击键往往重跑好几遍 body 的开销。
///
/// 隔离靠 target 的 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（整个
/// `uTermMobile` 都是），这里不必再标。
final class PaletteMemo {
    private var key: Key?
    private var cached = PaletteResults()

    private struct Key: Equatable {
        let query: String
        let hosts: Int
        let commands: Int
        let keys: Int
        let groups: Int
    }

    func results(query: String,
                 hosts: [ServerProfile], commands: [QuickCommand],
                 keys: [SSHKey], groups: [ServerGroup]) -> PaletteResults {
        let k = Key(query: query, hosts: hosts.count, commands: commands.count,
                    keys: keys.count, groups: groups.count)
        if k == key { return cached }
        let out = Self.compute(query: query, hosts: hosts, commands: commands,
                               keys: keys, groups: groups)
        key = k
        cached = out
        return out
    }

    /// 四张表各扫**一遍**；分组的「台数」复用共享的一趟过实现
    /// （改前是 `hosts.filter { $0.group == name }.count`，逐组扫全表）。
    private static func compute(query: String,
                                hosts: [ServerProfile], commands: [QuickCommand],
                                keys: [SSHKey], groups: [ServerGroup]) -> PaletteResults {
        func hit(_ s: String) -> Bool { query.isEmpty || s.lowercased().contains(query) }

        var out = PaletteResults()
        out.hosts = hosts.filter { hit($0.name) || hit($0.host) || hit($0.username) || hit($0.group ?? "") }
        out.commands = commands.filter { hit($0.name) || hit($0.command) || hit($0.intent) }
        out.keys = keys.filter { hit($0.name) || hit($0.comment) }
        let hitGroups = groups.filter { hit($0.name) }
        if !hitGroups.isEmpty {
            let counts = ServerGrouping.memberCounts(hosts)
            out.groups = hitGroups.map {
                PaletteGroupHit(id: $0.persistentModelID, name: $0.name,
                                members: counts[$0.name] ?? 0)
            }
        }
        out.showNewHost = hit(String(localized: "新建主机")) || hit("新建主机") || hit("new host")
        return out
    }
}
