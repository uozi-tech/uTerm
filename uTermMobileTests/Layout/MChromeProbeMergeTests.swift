import SwiftUI
import XCTest
@testable import uTermMobile

/// UIKit 探针的结果要原样进几何值：展开 Duo 的判定只有探针知道。
@MainActor
final class MChromeProbeMergeTests: XCTestCase {
    private func portrait(width: CGFloat = 669, height: CGFloat = 951) -> MChromeGeometry {
        MChromeGeometry(root: CGRect(x: 0, y: 82, width: width, height: height - 82 - 20),
                        safeAreaInsets: EdgeInsets(top: 82, leading: 0, bottom: 20, trailing: 0))
    }

    private func probe(unfolded: Bool, topBarWidth: CGFloat = 500) -> MChromeProbeResult {
        MChromeProbeResult(topBar: CGRect(x: 16, y: 10, width: topBarWidth, height: 48),
                           cornerSafeArea: CGRect(x: 0, y: 10, width: 516, height: 900),
                           isUnfoldedPhone: unfolded)
    }

    func testMergingCarriesEveryProbedField() {
        let result = probe(unfolded: true)
        let merged = portrait().merging(result)

        XCTAssertEqual(merged.topBar, result.topBar)
        XCTAssertEqual(merged.cornerSafeArea, result.cornerSafeArea)
        XCTAssertTrue(merged.isUnfoldedPhone)
    }

    func testMergingKeepsWhatSwiftUIMeasured() {
        let base = portrait()
        let merged = base.merging(probe(unfolded: false))
        XCTAssertEqual(merged.root, base.root)
        XCTAssertEqual(merged.safeAreaInsets, base.safeAreaInsets)
    }

    func testFoldStateAloneDecidesTheStatusRow() {
        XCTAssertEqual(portrait().merging(probe(unfolded: true)).statusRowHeight, 82)
        XCTAssertNil(portrait().merging(probe(unfolded: false)).statusRowHeight)
    }

    /// 折叠 ⇄ 展开要让监听探针结果的地方看得到变化。
    func testFoldChangeIsAProbeChange() {
        XCTAssertNotEqual(probe(unfolded: true), probe(unfolded: false))
    }

    // MARK: - 连接中页的 chip 进状态行

    func testChipJoinsTheStatusRowOnAWideUnfoldedScreen() {
        let chrome = portrait().merging(probe(unfolded: true))
        XCTAssertEqual(ConnectingCoverView.chipStatusRow(chrome: chrome, fillsScreen: true), 82)
    }

    func testChipStaysOutWhenOnlyCoveringAPane() {
        let chrome = portrait().merging(probe(unfolded: true))
        XCTAssertNil(ConnectingCoverView.chipStatusRow(chrome: chrome, fillsScreen: false))
    }

    func testChipStaysOutInANarrowWindow() {
        let chrome = portrait(width: 330).merging(probe(unfolded: true, topBarWidth: 280))
        XCTAssertNotNil(chrome.statusRowHeight, "窗口窄但状态行还在，拦住它的是宽度")
        XCTAssertNil(ConnectingCoverView.chipStatusRow(chrome: chrome, fillsScreen: true))
    }

    func testChipStaysOutWhenItWouldRunIntoTheStatusBar() {
        // 屏幕中线 334.5，chip 半宽 64 + 间距 8：右沿 406.5，顶部横条只到 396。
        let chrome = portrait().merging(probe(unfolded: true, topBarWidth: 380))
        XCTAssertNotNil(chrome.statusRowHeight)
        XCTAssertNil(ConnectingCoverView.chipStatusRow(chrome: chrome, fillsScreen: true))
    }

    func testChipStaysOutOnOtherDevices() {
        let chrome = portrait().merging(probe(unfolded: false))
        XCTAssertNil(ConnectingCoverView.chipStatusRow(chrome: chrome, fillsScreen: true))
    }
}
