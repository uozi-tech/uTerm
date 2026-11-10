import XCTest
@testable import uTerm

/// `TerminalViewportMark`：整屏回放（视口回到底部）之后按内容找回切走前的视口。在真的影子终端上核。
final class TerminalViewportMarkTests: XCTestCase {

    private func makeShadow(scrollback: Int = 1_000, cols: UInt16 = 40, rows: UInt16 = 6) -> ShadowTerminal {
        ShadowTerminal(cols: cols, rows: rows, options: TerminalScrollbackLimits(lines: scrollback).shadowOptions)
    }

    private func lines(_ range: ClosedRange<Int>) -> Data {
        Data(range.map { "line \($0)\r\n" }.joined().utf8)
    }

    /// 像 surface 那样读视口：从整屏第 `offset` 行起 `rows` 行。
    private func viewport(_ shadow: ShadowTerminal, offset: Int, rows: Int) -> String {
        (offset..<(offset + rows)).map { shadow.screenRowText($0) ?? "" }.joined(separator: "\n")
    }

    private func target(_ mark: TerminalViewportMark, _ shadow: ShadowTerminal) -> Int? {
        let size = shadow.size
        return mark.targetRow(totalRows: shadow.totalRows, rows: size.rows, columns: size.cols) { shadow.screenRowText($0) }
    }

    func testScreenRowTextReadsScrollbackFromTheTop() {
        let shadow = makeShadow()
        shadow.feed(lines(1...30))
        XCTAssertEqual(shadow.screenRowText(0), "line 1")
        XCTAssertEqual(shadow.screenRowText(29), "line 30")
        XCTAssertEqual(shadow.screenRowText(30), "", "最后一行是光标所在的空行")
        XCTAssertNil(shadow.screenRowText(shadow.totalRows), "越界")
    }

    func testAtBottomNothingIsRemembered() {
        XCTAssertNil(TerminalViewportMark.capture(offset: 25, rows: 6, total: 31, columns: 40, viewportText: "x"))
        XCTAssertNil(TerminalViewportMark.capture(offset: 0, rows: 6, total: 6, columns: 40, viewportText: "x"))
    }

    /// 期间只往底部加了行：原来看的那几行行号不变，当场找到。
    func testOutputBelowKeepsTheSameRow() throws {
        let shadow = makeShadow()
        shadow.feed(lines(1...30))
        let total = shadow.totalRows
        let mark = try XCTUnwrap(TerminalViewportMark.capture(offset: 10, rows: 6, total: total, columns: 40,
                                                              viewportText: viewport(shadow, offset: 10, rows: 6)))
        XCTAssertEqual(mark.anchor.first, "line 11")
        shadow.feed(lines(31...80))
        XCTAssertEqual(target(mark, shadow), 10)
    }

    /// 往影子里接着灌行，直到回滚最早的那一行被挤掉（引擎按页挤，一次挤掉一整页）。返回灌到了第几行。
    private func feedUntilTrimmed(_ shadow: ShadowTerminal, from next: Int, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let top = shadow.screenRowText(0)
        var n = next
        while shadow.screenRowText(0) == top, n < next + 200_000 {
            shadow.feed(lines(n...(n + 99)))
            n += 100
        }
        XCTAssertNotEqual(shadow.screenRowText(0), top, "自证：回滚满了，最早的行被挤掉了", file: file, line: line)
        return n
    }

    /// 回滚满了、最早的行被挤掉：那几行整体上移，往上找到它们（按行号记会错开被挤掉的行数）。
    func testTrimmedScrollbackFollowsTheContent() throws {
        // 引擎按页挤（40 列时一页一千多行），回滚设大一点，让原来看的那几行落在后面的页里、挤掉一页后还在。
        let shadow = makeShadow(scrollback: 5_000)
        shadow.feed(lines(1...100))
        let next = feedUntilTrimmed(shadow, from: 101)
        let offset = shadow.totalRows - 50
        let mark = try XCTUnwrap(TerminalViewportMark.capture(offset: offset, rows: 6, total: shadow.totalRows, columns: 40,
                                                              viewportText: viewport(shadow, offset: offset, rows: 6)))
        let first = try XCTUnwrap(mark.anchor.first)
        _ = feedUntilTrimmed(shadow, from: next)
        let row = try XCTUnwrap(target(mark, shadow))
        XCTAssertLessThan(row, offset, "最早的行被挤掉了，原来那几行上移了")
        XCTAssertEqual(shadow.screenRowText(row), first, "找回的是同一段内容")
    }

    /// 原来看的那几行也被挤出去了：停在回滚最顶上（离原处最近）。
    func testContentScrolledAwayStopsAtTheTop() throws {
        let shadow = makeShadow(scrollback: 500)
        shadow.feed(lines(1...100))
        let mark = try XCTUnwrap(TerminalViewportMark.capture(offset: 2, rows: 6, total: shadow.totalRows, columns: 40,
                                                              viewportText: viewport(shadow, offset: 2, rows: 6)))
        let next = feedUntilTrimmed(shadow, from: 101)
        XCTAssertNotEqual(shadow.screenRowText(0), "line 1")
        // 原来那几行（line 3…）在被挤掉的第一页里。
        XCTAssertFalse((0..<shadow.totalRows).contains { shadow.screenRowText($0) == "line 3" }, "自证：已经挤出去了（灌到 \(next)）")
        XCTAssertEqual(target(mark, shadow), 0)
    }

    /// 宽度变了（折行不同，文字比不上）：退回原来的行号。原来的行号已经落进底下那一屏：留在底部。
    func testColumnChangeFallsBackToTheRowNumber() throws {
        let shadow = makeShadow()
        shadow.feed(lines(1...30))
        let mark = try XCTUnwrap(TerminalViewportMark.capture(offset: 10, rows: 6, total: shadow.totalRows, columns: 80,
                                                              viewportText: viewport(shadow, offset: 10, rows: 6)))
        XCTAssertEqual(target(mark, shadow), 10)
        let late = try XCTUnwrap(TerminalViewportMark.capture(offset: 90, rows: 6, total: 100, columns: 80, viewportText: "a"))
        XCTAssertNil(target(late, shadow), "原处已经在底下那一屏里（现在一共只有 \(shadow.totalRows) 行）")
    }

    /// 视口里落在活动区（底下那一屏）的行不拿来比：程序会改写它们。
    func testAnchorOnlyUsesScrollbackRows() throws {
        let mark = try XCTUnwrap(TerminalViewportMark.capture(offset: 20, rows: 6, total: 30, columns: 40,
                                                              viewportText: "a\nb\nc\nd\ne\nf"))
        XCTAssertEqual(mark.anchor, ["a", "b", "c", "d"], "第 24 行起是活动区")
    }
}
