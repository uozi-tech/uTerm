import Foundation
import SwiftData

/// 集中所有 ServerGroup 读写，便于内存容器单测。成员归属仍按 `ServerProfile.group` 字符串（按名键）。
@MainActor
struct GroupStore {
    let context: ModelContext

    /// 为每个「有 profile 引用、但无 ServerGroup 行」的分组名补建。幂等、只补不删（空组保留）。
    func reconcile() {
        let profiles = (try? context.fetch(FetchDescriptor<ServerProfile>())) ?? []
        let usedNames = Set(profiles.compactMap { p -> String? in
            let g = p.group ?? ""
            return g.isEmpty ? nil : g
        })
        let existing = (try? context.fetch(FetchDescriptor<ServerGroup>())) ?? []
        let existingNames = Set(existing.map(\.name))
        var count = existing.count
        var maxOrder = existing.map(\.sortOrder).max() ?? -1
        for name in usedNames.sorted() where !existingNames.contains(name) {
            maxOrder += 1
            context.insert(ServerGroup(name: name,
                                       colorHex: GroupStore.nextColor(existingCount: count),
                                       isPinned: false, sortOrder: maxOrder))
            count += 1
        }
        try? context.save()
    }

    /// 按名取 ServerGroup；缺则建并返回。
    @discardableResult
    func ensure(name: String) -> ServerGroup {
        let descriptor = FetchDescriptor<ServerGroup>(predicate: #Predicate { $0.name == name })
        if let found = try? context.fetch(descriptor).first { return found }
        let existing = (try? context.fetch(FetchDescriptor<ServerGroup>())) ?? []
        let g = ServerGroup(name: name,
                            colorHex: GroupStore.nextColor(existingCount: existing.count),
                            isPinned: false,
                            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1)
        context.insert(g)
        try? context.save()
        return g
    }

    /// 配色：按现有组数循环取 palette。纯函数。
    nonisolated static func nextColor(existingCount: Int) -> String {
        ServerGroup.palette[existingCount % ServerGroup.palette.count]
    }

    /// 侧栏排序：置顶优先 → sortOrder 升序 → name 本地化升序。
    static func sortedForSidebar(_ groups: [ServerGroup]) -> [ServerGroup] {
        groups.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - spec B 写操作

    /// 新建空组（去空白；空名 nil；已存在返回原行）。
    @discardableResult
    func create(name: String) -> ServerGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ensure(name: trimmed)
    }

    /// 重命名。目标名被别的组占用 → false 不改；空名 → false；同名自身 → true no-op。
    /// 成功时把成员 `profile.group` 同步改名，与 `ServerGroup.name` 同事务 save。
    @discardableResult
    func rename(_ group: ServerGroup, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == group.name { return true }
        let all = (try? context.fetch(FetchDescriptor<ServerGroup>())) ?? []
        if all.contains(where: { $0.name == trimmed && $0.persistentModelID != group.persistentModelID }) {
            return false
        }
        let old = group.name
        for p in (try? context.fetch(FetchDescriptor<ServerProfile>())) ?? [] where p.group == old {
            p.group = trimmed
        }
        group.name = trimmed
        try? context.save()
        return true
    }

    /// 删组：成员解组（group=nil）+ 删行，同事务 save。
    func delete(_ group: ServerGroup) {
        let name = group.name
        for p in (try? context.fetch(FetchDescriptor<ServerProfile>())) ?? [] where p.group == name {
            p.group = nil
        }
        context.delete(group)
        try? context.save()
    }

    func setColor(_ group: ServerGroup, hex: String) { group.colorHex = hex; try? context.save() }
    func setPinned(_ group: ServerGroup, _ pinned: Bool) { group.isPinned = pinned; try? context.save() }

    /// 把 profile 加入组（从原组移走；单组归属）。
    func addMember(_ profile: ServerProfile, to name: String) { profile.group = name; try? context.save() }
    func removeMember(_ profile: ServerProfile) { profile.group = nil; try? context.save() }

    /// 某名的成员。读 @Model 属性 → `@MainActor`（默认隔离，不要标 nonisolated）。
    static func members(of name: String, in profiles: [ServerProfile]) -> [ServerProfile] {
        profiles.filter { $0.group == name }
    }
}
