import AppKit
import SwiftTerm
import XCTest
@testable import uTerm

/// 注册 OSC 7501 / 133 / 9 / 777 处理器（补丁 #11）之后，其他 OSC 和前后的文字不受影响。
/// 133、9;4、777 本身见 `TerminalProgramStatusTests`。
@MainActor
final class TerminalOSCRegressionTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var session: TerminalSession!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("uterm-test-\(UUID().uuidString)"))
        session = TerminalSession()
        (session.terminalView as? CopyableTerminalView)?.pasteboard = pasteboard
        session.attentionSink = { _ in }
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    private var terminal: Terminal { session.terminalView.getTerminal() }

    private func feed(_ text: String) {
        session.terminalView.feed(text: text)
    }

    private func line(_ row: Int) -> String {
        terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
    }

    func testOSC7ReportsCurrentDirectory() {
        feed("\u{1b}]7;file:///Users/me/project\u{07}")
        XCTAssertEqual(terminal.hostCurrentDirectory, "file:///Users/me/project")
    }

    func testOSC8MarksOnlyTheLinkedCells() throws {
        feed("\u{1b}]8;;https://example.com/a\u{07}link\u{1b}]8;;\u{07}plain")
        XCTAssertEqual(line(0), "linkplain")

        let linked = try XCTUnwrap(terminal.getCharData(col: 0, row: 0))
        XCTAssertEqual((linked.getPayload() as? String)?.contains("https://example.com/a"), true)
        let plain = try XCTUnwrap(terminal.getCharData(col: 4, row: 0))
        XCTAssertFalse(plain.hasPayload)
    }

    func testOSC52WritesToTheTerminalsPasteboard() {
        feed("\u{1b}]52;c;\(Data("hello 世界".utf8).base64EncodedString())\u{07}")
        XCTAssertEqual(pasteboard.string(forType: .string), "hello 世界")
    }

    func testOSC52WithInvalidBase64LeavesPasteboardAlone() {
        pasteboard.clearContents()
        pasteboard.setString("原来的", forType: .string)
        feed("\u{1b}]52;c;@@@not-base64@@@\u{07}")
        XCTAssertEqual(pasteboard.string(forType: .string), "原来的")
    }

    /// 远端程序不能靠 OSC 52 读走 Mac 的剪贴板。
    func testOSC52QueryIsNeverAnswered() async throws {
        let backend = MockBackend()
        await session.connect(using: backend)
        pasteboard.clearContents()
        pasteboard.setString("秘密", forType: .string)

        feed("\u{1b}]52;c;?\u{07}")
        try await Task.sleep(for: .milliseconds(80))

        let written = await backend.writtenData
        XCTAssertTrue(written.isEmpty, "\(written.map { String(decoding: $0, as: UTF8.self) })")
        await session.close()
    }

    func testTitleAndStatusSequencesDoNotDisturbEachOtherOrTheText() {
        feed("before\u{1b}]7501;state=working:app=claude-code\u{1b}\\\u{1b}]0;vim\u{07}after")
        XCTAssertEqual(line(0), "beforeafter")
        XCTAssertEqual(session.shellTitle, "vim")
    }

    func testStatusSequenceSplitAcrossFeedsIsStillUnderstood() {
        feed("\u{1b}]75")
        feed("01;state=blocked:app=claude-")
        feed("code\u{1b}\\tail")
        XCTAssertNotNil(session.programStatus)
        XCTAssertEqual(line(0), "tail")
    }

    func testUnknownOSCIsDroppedWithoutEatingText() {
        feed("a\u{1b}]99999;whatever\u{07}b")
        XCTAssertEqual(line(0), "ab")
    }

    func testMalformedStatusIsIgnored() {
        feed("\u{1b}]7501;\u{07}x")
        XCTAssertNil(session.programStatus)
        XCTAssertEqual(line(0), "x")
    }
}
