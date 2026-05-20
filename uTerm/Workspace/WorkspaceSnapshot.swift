import Foundation

/// 持久化用的布局树快照。叶子记录 `serverProfileID` 与窗格种类。
nonisolated indirect enum NodeSnapshot: Codable, Equatable, Sendable {
    case leaf(serverProfileID: UUID, kind: PaneKindTag)
    case split(direction: SplitDirection, fraction: Double,
               first: NodeSnapshot, second: NodeSnapshot)
}

// 自定义 Codable —— `leaf` 解码时兼容无 kind 字段的 Spec 1 旧快照。
// 冲突说明：把 `Codable` 写在主声明（`nonisolated` 类型）上而非扩展上，
// 否则在 main-actor 默认隔离的模块里扩展会让该 conformance 变成 main-actor 隔离。
extension NodeSnapshot {
    private enum CodingKeys: String, CodingKey { case leaf, split }
    private enum LeafKeys: String, CodingKey { case serverProfileID, kind }
    private enum SplitKeys: String, CodingKey { case direction, fraction, first, second }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.leaf) {
            let leaf = try container.nestedContainer(keyedBy: LeafKeys.self, forKey: .leaf)
            // 兼容 Spec 1 时代无 kind 字段的旧快照 —— 缺省按 .terminal。
            self = .leaf(
                serverProfileID: try leaf.decode(UUID.self, forKey: .serverProfileID),
                kind: try leaf.decodeIfPresent(PaneKindTag.self, forKey: .kind) ?? .terminal)
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
        case .leaf(let serverProfileID, let kind):
            var leaf = container.nestedContainer(keyedBy: LeafKeys.self, forKey: .leaf)
            try leaf.encode(serverProfileID, forKey: .serverProfileID)
            try leaf.encode(kind, forKey: .kind)
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
}
