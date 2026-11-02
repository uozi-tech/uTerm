import UDesignKit
// uTerm/Views/WelcomeSidebar.swift
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

nonisolated struct WelcomeSidebarBuiltInRow: Equatable {
    let section: NavSection
    let icon: String
    let title: String
}

nonisolated enum WelcomeSidebarLayout {
    static func showsViewSection(pinnedCount: Int, recentCount: Int) -> Bool {
        pinnedCount > 0 || recentCount > 0
    }

    static func showsGroupSection(totalCount: Int, groupCount: Int, ungroupedCount: Int) -> Bool {
        totalCount > 0 || groupCount > 0 || ungroupedCount > 0
    }

    static func groupBuiltInRows(ungroupedCount: Int) -> [WelcomeSidebarBuiltInRow] {
        var rows = [
            WelcomeSidebarBuiltInRow(section: .allHosts,
                                     icon: "square.grid.2x2",
                                     title: "全部")
        ]
        if ungroupedCount > 0 {
            rows.append(WelcomeSidebarBuiltInRow(section: .ungrouped,
                                                 icon: "minus.circle",
                                                 title: "未分组"))
        }
        return rows
    }
}

private struct SidebarProfileDropModifier: ViewModifier {
    let target: WelcomeSidebarProfileDropTarget?
    @Binding var draggingProfileID: UUID?
    let onDropProfileToGroup: (_ profileID: UUID, _ groupName: String?) -> Void

    @State private var isTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if let target {
            content
                .onDrop(of: [.text], isTargeted: $isTargeted) { _ in
                    guard let profileID = draggingProfileID else { return false }
                    onDropProfileToGroup(profileID, target.groupName)
                    draggingProfileID = nil
                    return true
                }
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(UD.accent, lineWidth: 1)
                            .padding(.horizontal, 8)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }
}

private struct WelcomeSidebarGroupDragModifier: ViewModifier {
    let enabled: Bool
    let groupID: PersistentIdentifier
    let profileDropTarget: WelcomeSidebarProfileDropTarget?
    @Binding var draggingGroupID: PersistentIdentifier?
    @Binding var draggingProfileID: UUID?
    let onMoveGroup: (PersistentIdentifier, PersistentIdentifier) -> Void
    let onDropProfileToGroup: (_ profileID: UUID, _ groupName: String?) -> Void

    @State private var isProfileTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let dropTarget = content
            .onDrop(of: [.text], delegate: WelcomeSidebarGroupDropDelegate(
                targetID: groupID,
                profileDropTarget: profileDropTarget,
                draggingGroupID: $draggingGroupID,
                draggingProfileID: $draggingProfileID,
                isProfileTargeted: $isProfileTargeted,
                onMoveGroup: onMoveGroup,
                onDropProfileToGroup: onDropProfileToGroup
            ))
            .overlay {
                if isProfileTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(UD.accent, lineWidth: 1)
                        .padding(.horizontal, 8)
                        .allowsHitTesting(false)
                }
            }

        if enabled {
            dropTarget.onDrag {
                draggingGroupID = groupID
                return NSItemProvider(object: "group" as NSString)
            }
        } else {
            dropTarget
        }
    }
}

private struct WelcomeSidebarGroupDropDelegate: DropDelegate {
    let targetID: PersistentIdentifier
    let profileDropTarget: WelcomeSidebarProfileDropTarget?
    @Binding var draggingGroupID: PersistentIdentifier?
    @Binding var draggingProfileID: UUID?
    @Binding var isProfileTargeted: Bool
    let onMoveGroup: (PersistentIdentifier, PersistentIdentifier) -> Void
    let onDropProfileToGroup: (_ profileID: UUID, _ groupName: String?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingGroupID != nil || draggingProfileID != nil
    }

    func dropEntered(info: DropInfo) {
        if draggingProfileID != nil, profileDropTarget != nil {
            isProfileTargeted = true
            return
        }
        guard let from = draggingGroupID, from != targetID else { return }
        onMoveGroup(from, targetID)
    }

    func dropExited(info: DropInfo) {
        isProfileTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingGroupID = nil
            draggingProfileID = nil
            isProfileTargeted = false
        }
        if let profileID = draggingProfileID, let profileDropTarget {
            onDropProfileToGroup(profileID, profileDropTarget.groupName)
            return true
        }
        return draggingGroupID != nil
    }
}

nonisolated struct WelcomeSidebarProfileDropTarget: Equatable {
    let section: NavSection
    let groupName: String?

    nonisolated init?(section: NavSection) {
        switch section {
        case .group(let name):
            self.section = section
            self.groupName = name
        case .ungrouped:
            self.section = section
            self.groupName = nil
        case .allHosts, .pinned, .recent:
            return nil
        }
    }
}

