import XCTest
@testable import uTermMobile

/// 宽度自适应的两条纯函数：终端字号曲线与主机卡片网格列数。
final class MobileAdaptiveLayoutTests: XCTestCase {

    // MARK: - 终端字号

    func testFontSizeAtReferenceWidthIsBase() {
        XCTAssertEqual(TerminalSessionBody.adaptiveFontSize(width: 390), 11, accuracy: 0.001)
    }

    func testFontSizeShrinksOnNarrowScreensDownToNine() {
        // iPhone Duo 分屏 ≈ 330pt、SE 320pt：按比例缩小。
        XCTAssertEqual(TerminalSessionBody.adaptiveFontSize(width: 330), 11 * 330 / 390, accuracy: 0.001)
        XCTAssertEqual(TerminalSessionBody.adaptiveFontSize(width: 200), 9, accuracy: 0.001)
    }

    func testFontSizeGrowsSlowlyOnWideScreens() {
        // Duo 折叠 466pt / 展开 669pt：只比基准大一点，不再顶到 16pt。
        let folded = TerminalSessionBody.adaptiveFontSize(width: 466)
        let unfolded = TerminalSessionBody.adaptiveFontSize(width: 669)
        XCTAssertGreaterThan(folded, 11)
        XCTAssertLessThan(folded, 11.5)
        XCTAssertLessThan(unfolded, 12.5)
        // iPad：封顶 13pt。
        XCTAssertEqual(TerminalSessionBody.adaptiveFontSize(width: 1366), 13, accuracy: 0.001)
    }

    func testFontSizeZeroWidthFallsBackToBase() {
        XCTAssertEqual(TerminalSessionBody.adaptiveFontSize(width: 0), 11, accuracy: 0.001)
    }

    // MARK: - 卡片网格列数

    func testCardColumnsByDeviceWidth() {
        // 内容宽 = 屏宽 − 左右各 16pt 页边距。
        XCTAssertEqual(mCardColumns(for: 390 - 32), 1, "普通 iPhone 竖屏一列")
        XCTAssertEqual(mCardColumns(for: 466 - 32), 1, "Duo 折叠一列")
        XCTAssertEqual(mCardColumns(for: 669 - 32), 2, "Duo 展开两列")
        XCTAssertEqual(mCardColumns(for: 1032 - 32), 3, "iPad 竖屏三列")
        XCTAssertEqual(mCardColumns(for: 1080 - 32), 3, "网格页封顶宽度仍三列")
    }

    func testCardSpacingIsTightAndStepsUpOnWideScreens() {
        XCTAssertEqual(mCardSpacing(for: 0), 10, "未量到宽度按窄屏")
        XCTAssertEqual(mCardSpacing(for: 358), 10)
        XCTAssertEqual(mCardSpacing(for: 637), 12)
        XCTAssertEqual(mCardSpacing(for: 1048), 12)
    }

    func testCardColumnsNeverExceedMaxOrDropBelowOne() {
        XCTAssertEqual(mCardColumns(for: 0), 1)
        XCTAssertEqual(mCardColumns(for: 5000), 3)
        XCTAssertEqual(mCardColumns(for: 5000, maxColumns: 2), 2)
    }
}
