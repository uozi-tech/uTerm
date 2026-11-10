import Foundation

/// 整台接管一台 Mac 之后，本机标签跟着它的终端列表走（两端共用的对账，界面各自开关标签）：
/// - 没见过的终端在后台开标签。在本机关掉的不算新的，不会再开回来。
/// - 列表里出现过、现在没了的终端（在 Mac 上关了、Mac 上的连接断了）关掉标签。之后回来的算新的。
/// - 接管时已开标签、但还没在列表里出现过的终端（刚在 Mac 上开的本机 shell 可能排在列表更新之前）
///   不能因为列表里没有就当它关了，也不能在它第一次出现时再开一个。
nonisolated struct RemoteSessionFollower: Equatable, Sendable {
    /// 上次收到的终端列表。
    private(set) var listed: Set<UUID> = []
    /// 已开标签、还没在列表里出现过的终端。
    private(set) var awaitingListing: Set<UUID>

    init(takingOver sessionIDs: [UUID]) {
        awaitingListing = Set(sessionIDs)
    }

    /// 收到新的终端列表：返回要关掉的（`gone`）与要新开的（`fresh`，保持列表顺序）。
    mutating func update(_ sessionIDs: [UUID]) -> (gone: Set<UUID>, fresh: [UUID]) {
        let current = Set(sessionIDs)
        let gone = listed.subtracting(current)
        let fresh = sessionIDs.filter { !listed.contains($0) && !awaitingListing.contains($0) }
        listed = current
        awaitingListing.subtract(current)
        return (gone, fresh)
    }
}

/// 按 Mac 上的标签顺序重排本机一条标签条里属于那台 Mac 的标签（两端共用，界面各自落到自己的标签条上）。
///
/// 只在这些标签原来占的那几格之间换位置：别的标签（直连主机、文件、另一台 Mac 的）原地不动，`order` 里没有的
/// 远控标签（刚开的本机 shell 还没进列表）也不动。前台标签是谁由调用方保留，这里只排顺序。
nonisolated enum RemoteTabArrangement {
    /// `sessionID` 取标签接着的那台 Mac 上的会话 id；不是这台 Mac 的标签返回 nil。
    static func arranged<Tab>(_ tabs: [Tab], order: [UUID], sessionID: (Tab) -> UUID?) -> [Tab] {
        var rank: [UUID: Int] = [:]
        for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
        var slots: [Int] = []
        var ranked: [(rank: Int, tab: Tab)] = []
        for (slot, tab) in tabs.enumerated() {
            guard let id = sessionID(tab), let position = rank[id] else { continue }
            slots.append(slot)
            ranked.append((position, tab))
        }
        ranked.sort { $0.rank < $1.rank }
        var arranged = tabs
        for (slot, entry) in zip(slots, ranked) { arranged[slot] = entry.tab }
        return arranged
    }
}
