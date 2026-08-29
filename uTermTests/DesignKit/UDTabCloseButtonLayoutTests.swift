import XCTest
@testable import UDesignKit
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

    func testCloseButtonVisibleChromeSitsNearTabTitle() {
        XCTAssertEqual(UDTabCloseButtonLayout.visibleLeadingInset, 0)
        XCTAssertGreaterThan(UDTabCloseButtonLayout.visibleTrailingInset, 0)
        XCTAssertLessThanOrEqual(UDTabLayout.closeButtonSpacing, 4)
        XCTAssertLessThan(
            UDTabLayout.closeButtonSpacing + (UDTabCloseButtonLayout.visibleSize / 2),
            UDTabLayout.contentSpacing + (UDTabCloseButtonLayout.hitWidth / 2)
        )
    }

    func testTabTrailingPaddingIsTighterThanLeadingPadding() {
        XCTAssertLessThan(UDTabLayout.trailingPadding, UDTabLayout.leadingPadding)
    }
}
