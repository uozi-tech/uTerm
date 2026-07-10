import SwiftUI
import SwiftData

/// 快捷命令列表（真实 `QuickCommand`）。展示等效命令 / AI 介入徽标 / 关联主机数；可新增、编辑、删除。
struct CommandsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.mAccent) private var accent
    @Query(sort: [SortDescriptor(\QuickCommand.sortOrder)]) private var commands: [QuickCommand]
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Group {
                if commands.isEmpty {
                    MEmptyState(icon: "bolt", title: "还没有快捷命令",
                                message: "把常用运维命令存成可复用条目，绑定主机一键执行。",
                                actionTitle: "新建命令", action: { creating = true })
                } else {
                    ScrollView {
                        MCardList {
                            ForEach(commands) { cmd in
                                NavigationLink { QuickCommandDetailView(cmd: cmd) } label: {
                                    CommandCard(cmd: cmd)
                                }.buttonStyle(MPressStyle())
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.top, 12)
                        .mReadableColumn()
                    }
                }
            }
            .background(M.canvas)
            .navigationTitle("快捷命令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { MIcon(name: "plus", size: 18, color: accent) }
                }
            }
            .sheet(isPresented: $creating) { CommandFormSheet(cmd: nil) }
        }
    }
}

struct CommandCard: View {
    let cmd: QuickCommand
    @Environment(\.mAccent) private var accent

    var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(cmd.name).font(M.sans(15.5, weight: .semibold)).foregroundStyle(M.text).lineLimit(1)
                    if cmd.aiAssisted { MChip(text: "AI 介入", icon: "spark", tone: .accent) }
                    Spacer()
                    MIcon(name: "chev", size: 14, color: M.text4, weight: .semibold)
                }
                Text(cmd.aiAssisted && !cmd.intent.isEmpty ? cmd.intent : cmd.command)
                    .font(M.mono(12.5)).foregroundStyle(M.text3)
                    .lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    MChip(text: "\(cmd.serverIDs.count) 台主机", icon: "server")
                    if cmd.runCount > 0 { MChip(text: "运行 \(cmd.runCount) 次") }
                    Spacer()
                }
            }
            .padding(14)
            .background(M.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .udShadow(.card)
    }
}

