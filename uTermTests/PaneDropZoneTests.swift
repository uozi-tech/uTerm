import XCTest
import SwiftUI
@testable import uTerm

final class PaneDropZoneTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testCenter() {
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 50, y: 50), in: bounds), .center)
    }

    func testLeading() {
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 5, y: 50), in: bounds), .leading)
    }

    func testTrailing() {
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 95, y: 50), in: bounds), .trailing)
    }

    func testTop() {
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 50, y: 5), in: bounds), .top)
    }

    func testBottom() {
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 50, y: 95), in: bounds), .bottom)
    }

    func testCornerGoesToNearestEdge() {
        // 左上角 (5, 8)：distLeading=0.05 < distTop=0.08 → leading
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 5, y: 8), in: bounds), .leading)
    }

    func testCenterBoundaryAtEdgeFraction() {
        // nx = 0.25 恰在 center 边界内（>= 0.25）
        XCTAssertEqual(paneDropZone(at: CGPoint(x: 25, y: 50), in: bounds), .center)
    }

    func testZeroSizeBoundsReturnsNil() {
        XCTAssertNil(paneDropZone(at: .zero, in: .zero))
    }
}
