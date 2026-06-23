import Foundation
import SwiftData

/// 集中 `ForwardingRule` 的读写 + 排序 + 孤儿清理，便于内存容器单测。
/// 规则↔主机用外键 `serverID`（非 `@Relationship`）—— 删主机时由调用方走 `deleteAll(forServer:)` 清孤儿。
/// CRUD 也可在视图里直接用 `modelContext`（仿 `GroupsManagerView`）；本 store 承载可单测的过滤/排序逻辑。
@MainActor
struct ForwardingRuleStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// 某主机的全部规则，按 `sortOrder` 升序。
    func rules(forServer serverID: UUID) -> [ForwardingRule] {
        let descriptor = FetchDescriptor<ForwardingRule>(
            predicate: #Predicate { $0.serverID == serverID },
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 跨主机的全部规则，按 `sortOrder` 升序（全局端口转发面板的数据源；分组在视图层做）。
    func allRules() -> [ForwardingRule] {
        let descriptor = FetchDescriptor<ForwardingRule>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 插入一条规则并保存。
    func add(_ rule: ForwardingRule) {
        context.insert(rule)
        try? context.save()
    }

    /// 删除单条规则并保存。
    func delete(_ rule: ForwardingRule) {
        context.delete(rule)
        try? context.save()
    }

    /// 删除某主机的全部规则（孤儿清理：删主机时调用）。
    func deleteAll(forServer serverID: UUID) {
        for rule in rules(forServer: serverID) {
            context.delete(rule)
        }
        try? context.save()
    }

    /// 某主机的下一个 `sortOrder`（现有最大值 +1；空则 0）。
    func nextSortOrder(forServer serverID: UUID) -> Int {
        (rules(forServer: serverID).map(\.sortOrder).max() ?? -1) + 1
    }
}
