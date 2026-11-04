import XCTest
import SwiftTerm
@testable import uTerm

/// 选区不能被持续刷新的程序（如 Claude Code 的 spinner）清掉，但原文没了的时候也不能留。
@MainActor
final class TerminalSelectionDuringOutputTests: XCTestCase {

    private func makeSelectedView(preserves: Bool = true) -> CopyableTerminalView {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.preservesSelectionDuringOutput = preserves
        view.feed(text: (0..<5).map { "line \($0)\r\n" }.joined())
        view.selection.setSoftStart(bufferPosition: Position(col: 0, row: 1))
        view.selection.startSelection()
        view.selection.dragExtend(bufferPosition: Position(col: 6, row: 1))
        XCTAssertTrue(view.selection.active)
        return view
    }

    func testTerminalSessionViewPreservesSelection() {
        XCTAssertTrue(TerminalSession().terminalView.preservesSelectionDuringOutput)
    }

    func testSpinnerFrameKeepsSelection() {
        let view = makeSelectedView()
        view.feed(text: "\u{1B}[s\u{1B}[1;1H*\u{1B}[u")
        XCTAssertTrue(view.selection.active)
        XCTAssertEqual(view.selection.getSelectedText(), "line 1")
    }

    func testLinefeedKeepsSelection() {
        let view = makeSelectedView()
        view.feed(text: "more\r\n")
        XCTAssertTrue(view.selection.active)
        XCTAssertEqual(view.selection.getSelectedText(), "line 1")
    }

    func testSelectionFollowsTextWhenOutputScrollsPastScreen() {
        let view = makeSelectedView()
        let rows = view.getTerminal().rows
        view.feed(text: String(repeating: "x\r\n", count: rows * 3))
        XCTAssertTrue(view.selection.active)
        XCTAssertEqual(view.selection.getSelectedText(), "line 1")
    }

    func testEraseScreenClearsSelection() {
        let view = makeSelectedView()
        view.feed(text: "\u{1B}[2J")
        XCTAssertFalse(view.selection.active)
    }

    func testEraseScrollbackClearsSelection() {
        let view = makeSelectedView()
        view.feed(text: "\u{1B}[3J")
        XCTAssertFalse(view.selection.active)
    }

    func testAlternateScreenSwitchClearsSelection() {
        let view = makeSelectedView()
        view.feed(text: "\u{1B}[?1049h")
        XCTAssertFalse(view.selection.active)
    }

    func testDefaultKeepsUpstreamClearOnOutput() {
        let view = makeSelectedView(preserves: false)
        view.feed(text: "x")
        XCTAssertFalse(view.selection.active)
    }
}
