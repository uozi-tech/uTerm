import XCTest
@testable import uTermMobile

/// 远程桌面的键盘里用听写：同终端（`GhosttyDictationTests`），文档要留着上一版识别结果，改写时退格再补字。
@MainActor
final class RemoteKeyDictationTests: XCTestCase {
    private func input(language: String) -> (view: RemoteKeyInputView, sent: () -> [RemoteDesktopInput], clear: () -> Void) {
        let view = RemoteKeyInputView()
        view.languageOverride = language
        view.keys = RemoteDesktopKeyState()
        var sent: [RemoteDesktopInput] = []
        view.send = { sent.append($0) }
        return (view, { sent }, { sent = [] })
    }

    private var delete: [RemoteDesktopInput] {
        [.key(code: RemoteKeyMap.Key.delete, down: true, modifiers: []),
         .key(code: RemoteKeyMap.Key.delete, down: false, modifiers: [])]
    }

    private func documentText(_ view: UITextInput) -> String? {
        view.textRange(from: view.beginningOfDocument, to: view.endOfDocument).flatMap { view.text(in: $0) }
    }

    func testChineseDictationRewritesTheHypothesisOnTheMac() {
        let (view, sent, clear) = input(language: "zh-Hans")
        var dictation = DictationSimulator(view)

        XCTAssertTrue(dictation.hypothesis("你好"))
        XCTAssertEqual(sent(), [.text("你好")])
        clear()

        XCTAssertTrue(dictation.hypothesis("你好世界"), "第二版要能找到第一版")
        XCTAssertEqual(sent(), [.text("世界")])
        clear()

        XCTAssertTrue(dictation.hypothesis("你好，世界。"))
        XCTAssertEqual(sent(), delete + delete + [.text("，世界。")])
        XCTAssertEqual(documentText(view), "你好，世界。")
    }

    func testEnglishDictationIsTypedAsKeys() {
        let (view, sent, clear) = input(language: "en-US")
        var dictation = DictationSimulator(view)
        dictation.hypothesis("hi")
        clear()
        XCTAssertTrue(dictation.hypothesis("hi there"))
        XCTAssertEqual(sent(), RemoteKeyboardRouting.inputs(for: " there", armed: [], asKeys: true))
    }

    func testBackspaceAfterDictationKeepsTheDocumentInStep() {
        let (view, sent, clear) = input(language: "zh-Hans")
        var dictation = DictationSimulator(view)
        dictation.hypothesis("你好")
        clear()
        view.deleteBackward()
        XCTAssertEqual(sent(), delete)
        XCTAssertEqual(documentText(view), "你")
    }

    func testTypingWithoutDictationKeepsTheDocumentEmpty() {
        let (view, _, _) = input(language: "zh-Hans")
        view.insertText("好")
        XCTAssertEqual(documentText(view), "", "普通打字照旧不留")
    }

    func testCompositionFollowsTheDictatedText() throws {
        let (view, sent, clear) = input(language: "zh-Hans")
        var dictation = DictationSimulator(view)
        dictation.hypothesis("hi")
        clear()
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(view.text(in: try XCTUnwrap(view.markedTextRange)), "ni")
        view.insertText("你")
        XCTAssertEqual(sent(), [.text("你")])
        XCTAssertEqual(documentText(view), "hi你")
    }

    func testArmedShortcutEndsTheDictatedText() {
        let (view, _, _) = input(language: "zh-Hans")
        var dictation = DictationSimulator(view)
        dictation.hypothesis("hi")
        view.tap(RemoteKeyMap.Key.delete, modifiers: [.command])
        XCTAssertEqual(documentText(view), "", "别的按键改了那一行")
        XCTAssertFalse(dictation.hypothesis("hi there"))
    }
}
