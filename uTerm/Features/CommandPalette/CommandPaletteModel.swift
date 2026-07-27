import Foundation
import Observation

/// 命令面板状态机：查询 / 选中索引 / 显隐 / 当前命令集。
/// `results` 与 `sections` 都是计算属性，跟随 `query` 与 `allItems`。
@Observable @MainActor
final class CommandPaletteModel {
    var query: String = ""
    var selectedIndex: Int = 0
    var isPresented: Bool = false
    private(set) var allItems: [CommandPaletteItem] = []

    /// 注入的异步搜索（query → 命令项）。nil = 不搜。
    var searchProvider: (@MainActor (String) async -> [CommandPaletteItem])?
    private(set) var dynamicItems: [CommandPaletteItem] = []
    private(set) var isSearching = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// 防抖时长；测试可置 0 以确定性等待。
    var searchDebounceNanos: UInt64 = 200_000_000

    /// 分组（供渲染）：完全匹配优先，其余结果按 kind 分组。
    var sections: [CommandPaletteSection] {
        let merged = dedupeCommandPaletteByID(
            filterCommandPalette(allItems, query: query) + dynamicItems)
        return groupCommandPaletteByMatchPriority(merged, query: query)
    }

    /// 扁平结果（供选中索引）——顺序与 `sections` 的显示顺序一致。
    var results: [CommandPaletteItem] {
        sections.flatMap(\.items)
    }

    /// 当前选中项 id（供视图高亮）。
    var selectedItemID: String? {
        let r = results
        return r.indices.contains(selectedIndex) ? r[selectedIndex].id : nil
    }

    func open(items: [CommandPaletteItem]) {
        allItems = items
        query = ""
        selectedIndex = 0
        isPresented = true
        dynamicItems = []
        isSearching = false
        searchTask?.cancel()
        searchTask = nil
    }

    func close() {
        isPresented = false
        query = ""
        selectedIndex = 0
        searchTask?.cancel()
        searchTask = nil
        dynamicItems = []
        isSearching = false
    }

    func setQuery(_ q: String) {
        query = q
        selectedIndex = 0            // 复刻设计稿 useEffect([query])
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let provider = searchProvider else {
            dynamicItems = []
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
            self.isSearching = false
        }
    }

    /// 测试用：等当前搜索任务跑完（含防抖）。
    func waitForSearch() async { await searchTask?.value }

    func moveSelection(by delta: Int) {
        let count = results.count
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    func executeSelected() {
        let r = results
        guard r.indices.contains(selectedIndex) else { return }
        execute(r[selectedIndex])
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
