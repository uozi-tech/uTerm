import XCTest
@testable import uTerm

/// 原来核的是 SwiftTerm 视图上的光标：往上翻到看不见光标所在行时，程序重绘不能把光标画回屏幕上（SwiftTerm 的光标是
/// 一个独立的 `CaretView` 子视图，要靠补丁在翻上去时把它摘掉、程序重绘时别再挂回来）。
///
/// Ghostty 的光标不是视图：渲染器把它画在活动屏的那一格上，视口翻上去之后那一行不在视口里，自然不画；翻回底部
/// 又在。这件事没有可读的视图状态（没有子视图、没有对外的「光标画没画」的读数），所以翻上去那几条没有等价断言，
/// 保留用例、标跳过。程序显隐光标（DECTCEM）仍然可核：读影子终端的 `cursor.visible`。
///
/// Claude Code 每帧都是 `?25l`、重绘、把光标移回输入框、`?25h`，序列取自 2.1.318 的真实输出。
final class TerminalCaretViewportTests: XCTestCase {

    private static let claudeFrame = "\u{1B}[?25l\u{1B}[2D\u{1B}[4B\r\u{1B}[82C\u{1B}[1A\u{1B}[K\r\r\n\u{1B}[2C\u{1B}[4A\u{1B}[?25h"
    private static let noCaretView = "SwiftTerm 的 CaretView 补丁随 SwiftTerm 删除：Ghostty 的光标由渲染器画在活动屏的格子上，"
        + "视口翻上去时那一行不在视口里就不画，没有可读的视图状态"

    private func makeTerminal() -> ShadowTerminal {
        let terminal = ShadowTerminal(cols: 85, rows: 28, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        terminal.feed(Data((0..<(28 * 4)).map { "line \($0)\r\n" }.joined().utf8))
        return terminal
    }

    func testScrollingBackRemovesCaret() throws {
        throw XCTSkip(Self.noCaretView)
    }

    func testProgramRedrawKeepsCaretHiddenWhileScrolledBack() throws {
        throw XCTSkip(Self.noCaretView)
    }

    func testCaretReturnsAfterScrollingBackToBottom() throws {
        throw XCTSkip(Self.noCaretView)
    }

    func testProgramHiddenCaretStaysHiddenAfterScrollingBackToBottom() throws {
        throw XCTSkip(Self.noCaretView)
    }

    /// 程序自己显隐光标照常生效。
    func testProgramCanStillShowCaretAtBottom() {
        let terminal = makeTerminal()
        XCTAssertTrue(terminal.cursor.visible)
        terminal.feed(Data("\u{1B}[?25l".utf8))
        XCTAssertFalse(terminal.cursor.visible)
        terminal.feed(Data("\u{1B}[?25h".utf8))
        XCTAssertTrue(terminal.cursor.visible)
    }

    /// Claude 的一帧（先藏光标、重绘、移回输入框、再显示）走完：光标是显示的，位置回到这一帧开始的地方。
    func testClaudeFrameLeavesCaretVisibleWhereItStarted() {
        let terminal = makeTerminal()
        terminal.feed(Data("\u{1B}[20;5H".utf8))
        let before = terminal.cursor
        terminal.feed(Data(Self.claudeFrame.utf8))
        XCTAssertTrue(terminal.cursor.visible)
        XCTAssertEqual(terminal.cursor.y, before.y)
        XCTAssertEqual(terminal.cursor.x, 2, "这一帧最后把光标放在输入框的第 3 列")
        // 帧被拆成两次读取：中间那一刻光标是藏着的，走完又回来。
        let bytes = Array(Self.claudeFrame.utf8)
        terminal.feed(Data(bytes[..<10]))
        XCTAssertFalse(terminal.cursor.visible)
        terminal.feed(Data(bytes[10...]))
        XCTAssertTrue(terminal.cursor.visible)
    }
}
