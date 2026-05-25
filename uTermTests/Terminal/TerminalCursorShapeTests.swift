import XCTest
@testable import uTerm

final class TerminalCursorShapeTests: XCTestCase {
    func test_allCases_count_and_order() {
        XCTAssertEqual(TerminalCursorShape.allCases, [.block, .underline, .bar])
    }

    func test_rawValues() {
        XCTAssertEqual(TerminalCursorShape.block.rawValue,     "block")
        XCTAssertEqual(TerminalCursorShape.underline.rawValue, "underline")
        XCTAssertEqual(TerminalCursorShape.bar.rawValue,       "bar")
    }

    func test_localizedLabels() {
        XCTAssertEqual(TerminalCursorShape.block.localizedLabel,     "█ 块")
        XCTAssertEqual(TerminalCursorShape.underline.localizedLabel, "_ 下划线")
        XCTAssertEqual(TerminalCursorShape.bar.localizedLabel,       "| 竖线")
    }

    func test_decscusrParameter_steady() {
        XCTAssertEqual(TerminalCursorShape.block.decscusrParameter(blink: false),     2)
        XCTAssertEqual(TerminalCursorShape.underline.decscusrParameter(blink: false), 4)
        XCTAssertEqual(TerminalCursorShape.bar.decscusrParameter(blink: false),       6)
    }

    func test_decscusrParameter_blink() {
        XCTAssertEqual(TerminalCursorShape.block.decscusrParameter(blink: true),     1)
        XCTAssertEqual(TerminalCursorShape.underline.decscusrParameter(blink: true), 3)
        XCTAssertEqual(TerminalCursorShape.bar.decscusrParameter(blink: true),       5)
    }
}
