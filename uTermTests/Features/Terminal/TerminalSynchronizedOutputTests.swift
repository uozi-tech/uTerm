import XCTest
@testable import uTerm

/// Claude Code 思考时的帧，序列取自 2.1.318 的真实输出：每帧约 150 字节、10 帧/秒，包在 DEC 2026（同步输出）里，
/// 可能被拆进两次读取。
///
/// 原来核的是旧引擎视图里围着 2026 打的补丁（帧结束时只标脏这一帧碰过的行、帧没写完时光标不闪、滚轮等帧结束）。
/// Ghostty 这些都在渲染器里：2026 开着时渲染器不出帧，关了（或超时）才画，没有对外的脏行范围和「滚轮在等」的状态。
/// 能核的是解析这一半（影子终端，和画面同一个引擎）：帧拆不拆开结果一样、帧开着时引擎知道、内容与光标取帧的最终状态。
/// 渲染器内部的那几条保留用例、标跳过。
final class TerminalSynchronizedOutputTests: XCTestCase {
    private static let frameStart = "\u{1B}[?2026h\u{1B}[?25l\u{1B}[2D\u{1B}[3B\r\u{1B}[6A\u{1B}[38;2;215;119;87m*"
    private static let frameEnd = "\u{1B}[39m\r\r\n\r\n\r\n\r\n\r\n\r\n\u{1B}[2C\u{1B}[3A\u{1B}[?25h\u{1B}[?2026l"
    private static let rendererInternal = "旧引擎视图的同步输出补丁随旧引擎删除：Ghostty 的渲染器在 2026 开着时不出帧，"
        + "脏行范围 / 滚轮等待都在渲染器内部，没有对外的读数"

    private func makeTerminal() -> ShadowTerminal {
        let terminal = ShadowTerminal(cols: 85, rows: 28, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        terminal.feed(Data((0..<(28 * 4)).map { "line \($0)\r\n" }.joined().utf8))
        terminal.feed(Data("\u{1B}[3A".utf8))
        return terminal
    }

    private func feed(_ terminal: ShadowTerminal, _ text: String) {
        terminal.feed(Data(text.utf8))
    }

    func testFrameEndOnlyMarksRowsTheFrameTouched() throws {
        throw XCTSkip(Self.rendererInternal)
    }

    /// 帧里改过的行，帧结束之后内容就在那里。
    func testRowsChangedInsideAFrameStayAfterItEnds() {
        let terminal = makeTerminal()
        feed(terminal, "\u{1B}[?2026h\u{1B}[H\u{1B}[2Kchanged")
        XCTAssertTrue(terminal.isModeSet(2026))
        feed(terminal, "\u{1B}[?2026l")
        XCTAssertFalse(terminal.isModeSet(2026))
        XCTAssertEqual(terminal.viewportText().components(separatedBy: "\n").first, "changed")
    }

    /// 帧被拆进两次读取：中间那一刻引擎知道帧还开着（渲染器据此不出帧，光标不会闪一下）；走完之后和一口气喂完
    /// 得到的是同一个终端。
    func testSplitFrameEndsInTheSameStateAsAWholeOne() {
        let split = makeTerminal(), whole = makeTerminal()
        XCTAssertTrue(split.cursor.visible)
        feed(split, Self.frameStart)
        XCTAssertTrue(split.isModeSet(2026), "帧没写完：同步输出还开着")
        XCTAssertFalse(split.cursor.visible, "这一帧开头先藏了光标——所以帧没写完时不能画")
        feed(split, Self.frameEnd)
        feed(whole, Self.frameStart + Self.frameEnd)
        XCTAssertFalse(split.isModeSet(2026))
        XCTAssertTrue(split.cursor.visible)
        XCTAssertEqual(split.stateDifferences(from: whole), [:])
    }

    /// 任意位置拆开都一样（真实读取可以切在任何字节上，包括转义序列中间）。
    func testFrameSplitAtEveryByteMatchesTheWholeFrame() {
        let frame = Array((Self.frameStart + Self.frameEnd).utf8)
        let whole = makeTerminal()
        whole.feed(Data(frame))
        let expected = whole.viewportText()
        for cut in 1..<frame.count {
            let split = makeTerminal()
            split.feed(Data(frame[..<cut]))
            split.feed(Data(frame[cut...]))
            XCTAssertEqual(split.viewportText(), expected, "切在第 \(cut) 字节")
            XCTAssertEqual(split.cursor, whole.cursor, "切在第 \(cut) 字节")
            XCTAssertFalse(split.isModeSet(2026), "切在第 \(cut) 字节")
        }
    }

    func testCaretFollowsTheFinalStateOfTheFrame() {
        let terminal = makeTerminal()
        feed(terminal, "\u{1B}[?2026h\u{1B}[?25l\u{1B}[?2026l")
        XCTAssertFalse(terminal.cursor.visible)
        feed(terminal, "\u{1B}[?2026h\u{1B}[?25h\u{1B}[?2026l")
        XCTAssertTrue(terminal.cursor.visible)
    }

    func testWheelWaitsForAnOpenFrameToEnd() throws {
        throw XCTSkip(Self.rendererInternal)
    }

    /// 没有打开的帧时滚轮立刻滚：在真的 surface 上核，见 `GhosttyMacScrollTests` / `GhosttyMacHostTests` 的滚动条用例。
    func testWheelScrollsRightAwayWithoutAnOpenFrame() throws {
        throw XCTSkip("滚轮滚动在真的 surface 上核：GhosttyMacScrollTests、GhosttyMacHostTests.testScrollIndicatorShowsWhileScrollingAndTracksTheViewport")
    }
}
