import Foundation

/// 把 AppKit 属性写入限制在可视区附近，避免大文件每次高亮都清除、重铺并重新布局全文。
nonisolated enum EditorHighlightWindow {
    static let fullDocumentThreshold = 256 * 1024
    static let prefetchLength = 32 * 1024

    static func applicationRange(textLength: Int, visibleRange: NSRange?) -> NSRange {
        guard textLength > 0 else { return NSRange(location: 0, length: 0) }
        guard textLength > fullDocumentThreshold else {
            return NSRange(location: 0, length: textLength)
        }

        let visible = visibleRange ?? NSRange(
            location: 0,
            length: min(textLength, prefetchLength)
        )
        let safeLocation = min(max(0, visible.location), textLength)
        let safeEnd = min(textLength, max(safeLocation, NSMaxRange(visible)))
        let start = max(0, safeLocation - prefetchLength)
        let end = min(textLength, safeEnd + prefetchLength)
        return NSRange(location: start, length: end - start)
    }

    static func contains(_ inner: NSRange, in outer: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }
}