struct WelcomeSidebar: View {
    let profiles: [ServerProfile]
    @Binding var filter: ServerFilter
    @Binding var pane: WelcomePane
    @Binding var draggingProfileID: UUID?
    /// 命令面板是否打开。开着时停用侧栏 ⌘1…9 / ⌥↑↓，与 WelcomeView 的列表监听一致——
    /// 面板打开期间由它独占键盘导航（见 `WelcomeView.handleListKey` 的 palette 守卫）。
    var paletteActive = false
    let onDropProfileToGroup: (_ profileID: UUID, _ groupName: String?) -> Void
    @Query private var groups: [ServerGroup]
    @Query private var quickCommands: [QuickCommand]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @State private var draggingGroupID: PersistentIdentifier?

    private var sortedGroups: [ServerGroup] {
        GroupStore.sortedForSidebar(groups)
    }

    private var store: GroupStore {
        GroupStore(context: modelContext)
    }

    var body: some View {
        // `sortedGroups` 一次 body 只求一次值（改前 `navEntries` 与下面的
        // `ForEach` 各求一次，等于每次击键 / 每按一次 ↑↓ 都多排一遍序）。
        let sortedGroups = self.sortedGroups
        // 这一行的成本模型见 `ServerFilter.counts` 的注释：改前它一行就要 50ms
        // （2000 台 / 60 组），而 body 每次击键与每按一次 ↑↓ 都重跑。
        let counts = ServerFilter.counts(for: profiles, query: filter.query)
        let pinnedCount = counts[.pinned] ?? 0
        let recentCount = counts[.recent] ?? 0
        let totalCount = counts[.allHosts] ?? 0
        let ungroupedCount = counts[.ungrouped] ?? 0
        let showViewSection = WelcomeSidebarLayout.showsViewSection(
            pinnedCount: pinnedCount,
            recentCount: recentCount
        )
        let showGroupSection = WelcomeSidebarLayout.showsGroupSection(
            totalCount: totalCount,
            groupCount: groups.count,
            ungroupedCount: ungroupedCount
        )
        let groupBuiltIns = WelcomeSidebarLayout.groupBuiltInRows(ungroupedCount: ungroupedCount)
        // ⌘1…⌘9 / ⌥↑↓ 的条目顺序，必须与下面的渲染顺序逐项对齐。
        let navEntries = WelcomeSidebarNav.entries(
            pinnedCount: pinnedCount,
            recentCount: recentCount,
            showsGroupSection: showGroupSection,
            groupNames: sortedGroups.map(\.name),
            ungroupedCount: ungroupedCount
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if showViewSection {
                    UDSidebarSectionHeader("视图")
                        .accessibilityAddTraits(.isHeader)
                }
                if pinnedCount > 0 {
                    navRow(.pinned, icon: "star.fill", title: "置顶", counts: counts, entries: navEntries)
                }
                if recentCount > 0 {
                    navRow(.recent, icon: "clock", title: "最近", counts: counts, entries: navEntries)
                }
                if showGroupSection {
                    HStack(spacing: 0) {
                        UDSidebarSectionHeader("分组")
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button { openWindow(id: "groups") } label: {
                            // 图标色交给 iconButtonHover（静息 text2、悬停 text + 灰底），这里不设。
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .iconButtonHover(cornerRadius: 5)
                        // 20pt 命中框比图标宽约 4pt：外边距相应减 4，图标位置不变。
                        .padding(.trailing, 10)
                        .accessibilityLabel("管理分组")
                        .help("管理分组")
                    }
                    .padding(.top, showViewSection ? Self.sectionGap : 0)
                    if let allRow = groupBuiltIns.first(where: { $0.section == .allHosts }) {
                        navRow(allRow.section, icon: allRow.icon, title: allRow.title,
                               counts: counts, entries: navEntries)
                    }
                }
                ForEach(sortedGroups, id: \.persistentModelID) { g in
                    navRow(.group(g.name), icon: "circle.fill", title: g.name,
                           counts: counts, entries: navEntries, iconColor: g.color)
                    .modifier(WelcomeSidebarGroupDragModifier(
                        enabled: !isDimmedGroup(g, counts: counts),
                        groupID: g.persistentModelID,
                        profileDropTarget: WelcomeSidebarProfileDropTarget(section: .group(g.name)),
                        draggingGroupID: $draggingGroupID,
                        draggingProfileID: $draggingProfileID,
                        onMoveGroup: moveGroup,
                        onDropProfileToGroup: onDropProfileToGroup
                    ))
                }
                if let ungroupedRow = groupBuiltIns.first(where: { $0.section == .ungrouped }) {
                    navRow(ungroupedRow.section,
                           icon: ungroupedRow.icon,
                           title: ungroupedRow.title,
                           counts: counts,
                           entries: navEntries)
                        .modifier(SidebarProfileDropModifier(
                            target: WelcomeSidebarProfileDropTarget(section: .ungrouped),
                            draggingProfileID: $draggingProfileID,
                            onDropProfileToGroup: onDropProfileToGroup
                        ))
                }

                // 动作分组：快捷命令库入口（功能文档 §1 入口；闪电图标 + 数量徽标，始终可见）。
                UDSidebarSectionHeader("动作")
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, (showViewSection || showGroupSection) ? Self.sectionGap : 0)
                UDSidebarRow(
                    systemImage: "bolt.fill",
                    label: "快捷命令",
                    count: quickCommands.count,
                    selected: pane == .quickCommands,
                    action: { pane = .quickCommands },
                    shortcutHint: WelcomeSidebarNav.shortcutHint(for: .quickCommands, in: navEntries)
                )
                .padding(.horizontal, 8)
            }
            // 设计稿 Sidebar：padding 6 0 14 —— 顶部紧贴工具栏，分组靠 16pt 间距 + 小标题。
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 侧栏不铺底色（与整窗同为卡面色），右侧竖线由 WelcomeView 画。
        // 侧栏快捷键：⌘1…⌘9 直达第 N 项、⌥↑/⌥↓ 顺序切换。隐藏的零尺寸按钮承载 key
        // equivalent（与命令面板 escHotkey 同款），故输入框聚焦时也能触发、不会被吃成文本。
        .background(
            WelcomeSidebarShortcuts(entries: navEntries, current: currentTarget, onSelect: select)
                .disabled(paletteActive)
        )
    }

