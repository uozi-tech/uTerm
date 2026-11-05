import UDesignKit
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
            // 与「主机 / 终端 / 文件 / 设置」四个标签同一套大标题页头（MScreen）：此前这里是系统
            // 内联导航栏 + 「快捷命令」小标题，五个标签里唯独它换了一种页头。
            MScreen(title: "命令", sub: commands.isEmpty ? nil : "\(commands.count) 条快捷命令",
                    maxContentWidth: M.gridContentWidth, embedsNavigationStack: false, pinsHeader: true, actions: {
                MRoundBtn(icon: "plus", filled: true) { creating = true }
                    .accessibilityLabel(Text("新建命令"))
            }) {
                if commands.isEmpty {
                    MEmptyState(icon: "bolt", title: "还没有快捷命令",
                                message: "把常用运维命令存成可复用条目，绑定主机一键执行。",
                                actionTitle: "新建命令", action: { creating = true })
                } else {
                    MCardGrid {
                        ForEach(commands) { cmd in
                            NavigationLink { QuickCommandDetailView(cmd: cmd) } label: {
                                CommandCard(cmd: cmd)
                            }.buttonStyle(MPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }
            }
            .sheet(isPresented: $creating) { CommandFormSheet(cmd: nil).mSheetContentMargins() }
        }
    }
}

