import SwiftUI
import XCTest
@testable import uTermMobile

/// iPhone Duo 真机读数（2026-11-15 `FoldableChromeProbeTests.testRecordPostures` 实录，iOS 27.2）
/// 喂进 `MChromeGeometry`：状态栏要从 UIKit 的遮挡保留区挑出来，侧列要认左右两边。
@MainActor
final class MChromeDuoReadingsTests: XCTestCase {
    private func region(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                        active: Bool = true) -> MChromeGeometry.RawRegion {
        .init(frame: CGRect(x: x, y: y, width: w, height: h), active: active)
    }

    /// 按整屏尺寸与安全区造几何值，再叠上 UIKit 探针的遮挡区与竖栏。
    private func chrome(screen: CGSize, top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 34,
                        trailing: CGFloat = 0, occlusion: [MChromeGeometry.RawRegion],
                        verticalBar: HorizontalEdge? = nil, reportsVerticalBar: Bool = true) -> MChromeGeometry {
        let base = MChromeGeometry(
            root: CGRect(x: leading, y: top, width: screen.width - leading - trailing,
                         height: screen.height - top - bottom),
            safeAreaInsets: EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing))
        var probe = MChromeProbeResult()
        probe.occlusion = occlusion
        probe.verticalBarEdge = verticalBar
        probe.reportsVerticalBarEdge = reportsVerticalBar
        return base.merging(probe)
    }

    private var unfoldedLandscape: MChromeGeometry {
        chrome(screen: CGSize(width: 951, height: 669), trailing: 84,
               occlusion: [region(658, 22, 61, 39, active: false), region(867, 0, 84, 124)],
               verticalBar: .trailing)
    }

    private var foldedPortrait: MChromeGeometry {
        chrome(screen: CGSize(width: 466, height: 678), trailing: 84,
               occlusion: [region(399, 29, 37, 37), region(382, 0, 84, 174)], verticalBar: .trailing)
    }

    private var foldedLandscape: MChromeGeometry {
        chrome(screen: CGSize(width: 678, height: 466), leading: 84,
               occlusion: [region(29, 29, 37, 37), region(0, 0, 84, 82)], verticalBar: .leading)
    }

    func testUnfoldedLandscapeColumnSitsBelowTheStatusBar() throws {
        let g = unfoldedLandscape
        XCTAssertEqual(g.statusBar, CGRect(x: 867, y: 0, width: 84, height: 124))
        let column = try XCTUnwrap(g.statusColumn)
        XCTAssertEqual(column.edge, .trailing)
        XCTAssertEqual(column.width, 84)
        XCTAssertEqual(column.statusBottom, 124)
        XCTAssertTrue(g.hasSideStatusColumn)
        XCTAssertNil(g.statusRowHeight)
    }

    func testFoldedPortraitIgnoresTheCameraCutout() throws {
        let g = foldedPortrait
        XCTAssertEqual(g.statusBar, CGRect(x: 382, y: 0, width: 84, height: 174), "前置摄像头那块不贴屏幕顶")
        let column = try XCTUnwrap(g.statusColumn)
        XCTAssertEqual(column.edge, .trailing)
        XCTAssertEqual(column.statusBottom, 174)
        XCTAssertTrue(g.hasSideStatusColumn)
    }

    func testFoldedLandscapeColumnIsOnTheLeadingEdge() throws {
        let g = foldedLandscape
        XCTAssertEqual(g.statusBar, CGRect(x: 0, y: 0, width: 84, height: 82))
        let column = try XCTUnwrap(g.statusColumn)
        XCTAssertEqual(column.edge, .leading)
        XCTAssertEqual(column.width, 84)
        XCTAssertEqual(column.statusBottom, 82)
        XCTAssertTrue(g.hasSideStatusColumn)
    }

    func testInactiveRegionsAreNotTheStatusBar() {
        let g = chrome(screen: CGSize(width: 951, height: 669), trailing: 84,
                       occlusion: [region(867, 0, 84, 124, active: false)], verticalBar: .trailing)
        XCTAssertNil(g.statusBar)
        XCTAssertNil(g.statusColumn)
        XCTAssertTrue(g.hasSideStatusColumn, "侧列判定不依赖状态栏矩形")
    }

    /// 转屏后 `verticalBarEdge` 比安全区晚一拍：折叠横握第一次读数仍是 trailing，安全区已在左边。
    func testVerticalBarEdgeLaggingBehindTheSafeAreaDoesNotCount() {
        let lagging = chrome(screen: CGSize(width: 678, height: 466), leading: 84,
                             occlusion: [region(0, 0, 84, 82)], verticalBar: .trailing)
        XCTAssertFalse(lagging.hasSideStatusColumn)
    }

    func testNoVerticalBarMeansNoSideColumn() {
        // 系统说没有竖栏时，即使安全区只有一侧也不算（普通 iPhone 横屏两侧都有，本来就不算）。
        let g = chrome(screen: CGSize(width: 466, height: 678), trailing: 84, occlusion: [], verticalBar: nil)
        XCTAssertFalse(g.hasSideStatusColumn)
    }

    func testOlderSystemsGuessFromAOneSidedSafeArea() {
        func guess(leading: CGFloat, trailing: CGFloat) -> Bool {
            chrome(screen: CGSize(width: 678, height: 466), leading: leading, trailing: trailing,
                   occlusion: [], reportsVerticalBar: false).hasSideStatusColumn
        }
        XCTAssertTrue(guess(leading: 0, trailing: 84), "Duo 折叠竖握")
        XCTAssertTrue(guess(leading: 84, trailing: 0), "Duo 折叠横握")
        XCTAssertFalse(guess(leading: 62, trailing: 62), "普通 iPhone 横屏")
    }
}
