import Foundation

/// 左 nav 的逻辑分区。Hashable 让它能进 Set / 作 Dictionary key（counts 字典）。
nonisolated enum NavSection: Hashable, Sendable {
    case allHosts
    case pinned
    case recent
    case group(String)
    case ungrouped
}

/// Welcome 窗口的过滤状态。`section` 决定主分类，`query` 是搜索词。
@MainActor
struct ServerFilter {
    var query: String = ""
    var section: NavSection = .allHosts

    /// 双过滤：先按 section 取子集，再按 query 字符串过滤。
    /// `recent` 段额外按 `lastConnectedAt` 倒序、截最多 20 条。
    func apply(to profiles: [ServerProfile]) -> [ServerProfile] {
        let bySection = profiles.filter { matches(section: section, $0) }
        let sectionFinal: [ServerProfile]
        if case .recent = section {
            sectionFinal = bySection
                .filter { $0.lastConnectedAt != nil }
                .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
                .prefix(20)
                .map { $0 }
        } else {
            sectionFinal = bySection
        }
        return query.isEmpty ? sectionFinal : sectionFinal.filter { matches(query: query, $0) }
    }

    /// 每个 NavSection 当前的命中数。section 始终用 `allHosts` 风格全集，再额外算每段；
    /// query 会一并应用到子集计数（用户搜索时 nav 计数立即反映）。
    static func counts(for profiles: [ServerProfile], query: String) -> [NavSection: Int] {
        let queryHits: (ServerProfile) -> Bool = { p in
            query.isEmpty || ServerFilter.matchesQuery(query, p)
        }
        var result: [NavSection: Int] = [:]
        result[.allHosts] = profiles.lazy.filter(queryHits).count
        result[.pinned]   = profiles.lazy.filter { $0.isPinned && queryHits($0) }.count
        result[.recent]   = profiles.lazy.filter { $0.lastConnectedAt != nil && queryHits($0) }.count
        let allGroups = Set(profiles.compactMap { name in
            let g = name.group ?? ""
            return g.isEmpty ? nil : g
        })
        for g in allGroups {
            result[.group(g)] = profiles.lazy.filter { ($0.group ?? "") == g && queryHits($0) }.count
        }
        result[.ungrouped] = profiles.lazy.filter { ($0.group ?? "").isEmpty && queryHits($0) }.count
        return result
    }

    // MARK: private

    private func matches(section: NavSection, _ p: ServerProfile) -> Bool {
        switch section {
        case .allHosts:        return true
        case .pinned:          return p.isPinned
        case .recent:          return p.lastConnectedAt != nil
        case .group(let g):    return (p.group ?? "") == g
        case .ungrouped:       return (p.group ?? "").isEmpty
        }
    }

    private func matches(query: String, _ p: ServerProfile) -> Bool {
        Self.matchesQuery(query, p)
    }

    fileprivate static func matchesQuery(_ q: String, _ p: ServerProfile) -> Bool {
        let needle = q
        return p.name.localizedCaseInsensitiveContains(needle)
            || p.displayEndpoint.localizedCaseInsensitiveContains(needle)
            || (p.group ?? "").localizedCaseInsensitiveContains(needle)
    }
}
