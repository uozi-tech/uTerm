import XCTest
import UDesignKit
@testable import uTerm

final class ChatCodeBlockTests: XCTestCase {
    @MainActor
    func test_usesBubbleCornerRadiusToken() {
        XCTAssertEqual(ChatCodeBlock.containerCornerRadius, UD.Radius.lg)
    }
}
