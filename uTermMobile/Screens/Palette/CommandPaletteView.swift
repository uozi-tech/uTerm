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
    @FocusState private var focused: Bool
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

        return VStack(spacing: 0) {
            header(results: r)
            if r.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if r.showNewHost {
                            cap("动作")
                            row(icon: "plus", title: "新建主机…", detail: "创建一台新服务器", tinted: true) {
                                close(); store.tab = .hosts; store.requestNewServer = true
                            }
                        }
                        if !r.hosts.isEmpty {
                            cap("主机")
                            ForEach(r.hosts) { h in
                                row(icon: "server", title: h.name, detail: h.displayEndpoint,
                                    hint: "连接", tinted: true, mono: true) { connect(h) }
                            }
                        }
                        if !r.commands.isEmpty {
                            cap("命令")
                            ForEach(r.commands) { c in
                                row(icon: c.aiAssisted ? "spark" : "bolt",
                                    title: c.name,
                                    detail: c.aiAssisted && !c.intent.isEmpty ? c.intent : c.command) {
                                    close(); store.tab = .commands
                                }
                            }
                        }
                        if !r.keys.isEmpty {
                            cap("密钥")
                            ForEach(r.keys) { k in
                                row(icon: "key", title: k.name, detail: k.typeLabel, mono: true) {
                                    close(); store.tab = .settings
                                }
                            }
                        }
                        if !r.groups.isEmpty {
                            cap("分组")
                            ForEach(r.groups) { g in
                                row(icon: "tag", title: g.name, detail: "\(g.members) 台主机") {
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
        // 整屏一个工作面：搜索头与结果同底色，只靠 hairline 分区。
        .background(M.surface)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { focused = true } }
    }

    // MARK: pieces
    private func header(results: PaletteResults) -> some View {
        HStack(spacing: 10) {
            MIcon(name: "search", size: 18, color: M.text3)
            TextField("搜索主机、命令、密钥、分组…", text: $q)
                .focused($focused)
                .font(M.sans(17)).foregroundStyle(M.text)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { if let h = results.hosts.first { connect(h) } }
            Button("取消") { close() }
                .font(M.sans(15, weight: .medium)).foregroundStyle(accent)
        }
        .padding(.horizontal, 16).frame(height: 52)
        .mTopClearance(0)
        .mReadableColumn()
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("没有匹配「\(q)」的结果").font(M.sans(15)).foregroundStyle(M.text3)
            Text("试试 host、md、密钥").font(M.mono(12.5)).foregroundStyle(M.text4)
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
                    .clipShape(RoundedRectangle(cornerRadius: 9))
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
        .clipShape(RoundedRectangle(cornerRadius: 11))
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
        out.showNewHost = hit("新建主机") || hit("new host")
        return out
    }
}
