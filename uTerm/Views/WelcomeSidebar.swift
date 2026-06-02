// uTerm/Views/WelcomeSidebar.swift
import SwiftUI

struct WelcomeSidebar: View {
    let profiles: [ServerProfile]
    @Binding var filter: ServerFilter

    var body: some View {
        let counts = ServerFilter.counts(for: profiles, query: filter.query)
        List(selection: Binding(
            get: { filter.section },
            set: { if let s = $0 { filter.section = s } }
        )) {
            Section("视图") {
                row(.allHosts, icon: "square.grid.2x2", title: "所有主机", counts: counts)
                if (counts[.pinned] ?? 0) > 0 {
                    row(.pinned, icon: "star.fill", title: "置顶", counts: counts)
                }
                if (counts[.recent] ?? 0) > 0 {
                    row(.recent, icon: "clock", title: "最近", counts: counts)
                }
            }
            if !customGroups.isEmpty || (counts[.ungrouped] ?? 0) > 0 {
                Section("分组") {
                    ForEach(customGroups, id: \.self) { g in
                        row(.group(g), icon: "circle.fill", title: g, counts: counts)
                    }
                    if (counts[.ungrouped] ?? 0) > 0 {
                        row(.ungrouped, icon: "minus.circle", title: "未分组", counts: counts)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// 已有自定义分组名（去重、locale 排序）。
    private var customGroups: [String] {
        let set = Set(profiles.compactMap { p -> String? in
            let g = p.group ?? ""
            return g.isEmpty ? nil : g
        })
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func row(_ section: NavSection, icon: String, title: String,
                     counts: [NavSection: Int]) -> some View {
        Label(title, systemImage: icon)
            .badge(counts[section] ?? 0)
            .tag(section)
    }
}
