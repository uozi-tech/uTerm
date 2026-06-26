import XCTest
import AppKit
@testable import uTerm

/// 验证编辑器本地 keyDown 监听器对 ⌘S 的处理：拦截并请求保存、消费事件，
/// 不与既有的 ⌘F/⌘G 串味。回归点：分屏下点进非聚焦面板的编辑器编辑后，⌘S 必须
/// 保存“正在编辑的这个 buffer”，而不是被过期 activeBufferID 误导成 no-op。
@MainActor
final class CodeEditorControllerKeyTests: XCTestCase {

    private func keyEvent(_ chars: String,
                          modifiers: NSEvent.ModifierFlags,
                          keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: keyCode)!
    }

    func test_cmdS_requestsSave_andConsumesEvent() {
        let controller = CodeEditorController()
        var saveCount = 0
        var findOpened = false
        let handled = controller.handleKeyEvent(
            keyEvent("s", modifiers: .command, keyCode: 1),
            openFind: { _ in findOpened = true },
            closeFind: {},
            requestSave: { saveCount += 1 })
        XCTAssertTrue(handled, "⌘S 必须被监听器消费（return true），否则菜单项会再触发一次造成双保存")
        XCTAssertEqual(saveCount, 1)
        XCTAssertFalse(findOpened)
    }

    func test_cmdShiftS_isNotTreatedAsSave() {
        // ⇧⌘S（另存为之类）不应被当成普通保存拦截 —— 留给系统/菜单。
        let controller = CodeEditorController()
        var saveCount = 0
        let handled = controller.handleKeyEvent(
            keyEvent("s", modifiers: [.command, .shift], keyCode: 1),
            openFind: { _ in },
            closeFind: {},
            requestSave: { saveCount += 1 })
        XCTAssertFalse(handled)
        XCTAssertEqual(saveCount, 0)
    }

    func test_cmdF_opensFind_notSave() {
        let controller = CodeEditorController()
        var saveCount = 0
        var findOpened = false
        let handled = controller.handleKeyEvent(
            keyEvent("f", modifiers: .command, keyCode: 3),
            openFind: { _ in findOpened = true },
            closeFind: {},
            requestSave: { saveCount += 1 })
        XCTAssertTrue(handled)
        XCTAssertTrue(findOpened)
        XCTAssertEqual(saveCount, 0)
    }

    func test_plainCharacter_isNotHandled() {
        let controller = CodeEditorController()
        var saveCount = 0
        let handled = controller.handleKeyEvent(
            keyEvent("s", modifiers: [], keyCode: 1),
            openFind: { _ in },
            closeFind: {},
            requestSave: { saveCount += 1 })
        XCTAssertFalse(handled)
        XCTAssertEqual(saveCount, 0)
    }
}
