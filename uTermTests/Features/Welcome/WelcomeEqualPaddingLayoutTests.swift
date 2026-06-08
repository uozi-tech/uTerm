import XCTest
@testable import uTerm

final class WelcomeEqualPaddingLayoutTests: XCTestCase {
    func testServerRowUsesEqualEdgePadding() {
        XCTAssertEqual(ServerRowLayout.contentPadding, UD.Space.xl)
    }

    func testServerFormInfoCardUsesEqualEdgePadding() {
        XCTAssertEqual(ServerFormLayout.infoCardPadding, UD.Space.lg)
    }
}
