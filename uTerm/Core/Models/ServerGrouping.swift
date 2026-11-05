import Foundation

/// 主机列表的「分组 / 计数 / 最近」派生 —— macOS 与 iOS 共用一份。
///
/// ## 为什么要收成共享的
///
/// iOS 端原来有**四份**各自手写的副本：`HostsScreen.grouped`、
/// `CommandFormSheet.grouped`、`GroupsScreen.count(_:)`、
/// `CommandPaletteView.memberCount(_:)`。其中后两者是
/// `hosts.filter { $0.group == name }.count`，**每个分组各扫一遍全部主机** ——
/// O(分组 × 主机)，与 `ServerFilter.counts` 改前是同一个形态（见那边的注释：
/// 2000 台 × 60 组 = 12 万次 `ServerProfile.group` 取值，单独就要 50ms，
/// 而 SwiftData 的属性读要走一遍持久化 / 观察机制）。
///
/// 收成共享实现还有第二个好处：**纯逻辑可以在 macOS 的 `uTermTests` 里量**。
/// iOS 端没有测试 target（也没有可用的模拟器 runtime），
/// 视图里的副本压根没法钉闸门；搬到这里之后
/// `ServerGroupingTests` 就能同时守语义等价与「一趟过」的结构判据。
///
/// ## 隔离
///
/// 与 `ServerFilter` 同样标 `@MainActor`：入参是 SwiftData 的 `@Model`
/// （非 Sendable），调用方全是 MainActor 上的视图 body。
@MainActor
enum ServerGrouping {

    /// 空 / nil 组名在 iOS 列表里显示成的段名。
    static let ungroupedLabel = "未分组"

    /// 按分组保序归类：段的顺序 = 组名在 `profiles` 里**首次出现**的顺序，
    /// 段内主机保持 `profiles` 的原顺序（调用方通常已按 `sortOrder` 排好）。
    /// 空 / nil 组名归到 `ungroupedLabel` 段。
    ///
    /// 与改前 `HostsScreen.grouped` / `CommandFormSheet.grouped` 逐字等价，
    /// 由 `ServerGroupingTests.testGroupedMatchesLegacy` 守。
    static func grouped(_ profiles: [ServerProfile],
                        ungroupedLabel: String = ServerGrouping.ungroupedLabel)
        -> [(name: String, hosts: [ServerProfile])] {
        var order: [String] = []
        var map: [String: [ServerProfile]] = [:]
        map.reserveCapacity(8)
        for p in profiles {
            let raw = p.group ?? ""
            let name = raw.isEmpty ? ungroupedLabel : raw
            if map[name] == nil {
                order.append(name)
                map[name] = []
            }
            map[name]?.append(p)
        }
        return order.map { (name: $0, hosts: map[$0] ?? []) }
    }

    /// 组名 → 台数，**一趟过**。空 / nil 组名不计入
    ///（对齐改前三处 `hosts.filter { $0.group == name }.count` 的语义：
    /// 只有 `group` 精确等于该名字才算，`nil` 不等于任何名字）。
    ///
    /// 调用方按需 `?? 0` 兜底 —— 一个 `ServerGroup` 行没有任何成员时
    /// 不会出现在字典里。与 `ServerFilter.counts` 的 `groupHits`
    /// 不同的是那边会为「profiles 里出现过的组」补 0，这里不补，
    /// 因为调用方遍历的是 `ServerGroup` 表而不是 profiles。
    static func memberCounts(_ profiles: [ServerProfile]) -> [String: Int] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(8)
        for p in profiles {
            let group = p.group ?? ""
            guard !group.isEmpty else { continue }
            counts[group, default: 0] += 1
        }
        return counts
    }

    /// 主机里出现过的非空分组名：去重 + 本地化升序（表单与右键菜单里的「已有分组」候选）。
    static func existingNames(_ profiles: [ServerProfile]) -> [String] {
        Set(profiles.compactMap { p -> String? in
            let group = p.group ?? ""
            return group.isEmpty ? nil : group
        }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 最近连接：有 `lastConnectedAt` 的按时间倒序，最多 `limit` 条。
    ///
    /// `limit` 的默认值与 `ServerFilter.apply` 的 `.recent` 段一致（20）——
    /// iOS 的 `HostsScreen` 改前**没有截断**，一个连过几千台的库会把整张表
    /// 排序后全铺进 `MCardList`（非 lazy）。
    static func recent(_ profiles: [ServerProfile], limit: Int = 20) -> [ServerProfile] {
        profiles
            .filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}
