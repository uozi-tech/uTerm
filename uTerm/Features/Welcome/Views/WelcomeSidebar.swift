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
    @Binding var draggingProfileID: UUID?
    let onDropProfileToGroup: (_ profileID: UUID, _ groupName: String?) -> Void
    @Query private var groups: [ServerGroup]
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
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if showViewSection {
                    UDSidebarSectionHeader("视图")
                        .accessibilityAddTraits(.isHeader)
                }
                if pinnedCount > 0 {
                    navRow(.pinned, icon: "star.fill", title: "置顶", counts: counts)
                }
                if recentCount > 0 {
                    navRow(.recent, icon: "clock", title: "最近", counts: counts)
                }
                if showGroupSection {
                    HStack(spacing: 0) {
                        UDSidebarSectionHeader("分组")
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button { openWindow(id: "groups") } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11))
                                .foregroundStyle(UD.text4)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 14)
                        .accessibilityLabel("管理分组")
                        .help("管理分组")
                    }
                    .padding(.top, showViewSection ? 14 : 0)
                    if let allRow = groupBuiltIns.first(where: { $0.section == .allHosts }) {
                        navRow(allRow.section, icon: allRow.icon, title: allRow.title, counts: counts)
                    }
                }
                ForEach(sortedGroups, id: \.persistentModelID) { g in
                    navRow(.group(g.name), icon: "circle.fill", title: g.name,
                           counts: counts, iconColor: g.color)
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
                           counts: counts)
                        .modifier(SidebarProfileDropModifier(
                            target: WelcomeSidebarProfileDropTarget(section: .ungrouped),
                            draggingProfileID: $draggingProfileID,
                            onDropProfileToGroup: onDropProfileToGroup
                        ))
                }
            }
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UD.bg)
        .overlay(alignment: .trailing) {
            Rectangle().fill(UD.border).frame(width: 1)
        }
    }

    @ViewBuilder
    private func navRow(_ section: NavSection, icon: String, title: String,
                        counts: [NavSection: Int], iconColor: Color? = nil) -> some View {
        let count = counts[section] ?? 0
        let isActive = filter.section == section
        // 搜索时不命中的 section（除 allHosts 之外）半透明 + 禁点击
        let isDimmed = !filter.query.isEmpty && count == 0 && section != .allHosts

        // 复用 DesignKit `UDSidebarRow`：高 28、圆角 6、选中 `rowSelected` / hover
        // `rowHover`。外缩 8pt（设计稿 `margin: 0 8px`）让选中底两侧留白，不再贴边。
        UDSidebarRow(
            systemImage: icon,
            label: title,
            count: count,
            selected: isActive,
            action: { filter.section = section },
            iconColor: iconColor
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
