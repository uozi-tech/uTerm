// uTerm/Views/WelcomeSidebar.swift
import SwiftUI
import SwiftData

struct WelcomeSidebar: View {
    let profiles: [ServerProfile]
    @Binding var filter: ServerFilter
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
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                UDSidebarSectionHeader("视图")
                    .accessibilityAddTraits(.isHeader)
                navRow(.allHosts, icon: "square.grid.2x2", title: "所有主机", counts: counts)
                if (counts[.pinned] ?? 0) > 0 {
                    navRow(.pinned, icon: "star.fill", title: "置顶", counts: counts)
                }
                if (counts[.recent] ?? 0) > 0 {
                    navRow(.recent, icon: "clock", title: "最近", counts: counts)
                }
                if !groups.isEmpty || (counts[.ungrouped] ?? 0) > 0 {
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
                    .padding(.top, 14)
                }
                ForEach(sortedGroups, id: \.persistentModelID) { g in
                    navRow(.group(g.name), icon: "circle.fill", title: g.name,
                           counts: counts, iconColor: g.color)
                    .modifier(GroupRowDragModifier(
                        enabled: !isDimmedGroup(g, counts: counts),
                        groupID: g.persistentModelID,
                        draggingID: $draggingGroupID,
                        onMove: moveGroup
                    ))
                }
                if (counts[.ungrouped] ?? 0) > 0 {
                    navRow(.ungrouped, icon: "minus.circle", title: "未分组", counts: counts)
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
