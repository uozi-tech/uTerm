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

    // MARK: filtering
    private var query: String { q.trimmingCharacters(in: .whitespaces).lowercased() }
    private func hit(_ s: String) -> Bool { query.isEmpty || s.lowercased().contains(query) }

    private var fHosts: [ServerProfile] {
        hosts.filter { hit($0.name) || hit($0.host) || hit($0.username) || hit($0.group ?? "") }
    }
    private var fCommands: [QuickCommand] {
        commands.filter { hit($0.name) || hit($0.command) || hit($0.intent) }
    }
    private var fKeys: [SSHKey] { keys.filter { hit($0.name) || hit($0.comment) } }
    private var fGroups: [ServerGroup] { groups.filter { hit($0.name) } }
    private var showNewHost: Bool { hit("新建主机") || hit("new host") }
    private var empty: Bool {
        fHosts.isEmpty && fCommands.isEmpty && fKeys.isEmpty && fGroups.isEmpty && !showNewHost
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if empty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if showNewHost {
                            cap("动作")
                            row(icon: "plus", title: "新建主机…", detail: "创建一台新服务器", tinted: true) {
                                close(); store.tab = .hosts; store.requestNewServer = true
                            }
                        }
                        if !fHosts.isEmpty {
                            cap("主机")
                            ForEach(fHosts) { h in
                                row(icon: "server", title: h.name, detail: h.displayEndpoint,
                                    hint: "连接", tinted: true, mono: true) { connect(h) }
                            }
                        }
                        if !fCommands.isEmpty {
                            cap("命令")
                            ForEach(fCommands) { c in
                                row(icon: c.aiAssisted ? "spark" : "bolt",
                                    title: c.name,
                                    detail: c.aiAssisted && !c.intent.isEmpty ? c.intent : c.command) {
                                    close(); store.tab = .commands
                                }
                            }
                        }
                        if !fKeys.isEmpty {
                            cap("密钥")
                            ForEach(fKeys) { k in
                                row(icon: "key", title: k.name, detail: k.typeLabel, mono: true) {
                                    close(); store.tab = .settings
                                }
                            }
                        }
                        if !fGroups.isEmpty {
                            cap("分组")
                            ForEach(fGroups) { g in
                                row(icon: "tag", title: g.name, detail: "\(memberCount(g.name)) 台主机") {
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
        .background(M.bg)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { focused = true } }
    }

    // MARK: pieces
    private var header: some View {
        HStack(spacing: 10) {
            MIcon(name: "search", size: 18, color: M.text3)
            TextField("搜索主机、命令、密钥、分组…", text: $q)
                .focused($focused)
                .font(M.sans(17)).foregroundStyle(M.text)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { if let h = fHosts.first { connect(h) } }
            Button("取消") { close() }
                .font(M.sans(15, weight: .medium)).foregroundStyle(accent)
        }
        .padding(.horizontal, 16).frame(height: 52)
        .background(M.overlayHi)
        .overlay(alignment: .bottom) { Rectangle().fill(M.border).frame(height: 1) }
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
            .foregroundStyle(M.text4)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 5)
    }

    private func row(icon: String, title: String, detail: String, hint: String = "",
                     tinted: Bool = false, mono: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                MIcon(name: icon, size: 16, color: tinted ? accent : M.text2)
                    .frame(width: 32, height: 32)
                    .background(tinted ? accent.opacity(0.1) : M.fillFaint)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(tinted ? accent.opacity(0.2) : M.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    highlight(title).font(M.sans(15)).foregroundStyle(M.text).lineLimit(1)
                    Text(detail).font(mono ? M.mono(12.5) : M.sans(12.5))
                        .foregroundStyle(M.text4).lineLimit(1)
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
    private func memberCount(_ name: String) -> Int { hosts.filter { $0.group == name }.count }
    private func connect(_ h: ServerProfile) { close(); store.openTerminal(h) }
    private func close() { store.showPalette = false }
}
