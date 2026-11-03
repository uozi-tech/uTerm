import UDesignKit
import SwiftUI
import SwiftData

/// 分组管理（真实 `ServerGroup`）。列表 + 新建；点进详情管理成员 / 颜色 / 改名 / 删除。
struct GroupsScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\ServerGroup.sortOrder)]) private var groups: [ServerGroup]
    @Query private var hosts: [ServerProfile]
    @State private var creating = false

    var body: some View {
        // 「组名 → 台数」一趟过。改前是 `hosts.filter { $0.group == name }.count`
        // 逐组各扫一遍全表，而且**扫两遍**——列表里每行一次，页脚的
        // `groups.reduce` 里再来一次，合计 O(2 × 分组 × 主机)。
        let counts = ServerGrouping.memberCounts(hosts)
        // 页脚总数仍按 `ServerGroup` 表汇总（组名对不上的悬空 group 不计），与改前一致。
        let total = groups.reduce(0) { $0 + (counts[$1.name] ?? 0) }

        return Group {
            if groups.isEmpty {
                MEmptyState(icon: "folder-tag", title: "还没有分组",
                            message: "把主机按环境（prod / dev）或项目归类，列表更清爽。",
                            actionTitle: "新建分组", action: { creating = true })
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        MInsetGroup {
                            ForEach(Array(groups.enumerated()), id: \.element.persistentModelID) { idx, g in
                                NavigationLink { GroupDetailView(group: g) } label: {
                                    MInsetRow(label: g.name, value: "\(counts[g.name] ?? 0) 台", chevron: true,
                                              last: idx == groups.count - 1,
                                              trailing: AnyView(Circle().fill(g.color).frame(width: 14, height: 14)
                                                .overlay(Circle().stroke(M.border, lineWidth: 1))))
                                }.buttonStyle(MRowStyle())
                            }
                        }
                        Text("\(groups.count) 个分组 · \(UFormat.count(total)) 台主机")
                            .font(M.sans(12)).foregroundStyle(M.text4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22).padding(.top, 2)
                    }
                    .padding(.top, 12)
                    .mReadableColumn()
                }
            }
        }
        .background(M.canvas)
        .navigationTitle("分组")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { MIcon(name: "plus", size: 18, color: M.accent) }
            }
        }
        .sheet(isPresented: $creating) { GroupFormSheet(group: nil) }
    }
}

/// 新建 / 改名 + 选色的表单（创建用；编辑在 GroupDetailView 内进行）。
struct GroupFormSheet: View {
    let group: ServerGroup?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var colorHex = ServerGroup.palette[4]
    @State private var duplicateName = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    MInsetGroup(header: "名称") {
                        TextField("分组名", text: $name)
                            .font(M.sans(15)).foregroundStyle(M.text)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        MSectionCap(text: "颜色").padding(.horizontal, 20)
                        let cols = [GridItem](repeating: GridItem(.flexible()), count: 5)
                        LazyVGrid(columns: cols, spacing: 16) {
                            ForEach(ServerGroup.palette, id: \.self) { hex in
                                let (r, g, b) = groupHexRGB(hex)
                                Circle().fill(Color(.sRGB, red: r, green: g, blue: b))
                                    .frame(width: 36, height: 36)
                                    .overlay(Circle().stroke(.white, lineWidth: colorHex == hex ? 3 : 0))
                                    .overlay(Circle().stroke(M.border, lineWidth: 1))
                                    .onTapGesture { colorHex = hex }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 12)
                .mReadableColumn()
            }
            .background(M.canvas)
            .navigationTitle(group == nil ? "新建分组" : "编辑分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear { if let group { name = group.name; colorHex = group.colorHex } }
        .alert("已有同名分组", isPresented: $duplicateName) {
            Button("好", role: .cancel) {}
        } message: {
            Text("分组按名称归并：同名的两个分组在同步时会被合成一个。请换一个名称。")
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let group {
            // 走 GroupStore：查重名，并把成员主机的 `group` 一起改过去。
            guard GroupStore(context: context).rename(group, to: trimmed) else {
                duplicateName = true
                return
            }
            group.colorHex = colorHex
        } else {
            let existing = (try? context.fetch(FetchDescriptor<ServerGroup>())) ?? []
            guard !existing.contains(where: { $0.name == trimmed }) else {
                duplicateName = true
                return
            }
            let next = existing.map(\.sortOrder).max() ?? -1
            context.insert(ServerGroup(name: trimmed, colorHex: colorHex, sortOrder: next + 1))
        }
        try? context.save()
        dismiss()
    }
}

/// 分组详情（设计稿 `GroupDetail`）：改名 / 选色 / 成员·添加两态管理 / 删除。
struct GroupDetailView: View {
    let group: ServerGroup
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mAccent) private var accent
    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]

    @State private var name = ""
    @State private var tab = 0   // 0=成员 1=添加
    @State private var pendingDelete = false
    @State private var duplicateName = false

