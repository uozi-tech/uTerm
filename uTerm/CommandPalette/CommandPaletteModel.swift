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

    /// 分组（供渲染）：过滤后按 kind 分组。
    var sections: [CommandPaletteSection] {
        groupCommandPalette(filterCommandPalette(allItems, query: query))
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
    }

    func close() {
        isPresented = false
        query = ""
        selectedIndex = 0
    }

    func setQuery(_ q: String) {
        query = q
        selectedIndex = 0            // 复刻设计稿 useEffect([query])
    }

    func moveSelection(by delta: Int) {
        let count = results.count
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    func hover(itemID: String) {
        if let idx = results.firstIndex(where: { $0.id == itemID }) {
            selectedIndex = idx
        }
    }

    func executeSelected() {
        let r = results
        guard r.indices.contains(selectedIndex) else { return }
        let item = r[selectedIndex]
        close()
        item.run()
    }
}
