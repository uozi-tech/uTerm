import XCTest
@testable import uTerm

/// `paneGrabOffset` maps (mouse, pane on-screen frame) → offset from the pane's
/// TOP-LEFT. macOS screen coords are bottom-up, so the pane's top edge is
/// `frame.maxY`; vertical offset is `maxY - mouse.y`. Result is clamped to the
/// pane's size.
final class PaneGrabOffsetTests: XCTestCase {
    // Pane on screen: x∈[100,400], y∈[200,350] (bottom-up). Top edge y = 350.
    private let frame = CGRect(x: 100, y: 200, width: 300, height: 150)

    func testTopLeftCornerIsZero() {
        let off = paneGrabOffset(mouse: CGPoint(x: 100, y: 350), in: frame)
        XCTAssertEqual(off.width, 0, accuracy: 0.0001)
        XCTAssertEqual(off.height, 0, accuracy: 0.0001)
    }

    func testCenter() {
        let off = paneGrabOffset(mouse: CGPoint(x: 250, y: 275), in: frame)
        XCTAssertEqual(off.width, 150, accuracy: 0.0001)
        XCTAssertEqual(off.height, 75, accuracy: 0.0001)
    }

    func testClampsLeftOfPaneToZeroWidth() {
        let off = paneGrabOffset(mouse: CGPoint(x: 50, y: 275), in: frame)
        XCTAssertEqual(off.width, 0, accuracy: 0.0001)
    }

    func testClampsBelowPaneToFullHeight() {
        // mouse.y below bottom edge (y < 200): maxY - y = 350 - 100 = 250 → clamp 150
        let off = paneGrabOffset(mouse: CGPoint(x: 250, y: 100), in: frame)
        XCTAssertEqual(off.height, 150, accuracy: 0.0001)
    }

    func testClampsAbovePaneToZeroHeight() {
        // mouse.y above top edge (y > 350): maxY - y = 350 - 400 = -50 → clamp 0
        let off = paneGrabOffset(mouse: CGPoint(x: 250, y: 400), in: frame)
        XCTAssertEqual(off.height, 0, accuracy: 0.0001)
    }
}
