// uTerm/Views/WelcomeSidebar.swift
import SwiftUI

struct WelcomeSidebar: View {
    let profiles: [ServerProfile]
    @Binding var filter: ServerFilter

    var body: some View {
        let counts = ServerFilter.counts(for: profiles, query: filter.query)
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                navHeader("视图")
                navRow(.allHosts, icon: "square.grid.2x2", title: "所有主机", counts: counts)
                if (counts[.pinned] ?? 0) > 0 {
                    navRow(.pinned, icon: "star.fill", title: "置顶", counts: counts)
                }
                if (counts[.recent] ?? 0) > 0 {
                    navRow(.recent, icon: "clock", title: "最近", counts: counts)
                }
                if !customGroups.isEmpty || (counts[.ungrouped] ?? 0) > 0 {
                    navHeader("分组")
                }
                ForEach(customGroups, id: \.self) { g in
                    navRow(.group(g), icon: "circle.fill", title: g, counts: counts)
                }
                if (counts[.ungrouped] ?? 0) > 0 {
                    navRow(.ungrouped, icon: "minus.circle", title: "未分组", counts: counts)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Palette.bgPanel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppTheme.Palette.border).frame(width: 1)
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

    private func navHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(AppTheme.Palette.textMuted)
            .padding(.horizontal, 14)
            .padding(.top, 10).padding(.bottom, 4)
    }

    @ViewBuilder
    private func navRow(_ section: NavSection, icon: String, title: String,
                        counts: [NavSection: Int]) -> some View {
        let count = counts[section] ?? 0
        let isActive = filter.section == section
        // 搜索时不命中的 section（除 allHosts 之外）半透明 + 禁点击
        let isDimmed = !filter.query.isEmpty && count == 0 && section != .allHosts

        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 14)
                .foregroundStyle(isActive ? AppTheme.Palette.textPrimary
                                          : AppTheme.Palette.textMuted)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(isActive ? AppTheme.Palette.textPrimary
                                          : AppTheme.Palette.textSecondary)
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(AppTheme.Palette.textMuted)
                .monospacedDigit()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        // 选中态圆角底：与 hoverBackground 同几何（全宽、cornerRadius 4、无横向内缩），
        // 否则 hover 比选中宽 8pt。也与 FileBrowser/全 app 选中风格一致。
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? AppTheme.Palette.bgSelected : Color.clear)
        )
        // hover 反馈：非 active 时鼠标悬停切 bgRaised。
        .hoverBackground(cornerRadius: 4, isActive: isActive)
        .opacity(isDimmed ? 0.4 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isDimmed else { return }
            filter.section = section
        }
    }
}
