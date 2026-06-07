import XCTest
import AppKit
@testable import uTerm

@MainActor
final class PreviewTabBarTests: XCTestCase {
    func test_tabBarBackground_matches_editor_background_in_dark_mode() {
        var resolved = PreviewTabBar.tabBarBackgroundColor
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            resolved = PreviewTabBar.tabBarBackgroundColor.usingColorSpace(NSColorSpace.sRGB)
                ?? PreviewTabBar.tabBarBackgroundColor
        }

        XCTAssertEqual(Double(resolved.redComponent), 16/255, accuracy: 0.01)
        XCTAssertEqual(Double(resolved.greenComponent), 16/255, accuracy: 0.01)
        XCTAssertEqual(Double(resolved.blueComponent), 18/255, accuracy: 0.01)
    }
}
