import XCTest
@testable import uTerm

final class UDEqualPaddingLayoutTests: XCTestCase {
    func testChatMessageUserBubbleUsesEqualEdgePadding() {
        XCTAssertEqual(UDChatMessageLayout.userBubblePadding, UD.Space.lg)
    }

    func testTransferRowCardUsesEqualEdgePadding() {
        XCTAssertEqual(UDTransferRowLayout.cardPadding, UD.Space.lg)
    }
}
