import XCTest
@testable import uTerm

final class UDTabCloseButtonLayoutTests: XCTestCase {
    func testCloseButtonUsesLargeHitTargetInsideCompactTabs() {
        XCTAssertGreaterThanOrEqual(UDTabCloseButtonLayout.hitWidth, 28)
        XCTAssertGreaterThanOrEqual(UDTabCloseButtonLayout.hitHeight, 28)
    }
}
