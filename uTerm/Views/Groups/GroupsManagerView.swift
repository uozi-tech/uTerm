import SwiftUI
import SwiftData
import AppKit

/// 分组管理窗口（设计稿 `groups.jsx`）。两窗格：左=新建+组列表+未分组只读行；
/// 右=选中组详情（色板/置顶/重命名/删/成员增删）。独立 `Window`，外观随全局主题。
struct GroupsManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServerGroup.sortOrder) private var groups: [ServerGroup]
    @Query private var profiles: [ServerProfile]

    enum ManagerSelection: Hashable { case group(PersistentIdentifier); case ungrouped }

    @State private var selection: ManagerSelection?
    @State private var newGroupName = ""
    @State private var renameDraft = ""
    @State private var renameError = false
    @State private var pendingDelete: ServerGroup?

    private var store: GroupStore { GroupStore(context: modelContext) }
    private var sortedGroups: [ServerGroup] { GroupStore.sortedForSidebar(groups) }
    private var ungroupedCount: Int { profiles.filter { ($0.group ?? "").isEmpty }.count }
    private var selectedGroup: ServerGroup? {
        if case .group(let id) = selection { return groups.first { $0.persistentModelID == id } }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            GroupsTitleBar()
            HStack(spacing: 0) {
                leftPane.frame(width: 280)
                Rectangle().fill(UD.border).frame(width: 1)
                rightPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: "分组管理"))
        .confirmationDialog("删除分组？",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete) { g in
                Button("删除", role: .destructive) {
                    store.delete(g); selection = nil; pendingDelete = nil
                }
                Button("取消", role: .cancel) {}
            } message: { g in
                Text("「\(g.name)」将被删除，其主机会变为未分组。")
            }
    }

    // MARK: 左栏

    private var leftPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("新建分组…", text: $newGroupName)
                    .textFieldStyle(.plain)
                    .font(UD.body)
                    .foregroundStyle(UD.text)
                    .onSubmit(createGroup)
                Button("添加", action: createGroup)
                    .buttonStyle(.plain)
                    .foregroundStyle(UD.accent)
                    .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            Rectangle().fill(UD.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(sortedGroups, id: \.persistentModelID) { g in
                        groupRow(g)
                    }
                    if ungroupedCount > 0 {
                        ungroupedRow
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxHeight: .infinity)
        .background(UD.bg)
    }

    private func groupRow(_ g: ServerGroup) -> some View {
        let isSel = selection == .group(g.persistentModelID)
        return HStack(spacing: 10) {
            Circle().fill(g.color).frame(width: 10, height: 10)
            Text(g.name).font(UD.body).foregroundStyle(isSel ? UD.text : UD.text2).lineLimit(1)
            if g.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(UD.text4)
            }
            Spacer(minLength: 6)
            Text("\(GroupStore.members(of: g.name, in: profiles).count)")
                .font(UD.monoMetric).foregroundStyle(UD.text4)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSel ? UD.rowSelected : .clear))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { select(.group(g.persistentModelID), draft: g.name) }
    }

    private var ungroupedRow: some View {
        let isSel = selection == .ungrouped
        return HStack(spacing: 10) {
            Image(systemName: "minus.circle").font(.system(size: 11)).foregroundStyle(UD.text4)
            Text("未分组").font(UD.body).foregroundStyle(isSel ? UD.text : UD.text2)
            Spacer(minLength: 6)
            Text("\(ungroupedCount)").font(UD.monoMetric).foregroundStyle(UD.text4)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSel ? UD.rowSelected : .clear))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { selection = .ungrouped }
    }

    // MARK: 右栏

    @ViewBuilder
    private var rightPane: some View {
        if let g = selectedGroup {
            groupDetail(g)
        } else if selection == .ungrouped {
            ungroupedDetail
        } else {
            VStack { Text("选择一个分组").font(UD.body).foregroundStyle(UD.text4) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func groupDetail(_ g: ServerGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // 头：大色块 + 重命名
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 10).fill(g.color).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("分组名", text: $renameDraft)
                            .textFieldStyle(.plain).font(.system(size: 16, weight: .medium))
                            .foregroundStyle(UD.text)
                            .onSubmit { commitRename(g) }
                        Text(renameError ? "名称已被占用" :
                                "\(GroupStore.members(of: g.name, in: profiles).count) 台主机")
                            .font(UD.caption).foregroundStyle(renameError ? UD.danger : UD.text3)
                    }
                    Spacer()
                    Button(role: .destructive) { pendingDelete = g } label: {
                        Image(systemName: "trash").foregroundStyle(UD.danger)
                    }.buttonStyle(.plain)
                }
                // 颜色
                VStack(alignment: .leading, spacing: 8) {
                    Text("颜色").font(UD.caption).foregroundStyle(UD.text3)
                    HStack(spacing: 10) {
                        ForEach(ServerGroup.palette, id: \.self) { hex in
                            let sel = g.colorHex == hex
                            Circle().fill(colorFor(hex)).frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(sel ? UD.text : .clear, lineWidth: 2).padding(-3))
                                .contentShape(Circle())
                                .onTapGesture { store.setColor(g, hex: hex) }
                        }
                    }
                }
                // 置顶
                Toggle(isOn: Binding(get: { g.isPinned }, set: { store.setPinned(g, $0) })) {
                    Text("置顶显示").font(UD.body).foregroundStyle(UD.text)
                }.toggleStyle(.switch)
                // 成员
                memberSection(g)
            }
            .padding(.horizontal, 26).padding(.vertical, 22)
        }
    }

    private func memberSection(_ g: ServerGroup) -> some View {
        let members = GroupStore.members(of: g.name, in: profiles)
        let candidates = profiles.filter { $0.group != g.name }
        return VStack(alignment: .leading, spacing: 12) {
            Text("成员（\(members.count)）").font(UD.caption).foregroundStyle(UD.text3)
            VStack(spacing: 1) {
                ForEach(members, id: \.id) { p in
                    HStack {
                        Text(p.name.isEmpty ? p.host : p.name).font(UD.body).foregroundStyle(UD.text2)
                        Spacer()
                        Button { store.removeMember(p) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(UD.text4)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
            if !candidates.isEmpty {
                Text("添加成员").font(UD.caption).foregroundStyle(UD.text3).padding(.top, 6)
                VStack(spacing: 1) {
                    ForEach(candidates, id: \.id) { p in
                        HStack {
                            Text(p.name.isEmpty ? p.host : p.name).font(UD.body).foregroundStyle(UD.text3)
                            Spacer()
                            Button { store.addMember(p, to: g.name) } label: {
                                Image(systemName: "plus.circle").foregroundStyle(UD.accent)
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private var ungroupedDetail: some View {
        let members = profiles.filter { ($0.group ?? "").isEmpty }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("未分组").font(.system(size: 16, weight: .medium)).foregroundStyle(UD.text)
                Text("系统内置，不可删除 · \(members.count) 台主机").font(UD.caption).foregroundStyle(UD.text4)
                VStack(spacing: 1) {
                    ForEach(members, id: \.id) { p in
                        Text(p.name.isEmpty ? p.host : p.name).font(UD.body).foregroundStyle(UD.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 22)
        }
    }

    // MARK: 动作

    private func createGroup() {
        guard let g = store.create(name: newGroupName) else { return }
        newGroupName = ""
        select(.group(g.persistentModelID), draft: g.name)
    }

    private func select(_ s: ManagerSelection, draft: String) {
        selection = s; renameDraft = draft; renameError = false
    }

    private func commitRename(_ g: ServerGroup) {
        if store.rename(g, to: renameDraft) {
            renameError = false; renameDraft = g.name
        } else {
            renameError = true
        }
    }

    private func colorFor(_ hex: String) -> Color {
        let (r, gg, b) = groupHexRGB(hex)
        return Color(.sRGB, red: r, green: gg, blue: b)
    }
}

/// 分组管理窗口自绘扁平标题栏（仿 KeysTitleBar）。
private struct GroupsTitleBar: View {
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 84)
            Text("分组管理").font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text2)
            Spacer()
        }
        .frame(height: 38).frame(maxWidth: .infinity)
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }
}
