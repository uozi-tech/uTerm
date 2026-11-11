import XCTest
@testable import uTerm

/// 「按行填满」的规则（`TerminalRowFill`，两端共用的纯函数）：行数只由自然行高定、拉伸不多不少一行、零头上下均分、
/// 封顶 25%。真 surface 上的接线在 `TerminalRowFillSurfaceTests`（Mac）与 iOS 的 `TerminalRowFillMobileTests`。
final class TerminalRowFillRuleTests: XCTestCase {

    /// 一大片 (H, h0) 上逐个核：行数 = ⌊H ÷ h0⌋；格子不比自然的矮、不超过封顶；按调整后的格子量出来还是这么多行；
    /// 零头小于一行，不封顶时还小于行数（每行都再拉 1 像素就会多出 rows 个像素）；上下两份最多差 1。
    func testRowsNeverChangeAndTheRestIsSplitEvenly() {
        for naturalCellHeight in [14, 19, 28, 31, 40, 58] {
            for viewHeight in naturalCellHeight...(naturalCellHeight * 130) {
                let fill = TerminalRowFill(viewHeight: viewHeight, naturalCellHeight: naturalCellHeight)
                let rows = viewHeight / naturalCellHeight
                XCTAssertEqual(fill.rows, rows)
                XCTAssertEqual(viewHeight / fill.cellHeight, rows, "H=\(viewHeight) h0=\(naturalCellHeight)：拉伸改了行数")
                XCTAssertGreaterThanOrEqual(fill.adjustment, 0)
                XCTAssertLessThanOrEqual(fill.adjustment, naturalCellHeight / 4)
                XCTAssertEqual(fill.cellHeight, naturalCellHeight + fill.adjustment)
                let margins = TerminalRowFill.margins(viewHeight: viewHeight, rows: fill.rows, cellHeight: fill.cellHeight)
                let rest = viewHeight - rows * fill.cellHeight
                XCTAssertEqual(margins.top + margins.bottom, rest)
                XCTAssertLessThan(rest, naturalCellHeight, "零头不到一行")
                XCTAssertTrue(margins.bottom - margins.top == 0 || margins.bottom - margins.top == 1)
                if fill.adjustment < naturalCellHeight / 4 {
                    XCTAssertLessThan(rest, rows, "H=\(viewHeight) h0=\(naturalCellHeight)：还能每行再拉 1 像素")
                    XCTAssertLessThanOrEqual(margins.bottom, rows / 2, "每边 ≤ ⌈(rows − 1) ÷ 2⌉")
                }
            }
        }
    }

    func testExactMultipleIsLeftAlone() {
        expect(TerminalRowFill(viewHeight: 28 * 40, naturalCellHeight: 28), rows: 40, cellHeight: 28, adjustment: 0)
        XCTAssertTrue(TerminalRowFill.margins(viewHeight: 28 * 40, rows: 40, cellHeight: 28) == (0, 0))
    }

    /// 余量差一像素就是一整行：行少（手机竖屏、小窗格）时摊进行距，行多时一行一像素都摊不满、只能上下均分。
    func testNearlyAFullLineOfRest() {
        // 10 行、余 27 像素：每行加 2，剩 7（上 3 下 4）。
        expect(TerminalRowFill(viewHeight: 28 * 10 + 27, naturalCellHeight: 28), rows: 10, cellHeight: 30, adjustment: 2)
        XCTAssertTrue(TerminalRowFill.margins(viewHeight: 28 * 10 + 27, rows: 10, cellHeight: 30) == (3, 4))
        // 40 行、余 27 像素：不够每行加 1，全靠均分（上 13 下 14）。
        let many = TerminalRowFill(viewHeight: 28 * 40 + 27, naturalCellHeight: 28)
        XCTAssertEqual(many.adjustment, 0)
        XCTAssertTrue(TerminalRowFill.margins(viewHeight: 28 * 40 + 27, rows: 40, cellHeight: 28) == (13, 14))
    }

    /// 只有一两行的小窗格：最多拉高四分之一，剩下的照样均分。
    func testStretchIsCappedForTinyPanes() {
        expect(TerminalRowFill(viewHeight: 55, naturalCellHeight: 28), rows: 1, cellHeight: 35, adjustment: 7)
        XCTAssertTrue(TerminalRowFill.margins(viewHeight: 55, rows: 1, cellHeight: 35) == (10, 10))
    }

    func testShorterThanOneRowIsLeftAlone() {
        expect(TerminalRowFill(viewHeight: 20, naturalCellHeight: 28), rows: 0, cellHeight: 28, adjustment: 0)
        XCTAssertEqual(TerminalRowFill(viewHeight: 100, naturalCellHeight: 0).adjustment, 0)
    }

    /// 影子终端只换格子像素（行列数不变）时，尺寸查询也跟着换：`CSI 14 t` 报文字区像素、`CSI 16 t` 报格子像素。
    func testShadowAnswersSizeQueriesWithTheNewCellHeight() {
        let terminal = ShadowTerminal(cols: 40, rows: 10, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        let replies = ReplyLog()
        terminal.setReplyHandler { replies.append($0) }
        terminal.setRepliesEnabled(true)
        terminal.resize(cols: 40, rows: 10, cellWidth: 15, cellHeight: 28)
        terminal.resize(cols: 40, rows: 10, cellWidth: 15, cellHeight: 31)
        XCTAssertTrue(terminal.cellPixels == (15, 31))
        terminal.feed(Data("\u{1B}[16t\u{1B}[14t".utf8))
        XCTAssertEqual(replies.text, "\u{1B}[6;31;15t\u{1B}[4;310;600t")
    }

    private func expect(_ fill: TerminalRowFill, rows: Int, cellHeight: Int, adjustment: Int,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fill.rows, rows, "rows", file: file, line: line)
        XCTAssertEqual(fill.cellHeight, cellHeight, "cellHeight", file: file, line: line)
        XCTAssertEqual(fill.adjustment, adjustment, "adjustment", file: file, line: line)
    }

    private final class ReplyLog: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
