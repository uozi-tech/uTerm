import XCTest
@testable import uTerm

final class EditorHighlightWindowTests: XCTestCase {
    func testSmallDocumentUsesFullRange() {
        let range = EditorHighlightWindow.applicationRange(
            textLength: 1_000,
            visibleRange: NSRange(location: 500, length: 20)
        )
        XCTAssertEqual(range, NSRange(location: 0, length: 1_000))
    }

    func testLargeDocumentBoundsAttributeWritesAroundViewport() {
        let length = EditorHighlightWindow.fullDocumentThreshold * 4
        let visible = NSRange(location: length / 2, length: 2_000)
        let range = EditorHighlightWindow.applicationRange(
            textLength: length,
            visibleRange: visible
        )

        XCTAssertTrue(EditorHighlightWindow.contains(visible, in: range))
        XCTAssertLessThanOrEqual(
            range.length,
            visible.length + EditorHighlightWindow.prefetchLength * 2
        )
        XCTAssertLessThan(range.length, length)
    }

    func testUnknownViewportStillAvoidsFullLargeDocumentWrite() {
        let length = EditorHighlightWindow.fullDocumentThreshold * 4
        let range = EditorHighlightWindow.applicationRange(
            textLength: length,
            visibleRange: nil
        )
        XCTAssertEqual(range.location, 0)
        XCTAssertLessThan(range.length, length)
    }
}
