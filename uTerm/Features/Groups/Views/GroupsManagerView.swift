import UDesignKit
import SwiftUI
import SwiftData

struct GroupRenameEditorState<ID: Hashable>: Equatable {
    var editingID: ID?
    var draft = ""
    var hasError = false

    var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isEditing(_ id: ID) -> Bool {
        editingID == id
    }

    mutating func begin(id: ID, currentName: String) {
        editingID = id
        draft = currentName
        hasError = false
    }

    @discardableResult
    mutating func save(id: ID, commit: (String) -> Bool) -> Bool {
        guard isEditing(id), canSave else {
            hasError = true
            return false
        }
        guard commit(draft) else {
            hasError = true
            return false
        }
        editingID = nil
        hasError = false
        return true
    }

    mutating func cancel(currentName: String) {
        draft = currentName
        editingID = nil
        hasError = false
    }
}

enum GroupRowDeleteButtonLayout {
    static let hitWidth: CGFloat = 30
    static let hitHeight: CGFloat = 30
    static let visibleSize: CGFloat = 22
    static let iconSize: CGFloat = 10
}

/// 分组管理窗口（设计稿 `groups.jsx`）。两窗格：左=新建输入 + 组列表（含底部统计）+
/// 未分组只读行；右=选中组详情（图标头 / 重命名 / 色板 / 成员「成员·添加」分页增删）。
/// 独立 `Window`，外观随全局主题。
///
/// 与设计稿差异说明：
/// - 「置顶」组在设计稿里只展示星标、未给开关；本实现保留语义（影响侧栏排序），
///   故置顶切换收进组行右键菜单（不破坏设计稿视觉）。
/// - 「未分组」在设计稿里是一条 builtin 组行；这里是由 `ServerProfile.group` 为空派生的
///   计算行，成员只读（既不能移出也不能再加入），其余视觉对齐 builtin 组。
/// - 组行拖拽手柄 hover 浮现，整行可拖拽重排（实时重排 + 持久化 `sortOrder`，见 `moveGroup`）；
///   「未分组」builtin 行不参与拖拽，始终置底。
struct GroupsManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServerGroup.sortOrder) private var groups: [ServerGroup]
    @Query private var profiles: [ServerProfile]

    enum ManagerSelection: Hashable { case group(PersistentIdentifier); case ungrouped }

    @State private var selection: ManagerSelection?
    @State private var newGroupName = ""
    @State private var renameEditor = GroupRenameEditorState<PersistentIdentifier>()
    @State private var pendingDelete: ServerGroup?
    @State private var draggingID: PersistentIdentifier?

    private var store: GroupStore { GroupStore(context: modelContext) }
    private var sortedGroups: [ServerGroup] { GroupStore.sortedForSidebar(groups) }

    /// 每个组名的成员数，**一趟聚合**。原来每行都 `GroupStore.members(of:in:profiles).count`
    /// 全表扫一遍：60 组 × 2000 台 = 每次 body 12 万次比较，而且每次比较都要过
    /// SwiftData 的属性访问器。这里一趟 O(profiles) 建字典，行里改成 O(1) 查表。
    private var memberCounts: [String: Int] { ServerGrouping.memberCounts(profiles) }
    private var ungroupedCount: Int { profiles.count - memberCounts.values.reduce(0, +) }
    private var totalHosts: Int { profiles.count }
    private var selectedGroup: ServerGroup? {
        if case .group(let id) = selection { return groups.first { $0.persistentModelID == id } }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            GroupsTitleBar()
            HStack(spacing: 0) {
                leftPane.frame(width: 240)
                Rectangle().fill(UD.border).frame(width: 1)
                rightPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: "分组管理"))
        .overlay { deleteConfirmOverlay }
        .onAppear {
            if selection == nil {
                selection = sortedGroups.first.map { .group($0.persistentModelID) }
            }
        }
    }

    // MARK: - 左栏

    private var leftPane: some View {
        VStack(spacing: 0) {
            createBar
            Rectangle().fill(UD.border).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    let counts = memberCounts
                    ForEach(sortedGroups, id: \.persistentModelID) { g in
                        groupRow(g, counts: counts)
                    }
                    if ungroupedCount > 0 {
                        GroupRowView(
                            name: "未分组",
                            color: ServerGroupTint.color(hex: "#9aa7b5"),
                            count: ungroupedCount,
                            pinned: false,
                            builtin: true,
                            selected: selection == .ungrouped,
                            onSelect: { selection = .ungrouped }
                        )
                    }
                }
                .padding(.vertical, 6)
            }
            Rectangle().fill(UD.border).frame(height: 1)
            footer
        }
        .frame(maxHeight: .infinity)
        .background(UD.bg)
    }

    private var createBar: some View {
        HStack(spacing: 6) {
            TextField("新建分组…", text: $newGroupName)
                .textFieldStyle(.plain)
                .font(UD.font(12.5))
                .foregroundStyle(UD.text)
                .onSubmit(createGroup)
            Button(action: createGroup) {
                Text("添加")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(canCreate ? .white : UD.text4)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(canCreate ? UD.accent : UD.fillSoft))
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(UD.inputBg))   // 日间浅灰底
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var canCreate: Bool {
        !newGroupName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func groupRow(_ g: ServerGroup, counts: [String: Int]) -> some View {
        GroupRowView(
            name: g.name,
            color: g.color,
            count: counts[g.name] ?? 0,
            pinned: g.isPinned,
            builtin: false,
            selected: selection == .group(g.persistentModelID),
            onSelect: { selection = .group(g.persistentModelID) },
            onDelete: { pendingDelete = g },
            onTogglePin: { store.setPinned(g, !g.isPinned) }
        )
        .modifier(GroupRowDragModifier(
            enabled: !renameEditor.isEditing(g.persistentModelID),
            groupID: g.persistentModelID,
            draggingID: $draggingID,
            onMove: moveGroup
        ))
    }

    /// 把 `from` 组拖到 `to` 组的位置（拖拽中实时调用），并持久化新的 `sortOrder`。
    private func moveGroup(_ from: PersistentIdentifier, _ to: PersistentIdentifier) {
        var order = sortedGroups
        guard let fromIdx = order.firstIndex(where: { $0.persistentModelID == from }),
              let toIdx = order.firstIndex(where: { $0.persistentModelID == to }),
              fromIdx != toIdx else { return }
        let moved = order.remove(at: fromIdx)
        order.insert(moved, at: min(toIdx, order.count))
        withAnimation(.easeInOut(duration: 0.18)) {
            store.reorder(order)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(sortedGroups.count + (ungroupedCount > 0 ? 1 : 0)) 个分组")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(totalHosts) 台主机")
                .font(UD.monoMetric)
        }
        .font(.system(size: 11))
        .foregroundStyle(UD.text4)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - 右栏

    @ViewBuilder
    private var rightPane: some View {
        if let g = selectedGroup {
            GroupDetailView(
                group: g,
                members: GroupStore.members(of: g.name, in: profiles),
                candidates: profiles.filter { $0.group != g.name },
                isRenaming: renameEditor.isEditing(g.persistentModelID),
                renameDraft: $renameEditor.draft,
                renameError: renameEditor.hasError,
                canSaveRename: renameEditor.canSave,
                onBeginRename: { beginRename(g) },
                onCommitRename: { commitRename(g) },
                onCancelRename: { cancelRename(g) },
                onSetColor: { store.setColor(g, hex: $0) },
                onAdd: { store.addMember($0, to: g.name) },
                onRemove: { store.removeMember($0) }
            )
            .id(g.persistentModelID)
        } else if selection == .ungrouped {
            UngroupedDetailView(members: profiles.filter { ($0.group ?? "").isEmpty })
        } else {
            Text("从左侧选择一个分组")
                .font(UD.body)
                .foregroundStyle(UD.text4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 删除确认

    @ViewBuilder
    private var deleteConfirmOverlay: some View {
        if let g = pendingDelete {
            GroupDeleteConfirm(
                groupName: g.name,
                hostCount: GroupStore.members(of: g.name, in: profiles).count,
                onCancel: { pendingDelete = nil },
                onConfirm: {
                    let remaining = sortedGroups.filter { $0.persistentModelID != g.persistentModelID }
                    store.delete(g)
                    if selection == .group(g.persistentModelID) {
                        selection = remaining.first.map { .group($0.persistentModelID) }
                    }
                    pendingDelete = nil
                }
            )
        }
    }

    // MARK: - 动作

    private func createGroup() {
        // 已有同名分组：照旧选中那一行，不另建。
        switch store.createUnique(name: newGroupName) {
        case .created(let g), .duplicate(let g):
            newGroupName = ""
            selection = .group(g.persistentModelID)
        case .emptyName:
            return
        }
    }

    private func beginRename(_ g: ServerGroup) {
        renameEditor.begin(id: g.persistentModelID, currentName: g.name)
    }

    /// 提交重命名。成功关闭编辑器；失败（重名 / 空名）保持编辑器打开并标红，让用户改正。
    @discardableResult
    private func commitRename(_ g: ServerGroup) -> Bool {
        renameEditor.save(id: g.persistentModelID) { store.rename(g, to: $0) }
    }

    private func cancelRename(_ g: ServerGroup) {
        renameEditor.cancel(currentName: g.name)
    }
}

// MARK: - 组行（设计稿 GroupRow）

/// 单条分组行：拖拽手柄（hover 浮现）/ 彩点 / 名称（含星标·系统徽标）/ 主机数。
/// hover 时主机数淡出、浮现删除图标按钮。builtin 行（未分组）无 hover 动作、无拖拽手柄。
private struct GroupRowView: View {
    let name: String
    let color: Color
    let count: Int
    let pinned: Bool
    let builtin: Bool
    let selected: Bool
    var onSelect: () -> Void
    var onDelete: () -> Void = {}
    var onTogglePin: () -> Void = {}

    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            // 拖拽手柄：2×3 圆点 grip（hover 且非 builtin 时浮现）
            VStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 2.5) {
                        Circle().frame(width: 2, height: 2)
                        Circle().frame(width: 2, height: 2)
                    }
                }
            }
            .foregroundStyle(hover && !builtin ? UD.text4 : .clear)
            .frame(width: 8)

            // 彩点 + 1px 同色描边
            Circle().fill(color).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(color.opacity(0.2), lineWidth: 1).padding(-1))

            nameLabel
                .frame(maxWidth: .infinity, alignment: .leading)

            trailingSlot
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? UD.rowSelected : (hover ? UD.rowHover : .clear)))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(name)，\(UFormat.count(count)) 台主机\(builtin ? "，系统内置" : "")")
        // `onTapGesture` 不像 `Button` 那样自带 AX 默认动作：只标 `.isButton`
        // 的话 VoiceOver / 全键盘控制按下去是空转。显式补一条默认动作。
        .accessibilityAction { onSelect() }
        .contextMenu {
            if !builtin {
                Button(pinned ? "取消置顶" : "置顶", action: onTogglePin)
                Divider()
                Button("删除", role: .destructive, action: onDelete)
            }
        }
    }

    /// Count and hover action share one fixed trailing column, so rows stay aligned.
    private var trailingSlot: some View {
        Text("\(count)")
            .font(UD.monoMetric)
            .foregroundStyle(UD.text3)
            .opacity(hover && !builtin ? 0 : 1)
            .frame(width: GroupRowDeleteButtonLayout.hitWidth, alignment: .center)
            .overlay {
                if hover && !builtin {
                    rowIconButton("trash", danger: true, action: onDelete)
                }
            }
    }

    @ViewBuilder
    private var nameLabel: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(UD.font(12.5))
                .foregroundStyle(selected ? UD.text : UD.text2)
                .lineLimit(1)
            if pinned {
                Image(systemName: "star")
                    .font(.system(size: 9))
                    .foregroundStyle(UD.text3)
            }
            if builtin {
                Text("系统")
                    .font(.system(size: 9.5))
                    .foregroundStyle(UD.text4)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(UD.fillFaint))
            }
        }
    }

}

