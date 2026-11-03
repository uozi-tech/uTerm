import XCTest
import SwiftTerm

/// vendored SwiftTerm 补丁 #7：终端放宽后，原本铺满整行的右边距跟着放宽。
///
/// 上游只在变窄时把右边距收进来，放宽时不动，于是它停在旧宽度上。VT420 的列操作（DECIC 插入列
/// 因 `csiCloseBrace` 里 `&&` / `||` 的优先级失误、以及 `columnScroll`）即使没开左右边距模式也会
/// 读它，于是在旧宽度以右什么都不做。Mac 端的终端都是先 80 列创建、再按窗口放宽的。
/// 远控快照会把两块缓冲区的边距都比对一遍，所以这里的状态也必须两端一致。
final class SwiftTermResizeMarginTests: XCTestCase {

    private final class SilentDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let delegate = SilentDelegate()

    private func character(_ t: Terminal, col: Int, row: Int) -> Character? {
        t.getCharacter(col: col, row: row)
    }

    func test_insert_column_past_old_width_works_after_widening_in_both_buffers() {
        for useAlternate in [false, true] {
            let t = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24))
            t.resize(cols: 130, rows: 30)
            if useAlternate { t.feed(text: "\u{1b}[?1049h") }
            // 第 1 行第 101 列起写 ABC，回到第 101 列插入一列（DECIC）：ABC 应整体右移一格。
            t.feed(text: "\u{1b}[1;101HABC\u{1b}[1;101H\u{1b}[1'}")
            let screen = useAlternate ? "备用屏" : "主屏"
            XCTAssertNotEqual(character(t, col: 100, row: 0), "A", "\(screen)：插入列被丢弃了")
            XCTAssertEqual(character(t, col: 101, row: 0), "A", screen)
            XCTAssertEqual(character(t, col: 103, row: 0), "C", screen)
            XCTAssertEqual(t.buffer.marginRight, 129, screen)
        }
    }

    func test_custom_margins_are_kept_on_widening() {
        let t = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24))
        t.feed(text: "\u{1b}[?69h\u{1b}[5;40s")
        t.resize(cols: 130, rows: 30)
        XCTAssertEqual(t.buffer.marginLeft, 4)
        XCTAssertEqual(t.buffer.marginRight, 39)
    }
}
