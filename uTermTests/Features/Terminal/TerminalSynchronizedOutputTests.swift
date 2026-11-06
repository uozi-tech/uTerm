import XCTest
import SwiftTerm
@testable import uTerm

/// Claude Code 思考时的帧，序列取自 2.1.318 跑在 SwiftTerm 里的真实输出：
/// 每帧约 150 字节、10 帧/秒，包在 DEC 2026 里，可能被拆进两次读取。
@MainActor
final class TerminalSynchronizedOutputTests: XCTestCase {
    private static let frameStart = "\u{1B}[?2026h\u{1B}[?25l\u{1B}[2D\u{1B}[3B\r\u{1B}[6A\u{1B}[38;2;215;119;87m*"
    private static let frameEnd = "\u{1B}[39m\r\r\n\r\n\r\n\r\n\r\n\r\n\u{1B}[2C\u{1B}[3A\u{1B}[?25h\u{1B}[?2026l"

    private func makeView() -> CopyableTerminalView {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let rows = view.getTerminal().rows
        view.feed(text: (0..<(rows * 4)).map { "line \($0)\r\n" }.joined())
        view.feed(text: "\u{1B}[3A")
        view.getTerminal().clearUpdateRange()
        return view
    }

    private func caretIsOnScreen(_ view: TerminalView) -> Bool {
        view.subviews.contains { String(describing: type(of: $0)) == "CaretView" }
    }

    private func wheel(lines: Int, in view: TerminalView) throws -> NSEvent {
        let cell = view.getOptimalFrameSize().height / CGFloat(view.getTerminal().rows)
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: Int32((CGFloat(lines) * cell).rounded(.up)), wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    func testFrameEndOnlyMarksRowsTheFrameTouched() throws {
        let view = makeView()
        let terminal = view.getTerminal()
        view.feed(text: Self.frameStart + Self.frameEnd)
        let range = try XCTUnwrap(terminal.getUpdateRange())
        XCTAssertEqual(range.startY, range.endY, "这一帧只写了一行，不该把整屏标脏")
    }

    func testRowsChangedInsideAFrameStayMarkedAfterItEnds() throws {
        let view = makeView()
        let terminal = view.getTerminal()
        view.feed(text: "\u{1B}[?2026h\u{1B}[H\u{1B}[2Kchanged")
        view.feed(text: "\u{1B}[?2026l")
        XCTAssertEqual(try XCTUnwrap(terminal.getUpdateRange()).startY, 0)
    }

    func testCaretStaysWhileASplitFrameIsOpen() {
        let view = makeView()
        XCTAssertTrue(caretIsOnScreen(view))
        view.feed(text: Self.frameStart)
        XCTAssertTrue(caretIsOnScreen(view), "帧被拆开时光标不能闪")
        view.feed(text: Self.frameEnd)
        XCTAssertTrue(caretIsOnScreen(view))
    }

    func testCaretFollowsTheFinalStateOfTheFrame() {
        let view = makeView()
        view.feed(text: "\u{1B}[?2026h\u{1B}[?25l\u{1B}[?2026l")
        view.flushPendingDisplay()
        XCTAssertFalse(caretIsOnScreen(view))
        view.feed(text: "\u{1B}[?2026h\u{1B}[?25h\u{1B}[?2026l")
        view.flushPendingDisplay()
        XCTAssertTrue(caretIsOnScreen(view))
    }

    func testWheelWaitsForAnOpenFrameToEnd() throws {
        let view = makeView()
        let terminal = view.getTerminal()
        let bottom = terminal.buffer.yDisp
        view.feed(text: Self.frameStart)
        view.scrollWheel(with: try wheel(lines: 2, in: view))
        XCTAssertEqual(terminal.buffer.yDisp, bottom, "帧没写完时滚动会把半帧画出来")
        view.feed(text: Self.frameEnd)
        XCTAssertLessThan(terminal.buffer.yDisp, bottom, "帧结束后要补上这次滚动")
    }

    func testWheelScrollsRightAwayWithoutAnOpenFrame() throws {
        let view = makeView()
        let terminal = view.getTerminal()
        let bottom = terminal.buffer.yDisp
        view.scrollWheel(with: try wheel(lines: 2, in: view))
        XCTAssertLessThan(terminal.buffer.yDisp, bottom)
    }
}