    private var members: [ServerProfile] { hosts.filter { $0.group == group.name } }
    private var candidates: [ServerProfile] { hosts.filter { ($0.group ?? "") != group.name } }
    private var dirty: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && n != group.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                renameSection
                colorSection
                membersSection
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 24)
            .mReadableColumn()
        }
        .background(M.canvas)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = group.name }
        .confirmationDialog("删除分组「\(group.name)」？", isPresented: $pendingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { delete() }
            Button("取消", role: .cancel) {}
        } message: { Text("里面的 \(members.count) 台主机会移到「未分组」。") }
        .alert("已有同名分组", isPresented: $duplicateName) {
            Button("好", role: .cancel) { name = group.name }
        } message: {
            Text("分组按名称归并：同名的两个分组在同步时会被合成一个。请换一个名称。")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Circle().fill(group.color).frame(width: 18, height: 18)
                .frame(width: 46, height: 46)
                .background(group.color.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).font(M.sans(19, weight: .bold)).tracking(-0.3).foregroundStyle(M.text)
                Text("\(UFormat.count(members.count)) 台主机").font(M.sans(13)).foregroundStyle(M.text3)
            }
            Spacer()
            Button { pendingDelete = true } label: {
                MIcon(name: "trash", size: 17, color: M.text3).frame(width: 38, height: 38)
                    .background(M.fillFaint)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }.buttonStyle(MPressStyle())
        }
    }

    private var renameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MSectionCap(text: "分组名称")
            HStack(spacing: 9) {
                MInput(text: $name)
                MBtn(title: "保存", kind: .primary, height: 48, disabled: !dirty) { rename() }.fixedSize()
            }
        }
        .padding(.top, 20)
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            MSectionCap(text: "颜色")
            FlexWrap(spacing: 12, lineSpacing: 12) {
                ForEach(ServerGroup.palette, id: \.self) { hex in
                    let (r, g, b) = groupHexRGB(hex)
                    let on = hex == group.colorHex
                    Button { group.colorHex = hex; try? context.save() } label: {
                        Color(.sRGB, red: r, green: g, blue: b)
                            .frame(width: 32, height: 32)
                            .overlay { if on { MIcon(name: "check", size: 15, color: .white, weight: .bold) } }
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(M.canvas, lineWidth: on ? 2 : 0))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(.sRGB, red: r, green: g, blue: b), lineWidth: on ? 2 : 0).padding(-2))
                    }.buttonStyle(MPressStyle())
                }
            }
        }
        .padding(.top, 18)
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MSectionCap(text: "成员")
                Spacer()
                HStack(spacing: 3) {
                    segBtn(0, "成员 \(members.count)")
                    segBtn(1, "添加 \(candidates.count)")
                }
                .padding(3).background(M.fillFaint)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            let list = tab == 0 ? members : candidates
            VStack(spacing: 0) {
                if list.isEmpty {
                    Text(tab == 0 ? "这个分组还没有主机" : "所有主机都在这个分组里")
                        .font(M.sans(13)).foregroundStyle(M.text4)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    ForEach(Array(list.enumerated()), id: \.element.id) { idx, h in
                        memberRow(h, last: idx == list.count - 1)
                    }
                }
            }
            .background(M.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.top, 22)
    }

    private func segBtn(_ i: Int, _ label: String) -> some View {
        Button { tab = i } label: {
            Text(label).font(M.sans(12.5, weight: .medium))
                .foregroundStyle(tab == i ? accent : M.text3)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(tab == i ? accent.opacity(0.14) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())   // 整段可点，不必点到文字
        }.buttonStyle(MPressStyle())
    }

    private func memberRow(_ h: ServerProfile, last: Bool) -> some View {
        HStack(spacing: 11) {
            Text(initials(h.name)).font(M.mono(11.5)).foregroundStyle(M.text3)
                .frame(width: 26, height: 26).background(M.fillMed)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            Text(h.name).font(M.mono(14)).foregroundStyle(M.text).lineLimit(1)
            Spacer(minLength: 6)
            Button {
                if tab == 0 { h.group = nil } else { h.group = group.name }
                try? context.save()
            } label: {
                Text(tab == 0 ? "移出" : "+ 加入").font(M.sans(12.5, weight: .medium))
                    .foregroundStyle(tab == 0 ? M.text2 : accent)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(tab == 0 ? M.fillMed : accent.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(MPressStyle())
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .overlay(alignment: .bottom) { if !last { MRowDivider(inset: 50) } }
    }

    private func initials(_ s: String) -> String {
        String(s.split(whereSeparator: { $0 == "-" || $0 == "_" }).compactMap(\.first).prefix(2)).uppercased()
    }
    private func rename() {
        let new = name.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != group.name else { return }
        // 改前不查重名：两个同名分组在局域网合并时按名字归并，多出来的那份永远删不掉。
        if !GroupStore(context: context).rename(group, to: new) { duplicateName = true }
    }
    private func delete() {
        for h in members { h.group = nil }
        context.delete(group)
        try? context.save()
        dismiss()
    }
}
