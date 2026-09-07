import Foundation

/// 「排好序的目录列表 + 筛选词 → 可见列表」的记忆化。
///
/// **为什么要它**：`SFTPBrowserView` 的 `visible` 原本是 computed property，
/// 一次 body 求值要跑三遍全表 `localizedCaseInsensitiveContains`
/// —— 文件表读一次（`entries:`），检视器经 `selected` 读一次，状态栏的
/// `selectedCount` 再经 `selected` 读一次。20000 条目下一次筛选击键端到端
/// 实测 112~130ms（`SFTPFileTableScrollCostTests.testFileTableInteractionCost`）。
///
/// 记忆化的 key 是「整份 `sortedEntries` 值 + 筛选词」。放整份数组而不是
/// 「条目数 + 路径」这种指纹：`Array ==` 先比缓冲区身份，`FileBrowserModel`
/// 不重算 `sortedEntries` 时是 O(1)，重算了就必然是新缓冲区、必然重算 —— 不会
/// 出现「指纹一样但内容变了」的漏判（抄自 uTable 侧栏记忆化，
/// `docs/table-rendering-guide.md` T2 硬约束第 2 条）。
///
/// 引用类型：由视图的 `@State` 持有，跨 body 求值存活。
@MainActor
final class RemoteEntryFilter {

    private var cachedSource: [RemoteEntry]?
    private var cachedQuery = ""
    private var cachedResult: [RemoteEntry] = []
    /// `cachedResult` 的 id → 条目索引，懒建：只有真去查选中项时才付这一次 O(n)。
    private var cachedIndex: [RemoteEntry.ID: RemoteEntry]?

    /// 命中缓存的次数 / 真正重算的次数。闸门用（「一次 body 只重算一遍」）。
    private(set) var recomputeCount = 0

    /// 按筛选词过滤。空词直接返回源数组（不复制、不扫描）。
    func apply(_ source: [RemoteEntry], query: String) -> [RemoteEntry] {
        if let cachedSource, cachedQuery == query, cachedSource == source {
            return cachedResult
        }
        recomputeCount += 1
        let result = query.isEmpty
            ? source
            : source.filter { $0.name.localizedCaseInsensitiveContains(query) }
        cachedSource = source
        cachedQuery = query
        cachedResult = result
        cachedIndex = nil
        return result
    }

    /// 在**过滤后的**列表里按 id 找条目。选中项被筛掉时返回 nil —— 与原先
    /// `visible.first { $0.id == selectedID }` 的语义一字不差。
    func entry(id: RemoteEntry.ID?, in source: [RemoteEntry], query: String) -> RemoteEntry? {
        guard let id else { return nil }
        _ = apply(source, query: query)
        if cachedIndex == nil {
            cachedIndex = Dictionary(cachedResult.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        }
        return cachedIndex?[id]
    }
}
