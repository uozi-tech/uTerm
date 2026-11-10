import XCTest
@testable import uTerm

/// 读屏的纯函数层。这一层不碰终端引擎，所以行为可以逐条钉死。
final class TerminalScreenReaderTests: XCTestCase {

    // MARK: 行数截取

    func testTakesTailLinesAndMarksTruncated() {
        let lines = (1...10).map { "line \($0)" }
        let result = TerminalScreenReader.trim(lines: lines, maxLines: 3, maxBytes: 16_000)
        XCTAssertEqual(result.lines, ["line 8", "line 9", "line 10"])
        XCTAssertTrue(result.truncated)
    }

    func testKeepsEverythingWhenUnderLimits() {
        let lines = ["a", "b", "c"]
        let result = TerminalScreenReader.trim(lines: lines, maxLines: 80, maxBytes: 16_000)
        XCTAssertEqual(result.lines, lines)
        XCTAssertFalse(result.truncated)
    }

    /// 尾部空行是「屏幕下半截没内容」，裁掉它不算截断 —— 否则每次读屏都会
    /// 谎报 truncated，且把 maxLines 白白喂给空白。
    func testTrailingBlankLinesAreDroppedWithoutTruncationFlag() {
        let lines = ["one", "two", "", "", ""]
        let result = TerminalScreenReader.trim(lines: lines, maxLines: 80, maxBytes: 16_000)
        XCTAssertEqual(result.lines, ["one", "two"])
        XCTAssertFalse(result.truncated)
    }

    /// 中间的空行必须保留（命令输出里的空行是有意义的）。
    func testInteriorBlankLinesSurvive() {
        let lines = ["one", "", "two", ""]
        let result = TerminalScreenReader.trim(lines: lines, maxLines: 80, maxBytes: 16_000)
        XCTAssertEqual(result.lines, ["one", "", "two"])
    }

    func testEmptyBufferYieldsEmptyResult() {
        let result = TerminalScreenReader.trim(lines: [], maxLines: 80, maxBytes: 16_000)
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertFalse(result.truncated)
    }

    func testAllBlankBufferYieldsEmptyResult() {
        let result = TerminalScreenReader.trim(lines: ["", "", ""], maxLines: 80, maxBytes: 16_000)
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertFalse(result.truncated)
    }

    func testNonPositiveLimitsYieldEmpty() {
        let lines = ["a", "b"]
        XCTAssertEqual(TerminalScreenReader.trim(lines: lines, maxLines: 0, maxBytes: 100).lines, [])
        XCTAssertTrue(TerminalScreenReader.trim(lines: lines, maxLines: 0, maxBytes: 100).truncated)
        XCTAssertEqual(TerminalScreenReader.trim(lines: lines, maxLines: 5, maxBytes: 0).lines, [])
    }

    // MARK: 字节封顶

    /// 字节收口从**最新**一行往回收：先丢最旧的。
    func testByteCapDropsOldestLinesFirst() {
        // 每行 "aaaa"(4) + 换行(1) = 5 字节。给 11 字节 → 只装得下 2 行。
        let lines = ["aaaa", "bbbb", "cccc", "dddd"]
        let result = TerminalScreenReader.trim(lines: lines, maxLines: 80, maxBytes: 11)
        XCTAssertEqual(result.lines, ["cccc", "dddd"])
        XCTAssertTrue(result.truncated)
    }

    func testByteCapExactFitIsNotTruncated() {
        let lines = ["aaaa", "bbbb"]
        let result = TerminalScreenReader.trim(lines: lines, maxLines: 80, maxBytes: 10)
        XCTAssertEqual(result.lines, lines)
        XCTAssertFalse(result.truncated)
    }

    /// 最后一行本身就超上限时切半行，而不是回空 —— 「最后一行是一条超长日志」
    /// 是很常见的读屏场景。
    func testSingleOversizedLineIsCutInsteadOfDropped() {
        let long = String(repeating: "x", count: 100)
        let result = TerminalScreenReader.trim(lines: [long], maxLines: 80, maxBytes: 11)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0], String(repeating: "x", count: 10))
        XCTAssertTrue(result.truncated)
    }

    /// 切半行不能把字素簇切碎成 U+FFFD。
    func testCutRespectsGraphemeBoundaries() {
        let line = "中文中文中文"  // 每字 3 字节
        let result = TerminalScreenReader.trim(lines: [line], maxLines: 80, maxBytes: 8)
        // 预算 8 - 1(换行) = 7 → 只装得下 2 个汉字（6 字节）。
        XCTAssertEqual(result.lines, ["中文"])
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.lines[0].contains("\u{FFFD}"))
    }

    func testUTF8PrefixNeverExceedsBudget() {
        let text = "aé中🙂"
        for budget in 0...text.utf8.count + 2 {
            let cut = TerminalScreenReader.utf8Prefix(text, maxBytes: budget)
            XCTAssertLessThanOrEqual(cut.utf8.count, budget, "budget=\(budget)")
            XCTAssertTrue(text.hasPrefix(cut), "budget=\(budget)")
        }
    }
}
