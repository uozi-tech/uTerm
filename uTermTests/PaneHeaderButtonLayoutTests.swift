import XCTest
@testable import uTerm

final class PaneHeaderButtonLayoutTests: XCTestCase {
    func testActionButtonsUseToolbarSizedHitTargets() {
        XCTAssertGreaterThanOrEqual(PaneHeaderButtonLayout.hitWidth, 28)
        XCTAssertGreaterThanOrEqual(PaneHeaderButtonLayout.hitHeight, 22)
    }
}
