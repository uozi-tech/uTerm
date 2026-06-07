import XCTest
@testable import uTerm

final class UDTabCloseButtonLayoutTests: XCTestCase {
    func testCloseButtonUsesLargeHitTargetInsideCompactTabs() {
        XCTAssertGreaterThanOrEqual(UDTabCloseButtonLayout.hitWidth, 28)
        XCTAssertGreaterThanOrEqual(UDTabCloseButtonLayout.hitHeight, 28)
    }

    func testCloseButtonVisibleChromeStaysCompact() {
        XCTAssertLessThan(UDTabCloseButtonLayout.visibleSize, UDTabCloseButtonLayout.hitWidth)
        XCTAssertLessThan(UDTabCloseButtonLayout.visibleSize, UDTabCloseButtonLayout.hitHeight)
    }

    func testTabTrailingPaddingIsTighterThanLeadingPadding() {
        XCTAssertLessThan(UDTabLayout.trailingPadding, UDTabLayout.leadingPadding)
    }
}
