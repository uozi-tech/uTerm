import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 终端里用听写：每出一版识别结果，UIKit 都要在文档里找到上一版再整段换掉，找不到就取消听写。
/// 原来文档只装组字，第二版永远找不到第一版——听写每说一个词就停。真听写在模拟器上跑不了，
/// 用 `DictationSimulator` 照 UIKit 的做法驱动，核文档和发给终端的字节。
@MainActor
final class GhosttyDictationTests: XCTestCase {
    private func ready() async throws -> GhosttyProbeHost {
        let host = try GhosttyProbeHost()
        host.window.makeKey()
        try await host.waitUntilReady()
        XCTAssertTrue(host.view.becomeFirstResponder())
        try await Task.sleep(for: .seconds(0.2))
        host.bridge.inputLog = []
        return host
    }

    /// write 回调是跳回主线程再记的：等一下再读，读完清空。
    private func sent(_ host: GhosttyProbeHost) async throws -> String {
        try await Task.sleep(for: .seconds(0.05))
        let bytes = host.bridge.inputLog?.flatMap { [UInt8]($0) } ?? []
        host.bridge.inputLog = []
        return String(decoding: bytes, as: UTF8.self)
    }

    private func documentText(_ view: UITextInput) -> String? {
        view.textRange(from: view.beginningOfDocument, to: view.endOfDocument).flatMap { view.text(in: $0) }
    }

    private let backspace = "\u{7F}"

    func testDictationKeepsRewritingTheSameHypothesis() async throws {
        let host = try await ready()
        defer { host.close() }
        var dictation = DictationSimulator(host.view)

        XCTAssertTrue(dictation.hypothesis("hello"))
        let first = try await sent(host)
        XCTAssertEqual(first, "hello")

        XCTAssertTrue(dictation.hypothesis("hello world"), "第二版要能在文档里找到第一版，否则听写就停了")
        let second = try await sent(host)
        XCTAssertEqual(second, " world", "只补新出来的字，不把上一版再打一遍")

        XCTAssertTrue(dictation.hypothesis("Hello world."))
        let third = try await sent(host)
        XCTAssertEqual(third, String(repeating: backspace, count: 11) + "Hello world.", "开头变了：退到开头重打")
        XCTAssertEqual(documentText(host.view), "Hello world.")
    }

    func testTypingWithoutDictationKeepsTheKeyboardContextEmpty() async throws {
        let host = try await ready()
        defer { host.close() }
        host.view.insertText("l")
        host.view.insertText("s")
        let bytes = try await sent(host)
        XCTAssertEqual(bytes, "ls")
        XCTAssertEqual(documentText(host.view), "", "普通打字键盘看到的前文照旧是空的（「双空格变句号」这类不会多出来）")
        XCTAssertEqual(host.view.offset(from: host.view.beginningOfDocument, to: host.view.endOfDocument), 1,
                       "占位还在：按住退格才能连删")
    }

    func testTypingAndBackspaceAfterDictationStayInTheDocument() async throws {
        let host = try await ready()
        defer { host.close() }
        var dictation = DictationSimulator(host.view)
        dictation.hypothesis("hello")
        host.view.insertText(" x")
        XCTAssertEqual(documentText(host.view), "hello x")
        host.view.deleteBackward()
        let bytes = try await sent(host)
        XCTAssertEqual(bytes, "hello x" + backspace)
        XCTAssertEqual(documentText(host.view), "hello ", "退格跟着删掉文档里最后一个字")
    }

    func testReturnAndKeyBarKeysEndTheRewritableText() async throws {
        let host = try await ready()
        defer { host.close() }
        var dictation = DictationSimulator(host.view)
        dictation.hypothesis("ls")
        host.view.insertText("\n")
        let bytes = try await sent(host)
        XCTAssertEqual(bytes, "ls\r")
        XCTAssertEqual(documentText(host.view), "", "回车之后那一行交出去了")
        XCTAssertFalse(dictation.hypothesis("ls -la"), "这时再改写上一版就该失败（真机上 UIKit 会结束这次听写）")

        var again = DictationSimulator(host.view)
        again.hypothesis("cd")
        host.bridge.send(TerminalKeyCatalog.arrows[0])
        XCTAssertEqual(documentText(host.view), "", "键盘条的键也改了那一行")

        again = DictationSimulator(host.view)
        again.hypothesis("echo")
        host.bridge.paste("x")
        XCTAssertEqual(documentText(host.view), "", "宿主绕过视图写字节（粘贴、提示词）也清掉")
    }

    func testPinyinCompositionAfterDictation() async throws {
        let host = try await ready()
        defer { host.close() }
        var dictation = DictationSimulator(host.view)
        dictation.hypothesis("hi")
        host.view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        let marked = try XCTUnwrap(host.view.markedTextRange)
        XCTAssertEqual(host.view.text(in: marked), "ni", "组字排在已上屏那一段后面，输入法读得回来")
        host.view.insertText("你")
        let bytes = try await sent(host)
        XCTAssertEqual(bytes, "hi你")
        XCTAssertEqual(documentText(host.view), "hi你")
    }
}
