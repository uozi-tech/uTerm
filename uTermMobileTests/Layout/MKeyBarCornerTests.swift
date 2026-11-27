import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 键盘条两端的键不进屏幕圆角（实机反馈：Duo 内屏横握、竖握，外屏也是，键盘条往下伸进 Home 条那一截之后，
/// 最左的面板键、最右的键盘键有一截画到了屏幕圆角外面）。
///
/// 修之前 Duo 模拟器展开横握的读数：屏幕 951×669、圆角 55，两端的键离侧边 10、离底边 10，键帽外角离圆弧
/// 还差十几点（在圆弧外面）。
@MainActor
final class MKeyBarCornerTests: XCTestCase {
    private final class Probe {
        var leading: CGRect = .zero
        var trailing: CGRect = .zero
    }

    private struct Harness: View {
        let probe: Probe

        var body: some View {
            VStack(spacing: 0) {
                Color.blue
                MKeyBar(panel: .constant(Int?.none), softKeyboardUp: .constant(false)) {
                    Color.red.frame(width: MKeyCapMetrics.minWidth, height: MKeyCapMetrics.height)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.leading = $0 }
                } row: {
                    Color.green.frame(width: 40, height: MKeyCapMetrics.height)
                } trailing: {
                    Color.red.frame(width: MKeyCapMetrics.minWidth, height: MKeyCapMetrics.height)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.trailing = $0 }
                } content: { _ in
                    EmptyView()
                }
            }
        }
    }

    // MARK: - 算法

    func testSideInsetMath() {
        let r = MRadius.sm
        // 键帽离底边 15（键盘条收回 Home 条之后的位置）、圆角 55：离侧边至少 47 − √(37² − 32²) ≈ 28.4。
        XCTAssertEqual(MKeyBarCornerClearance.sideInset(cornerRadius: 55, capBottomGap: 15, capRadius: r, margin: 10),
                       47 - (37.0 * 37 - 32 * 32).squareRoot(), accuracy: 0.01)
        XCTAssertEqual(MKeyBarCornerClearance.sideInset(cornerRadius: 55, capBottomGap: 50, capRadius: r, margin: 10), 0,
                       "键帽高过圆弧：不用让")
        XCTAssertEqual(MKeyBarCornerClearance.sideInset(cornerRadius: 0, capBottomGap: 0, capRadius: r, margin: 10), 0,
                       "没有圆角（读不到）：不让")
        XCTAssertEqual(MKeyBarCornerClearance.sideInset(cornerRadius: 55, capBottomGap: 6, capRadius: r, margin: 10), 47,
                       "离底边比要留的还近：整个挪出圆角那一段")
    }

    /// 藏着的标签页把整格挪到屏外：不按它算圆角，否则边距越算越大，整排键盘条把工作区撑破
    /// （TF 1657 实机：Duo 横握打开配对 Mac 的 Code 标签页，行在 x ≈ −99 699，左边距算成 99 710，下一轮 198 991；
    /// Code 标签页只剩顶上 55pt，键盘条压进右侧状态栏那一列）。
    func testRowOutsideTheWindowKeepsTheBasePadding() {
        let corners = MWindowCorners(size: CGSize(width: 951, height: 669), bottomLeft: 55, bottomRight: 55)
        for row in [CGRect(x: -99_699, y: 587, width: 566, height: 48),
                    CGRect(x: -198_962.5, y: 611, width: 199_093, height: 48),
                    CGRect(x: 960, y: 611, width: 400, height: 48)] {
            XCTAssertEqual(MKeyBarCornerClearance.padding(base: 10, row: row, corners: corners, edge: .left), 10, "\(row)")
            XCTAssertEqual(MKeyBarCornerClearance.padding(base: 10, row: row, corners: corners, edge: .right), 10, "\(row)")
        }
    }

    /// 无论坐标怎么来，让出的最多一个圆角半径。
    func testPaddingNeverExceedsTheCornerRadius() {
        let corners = MWindowCorners(size: CGSize(width: 951, height: 669), bottomLeft: 55, bottomRight: 55)
        for x in stride(from: 0.0, through: 900, by: 50) {
            let row = CGRect(x: x, y: 669 - 15 - 38 - 5, width: 951 - x, height: 48)
            for edge in [MKeyBarCornerClearance.HorizontalEdgeSide.left, .right] {
                XCTAssertLessThanOrEqual(MKeyBarCornerClearance.padding(base: 10, row: row, corners: corners, edge: edge), 65)
            }
        }
    }

    func testPaddingCountsFromTheRowEdge() {
        let corners = MWindowCorners(size: CGSize(width: 951, height: 669), bottomLeft: 55, bottomRight: 55)
        // 行从屏幕左边起、右边让出 84 的侧列；键帽底离屏幕底 15。
        let row = CGRect(x: 0, y: 669 - 15 - 38 - 5, width: 867, height: 48)
        let left = MKeyBarCornerClearance.padding(base: 10, row: row, corners: corners, edge: .left)
        let right = MKeyBarCornerClearance.padding(base: 10, row: row, corners: corners, edge: .right)
        XCTAssertEqual(left, 29, "左边贴着屏幕角")
        XCTAssertEqual(right, 10, "右边离屏幕边已有 84，平时的边距就够")
        XCTAssertEqual(MKeyBarCornerClearance.padding(base: 10, row: row, corners: MWindowCorners(), edge: .left), 10,
                       "还没读到窗口：照平时")
    }

    // MARK: - 实际排版

    /// 全屏铺开、键盘条贴底：两端键帽的外角都在屏幕圆弧里面，且离圆弧不少于 10pt。
    func testEndKeysStayInsideTheScreenCorners() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("iOS 26 才读得到窗口圆角") }
        defer { MobileProbeWindow.closeAll() }
        let probe = Probe()
        let (window, host) = MobileProbeWindow.make(placement: .visibleOnScreen, rootView: Harness(probe: probe))
        host.safeAreaRegions = .all
        try await Task.sleep(for: .milliseconds(800))

        let concentric = UIView(frame: window.bounds)
        concentric.cornerConfiguration = .corners(radius: .containerConcentric())
        window.addSubview(concentric)
        defer { concentric.removeFromSuperview() }
        window.layoutIfNeeded()
        let size = window.bounds.size
        let radii = (left: concentric.effectiveRadius(corner: .bottomLeft),
                     right: concentric.effectiveRadius(corner: .bottomRight))
        print("KEYBAR-CORNER screen=\(size) radius=\(radii) safe=\(window.safeAreaInsets) "
              + "leading=\(probe.leading) trailing=\(probe.trailing)")
        guard radii.left > 0 || radii.right > 0 else { throw XCTSkip("这台没有屏幕圆角") }
        XCTAssertGreaterThan(probe.leading.width, 0, "没量到键")

        let r = MRadius.sm
        func clearance(_ key: CGRect, radius R: CGFloat, left: Bool) -> CGFloat? {
            // 键帽外下角那段圆的圆心，与屏幕圆弧的圆心。
            let corner = CGPoint(x: left ? key.minX + r : key.maxX - r, y: key.maxY - r)
            let arc = CGPoint(x: left ? R : size.width - R, y: size.height - R)
            let inQuadrant = (left ? corner.x < arc.x : corner.x > arc.x) && corner.y > arc.y
            guard inQuadrant else { return nil }
            return R - r - hypot(corner.x - arc.x, corner.y - arc.y)
        }
        if let gap = clearance(probe.leading, radius: radii.left, left: true) {
            XCTAssertGreaterThanOrEqual(gap, 10 - 0.5, "最左的键离屏幕圆角只有 \(gap)pt（负数 = 画到圆角外面）")
        }
        if let gap = clearance(probe.trailing, radius: radii.right, left: false) {
            XCTAssertGreaterThanOrEqual(gap, 10 - 0.5, "最右的键离屏幕圆角只有 \(gap)pt（负数 = 画到圆角外面）")
        }
    }
}
