import XCTest
@testable import uTerm

final class MarkdownImageLayoutTests: XCTestCase {
    func testSmallBadgeKeepsIntrinsicSize() {
        let size = MarkdownImageLayout.displaySize(
            intrinsic: CGSize(width: 105, height: 20),
            availableWidth: 1_000)

        XCTAssertEqual(size.width, 105)
        XCTAssertEqual(size.height, 20)
    }

    func testWideImageScalesDownToAvailableWidth() {
        let size = MarkdownImageLayout.displaySize(
            intrinsic: CGSize(width: 1_200, height: 600),
            availableWidth: 600)

        XCTAssertEqual(size.width, 600)
        XCTAssertEqual(size.height, 300)
    }

    func testTallImageScalesDownToMaximumHeight() {
        let size = MarkdownImageLayout.displaySize(
            intrinsic: CGSize(width: 400, height: 1_000),
            availableWidth: 800)

        XCTAssertEqual(size.width, 208)
        XCTAssertEqual(size.height, 520)
    }

    func testFrameLimitKeepsBadgeIntrinsicSize() {
        let limit = MarkdownImageLayout.frameLimit(
            intrinsic: CGSize(width: 105, height: 20))

        XCTAssertEqual(limit.width, 105)
        XCTAssertEqual(limit.height, 20)
    }

    func testFrameLimitCapsTallImageHeightWithoutInventingWidth() {
        let limit = MarkdownImageLayout.frameLimit(
            intrinsic: CGSize(width: 400, height: 1_000))

        XCTAssertEqual(limit.width, 400)
        XCTAssertEqual(limit.height, 520)
    }
}
