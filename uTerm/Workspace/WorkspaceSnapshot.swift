import Foundation

/// 持久化用的布局树快照。叶子记录的是 `serverProfileID`（窗格 id 是运行期临时值）。
nonisolated indirect enum NodeSnapshot: Codable, Equatable, Sendable {
    case leaf(serverProfileID: UUID)
    case split(direction: SplitDirection, fraction: Double,
               first: NodeSnapshot, second: NodeSnapshot)
}

/// 一个标签的快照。
nonisolated struct TabSnapshot: Codable, Equatable, Sendable {
    var title: String
    var layout: NodeSnapshot
}

/// 整个工作区的快照。
nonisolated struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    var tabs: [TabSnapshot]
    var activeTabIndex: Int?
}
