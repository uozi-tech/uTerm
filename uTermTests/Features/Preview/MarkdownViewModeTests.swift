import XCTest
@testable import uTerm

/// Markdown 标签顶上的「预览 / 编辑」切换：二选一，默认预览，存着认不出的值也退回预览。
final class MarkdownViewModeTests: XCTestCase {
    func testDefaultsToPreview() {
        XCTAssertEqual(MarkdownViewMode.stored(nil), .preview)
        XCTAssertEqual(MarkdownViewMode.stored("split"), .preview, "旧值、坏值都退回预览")
    }

    func testRoundTripsTheStoredChoice() {
        for mode in MarkdownViewMode.allCases {
            XCTAssertEqual(MarkdownViewMode.stored(mode.rawValue), mode)
        }
    }
}
