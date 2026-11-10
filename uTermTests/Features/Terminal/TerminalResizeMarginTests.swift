import XCTest
@testable import uTerm

/// 原来核的是旧引擎的本地补丁 #7：终端放宽后，原本铺满整行的右边距要跟着放宽（上游只在变窄时收、放宽时不动，
/// 于是旧宽度以右的列操作什么都不做）。旧引擎没有了，这个补丁也就没有了；同一条行为在新引擎（影子终端，
/// libghostty-vt，和画面是同一棵源码树）上照样要成立，因为 Mac 的终端仍然是先按一个初始尺寸建、再按窗口放宽的，
/// 远控镜像也仍然要求两端的边距状态一致（现在靠二进制快照带过去）。文件名沿用旧的。
final class TerminalResizeMarginTests: XCTestCase {

    private func makeTerminal(cols: UInt16, rows: UInt16) -> ShadowTerminal {
        ShadowTerminal(cols: cols, rows: rows, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
    }

    private func feed(_ terminal: ShadowTerminal, _ text: String) {
        terminal.feed(Data(text.utf8))
    }

    /// 放宽之后，在旧宽度以右做列方向的编辑（插入字符 ICH、删除字符 DCH）照常生效，主屏、备用屏都一样。
    /// 右边距停在旧宽度的话，光标在边距之外，这两个操作会被整个丢弃。
    func test_column_edits_past_old_width_work_after_widening_in_both_buffers() {
        for useAlternate in [false, true] {
            let screen = useAlternate ? "备用屏" : "主屏"
            let t = makeTerminal(cols: 80, rows: 24)
            t.resize(cols: 130, rows: 30)
            if useAlternate { feed(t, "\u{1b}[?1049h") }
            // 第 1 行第 101 列起写 ABC，回到第 101 列插入一格：ABC 应整体右移一格。
            feed(t, "\u{1b}[1;101HABC\u{1b}[1;101H\u{1b}[@")
            XCTAssertEqual(t.character(col: 100, row: 0), " ", "\(screen)：插入的空格")
            XCTAssertEqual(t.character(col: 101, row: 0), "A", "\(screen)：插入被丢弃了")
            XCTAssertEqual(t.character(col: 103, row: 0), "C", screen)
            // 再删掉那一格：回到原位。
            feed(t, "\u{1b}[P")
            XCTAssertEqual(t.character(col: 100, row: 0), "A", "\(screen)：删除被丢弃了")
            // 写到最后一列再多写一个字：在新宽度的行末折行，而不是在旧的第 80 列。
            feed(t, "\u{1b}[2;129HXYZ")
            XCTAssertEqual(t.character(col: 129, row: 1), "Y", "\(screen)：第 130 列可写")
            XCTAssertEqual(t.character(col: 0, row: 2), "Z", "\(screen)：在新宽度的行末折行")
        }
    }

    /// 程序自己设的左右边距（DECSLRM）是终端状态的一部分：拍进快照、在另一台终端上还原之后，同样的字节在两边
    /// 产生同样的结果（换引擎之前快照会把两块缓冲区的边距都比一遍，这里是同一条要求）。
    func test_custom_margins_travel_with_the_snapshot() throws {
        let a = makeTerminal(cols: 130, rows: 30)
        feed(a, "\u{1b}[?69h\u{1b}[5;40s")
        let b = try ShadowTerminal(snapshot: a.snapshot(), options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        // 在边距里写一长串：折行的位置由右边距（第 40 列）决定。
        let more = "\u{1b}[3;5H" + String(repeating: "m", count: 60) + "\u{1b}[6;10H\u{1b}[2@x"
        feed(a, more)
        feed(b, more)
        XCTAssertEqual(a.stateDifferences(from: b), [:])
        XCTAssertEqual(a.character(col: 39, row: 2), "m", "写到右边距（第 40 列）")
        XCTAssertEqual(a.character(col: 40, row: 2), " ", "边距以右不写")
        XCTAssertEqual(a.character(col: 4, row: 3), "m", "折到下一行的左边距（第 5 列）")
    }

    /// 改尺寸之后边距怎么处理由引擎定（xterm、Ghostty 都是改尺寸时把滚动区域复位到整屏；旧引擎留着自定义边距）。
    /// 这里只钉一条：改尺寸后的状态同样能随快照原样带到另一端。
    func test_margin_state_after_a_resize_travels_with_the_snapshot() throws {
        let a = makeTerminal(cols: 80, rows: 24)
        feed(a, "\u{1b}[?69h\u{1b}[5;40s\u{1b}[3;20r")
        a.resize(cols: 130, rows: 30)
        let b = try ShadowTerminal(snapshot: a.snapshot(), options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        XCTAssertEqual(a.stateDifferences(from: b), [:])
        let more = "\u{1b}[2;1H" + String(repeating: "w", count: 150) + "\r\n\u{1b}[25;1H" + String(repeating: "line\r\n", count: 12)
        feed(a, more)
        feed(b, more)
        XCTAssertEqual(a.stateDifferences(from: b), [:])
    }
}
