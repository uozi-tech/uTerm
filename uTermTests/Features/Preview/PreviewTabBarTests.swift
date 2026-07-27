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

    func test_contextMenuCloseTargets_followTabOrderAndScope() {
        let first = UUID()
        let target = UUID()
        let third = UUID()
        let fourth = UUID()
        let ordered = [first, target, third, fourth]

        XCTAssertEqual(
            PreviewTabMenuPlanner.closeTargets(
                for: .selected, targetID: target, orderedIDs: ordered),
            [target])
        XCTAssertEqual(
            PreviewTabMenuPlanner.closeTargets(
                for: .others, targetID: target, orderedIDs: ordered),
            [first, third, fourth])
        XCTAssertEqual(
            PreviewTabMenuPlanner.closeTargets(
                for: .tabsToRight, targetID: target, orderedIDs: ordered),
            [third, fourth])
        XCTAssertEqual(
            PreviewTabMenuPlanner.closeTargets(
                for: .all, targetID: target, orderedIDs: ordered),
            ordered)
    }

    func test_contextMenuCloseTargets_areEmptyForMissingTarget() {
        XCTAssertTrue(
            PreviewTabMenuPlanner.closeTargets(
                for: .all,
                targetID: UUID(),
                orderedIDs: [UUID(), UUID()])
                .isEmpty)
    }
}