/// 组行 hover 浮现的小图标按钮（22×22 / r5 / 细微底）。
private func rowIconButton(_ symbol: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(UD.fillFaint)
                .frame(width: GroupRowDeleteButtonLayout.visibleSize,
                       height: GroupRowDeleteButtonLayout.visibleSize)
            Image(systemName: symbol)
                .font(.system(size: GroupRowDeleteButtonLayout.iconSize))
                .foregroundStyle(danger ? UD.danger : UD.text3)
        }
        .frame(width: GroupRowDeleteButtonLayout.hitWidth,
               height: GroupRowDeleteButtonLayout.hitHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(danger ? "删除分组" : "")
    .help(danger ? "删除分组" : "")
}

// MARK: - 组详情（设计稿 GroupDetail）

private struct GroupDetailView: View {
    let group: ServerGroup
    let members: [ServerProfile]
    let candidates: [ServerProfile]
    let isRenaming: Bool
    @Binding var renameDraft: String
    let renameError: Bool
    let canSaveRename: Bool
    var onBeginRename: () -> Void
    var onCommitRename: () -> Bool
    var onCancelRename: () -> Void
    var onSetColor: (String) -> Void
    var onAdd: (ServerProfile) -> Void
    var onRemove: (ServerProfile) -> Void

    @State private var tab = 0   // 0 = 成员, 1 = 添加

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                colorSection
                memberSection
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            groupGlyph(color: group.color)
            VStack(alignment: .leading, spacing: 4) {
                titleEditor
                Text("\(UFormat.count(members.count)) 台主机")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text3)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var titleEditor: some View {
        if isRenaming {
            HStack(alignment: .top, spacing: 8) {
                UDTextField(
                    placeholder: "分组名",
                    text: $renameDraft,
                    errorMessage: renameError ? "名称不能为空或已存在" : nil
                )
                .frame(width: 220)
                .onSubmit { _ = onCommitRename() }
                .onExitCommand(perform: onCancelRename)

                UDButton(title: "保存", style: .primary) {
                    _ = onCommitRename()
                }
                .disabled(!canSaveRename)
            }
        } else {
            HStack(spacing: 10) {
                Text(group.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(UD.text)
                Button(action: onBeginRename) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text3)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(UD.fillFaint))
                }
                .buttonStyle(.plain)
                .help("重命名")
                .accessibilityLabel("重命名")
            }
        }
    }

    private var colorSection: some View {
        GroupFormSection(title: "颜色") {
            HStack(spacing: 8) {
                ForEach(ServerGroup.palette, id: \.self) { hex in
                    colorSwatch(hex)
                }
            }
        }
    }

    private func colorSwatch(_ hex: String) -> some View {
        let active = group.colorHex == hex
        let c = ServerGroupTint.color(hex: hex)
        return Button { onSetColor(hex) } label: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(c)
                .frame(width: 26, height: 26)
                // 选中：内圈 2px 背景色描边（留白缝）+ 外圈 2px 同色描边 + 白勾（设计稿双环）。
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(UD.bg, lineWidth: 2)
                    }
                }
                .overlay {
                    if active {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(c, lineWidth: 2)
                            .padding(-3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("颜色 \(hex)")
        .accessibilityAddTraits(active ? .isSelected : [])
        .help("颜色 \(hex)")
    }

    private var memberSection: some View {
        GroupFormSection(title: "成员") {
            memberTabs
        } content: {
            if tab == 0 {
                if members.isEmpty {
                    emptyBox(title: "这个分组还没有主机", hint: "切到「添加」标签页，把已有主机加入此分组")
                } else {
                    memberList(members, action: .remove, scroll: false)
                }
            } else {
                if candidates.isEmpty {
                    emptyBox(title: "所有主机都在这个分组里", hint: nil)
                } else {
                    memberList(candidates, action: .add, scroll: true)
                }
            }
        }
    }

    private var memberTabs: some View {
        HStack(spacing: 0) {
            segButton("成员 \(members.count)", index: 0)
            segButton("添加 \(candidates.count)", index: 1)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(UD.fillSoft))
    }

    private func segButton(_ label: String, index: Int) -> some View {
        Button { tab = index } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tab == index ? UD.text : UD.text3)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(tab == index ? UD.fillMed : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private func memberList(_ items: [ServerProfile], action: MemberRowView.Action, scroll: Bool) -> some View {
        // 懒栈：2000 台的组切进来时，原来 `VStack` 会把 2000 行连同 2000 个 Button 一次性建出来。
        let rows = LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.persistentModelID) { idx, p in
                MemberRowView(
                    name: serverProfileMemberDisplayName(p),
                    isLast: idx == items.count - 1,
                    action: action,
                    onAction: { action == .remove ? onRemove(p) : onAdd(p) }
                )
            }
        }
        return Group {
            if scroll {
                ScrollView { rows }.frame(maxHeight: 220)
            } else {
                rows
            }
        }
        // 成员列表 = 白底容器（panel 底 + 描边 + 行分隔线），非灰底。
        .background(RoundedRectangle(cornerRadius: 8).fill(UD.panel))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UD.border, lineWidth: 1))
    }

    private func emptyBox(title: String, hint: String?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(UD.text4)
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(UD.text4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(UD.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

// MARK: - 成员行（设计稿 MemberRow）

private struct MemberRowView: View {
    enum Action { case remove, add }

    let name: String
    let isLast: Bool
    let action: Action?       // nil = 只读（未分组）
    var onAction: () -> Void = {}

    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Text(memberInitials(name))
                .font(UD.monoMetric)
                .foregroundStyle(UD.text3)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(UD.fillFaint))

            Text(name)
                .font(UD.mono(12.5))
                .foregroundStyle(UD.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let action {
                // 不用 `Button`：密集行里每个 Button 都要建一棵平台控件子树
                // （playbook §三「Button 才是主因」）。命中区 + 手势 + AX traits
                // 能拿到一样的行为与可访问性，代价是 0 个平台视图。
                Text(action == .remove ? "移出" : "+ 加入")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(action == .remove ? UD.text2 : UD.accentInk)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(action == .remove ? UD.fillFaint : UD.accentSoft))
                    .opacity(hover ? 1 : 0.7)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onAction)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(action == .remove ? "移出 \(name)" : "把 \(name) 加入分组")
                    .accessibilityAction { onAction() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hover ? UD.rowHover : Color.clear)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(UD.border).frame(height: 1) }
        }
        .onHover { hover = $0 }
    }
}

