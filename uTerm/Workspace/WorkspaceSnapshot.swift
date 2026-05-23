import Foundation

/// 持久化用的布局树快照。叶子记录 `serverProfileID`。
nonisolated indirect enum NodeSnapshot: Codable, Equatable, Sendable {
    case leaf(serverProfileID: UUID)
    case split(direction: SplitDirection, fraction: Double,
               first: NodeSnapshot, second: NodeSnapshot)
}

// 自定义 Codable —— `leaf` 解码时兼容含 kind 字段的 pane-types 时期旧快照。
// 冲突说明：把 `Codable` 写在主声明（`nonisolated` 类型）上而非扩展上，
// 否则在 main-actor 默认隔离的模块里扩展会让该 conformance 变成 main-actor 隔离。
extension NodeSnapshot {
    private enum CodingKeys: String, CodingKey { case leaf, split }
    private enum LeafKeys: String, CodingKey { case serverProfileID, kind }  // kind 保留键名，仅为兼容旧 JSON
    private enum SplitKeys: String, CodingKey { case direction, fraction, first, second }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.leaf) {
            let leaf = try container.nestedContainer(keyedBy: LeafKeys.self, forKey: .leaf)
            // 老 JSON 可能含 kind 字段（pane-types 时期），统一忽略。
            self = .leaf(serverProfileID: try leaf.decode(UUID.self, forKey: .serverProfileID))
        } else if container.contains(.split) {
            let split = try container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            self = .split(
                direction: try split.decode(SplitDirection.self, forKey: .direction),
                fraction: try split.decode(Double.self, forKey: .fraction),
                first: try split.decode(NodeSnapshot.self, forKey: .first),
                second: try split.decode(NodeSnapshot.self, forKey: .second))
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "NodeSnapshot 既非 leaf 也非 split"))
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let serverProfileID):
            var leaf = container.nestedContainer(keyedBy: LeafKeys.self, forKey: .leaf)
            try leaf.encode(serverProfileID, forKey: .serverProfileID)
        case .split(let direction, let fraction, let first, let second):
            var split = container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            try split.encode(direction, forKey: .direction)
            try split.encode(fraction, forKey: .fraction)
            try split.encode(first, forKey: .first)
            try split.encode(second, forKey: .second)
        }
    }
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
    /// 窗口的 UI 状态（sidebar / inspector / 预览-终端比例）。
    /// 老的 workspace-<id>.json 没有这个字段，解码后为 nil，由 `WorkspaceModel`
    /// 用默认 `WorkspaceUIState()` 接住。
    var uiState: WorkspaceUIState?
}