struct CommandCard: View {
    let cmd: QuickCommand
    @Environment(\.mAccent) private var accent
    @Environment(\.mCardGridColumns) private var gridColumns

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
                    // 多列时预留两行，同一行的卡片才一样高；单列时按实际行数收起。
                    .lineLimit(2, reservesSpace: gridColumns > 1).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    MChip(text: "\(cmd.serverIDs.count) 台主机", icon: "server")
                    if cmd.runCount > 0 { MChip(text: "运行 \(cmd.runCount) 次") }
                    Spacer()
                }
            }
            .padding(14)
            .background(M.card)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.card))
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

    /// 与 macOS 表单同一套校验：名称非空、至少一台主机，AI 命令有意图或命令其一即可。
    private var valid: Bool {
        QuickCommandLogic.isSaveable(name: name, hasServers: !orderedSelection.isEmpty,
                                     command: command, intent: intent, ai: ai)
    }
    /// 按可选主机顺序收口（剔除已删除 / 仅 SFTP），对齐 macOS `orderedSelection`。
    private var orderedSelection: [UUID] {
        hosts.filter { !$0.sftpOnly && serverIDs.contains($0.id) }.map(\.id)
    }
    private func toggle(_ id: UUID) {
        if serverIDs.contains(id) { serverIDs.remove(id) } else { serverIDs.insert(id) }
    }

    // MARK: 关联主机（分组 + 全组选择，对齐 macOS QuickCommandForm）

    /// 关联主机区一次求值的全部派生量。
    ///
    /// 改前这里是 `selectableHosts` / `grouped` / `groupColorHexes` /
    /// `selectedVisibleCount` / `allSelected` 五个计算属性，互相还套着
    /// （`grouped` 里再走一遍 `selectableHosts`）；`hostSection` 一次 body 就要
    /// 各求好几遍，而 `groupHeader` 又**逐组**重建整张 `groupColorHexes`、
    /// 逐组再扫一遍成员算 `picked`（`groupState` 一遍、显示用的 `picked` 又一遍）。
    /// `serverIDs` 是 `@State`，**每点一台主机整个 body 就重跑一次**。
    private struct HostSelection {
        var selectable: [ServerProfile] = []
        var sections: [(name: String, hosts: [ServerProfile])] = []
        var groupColors: [String: Color] = [:]
        /// 组名 → 该组已选台数。
        var pickedByGroup: [String: Int] = [:]
        var pickedTotal = 0
        var allSelected: Bool { !selectable.isEmpty && pickedTotal == selectable.count }
    }

    /// 一趟算出上面那一整包。三次遍历（筛可选 / 归组 / 数已选），不再是嵌套的 O(组 × 主机)。
    private var selection: HostSelection {
        var out = HostSelection()
        out.selectable = hosts.filter { !$0.sftpOnly }
        out.sections = ServerGrouping.grouped(out.selectable)
        out.groupColors = MGroupTint.colors(for: groups)
        for sec in out.sections {
            var picked = 0
            for h in sec.hosts where serverIDs.contains(h.id) { picked += 1 }
            out.pickedByGroup[sec.name] = picked
            out.pickedTotal += picked
        }
        return out
    }

    private func toggleGroup(_ gHosts: [ServerProfile], all: Bool) {
        let ids = gHosts.map(\.id)
        if all { ids.forEach { serverIDs.remove($0) } } else { ids.forEach { serverIDs.insert($0) } }
    }

    private var hostSection: some View {
        let sel = selection
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("关联主机".uppercased())
                    .font(M.sans(12, weight: .semibold)).tracking(0.4).foregroundStyle(M.text4)
                Spacer()
                if !sel.selectable.isEmpty {
                    Text("\(sel.pickedTotal)/\(sel.selectable.count) 台")
                        .font(M.mono(11)).foregroundStyle(M.text4)
                    Button {
                        if sel.allSelected { sel.selectable.forEach { serverIDs.remove($0.id) } }
                        else { sel.selectable.forEach { serverIDs.insert($0.id) } }
                    } label: {
                        Text(sel.allSelected ? "清空" : "全选")
                            .font(M.sans(12, weight: .medium)).foregroundStyle(M.text2)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(M.fillFaint)
                            .clipShape(RoundedRectangle(cornerRadius: MRadius.sm, style: .continuous))
                    }.buttonStyle(MPressStyle())
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 7)

            // 容器仍是非 lazy 的 `VStack`：桌面那轮的反例摆着——小规模档换懒栈反而更慢，
            // 而这里的规模就是「一台机器上的主机数」。要换得先有读数。
            VStack(spacing: 0) {
                if sel.selectable.isEmpty {
                    Text(hosts.isEmpty ? "暂无主机" : "暂无可用主机").font(M.sans(14)).foregroundStyle(M.text4)
                        .frame(maxWidth: .infinity, minHeight: 50)
                } else {
                    ForEach(Array(sel.sections.enumerated()), id: \.element.name) { gi, sec in
                        groupHeader(sec.name, hosts: sec.hosts,
                                    picked: sel.pickedByGroup[sec.name] ?? 0,
                                    groupColors: sel.groupColors)
                        ForEach(Array(sec.hosts.enumerated()), id: \.element.id) { hi, h in
                            hostRow(h, last: gi == sel.sections.count - 1 && hi == sec.hosts.count - 1)
                        }
                    }
                }
            }
            .background(M.card)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.list))
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 22)
    }

    private func groupHeader(_ name: String, hosts gHosts: [ServerProfile],
                             picked: Int, groupColors: [String: Color]) -> some View {
        // 三态由上面那一趟数出来的 `picked` 直接推，不再逐组重扫成员。
        let all = !gHosts.isEmpty && picked == gHosts.count
        let some = picked > 0
        let tint = MGroupTint.color(for: name == ServerGrouping.ungroupedLabel ? nil : name,
                                    colors: groupColors)
        return Button { toggleGroup(gHosts, all: all) } label: {
            HStack(spacing: 10) {
                MGroupCheck(on: all, partial: some && !all)
                MDot(color: tint ?? M.text4, size: 7)
                Text(name.uppercased())
                    .font(M.sans(11.5, weight: .semibold)).tracking(0.4).foregroundStyle(M.text3).lineLimit(1)
                Text("\(picked)/\(gHosts.count)").font(M.mono(11)).foregroundStyle(M.text4)
                Spacer(minLength: 6)
                Text(all ? "取消整组" : "选择整组")
                    .font(M.sans(11.5)).foregroundStyle(some ? M.accent : M.text4)
            }
            .padding(.horizontal, 14).padding(.vertical, 9).frame(minHeight: 44)
            .background(UD.fillSoft)   // 容器已是卡片面，组头再深一档区分
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { MRowDivider() }
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
                if !last { MRowDivider(inset: 46) }
            }
        }.buttonStyle(MRowStyle())
    }

    private func load() {
        guard let cmd else { return }
        name = cmd.name; command = cmd.command; intent = cmd.intent
        ai = cmd.aiAssisted
        // 仅保留仍可选的绑定（剔除已删除 / 现为仅 SFTP 的悬空 id），否则三态 / 全选计数对不上。
        // 对齐 macOS `QuickCommandForm` 的 seed 过滤。
        let selectableIDs = Set(hosts.lazy.filter { !$0.sftpOnly }.map(\.id))
        serverIDs = Set(cmd.serverIDs).intersection(selectableIDs)
    }
    private func save() {
        let store = QuickCommandStore(context: context)
        if let cmd {
            store.update(cmd, name: name, serverIDs: orderedSelection, command: command,
                         intent: intent, aiAssisted: ai)
        } else {
            store.create(name: name, serverIDs: orderedSelection, command: command,
                         intent: intent, aiAssisted: ai)
        }
        dismiss()
    }
}

// MARK: - 勾选件（对齐 macOS QCCheckbox / QCGroupCheck）

/// 单台复选框：选中 = accent 填充 + 白勾；未选 = 中灰填充，不描边（v2）。
private struct MCheckbox: View {
    let checked: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: MRadius.xs, style: .continuous)
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
        RoundedRectangle(cornerRadius: MRadius.xs, style: .continuous)
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
