import XCTest
@testable import uTerm

final class AssistantInputBarLayoutTests: XCTestCase {
    func testAttachButtonUsesClickableHitTarget() {
        XCTAssertGreaterThanOrEqual(AssistantInputBarLayout.attachHitSize, 28)
        XCTAssertGreaterThanOrEqual(AssistantInputBarLayout.attachIconSize, 11)
    }

    func testSendButtonUsesFixedCenteredHeight() {
        XCTAssertGreaterThanOrEqual(AssistantInputBarLayout.sendButtonHeight, 24)
        XCTAssertLessThanOrEqual(AssistantInputBarLayout.keycapHeight,
                                 AssistantInputBarLayout.sendButtonHeight)
        XCTAssertEqual(AssistantInputBarLayout.sendContentAlignment, .center)
    }
}
