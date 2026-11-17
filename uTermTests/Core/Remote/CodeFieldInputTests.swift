import AppKit
import XCTest
@testable import uTerm

/// 定长数字码输入的规则（两端共用的 `CodeFieldInput`）和 Mac 收键的那个视图（`UCodeKeyView`）。
@MainActor
final class CodeFieldInputTests: XCTestCase {
    func test_normalize_keeps_digits_only_and_truncates() {
        XCTAssertEqual(CodeFieldInput.normalize("123456", length: 6), "123456")
        XCTAssertEqual(CodeFieldInput.normalize("1234567", length: 6), "123456", "超出的位截掉")
        XCTAssertEqual(CodeFieldInput.normalize("123 456", length: 6), "123456", "粘贴带空格")
        XCTAssertEqual(CodeFieldInput.normalize("配对码:12-34-56", length: 6), "123456", "粘贴带别的字符")
        XCTAssertEqual(CodeFieldInput.normalize("１２３４５６", length: 6), "123456", "全角数字换成半角")
        XCTAssertEqual(CodeFieldInput.normalize("١٢٣", length: 6), "", "别的文字里的数字不收")
        XCTAssertEqual(CodeFieldInput.normalize("", length: 6), "")
    }

    func test_typing_appends_and_stops_when_full() {
        XCTAssertEqual(CodeFieldInput.appending("4", to: "123", length: 6), "1234")
        XCTAssertEqual(CodeFieldInput.appending("a", to: "123", length: 6), "123", "不是数字的不进")
        XCTAssertEqual(CodeFieldInput.appending("7", to: "123456", length: 6), "123456", "满了不动")
    }

    func test_paste_replaces_a_partial_code_and_ignores_text_without_digits() {
        XCTAssertEqual(CodeFieldInput.pasting("654 321", over: "12", length: 6), "654321", "粘贴整串换掉输了一半的")
        XCTAssertEqual(CodeFieldInput.pasting("hello", over: "12", length: 6), "12", "剪贴板里没有数字就不动")
    }

    func test_delete_removes_the_last_digit() {
        XCTAssertEqual(CodeFieldInput.deletingLast(from: "123"), "12")
        XCTAssertEqual(CodeFieldInput.deletingLast(from: ""), "")
    }

    func test_spoken_value_reads_digit_by_digit() {
        XCTAssertEqual(CodeFieldInput.spoken("123"), "1 2 3")
    }

    func test_key_view_takes_typing_delete_and_return() {
        let view = UCodeKeyView()
        var changes: [String] = []
        var submits = 0
        view.onChange = { changes.append($0) }
        view.onSubmit = { submits += 1 }

        view.insertText("1")
        view.insertText("２")
        view.insertText("x")
        XCTAssertEqual(view.code, "12")
        XCTAssertEqual(changes, ["1", "12"], "没变化的输入不回调")

        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(view.code, "1")
        view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(view.code, "1", "方向键不处理")
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submits, 1)
        view.doCommand(by: #selector(NSResponder.deleteToBeginningOfLine(_:)))
        XCTAssertEqual(view.code, "")
    }

    /// 真的按键事件：数字键进 `insertText`、退格进 `deleteBackward`、回车进 `insertNewline`（AppKit 的键绑定这一段）。
    func test_real_key_events_reach_the_key_view() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = UCodeKeyView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        var submits = 0
        view.onSubmit = { submits += 1 }

        func key(_ characters: String, code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        view.keyDown(with: try key("4", code: 21))
        view.keyDown(with: try key("2", code: 19))
        XCTAssertEqual(view.code, "42")
        view.keyDown(with: try key("a", code: 0))
        XCTAssertEqual(view.code, "42", "字母不进")
        view.keyDown(with: try key("\u{7F}", code: 51))
        XCTAssertEqual(view.code, "4", "退格删最后一位")
        view.keyDown(with: try key("\r", code: 36))
        XCTAssertEqual(submits, 1, "回车回调")
    }

    func test_key_view_stops_at_its_length() {
        let view = UCodeKeyView()
        view.length = 4
        view.insertText("123456")
        XCTAssertEqual(view.code, "1234")
    }
}
