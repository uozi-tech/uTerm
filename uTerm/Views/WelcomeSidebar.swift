// uTerm/Views/WelcomeSidebar.swift
import SwiftUI

struct WelcomeSidebar: View {
    let profiles: [ServerProfile]
    @Binding var filter: ServerFilter

    var body: some View {
        let counts = ServerFilter.counts(for: profiles, query: filter.query)
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                UDSidebarSectionHeader("视图")
                navRow(.allHosts, icon: "square.grid.2x2", title: "所有主机", counts: counts)
                if (counts[.pinned] ?? 0) > 0 {
                    navRow(.pinned, icon: "star.fill", title: "置顶", counts: counts)
                }
                if (counts[.recent] ?? 0) > 0 {
                    navRow(.recent, icon: "clock", title: "最近", counts: counts)
                }
                if !customGroups.isEmpty || (counts[.ungrouped] ?? 0) > 0 {
                    UDSidebarSectionHeader("分组")
                        .padding(.top, 14)
                }
                ForEach(customGroups, id: \.self) { g in
                    navRow(.group(g), icon: "circle.fill", title: g, counts: counts)
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

    /// 已有自定义分组名（去重、locale 排序）。
    private var customGroups: [String] {
        let set = Set(profiles.compactMap { p -> String? in
            let g = p.group ?? ""
            return g.isEmpty ? nil : g
        })
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @ViewBuilder
    private func navRow(_ section: NavSection, icon: String, title: String,
                        counts: [NavSection: Int]) -> some View {
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
            action: { filter.section = section }
        )
        .padding(.horizontal, 8)
        .opacity(isDimmed ? 0.4 : 1.0)
        .allowsHitTesting(!isDimmed)
    }
}
