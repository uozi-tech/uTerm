import XCTest
@testable import uTerm

@MainActor
final class BackgroundLaunchModeTests: XCTestCase {
    func testLoginHelperUsesExplicitBackgroundEntry() {
        XCTAssertEqual(
            BackgroundLaunchMode.presentation(arguments: ["uTerm", "--background", "--launch-source", "login-item"]),
            .background
        )
    }

    func testCLIUsesExplicitBackgroundEntry() {
        XCTAssertTrue(BackgroundLaunchMode.shouldStartHidden(arguments: ["uTerm", "--background"]))
    }

    func testManualColdLaunchIsForegroundEvenWhenPreferencesExist() {
        XCTAssertEqual(BackgroundLaunchMode.presentation(arguments: ["uTerm"]), .foreground)
    }

    func testReopeningExistingBackgroundProcessPromotesGUI() {
        XCTAssertEqual(BackgroundLaunchMode.reopenPresentation, .foreground)
    }
}
