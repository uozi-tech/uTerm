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
                        VStack(spacing: 10) {
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
            .background(M.bg)
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
            .background(M.panel)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(M.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct CommandFormSheet: View {
    let cmd: QuickCommand?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]

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

                    MInsetGroup(header: "关联主机") {
                        if hosts.isEmpty {
                            MInsetRow(label: "暂无主机", last: true)
                        } else {
                            ForEach(Array(hosts.enumerated()), id: \.element.id) { idx, h in
                                let check: AnyView? = serverIDs.contains(h.id)
                                    ? AnyView(MIcon(name: "check", size: 15, color: M.accent)) : nil
                                MInsetRow(icon: "server", label: h.name, sub: h.displayEndpoint,
                                          last: idx == hosts.count - 1, trailing: check,
                                          onTap: { toggle(h.id) })
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
                .mReadableColumn()
            }
            .background(M.bg)
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
    private func load() {
        guard let cmd else { return }
        name = cmd.name; command = cmd.command; intent = cmd.intent
        ai = cmd.aiAssisted; serverIDs = Set(cmd.serverIDs)
    }
    private func save() {
        let c = cmd ?? QuickCommand()
        c.name = name.trimmingCharacters(in: .whitespaces)
        c.command = command; c.intent = intent; c.aiAssisted = ai
        c.serverIDs = Array(serverIDs)
        if cmd == nil {
            c.sortOrder = ((try? context.fetch(FetchDescriptor<QuickCommand>()))?.map(\.sortOrder).max() ?? -1) + 1
            context.insert(c)
        }
        try? context.save()
        dismiss()
    }
}
