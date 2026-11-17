import GhosttyTerminal
import XCTest

/// 听写改写已上屏的字时，终端和远程桌面要发的按键（`TerminalCommittedTail`，GhosttyKit 的 uTerm 本地补丁）。
final class TerminalCommittedTailTests: XCTestCase {
    private func replacing(_ tail: String, _ range: NSRange, with text: String) -> (TerminalCommittedTail.Edit, String) {
        var model = TerminalCommittedTail()
        model.append(tail)
        let edit = model.replace(range, with: text)
        return (edit, model.text)
    }

    func testAppendingToTheHypothesisOnlyTypesTheNewPart() {
        let (edit, text) = replacing("hello", NSRange(location: 0, length: 5), with: "hello world")
        XCTAssertEqual(edit, .init(deletions: 0, typed: " world"))
        XCTAssertEqual(text, "hello world")
    }

    func testRewritingTheStartDeletesBackToTheFirstDifference() {
        let (edit, text) = replacing("hello world", NSRange(location: 0, length: 11), with: "Hello world.")
        XCTAssertEqual(edit, .init(deletions: 11, typed: "Hello world."), "开头就不同：整句退掉重打")
        XCTAssertEqual(text, "Hello world.")
    }

    func testTextAfterTheRangeIsRetyped() {
        // 改的是中间一段：光标在末尾，后面的字要先退掉再原样打回去。
        let (edit, text) = replacing("one two three", NSRange(location: 4, length: 3), with: "2")
        XCTAssertEqual(edit, .init(deletions: 9, typed: "2 three"))
        XCTAssertEqual(text, "one 2 three")
    }

    func testInsertingAtTheEndTypesOnly() {
        let (edit, text) = replacing("你好", NSRange(location: 2, length: 0), with: "世界")
        XCTAssertEqual(edit, .init(deletions: 0, typed: "世界"))
        XCTAssertEqual(text, "你好世界")
    }

    func testDeletionsCountCharactersNotUTF16Units() {
        let (edit, _) = replacing("ok 👍🏽", NSRange(location: 0, length: ("ok 👍🏽" as NSString).length), with: "ok")
        XCTAssertEqual(edit, .init(deletions: 2, typed: ""), "一个带肤色的表情是一次退格")
    }

    func testOutOfRangeIsClamped() {
        let (edit, text) = replacing("abc", NSRange(location: 2, length: 99), with: "Z")
        XCTAssertEqual(edit, .init(deletions: 1, typed: "Z"))
        XCTAssertEqual(text, "abZ")
    }

    func testKeepsOnlyTheEndWhenTooLong() {
        var model = TerminalCommittedTail()
        model.append(String(repeating: "a", count: TerminalCommittedTail.limit))
        model.append("😀")
        XCTAssertLessThanOrEqual(model.length, TerminalCommittedTail.limit)
        XCTAssertTrue(model.text.hasSuffix("a😀"), "从开头丢，最新的字都在")
    }

    func testRemoveLast() {
        var model = TerminalCommittedTail()
        XCTAssertFalse(model.removeLast())
        model.append("hi")
        XCTAssertTrue(model.removeLast())
        XCTAssertEqual(model.text, "h")
    }
}
