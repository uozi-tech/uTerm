import AppKit
import XCTest
@testable import uTerm

/// 程序清屏 / 擦回滚 / 复位 / 换备用屏、或者把选中的内容擦掉之后，选区要清掉（换引擎前就是这样）；正常输出、滚动不清。
/// Ghostty 引擎自己只在复位和切到另一个屏时清那个屏的选区，ED 2 / ED 3 不清，高亮会留在擦空的格子上、拷贝拿到空白
/// （`TerminalEraseScanner` 认序列，`TerminalSurfaceKeeper` 让视图清选区）。真 surface，真鼠标事件拖出选区。
@MainActor
final class GhosttySelectionEraseTests: XCTestCase {

    private var rig: GhosttySurfaceRig!

    override func setUp() async throws {
        try await super.setUp()
        rig = await GhosttySurfaceRig()
    }

    override func tearDown() async throws {
        rig?.close()
        rig = nil
        try await super.tearDown()
    }

    /// 屏上写几行字，选中第 1 行的「second」。
    private func selectSecond(file: StaticString = #filePath, line: UInt = #line) async {
        await rig.feed("\u{1B}[H\u{1B}[2Jfirst line\r\nsecond line\r\nthird line\r\n")
        // 这一段自己带着清屏：等它引出的那次「清选区」跳回主线程做完，再拖（否则会把刚拖出的选区清掉）。
        try? await Task.sleep(for: .milliseconds(100))
        rig.drag(fromCol: 0, row: 1, toCol: 5)
        let selected = await rig.waitUntil(2) { self.rig.selection != nil }
        XCTAssertTrue(selected, "自证：拖出了选区", file: file, line: line)
        XCTAssertEqual(rig.selectedText?.hasPrefix("secon"), true, file: file, line: line)
    }

    private func assertSelectionCleared(after bytes: String, _ message: String,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        await selectSecond(file: file, line: line)
        await rig.feed(bytes)
        let cleared = await rig.waitUntil(2) { self.rig.selection == nil }
        XCTAssertTrue(cleared, "\(message)：选区应当清掉，还在 \(String(describing: rig.selection))", file: file, line: line)
    }

    private func assertSelectionKept(after bytes: String, _ message: String,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        await selectSecond(file: file, line: line)
        let before = rig.selection
        await rig.feed(bytes)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(rig.selection, "\(message)：选区不该清", file: file, line: line)
        XCTAssertEqual(rig.selection, before, "\(message)：选区不该动", file: file, line: line)
    }

    func testClearScreenClearsTheSelection() async {
        await assertSelectionCleared(after: "\u{1B}[H\u{1B}[2J", "ED 2")
    }

    func testEraseScrollbackClearsTheSelection() async {
        await assertSelectionCleared(after: "\u{1B}[3J", "ED 3")
    }

    func testClearCommandClearsTheSelection() async {
        // `clear` 命令（ncurses）发的就是这一串。
        await assertSelectionCleared(after: "\u{1B}[H\u{1B}[2J\u{1B}[3J", "clear")
    }

    func testResetClearsTheSelection() async {
        await assertSelectionCleared(after: "\u{1B}c", "RIS")
    }

    func testEnteringTheAlternateScreenClearsTheSelection() async {
        await assertSelectionCleared(after: "\u{1B}[?1049h", "进备用屏")
    }

    /// 从备用屏回到主屏：主屏原来的选区不能再冒出来（Ghostty 只清新屏的选区，主屏那份一直留着）。
    func testLeavingTheAlternateScreenDoesNotBringTheOldSelectionBack() async {
        await selectSecond()
        await rig.feed("\u{1B}[?1049h\u{1B}[Hin the app")
        _ = await rig.waitUntil(2) { self.rig.selection == nil }
        await rig.feed("\u{1B}[?1049l")
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(rig.selection, "回到主屏后旧选区不该冒出来")
        XCTAssertTrue(rig.surfaceText.contains("second line"), "主屏内容还在")
    }

    /// 把选中的那一行擦掉（EL）：选区里只剩空白，清掉。
    func testErasingTheSelectedTextClearsTheSelection() async {
        await assertSelectionCleared(after: "\u{1B}[2;1H\u{1B}[2K", "EL 擦掉选中的行")
    }

    /// 擦的是别的行：选区留着。
    func testErasingOtherTextKeepsTheSelection() async {
        await assertSelectionKept(after: "\u{1B}[3;1H\u{1B}[2K\u{1B}[5;1H", "EL 擦别的行")
    }

    func testOrdinaryOutputKeepsTheSelection() async {
        await assertSelectionKept(after: "\u{1B}[5;1Hmore output\r\nand more\r\n", "正常输出")
    }

    /// 滚动（往上翻、再翻回来）不清选区。
    func testScrollingKeepsTheSelection() async {
        await selectSecond()
        await rig.feed(String(repeating: "filler\r\n", count: 60))
        XCTAssertTrue(rig.view.performBindingAction("scroll_to_top"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(rig.view.performBindingAction("scroll_to_bottom"))
        XCTAssertTrue(rig.view.performBindingAction("scroll_to_top"))
        let shown = await rig.waitUntil(2) { self.rig.selection != nil }
        XCTAssertTrue(shown, "翻回选区所在处，选区还在")
    }
}