// MARK: - 未分组详情（builtin，成员只读）

private struct UngroupedDetailView: View {
    let members: [ServerProfile]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    groupGlyph(color: ServerGroupTint.color(hex: "#9aa7b5"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("未分组")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(UD.text)
                        Text("\(UFormat.count(members.count)) 台主机\(Text("  ·  系统内置，不可删除").foregroundStyle(UD.text4))")
                            .font(.system(size: 12))
                            .foregroundStyle(UD.text3)
                    }
                    Spacer(minLength: 0)
                }
                GroupFormSection(title: "成员") {
                    if members.isEmpty {
                        Text("没有未分组的主机")
                            .font(.system(size: 12.5))
                            .foregroundStyle(UD.text4)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(UD.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(members.enumerated()), id: \.element.persistentModelID) { idx, p in
                                MemberRowView(
                                    name: serverProfileMemberDisplayName(p),
                                    isLast: idx == members.count - 1,
                                    action: nil
                                )
                            }
                        }
                        // 成员列表 = 白底容器（panel 底 + 描边 + 行分隔线），与 GroupDetailView 一致。
                        .background(RoundedRectangle(cornerRadius: 8).fill(UD.panel))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UD.border, lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 表单小节（设计稿 FormSection：标题 + 可选右槽 + 内容）

private struct GroupFormSection<Right: View, Content: View>: View {
    let title: String
    let right: Right
    let content: () -> Content

    init(title: String,
         @ViewBuilder right: () -> Right,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.right = right()
        self.content = content
    }

    init(title: String, @ViewBuilder content: @escaping () -> Content) where Right == EmptyView {
        self.title = title
        self.right = EmptyView()
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(UD.caption).foregroundStyle(UD.text3)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                right
            }
            content()
        }
    }
}

