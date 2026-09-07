import Foundation

/// 消息流的**渲染窗口**。
///
/// 会话数据一条都不裁：`AssistantModel.messages`、SwiftData 里的
/// `ChatMessageRecord`、以及进模型的上下文（`ContextCompressor`）都保留全部消息。
/// 受限的只有「同时挂进 SwiftUI 视图树的条数」——超出窗口的旧消息由顶部的
/// 「显示更早的 N 条」按需放开。
///
/// 依据见 `docs/scroll-perf-findings.md`「Agent 消息流」一节：
/// 消息流是 `LazyVStack`，但每条 assistant 消息里包着**非 lazy** 的
/// `MarkdownBlocks`，懒栈只能推迟行的构造、推不掉行的几何维护，
/// 于是挂载与文档高度都随会话总长线性增长。
nonisolated enum AgentMessageWindow {
    /// 默认挂载上限。与 uTable AI 面板同为 200 条
    /// （`uTable/docs/perf-findings-agent-panel.md`）。
    static let defaultLimit = 200

    /// 点一次「显示更早」放开多少条。
    static let step = 200

    /// 要挂载的首条下标。`limit <= 0` 或 `limit >= count` 表示不裁。
    static func startIndex(count: Int, limit: Int) -> Int {
        guard count > 0, limit > 0, limit < count else { return 0 }
        return count - limit
    }

    /// 被折叠掉的旧消息条数（= `startIndex`）。
    static func hiddenCount(count: Int, limit: Int) -> Int {
        startIndex(count: count, limit: limit)
    }

    /// 点一次「显示更早」之后的新上限；不会超过总条数，也不会溢出。
    static func expanded(_ limit: Int, count: Int) -> Int {
        guard limit > 0, limit < count else { return count }
        guard count - limit > step else { return count }
        return limit + step
    }
}