    /// 侧栏分组之间的间距（设计稿 `SidebarSection` marginBottom 16）。
    private static let sectionGap: CGFloat = 16

    /// 当前侧栏选中的目标（用于 ⌥↑↓ 计算相邻项）。
    private var currentTarget: WelcomeNavTarget {
        pane == .quickCommands ? .quickCommands : .section(filter.section)
    }

    /// 应用一次侧栏跳转：主机分区切回主机面板并设 section；「快捷命令」切到命令面板。
    private func select(_ target: WelcomeNavTarget) {
        switch target {
        case .section(let s):
            pane = .hosts
            filter.section = s
        case .quickCommands:
            pane = .quickCommands
        }
    }

    @ViewBuilder
    private func navRow(_ section: NavSection, icon: String, title: String,
                        counts: [NavSection: Int], entries: [WelcomeNavTarget],
                        iconColor: Color? = nil) -> some View {
        let count = counts[section] ?? 0
        // 仅当处于主机面板时高亮主机 section；切到快捷命令面板时主机行全不选中。
        let isActive = pane == .hosts && filter.section == section
        // 搜索时不命中的 section（除 allHosts 之外）半透明 + 禁点击
        let isDimmed = !filter.query.isEmpty && count == 0 && section != .allHosts

        // 复用 DesignKit `UDSidebarRow`：高 28、圆角 6、选中 `rowSelected` / hover
        // `rowHover`。外缩 8pt（设计稿 `margin: 0 8px`）让选中底两侧留白，不再贴边。
        UDSidebarRow(
            systemImage: icon,
            label: title,
            count: count,
            selected: isActive,
            action: { pane = .hosts; filter.section = section },
            iconColor: iconColor,
            shortcutHint: WelcomeSidebarNav.shortcutHint(for: .section(section), in: entries)
        )
        .padding(.horizontal, 8)
        .opacity(isDimmed ? 0.4 : 1.0)
        .allowsHitTesting(!isDimmed)
    }

    private func isDimmedGroup(_ group: ServerGroup, counts: [NavSection: Int]) -> Bool {
        !filter.query.isEmpty && (counts[.group(group.name)] ?? 0) == 0
    }

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
}

/// 侧栏键盘快捷键载体：一组零尺寸隐藏按钮承载 ⌘1…⌘9（直达第 N 项）与 ⌥↑/⌥↓（顺序切换）。
/// 不渲染任何可见内容；只在 Welcome 窗口为 key 时由 `.keyboardShortcut` 触发。
private struct WelcomeSidebarShortcuts: View {
    let entries: [WelcomeNavTarget]
    let current: WelcomeNavTarget
    let onSelect: (WelcomeNavTarget) -> Void

    var body: some View {
        ZStack {
            ForEach(Array(entries.prefix(9).enumerated()), id: \.offset) { index, target in
                Button("") { onSelect(target) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: .option)
            Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: .option)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// ⌥↑/⌥↓：在 `entries` 里把选中项移动一格（钳制两端，不回绕）。
    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let idx = entries.firstIndex(of: current) ?? 0
        let new = max(0, min(entries.count - 1, idx + delta))
        onSelect(entries[new])
    }
}