// MARK: - 删除确认弹层（设计稿 DeleteConfirm）

private struct GroupDeleteConfirm: View {
    let groupName: String
    let hostCount: Int
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        ZStack {
            UDModalBackdrop(onDismiss: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(UD.danger.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UD.danger.opacity(0.3), lineWidth: 1))
                        .frame(width: 36, height: 36)
                        .overlay(Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(UD.danger))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("删除分组「\(groupName)」？")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(UD.text)
                        message
                            .font(.system(size: 12))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    UDButton(title: "取消", style: .secondary, action: onCancel)
                    UDButton(title: "删除", style: .danger, action: onConfirm)
                }
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 12).fill(UD.overlay))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UD.borderHi, lineWidth: 1))
            .shadow(color: UD.modalShadowColor, radius: 30, y: 18)
        }
    }

    private var message: Text {
        Text("里面的 \(Text("\(hostCount)").font(UD.mono(12)).foregroundStyle(UD.text)) 台主机会移到「未分组」，不会被删除。")
            .foregroundStyle(UD.text2)
    }
}

// MARK: - 共享小工具

/// 详情头部 38×38 圆角图标：同色低透明底 + 中心发光彩点。
private func groupGlyph(color: Color) -> some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(color.opacity(0.14))
        .frame(width: 38, height: 38)
        .overlay(
            Circle().fill(color).frame(width: 12, height: 12)
                .shadow(color: color.opacity(0.6), radius: 6)
        )
}


func serverProfileMemberDisplayName(_ profile: ServerProfile) -> String {
    let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? profile.host.trimmingCharacters(in: .whitespacesAndNewlines) : name
}

/// 成员显示名首字母缩写（按 `-` / `_` 拆词取首字母，最多两位）——设计稿成员头像。
private func memberInitials(_ name: String) -> String {
    let parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" })
    return String(parts.compactMap(\.first).prefix(2))
}

/// 分组管理窗口自绘扁平标题栏：左侧让位窗口红绿灯（~68pt），居中 "分组管理"。
private struct GroupsTitleBar: View {
    var body: some View {
        ZStack {
            Text("分组管理")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UD.text)
                // 纯展示，不参与命中测试：否则会截走标题栏空白处的双击（缩放）/ 拖动（见 WindowDragHandle）。
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                Color.clear.frame(width: 68)
                Spacer()
            }
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}
