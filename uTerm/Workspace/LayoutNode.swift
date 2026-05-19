import Foundation

/// 分屏方向。
nonisolated enum SplitDirection: String, Codable, Sendable, Equatable {
    case horizontal   // 左右两个子节点
    case vertical     // 上下两个子节点
}

/// 一个分屏节点。`fraction` 是首个子节点的占比（0–1）。
nonisolated struct SplitNode: Equatable, Sendable {
    let id: UUID
    var direction: SplitDirection
    var fraction: Double
    var first: LayoutNode
    var second: LayoutNode
}

/// 标签内的递归二叉布局树。值类型 —— 树操作是纯函数，返回新树。
nonisolated indirect enum LayoutNode: Equatable, Sendable {
    case leaf(paneID: UUID)
    case split(SplitNode)

    /// 树中所有窗格 id。
    nonisolated var leafIDs: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(let s): return s.first.leafIDs + s.second.leafIDs
        }
    }

    /// 深度优先的第一个窗格 id。
    nonisolated var firstLeafID: UUID? { leafIDs.first }

    /// 树中窗格数量。递归累加，不分配数组，比 `leafIDs.count` 轻。
    nonisolated var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .split(let s): return s.first.leafCount + s.second.leafCount
        }
    }

    /// 把 `.leaf(paneID)` 替换为一个 `.split`，子节点为 [原 leaf, 新 leaf]。
    nonisolated func splitting(paneID: UUID, direction: SplitDirection,
                               newPaneID: UUID, splitID: UUID, fraction: Double = 0.5) -> LayoutNode {
        switch self {
        case .leaf(let id):
            guard id == paneID else { return self }
            return .split(SplitNode(
                id: splitID, direction: direction, fraction: fraction,
                first: .leaf(paneID: id), second: .leaf(paneID: newPaneID)))
        case .split(var s):
            s.first = s.first.splitting(paneID: paneID, direction: direction,
                                        newPaneID: newPaneID, splitID: splitID, fraction: fraction)
            s.second = s.second.splitting(paneID: paneID, direction: direction,
                                          newPaneID: newPaneID, splitID: splitID, fraction: fraction)
            return .split(s)
        }
    }

    /// 移除某窗格。其兄弟子树上提替换父 `.split`。
    /// 若移除的是整棵树唯一的 leaf，返回 nil（标签应关闭）。
    nonisolated func removingLeaf(paneID: UUID) -> LayoutNode? {
        switch self {
        case .leaf(let id):
            return id == paneID ? nil : self
        case .split(var s):
            // 先判断目标在哪一侧子树，只递归含目标的那一侧。
            // 不能用 `if let = removingLeaf(...)` 直接试 —— 不含目标的子树
            // 也会返回非 nil 的自身，那样会误入错误分支、永不深入真正含
            // 目标的子树。
            if s.first.leafIDs.contains(paneID) {
                guard let newFirst = s.first.removingLeaf(paneID: paneID) else {
                    return s.second   // first 子树整体塌缩 → 兄弟上提
                }
                s.first = newFirst
                return .split(s)
            }
            if s.second.leafIDs.contains(paneID) {
                guard let newSecond = s.second.removingLeaf(paneID: paneID) else {
                    return s.first
                }
                s.second = newSecond
                return .split(s)
            }
            return .split(s)   // 树中无此窗格
        }
    }

    /// 设置某 `splitID` 的分隔比例。
    nonisolated func settingFraction(_ fraction: Double, splitID: UUID) -> LayoutNode {
        switch self {
        case .leaf:
            return self
        case .split(var s):
            if s.id == splitID {
                s.fraction = fraction
            } else {
                s.first = s.first.settingFraction(fraction, splitID: splitID)
                s.second = s.second.settingFraction(fraction, splitID: splitID)
            }
            return .split(s)
        }
    }
}
