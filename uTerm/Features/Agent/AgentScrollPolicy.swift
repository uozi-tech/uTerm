import CoreGraphics

/// Agent 对话滚动的共享策略。流式文本与 Markdown 排版都按批次刷新，自动贴底也必须
/// 合并，否则每个 SSE 碎片都会启动一次 SwiftUI LazyVStack 布局事务。
nonisolated enum AgentScrollPolicy {
    static let coalescingDelay: Double = 0.10
    static let bottomTolerance: CGFloat = 96

    static func isNearBottom(
        visibleMaxY: CGFloat,
        contentHeight: CGFloat,
        tolerance: CGFloat = bottomTolerance
    ) -> Bool {
        guard visibleMaxY.isFinite, contentHeight.isFinite else { return false }
        return visibleMaxY >= max(0, contentHeight - tolerance)
    }
}