struct CommandFormSheet: View {
    let cmd: QuickCommand?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]
    @Query(sort: [SortDescriptor(\ServerGroup.sortOrder)]) private var groups: [ServerGroup]

    @State private var name = ""
    @State private var command = ""
    @State private var intent = ""
    @State private var ai = false
    @State private var serverIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    MInsetGroup(header: "名称") {
                        TextField("命令名称", text: $name).font(M.sans(15)).foregroundStyle(M.text)
                            .autocorrectionDisabled().textInputAutocapitalization(.sentences)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                    }

                    MInsetGroup(header: "AI 介入") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("让 AI 自动执行").font(M.sans(15)).foregroundStyle(M.text)
                                Text("用自然语言描述目标，由 Agent 决策").font(M.sans(12)).foregroundStyle(M.text3)
                            }
                            Spacer()
                            MSwitch(on: $ai)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MSectionCap(text: ai ? "AI 指令（自然语言）" : "Shell 命令").padding(.horizontal, 20)
                        MTextArea(text: ai ? $intent : $command,
                                  placeholder: ai ? "如：重启 Nginx 并健康检查 /healthz" : "sudo systemctl restart nginx")
                            .padding(.horizontal, 16)
                    }

                    hostSection
                }
                .padding(.vertical, 12)
                .mReadableColumn()
            }
            .background(M.canvas)
            .navigationTitle(cmd == nil ? "新建命令" : "编辑命令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!valid).fontWeight(.semibold)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !(ai ? intent : command).trimmingCharacters(in: .whitespaces).isEmpty
    }
    private func toggle(_ id: UUID) {
        if serverIDs.contains(id) { serverIDs.remove(id) } else { serverIDs.insert(id) }
    }

    // MARK: 关联主机（分组 + 全组选择，对齐 macOS QuickCommandForm）

    /// 可关联的主机：剔除「仅 SFTP」的主机（无法执行命令），对齐 macOS `QuickCommandList.hostRefs`。
    private var selectableHosts: [ServerProfile] { hosts.filter { !$0.sftpOnly } }
    /// 按分组保序归类（首次出现顺序，空 → 「未分组」），对齐 `HostsScreen.grouped`。
    private var grouped: [(name: String, hosts: [ServerProfile])] {
        var order: [String] = []
        var map: [String: [ServerProfile]] = [:]
        for h in selectableHosts {
            let g = (h.group?.isEmpty == false ? h.group! : "未分组")
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(h)
        }
        return order.map { (name: $0, hosts: map[$0] ?? []) }
    }
    /// 组名 → colorHex 映射（对齐 macOS `ServerList.groupColorHexes`）。
    private var groupColorHexes: [String: String] {
        Dictionary(groups.map { ($0.name, $0.colorHex) }, uniquingKeysWith: { a, _ in a })
    }
    /// 可选主机里已选的台数（不含已删除 / 仅 SFTP 主机的悬空 id）。
    private var selectedVisibleCount: Int { selectableHosts.filter { serverIDs.contains($0.id) }.count }
    /// 全部可选主机均已选。
    private var allSelected: Bool { !selectableHosts.isEmpty && selectableHosts.allSatisfy { serverIDs.contains($0.id) } }

    /// 某组三态：`all`（整组都已选）/ `some`（部分已选，含全选）。
    private func groupState(_ gHosts: [ServerProfile]) -> (all: Bool, some: Bool) {
        guard !gHosts.isEmpty else { return (false, false) }
        let picked = gHosts.filter { serverIDs.contains($0.id) }.count
        return (picked == gHosts.count, picked > 0)
    }
    private func toggleGroup(_ gHosts: [ServerProfile], all: Bool) {
        let ids = gHosts.map(\.id)
        if all { ids.forEach { serverIDs.remove($0) } } else { ids.forEach { serverIDs.insert($0) } }
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("关联主机".uppercased())
                    .font(M.sans(12, weight: .semibold)).tracking(0.4).foregroundStyle(M.text4)
                Spacer()
                if !selectableHosts.isEmpty {
                    Text("\(selectedVisibleCount)/\(selectableHosts.count) 台")
                        .font(M.mono(11)).foregroundStyle(M.text4)
                    Button {
                        if allSelected { selectableHosts.forEach { serverIDs.remove($0.id) } }
                        else { selectableHosts.forEach { serverIDs.insert($0.id) } }
                    } label: {
                        Text(allSelected ? "清空" : "全选")
                            .font(M.sans(12, weight: .medium)).foregroundStyle(M.text2)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(M.fillFaint)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }.buttonStyle(MPressStyle())
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 7)

            VStack(spacing: 0) {
                if selectableHosts.isEmpty {
                    Text(hosts.isEmpty ? "暂无主机" : "暂无可用主机").font(M.sans(14)).foregroundStyle(M.text4)
                        .frame(maxWidth: .infinity, minHeight: 50)
                } else {
                    ForEach(Array(grouped.enumerated()), id: \.element.name) { gi, sec in
                        groupHeader(sec.name, hosts: sec.hosts)
                        ForEach(Array(sec.hosts.enumerated()), id: \.element.id) { hi, h in
                            hostRow(h, last: gi == grouped.count - 1 && hi == sec.hosts.count - 1)
                        }
                    }
                }
            }
            .background(M.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .udShadow(.card)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 22)
    }

    private func groupHeader(_ name: String, hosts gHosts: [ServerProfile]) -> some View {
        let st = groupState(gHosts)
        let picked = gHosts.filter { serverIDs.contains($0.id) }.count
        let tint = MGroupTint.color(for: name == "未分组" ? nil : name, in: groupColorHexes)
        return Button { toggleGroup(gHosts, all: st.all) } label: {
            HStack(spacing: 10) {
                MGroupCheck(on: st.all, partial: st.some && !st.all)
                MDot(color: tint ?? M.text4, size: 7)
                Text(name.uppercased())
                    .font(M.sans(11.5, weight: .semibold)).tracking(0.4).foregroundStyle(M.text3).lineLimit(1)
                Text("\(picked)/\(gHosts.count)").font(M.mono(11)).foregroundStyle(M.text4)
                Spacer(minLength: 6)
                Text(st.all ? "取消整组" : "选择整组")
                    .font(M.sans(11.5)).foregroundStyle(st.some ? M.accent : M.text4)
            }
            .padding(.horizontal, 14).padding(.vertical, 9).frame(minHeight: 44)
            .background(UD.fillSoft)   // 容器已是卡片面，组头再深一档区分
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1).padding(.leading, 14) }
        }.buttonStyle(MRowStyle())
    }

    private func hostRow(_ h: ServerProfile, last: Bool) -> some View {
        let on = serverIDs.contains(h.id)
        return Button { toggle(h.id) } label: {
            HStack(spacing: 11) {
                MCheckbox(checked: on)
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.name.isEmpty ? h.host : h.name)
                        .font(M.sans(14.5, weight: .medium)).foregroundStyle(M.text).lineLimit(1)
                    Text(h.displayEndpoint)
                        .font(M.mono(11.5)).foregroundStyle(M.text4).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
            }
            .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 9)
            .frame(minHeight: 50)
            .background(on ? M.accent.opacity(0.12) : .clear)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(M.divider).frame(height: 1).padding(.leading, 16) }
            }
        }.buttonStyle(MRowStyle())
    }

    private func load() {
        guard let cmd else { return }
        name = cmd.name; command = cmd.command; intent = cmd.intent
        ai = cmd.aiAssisted
        // 仅保留仍可选的绑定（剔除已删除 / 现为仅 SFTP 的悬空 id），否则三态 / 全选计数对不上。
        // 对齐 macOS `QuickCommandForm` 的 seed 过滤。
        let selectableIDs = Set(selectableHosts.map(\.id))
        serverIDs = Set(cmd.serverIDs).intersection(selectableIDs)
    }
    private func save() {
        let c = cmd ?? QuickCommand()
        c.name = name.trimmingCharacters(in: .whitespaces)
        c.command = command; c.intent = intent; c.aiAssisted = ai
        // 按可选主机顺序收口（剔除已删除 / 仅 SFTP），对齐 macOS `orderedSelection`。
        c.serverIDs = selectableHosts.filter { serverIDs.contains($0.id) }.map(\.id)
        if cmd == nil {
            c.sortOrder = ((try? context.fetch(FetchDescriptor<QuickCommand>()))?.map(\.sortOrder).max() ?? -1) + 1
            context.insert(c)
        }
        try? context.save()
        dismiss()
    }
}

// MARK: - 勾选件（对齐 macOS QCCheckbox / QCGroupCheck）

/// 单台复选框：选中 = accent 填充 + 白勾；未选 = 中灰填充，不描边（v2）。
private struct MCheckbox: View {
    let checked: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(checked ? M.accent : M.fillMed)
            .overlay { if checked { MIcon(name: "check", size: 10, color: .white, weight: .bold) } }
            .frame(width: 19, height: 19)
    }
}

/// 分组三态勾选：全选 = 勾 / 半选 = 横线 / 未选 = 空。
private struct MGroupCheck: View {
    let on: Bool
    let partial: Bool
    private var active: Bool { on || partial }
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(active ? M.accent : M.fillMed)
            .overlay {
                if on {
                    MIcon(name: "check", size: 10, color: .white, weight: .bold)
                } else if partial {
                    Capsule().fill(.white).frame(width: 9, height: 2)
                }
            }
            .frame(width: 19, height: 19)
    }
}
