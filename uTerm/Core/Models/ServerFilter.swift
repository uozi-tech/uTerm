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
    ///
    /// **一趟过，别改回「每段扫一遍」。** 这是 `WelcomeSidebar.body` 的第一行，
    /// 而 body 在**搜索框每一次击键**与**主机列表每按一次 ↑/↓**（`selectedProfileID`
    /// 是 `WelcomeView` 的 `@State`）都要重跑一次。
    ///
    /// 改前是「每个 section 各扫一遍 profiles」，其中分组那一段是
    /// `for g in allGroups { profiles.filter { $0.group == g } }` ——
    /// 2000 台 × 60 组 = 12 万次 `ServerProfile.group` 取值。SwiftData 的属性
    /// 读要走一遍持久化 / 观察机制（实测约 0.4µs 一次），于是这一行**单独就要
    /// 50ms**（空 query）/ 63ms（打字中）。改成一趟过之后每台主机只取 3 次值。
    /// 读数与闸门见 `uTermTests/Features/Welcome/WelcomeSidebarCostTests`。
    ///
    /// 语义与改前逐字等价（`WelcomeSidebarCountsEquivalenceTests` 逐档比字典）：
    /// 分组键取自 profiles 自身（不是 `ServerGroup` 表），命中数为 0 的分组仍然
    /// 出现在字典里（值 0），未出现的键由调用方 `?? 0` 兜底。
    static func counts(for profiles: [ServerProfile], query: String) -> [NavSection: Int] {
        let hasQuery = !query.isEmpty
        var all = 0, pinned = 0, recent = 0, ungrouped = 0
        var groupHits: [String: Int] = [:]

        for p in profiles {
            // 每台主机每个字段只取一次值 —— 循环里重复读 SwiftData 属性就是这一处
            // 改前 50ms 的来源。
            let group = p.group ?? ""
            if !group.isEmpty, groupHits[group] == nil { groupHits[group] = 0 }
            if hasQuery, !Self.matchesQuery(query, p) { continue }
            all += 1
            if p.isPinned { pinned += 1 }
            if p.lastConnectedAt != nil { recent += 1 }
            if group.isEmpty { ungrouped += 1 } else { groupHits[group, default: 0] += 1 }
        }

        var result: [NavSection: Int] = [:]
        result.reserveCapacity(groupHits.count + 4)
        result[.allHosts] = all
        result[.pinned] = pinned
        result[.recent] = recent
        result[.ungrouped] = ungrouped
        for (name, hits) in groupHits { result[.group(name)] = hits }
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
