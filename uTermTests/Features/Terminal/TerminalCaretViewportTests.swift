import XCTest
import SwiftTerm
@testable import uTerm

/// 往上翻到看不见光标所在行时，程序重绘不能把光标画回屏幕上。
///
/// Claude Code 每帧都是 `?25l`、重绘、把光标移回输入框、`?25h`，序列取自 2.1.318 的真实输出。
@MainActor
final class TerminalCaretViewportTests: XCTestCase {

    private static let claudeFrame = "\u{1B}[?25l\u{1B}[2D\u{1B}[4B\r\u{1B}[82C\u{1B}[1A\u{1B}[K\r\r\n\u{1B}[2C\u{1B}[4A\u{1B}[?25h"

    private func makeScrolledBackView() -> CopyableTerminalView {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let rows = view.getTerminal().rows
        view.feed(text: (0..<(rows * 4)).map { "line \($0)\r\n" }.joined())
        view.feed(text: Self.claudeFrame)
        view.scrollUp(lines: rows * 2)
        return view
    }

    private func caretIsOnScreen(_ view: TerminalView) -> Bool {
        view.subviews.contains { String(describing: type(of: $0)) == "CaretView" }
    }

    func testScrollingBackRemovesCaret() {
        XCTAssertFalse(caretIsOnScreen(makeScrolledBackView()))
    }

    func testProgramRedrawKeepsCaretHiddenWhileScrolledBack() {
        let view = makeScrolledBackView()
        view.feed(text: Self.claudeFrame)
        XCTAssertFalse(caretIsOnScreen(view))
    }

    func testCaretReturnsAfterScrollingBackToBottom() {
        let view = makeScrolledBackView()
        view.feed(text: Self.claudeFrame)
        view.scrollDown(lines: view.getTerminal().rows * 4)
        XCTAssertTrue(caretIsOnScreen(view))
    }

    func testProgramCanStillShowCaretAtBottom() {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.feed(text: "\u{1B}[?25l")
        XCTAssertFalse(caretIsOnScreen(view))
        view.feed(text: "\u{1B}[?25h")
        XCTAssertTrue(caretIsOnScreen(view))
    }

    func testProgramHiddenCaretStaysHiddenAfterScrollingBackToBottom() {
        let view = makeScrolledBackView()
        view.feed(text: "\u{1B}[?25l")
        view.scrollDown(lines: view.getTerminal().rows * 4)
        XCTAssertFalse(caretIsOnScreen(view))
    }
}
