import XCTest
@testable import uTerm

/// `TerminalEraseScanner`：在后端输出里认出清屏 / 擦除的转义序列（给「清屏后选区还在」那件事用）。
final class TerminalEraseScannerTests: XCTestCase {

    private func scan(_ chunks: String...) -> TerminalErase? {
        var scanner = TerminalEraseScanner()
        var found: TerminalErase?
        for chunk in chunks {
            if let erase = scanner.scan(Data(chunk.utf8)) { found = max(found ?? erase, erase) }
        }
        return found
    }

    func testWholeScreenErasesAreScreenLevel() {
        XCTAssertEqual(scan("\u{1B}[2J"), .screen, "ED 2 清屏")
        XCTAssertEqual(scan("\u{1B}[3J"), .screen, "ED 3 擦回滚")
        XCTAssertEqual(scan("\u{1B}[H\u{1B}[2J\u{1B}[3J"), .screen, "clear 命令发的那一串")
        XCTAssertEqual(scan("\u{1B}[?2J"), .screen, "DECSED 2")
        XCTAssertEqual(scan("\u{1B}c"), .screen, "RIS")
        XCTAssertEqual(scan("\u{1B}[?1049h"), .screen, "进备用屏")
        XCTAssertEqual(scan("\u{1B}[?1049l"), .screen, "出备用屏")
        XCTAssertEqual(scan("\u{1B}[?47h"), .screen)
        XCTAssertEqual(scan("\u{1B}[?1047l"), .screen)
        XCTAssertEqual(scan("\u{1B}[?1;1049;2004h"), .screen, "多个模式一起设")
    }

    func testPartialErasesAreInPlace() {
        XCTAssertEqual(scan("\u{1B}[J"), .inPlace, "ED 0")
        XCTAssertEqual(scan("\u{1B}[1J"), .inPlace, "ED 1")
        XCTAssertEqual(scan("\u{1B}[K"), .inPlace, "EL")
        XCTAssertEqual(scan("\u{1B}[2K"), .inPlace)
        XCTAssertEqual(scan("\u{1B}[5X"), .inPlace, "ECH")
        XCTAssertEqual(scan("\u{1B}[3P"), .inPlace, "DCH")
        XCTAssertEqual(scan("\u{1B}[2M"), .inPlace, "DL")
        XCTAssertEqual(scan("\u{1B}[K\u{1B}[2J"), .screen, "一片里取最重的")
    }

    func testOrdinaryOutputIsNotAnErase() {
        XCTAssertNil(scan("hello world\r\n"))
        XCTAssertNil(scan("\u{1B}[31mred\u{1B}[0m \u{1B}[10;20H\u{1B}[?25l\u{1B}[?2004h\u{1B}[?1h"))
        XCTAssertNil(scan("\u{1B}(B\u{1B})0"), "字符集指定")
        XCTAssertNil(scan("\u{1B}(c"), "ESC 带中间字节时 c 不是 RIS")
        XCTAssertNil(scan("\u{1B}[2 J"), "带中间字节的 J 不认")
        XCTAssertNil(scan("\u{1B}[?1000h\u{1B}[?1006h"), "鼠标模式不是换屏")
        XCTAssertNil(scan("\u{1B}[?25l"))
    }

    func testStringsAreSkipped() {
        // OSC / DCS 串里的字节不当序列看；串以 BEL 或 ST 结束，之后照常认。
        XCTAssertNil(scan("\u{1B}]0;title [2J c\u{07}text"))
        XCTAssertNil(scan("\u{1B}]52;c;Zm9v\u{1B}\\after"))
        XCTAssertNil(scan("\u{1B}Pq#0;2;0;0;0\u{1B}\\"))
        XCTAssertEqual(scan("\u{1B}]0;t\u{07}\u{1B}[2J"), .screen)
        XCTAssertEqual(scan("\u{1B}]0;t\u{1B}\\\u{1B}c"), .screen)
    }

    func testSequencesSplitAcrossChunksAreRecognised() {
        XCTAssertEqual(scan("abc\u{1B}", "[2J"), .screen)
        XCTAssertEqual(scan("\u{1B}[", "2", "J"), .screen)
        XCTAssertEqual(scan("\u{1B}[?10", "49h"), .screen)
        XCTAssertEqual(scan("\u{1B}", "c"), .screen)
        XCTAssertNil(scan("\u{1B}]0;ti", "tle [2J\u{07}"), "跨片的串里照样跳过")
    }

    func testInterruptedSequenceRestarts() {
        // CSI 被 ESC 打断：后面那条照常认；CAN 取消序列。
        XCTAssertEqual(scan("\u{1B}[1\u{1B}[2J"), .screen)
        XCTAssertNil(scan("\u{1B}[2\u{18}J"))
    }

    func testScanFreshDoesNotCarryState() {
        XCTAssertEqual(TerminalEraseScanner.scanFresh(Data("x\u{1B}[3J".utf8)), .screen)
        XCTAssertNil(TerminalEraseScanner.scanFresh(Data("2J".utf8)))
    }
}
