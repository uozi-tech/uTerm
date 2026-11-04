import SwiftUI
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

/// iPhone Duo 状态栏几何（数值取自 vphone sbdisplay-duo 实测，iOS 27.1）。
final class MChromeGeometryTests: XCTestCase {
    /// 展开竖屏：669×951，顶部安全区 82。
    private func portrait(status: CGRect?) -> MChromeGeometry {
        MChromeGeometry(root: CGRect(x: 0, y: 82, width: 669, height: 835),
                        safeAreaInsets: EdgeInsets(top: 82, leading: 0, bottom: 34, trailing: 0),
                        statusBar: status)
    }

    /// 展开横屏：951×669，右侧安全区 84。
    private func landscape(status: CGRect?) -> MChromeGeometry {
        MChromeGeometry(root: CGRect(x: 0, y: 0, width: 867, height: 635),
                        safeAreaInsets: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84),
                        statusBar: status)
    }

    func testPortraitStatusRowUsesTopInset() {
        let g = portrait(status: CGRect(x: 525, y: 0, width: 144, height: 82))
        XCTAssertEqual(g.statusRowHeight, 82)
        XCTAssertNil(g.statusColumn)
    }

    func testPortraitRejectsStaleRectsSeenMidRotation() {
        // 转屏途中报过的两个过期矩形：转置的左上角块、横屏那种竖条。
        XCTAssertNil(portrait(status: CGRect(x: 0, y: 0, width: 82, height: 144)).statusRowHeight)
        XCTAssertNil(portrait(status: CGRect(x: 585, y: 0, width: 84, height: 124)).statusRowHeight)
    }

    func testLandscapeStatusColumnBelowStatusBar() {
        let g = landscape(status: CGRect(x: 867, y: 0, width: 84, height: 124))
        XCTAssertEqual(g.statusColumn?.width, 84)
        XCTAssertEqual(g.statusColumn?.statusBottom, 124)
        XCTAssertNil(g.statusRowHeight)
    }

    func testLandscapeRejectsPortraitShapedRect() {
        XCTAssertNil(landscape(status: CGRect(x: 807, y: 0, width: 144, height: 82)).statusColumn)
    }

    func testPortraitStatusRowFromTopBarRegionWithoutOcclusion() {
        // 真机：状态栏不报遮挡保留区，只有系统的顶部横条区域（上沿在状态行里）。
        var g = portrait(status: nil)
        g.isUnfoldedPhone = true
        g.topBar = CGRect(x: 16, y: 10, width: 500, height: 48)
        XCTAssertEqual(g.statusRowHeight, 82)
        // 横条区域在安全区之下（普通 iPhone / iPad）：不进状态行。
        g.topBar = CGRect(x: 16, y: 82, width: 637, height: 48)
        XCTAssertNil(g.statusRowHeight)
    }

    /// 普通 iPhone 与 iPad 的状态栏占着顶行，即使顶部横条区域的上沿高于安全区也不能进（模拟器实测值）。
    func testTopBarRegionDoesNotMakeStatusRowOnOtherDevices() {
        let devices: [(name: String, width: CGFloat, height: CGFloat, top: CGFloat, bottom: CGFloat, bar: CGRect)] = [
            ("iPhone 18 Pro", 402, 874, 62, 34, CGRect(x: 18, y: 10, width: 366, height: 48)),
            ("iPhone 17e", 390, 844, 47, 34, CGRect(x: 14, y: 10, width: 362, height: 48)),
            ("iPad Air 13", 1024, 1366, 32, 20, CGRect(x: 5, y: 10, width: 1013, height: 48)),
        ]
        for device in devices {
            var g = MChromeGeometry(root: CGRect(x: 0, y: device.top, width: device.width,
                                                 height: device.height - device.top - device.bottom),
                                    safeAreaInsets: EdgeInsets(top: device.top, leading: 0, bottom: device.bottom, trailing: 0))
            g.topBar = device.bar
            XCTAssertNil(g.statusRowHeight, device.name)
        }
    }

    func testUnfoldedPhoneIsDecidedByTheWholeScreen() {
        func unfolded(_ idiom: UIUserInterfaceIdiom, _ w: CGFloat, _ h: CGFloat) -> Bool {
            MChromeGeometry.isUnfoldedPhone(idiom: idiom, screenSize: CGSize(width: w, height: h))
        }
        XCTAssertTrue(unfolded(.phone, 669, 951), "Duo 展开竖屏")
        XCTAssertTrue(unfolded(.phone, 951, 669), "Duo 展开横屏")
        XCTAssertFalse(unfolded(.phone, 466, 678), "Duo 折叠")
        XCTAssertFalse(unfolded(.phone, 440, 956), "最大的普通 iPhone")
        XCTAssertFalse(unfolded(.phone, 956, 440), "普通 iPhone 横屏")
        XCTAssertFalse(unfolded(.pad, 744, 1133), "最小的 iPad")
    }

    func testNoStatusRegionKeepsDefaultLayout() {
        XCTAssertNil(portrait(status: nil).statusRowHeight)
        XCTAssertNil(landscape(status: nil).statusColumn)
    }
}

/// 定长数字码输入的规范化（配对码弹窗）。
final class MCodeFieldTests: XCTestCase {
    func testKeepsOnlyAsciiDigitsUpToLength() {
        XCTAssertEqual(MCodeField.normalize("123456", length: 6), "123456")
        XCTAssertEqual(MCodeField.normalize("1234567", length: 6), "123456", "超出的位截掉")
        XCTAssertEqual(MCodeField.normalize("123 456", length: 6), "123456", "粘贴带空格")
        XCTAssertEqual(MCodeField.normalize("配对码:12-34-56", length: 6), "123456", "粘贴带别的字符")
        XCTAssertEqual(MCodeField.normalize("١٢٣", length: 6), "", "非 ASCII 数字不收")
        XCTAssertEqual(MCodeField.normalize("", length: 6), "")
    }
}
