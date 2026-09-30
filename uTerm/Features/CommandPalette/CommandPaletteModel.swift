import Foundation
import Observation

/// 命令面板状态机：查询 / 选中索引 / 显隐 / 当前命令集。
///
/// **`sections` / `results` 是「一次求值、存下来」而不是计算属性。**
/// 改前三者互相嵌套（`results` 读一遍 `sections`、`selectedItemID` 又读一遍
/// `results`），而 `CommandPaletteHost.paletteOverlay` 一次 body 就要读
/// `sections` + `selectedItemID` —— 于是每次击键跑**两遍**完整的
/// filter + dedupe + group，按一次 ↑/↓ 再跑两遍。2200 项候选下这是每次击键
/// 1.5ms 白花在重复求值上（读数与闸门见
/// `uTermTests/Features/CommandPalette/CommandPaletteCostTests`）。
///
/// 改动约束：**所有会影响候选集的写入都必须走 `rebuild()`**。
/// `query` 因此是 `private(set)`，外部只能经 `setQuery(_:)` 改。
@Observable @MainActor
final class CommandPaletteModel {
    /// 只能经 `setQuery(_:)` 改 —— 直接赋值会让 `sections` 失配。
    private(set) var query: String = ""
    var selectedIndex: Int = 0
    var isPresented: Bool = false
    private(set) var allItems: [CommandPaletteItem] = []

    /// 注入的异步搜索（query → 命令项）。nil = 不搜。
    var searchProvider: (@MainActor (String) async -> [CommandPaletteItem])?
    private(set) var dynamicItems: [CommandPaletteItem] = []
    private(set) var isSearching = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// 本轮查询里用户是否用 ↑/↓ 挪过选中。挪过则异步结果并入时按 id 锚住选中项，
    /// 没挪过则保持「第一项默认选中」。
    @ObservationIgnored private var selectionMovedByUser = false
    /// 防抖时长；测试可置 0 以确定性等待。
    var searchDebounceNanos: UInt64 = 200_000_000

    /// 分组（供渲染）：完全匹配优先，其余结果按 kind 分组。
    /// **一次求值存下来**，别改回计算属性（见类型注释）。
    private(set) var sections: [CommandPaletteSection] = []

    /// 扁平结果（供选中索引）——顺序与 `sections` 的显示顺序一致。
    /// 与 `sections` 同一次求值产出，两者永远一致。
    private(set) var results: [CommandPaletteItem] = []

    /// 当前选中项 id（供视图高亮）。这一个仍是计算属性 —— 它只做一次下标，
    /// 不重跑 filter / dedupe / group。
    var selectedItemID: String? {
        results.indices.contains(selectedIndex) ? results[selectedIndex].id : nil
    }

    /// 候选集派生的**唯一**求值点：filter → dedupe → group 各跑一次。
    /// 每一处会改 `query` / `allItems` / `dynamicItems` 的地方都要调它。
    private func rebuild() {
        let merged = dedupeCommandPaletteByID(
            filterCommandPalette(allItems, query: query) + dynamicItems)
        let grouped = groupCommandPaletteByMatchPriority(merged, query: query)
        sections = grouped
        results = grouped.flatMap(\.items)
    }

    /// 候选集在**查询不变**时变化（异步搜索结果并入）用这个：结果插在选中项前面会让
    /// 同一个下标指向另一项，回车就执行错。用户挪过选中则按 id 锚回原项，否则留在首项。
    private func rebuildKeepingSelection() {
        let anchorID = selectionMovedByUser ? selectedItemID : nil
        rebuild()
        if let anchorID, let index = results.firstIndex(where: { $0.id == anchorID }) {
            selectedIndex = index
        } else if !results.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
    }

    func open(items: [CommandPaletteItem]) {
        allItems = items
        query = ""
        selectedIndex = 0
        selectionMovedByUser = false
        isPresented = true
        dynamicItems = []
        isSearching = false
        searchTask?.cancel()
        searchTask = nil
        rebuild()
    }

    func close() {
        isPresented = false
        query = ""
        selectedIndex = 0
        searchTask?.cancel()
        searchTask = nil
        dynamicItems = []
        isSearching = false
        rebuild()
    }

    func setQuery(_ q: String) {
        // 同值写入必须是 no-op：macOS 的 TextField 按回车提交时会把**同一个**字符串
        // 再写回绑定一次，且先于 onSubmit。若照常重置 selectedIndex，↓ 选中的项在
        // 回车那一刻被换回第一项——执行的就成了第一项（例：输入 `~/` 选中目录回车，
        // 却打开了「导入 ~/.ssh/config」）。同时避免重启搜索把已并入的结果清掉。
        guard q != query else { return }
        query = q
        selectedIndex = 0            // 复刻设计稿 useEffect([query])
        selectionMovedByUser = false
        rebuild()
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let provider = searchProvider else {
            if !dynamicItems.isEmpty {
                dynamicItems = []
                rebuild()
            }
            isSearching = false
            searchTask = nil
            return
        }
        let debounce = searchDebounceNanos
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounce)
            guard !Task.isCancelled, let self else { return }
            self.isSearching = true
            let items = await provider(trimmed)
            guard !Task.isCancelled else { return }
            self.dynamicItems = items
            self.rebuildKeepingSelection()
            self.isSearching = false
        }
    }

    /// 测试用：等当前搜索任务跑完（含防抖）。
    func waitForSearch() async { await searchTask?.value }

    func moveSelection(by delta: Int) {
        let count = results.count
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
        selectionMovedByUser = true
    }

    func executeSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        execute(results[selectedIndex])
    }

    func execute(itemID: String) {
        guard let item = results.first(where: { $0.id == itemID }) else { return }
        execute(item)
    }

    private func execute(_ item: CommandPaletteItem) {
        close()
        item.run()
    }
}
