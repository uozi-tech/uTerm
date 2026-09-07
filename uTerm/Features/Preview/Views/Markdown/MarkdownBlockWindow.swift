import Foundation

/// 文件预览里 Markdown 的**分段渲染**上限。
///
/// `MarkdownBlocks` 是刻意非 lazy 的（`VStack`，不是 `LazyVStack`）：
/// `1a0bd63d`「修复窗口缩放时的布局卡死」把懒栈换了回来，
/// `MarkdownRendererTests.testMarkdownPreviewCoalescesParsingAndUsesStableBlocks`
/// 至今钉着这条。所以大文档只能靠「一次挂多少块」来钳，不能靠换懒栈。
///
/// 数据见 `docs/scroll-perf-findings.md`「预览窗口 Markdown」一节。
nonisolated enum MarkdownBlockWindow {
    /// 一段挂多少个顶层块。600 块的真实档一次就挂完（分段对常规文件无感）。
    static let defaultLimit = 800

    /// 点一次「继续渲染」再放开多少块。
    static let step = 800

    /// 还有多少块没挂。
    static func remaining(total: Int, limit: Int) -> Int {
        guard limit > 0, limit < total else { return 0 }
        return total - limit
    }

    /// 点一次「继续渲染」之后的新上限；不超过总块数，也不会溢出。
    static func expanded(_ limit: Int, total: Int) -> Int {
        guard limit > 0, limit < total else { return total }
        guard total - limit > step else { return total }
        return limit + step
    }
}
