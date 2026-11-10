import XCTest
import GhosttyTerminal
@testable import uTerm

/// 选区不能被持续刷新的程序（如 Claude Code 的 spinner）清掉，但原文没了的时候也不能留。
///
/// 原来核的是 SwiftTerm 视图上的补丁（`preservesSelectionDuringOutput`：上游一有输出就清选区）。现在选区在 Ghostty 的
/// surface 里（钉在内容上，跟着内容滚动），这里在真的 surface 上核同一组行为：三连击选中「line 1」那一行，再喂各种输出。
@MainActor
final class TerminalSelectionDuringOutputTests: XCTestCase {

    private var rigs: [GhosttySurfaceRig] = []

    override func tearDown() async throws {
        rigs.forEach { $0.close() }
        rigs = []
        try await super.tearDown()
    }

    /// 五行文字，选中第 2 行（「line 1」）。
    private func makeSelectedRig(file: StaticString = #filePath, line: UInt = #line) async -> GhosttySurfaceRig {
        let rig = await GhosttySurfaceRig()
        rigs.append(rig)
        await rig.feed((0..<5).map { "line \($0)\r\n" }.joined())
        rig.click(col: 2, row: 1, count: 3)
        let selected = await rig.waitUntil(2) { rig.selection != nil }
        XCTAssertTrue(selected, "三连击没选中这一行", file: file, line: line)
        XCTAssertEqual(rig.selection?.topLeft.row, 1, file: file, line: line)
        XCTAssertEqual(rig.selectedText, "line 1", file: file, line: line)
        return rig
    }

    /// 没有选区时读不到选区；右键菜单的「拷贝」据此置灰。
    func testNoSelectionUntilTheUserSelects() async {
        let rig = await GhosttySurfaceRig()
        rigs.append(rig)
        await rig.feed("hello\r\n")
        XCTAssertNil(rig.selection)
    }

    /// spinner 的一帧（存光标、到别的行写一个字、还原光标）不动选区。
    func testSpinnerFrameKeepsSelection() async {
        let rig = await makeSelectedRig()
        await rig.feed("\u{1B}[s\u{1B}[1;1H*\u{1B}[u")
        XCTAssertEqual(rig.selection?.topLeft.row, 1)
        XCTAssertEqual(rig.selectedText, "line 1")
    }

    func testLinefeedKeepsSelection() async {
        let rig = await makeSelectedRig()
        await rig.feed("more\r\n")
        XCTAssertEqual(rig.selection?.topLeft.row, 1)
        XCTAssertEqual(rig.selectedText, "line 1")
    }

    /// 输出把屏幕往上顶：选区跟着那行文字走，而不是留在屏幕的第 2 行上。
    func testSelectionFollowsTextWhenOutputScrolls() async {
        let rig = await makeSelectedRig()
        let rows = rig.session.shadow.size.rows
        // 现在光标在第 6 行；再写这么多行，整屏正好上移一行：「line 1」到了第 1 行。
        await rig.feed(String(repeating: "x\r\n", count: rows - 5))
        XCTAssertEqual(rig.session.shadow.viewportText().components(separatedBy: "\n").first, "line 1", "用例前提：上移了一行")
        XCTAssertEqual(rig.selection?.topLeft.row, 0, "选区跟着文字上移")
        XCTAssertEqual(rig.selectedText, "line 1")

        // 再往上顶出视口：选区还在（只是不在视口里了），翻回去能看到。
        await rig.feed(String(repeating: "y\r\n", count: 3))
        XCTAssertNil(rig.selection, "选中的那行已经滚出视口")
    }

    private static let engineKeepsSelection =
        "引擎行为：Ghostty 的选区钉在格子上，擦除 / 改写那几格不会清掉选区（SwiftTerm 上是 uTerm 的补丁在清）；要一致得打引擎补丁"

    /// 清屏：原文没了，选区不能留。
    ///
    /// **迁移后的差异（等主会话定）**：Ghostty 上清屏之后选区还在（高亮盖在已经擦空的格子上，「拷贝」也还亮着）。
    /// 「原文没了选区不留」仍然是要的行为，断言不改、标成预期失败；下面擦回滚、改写原文两条同理。切备用屏那条是清的。
    func testEraseScreenClearsSelection() async {
        XCTExpectFailure(Self.engineKeepsSelection, options: .nonStrict())
        let rig = await makeSelectedRig()
        await rig.feed("\u{1B}[2J")
        XCTAssertNil(rig.selection)
    }

    func testEraseScrollbackClearsSelection() async {
        XCTExpectFailure(Self.engineKeepsSelection, options: .nonStrict())
        let rig = await makeSelectedRig()
        await rig.feed("\u{1B}[3J\u{1B}[H\u{1B}[2J")
        XCTAssertNil(rig.selection)
    }

    func testAlternateScreenSwitchClearsSelection() async {
        let rig = await makeSelectedRig()
        await rig.feed("\u{1B}[?1049h")
        XCTAssertNil(rig.selection)
    }

    /// 写到选中的那一行上（原文被改了）：选区不能留着盖在新内容上。
    func testOverwritingTheSelectedTextClearsSelection() async {
        XCTExpectFailure(Self.engineKeepsSelection, options: .nonStrict())
        let rig = await makeSelectedRig()
        await rig.feed("\u{1B}[2;1Hchanged")
        XCTAssertNil(rig.selection)
    }
}
