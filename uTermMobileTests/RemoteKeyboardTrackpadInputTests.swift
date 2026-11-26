import XCTest
@testable import uTermMobile

/// 远程桌面里长按空格键把手机键盘当触控板：系统经 `UITextInput` 的 floating cursor 三个方法报手指位置，
/// 输入视图按设置换成 Mac 上的方向键（移动文字光标）或交给画布移动鼠标指针。
@MainActor
final class RemoteKeyboardTrackpadInputTests: XCTestCase {
    private let column = RemoteKeyboardTrackpad.columnStep

    private func press(_ code: UInt16, _ modifiers: RemoteKeyModifiers = []) -> [RemoteDesktopInput] {
        [.key(code: code, down: true, modifiers: modifiers), .key(code: code, down: false, modifiers: modifiers)]
    }

    private struct Rig {
        let view: RemoteKeyInputView
        let keys: RemoteDesktopKeyState
        var sent: () -> [RemoteDesktopInput]
        var pointerMoves: () -> [CGSize]
    }

    private func rig(mode: RemoteKeyboardTrackpadMode, pointerHandler: Bool = true) -> Rig {
        let view = RemoteKeyInputView()
        let keys = RemoteDesktopKeyState()
        view.keys = keys
        view.trackpadMode = mode
        var sent: [RemoteDesktopInput] = []
        var moves: [CGSize] = []
        view.send = { sent.append($0) }
        if pointerHandler { view.movePointer = { delta, _ in moves.append(delta) } }
        return Rig(view: view, keys: keys, sent: { sent }, pointerMoves: { moves })
    }

    /// 从 `start` 开始，横着一点一点滑 `distance`（每次 1 点，像真的拖动那样分很多次报）。
    private func slide(_ view: RemoteKeyInputView, from start: CGPoint = CGPoint(x: 100, y: 20), by distance: CGFloat) {
        view.beginFloatingCursor(at: start)
        let steps = Int(abs(distance))
        for index in 1...steps {
            view.updateFloatingCursor(at: CGPoint(x: start.x + CGFloat(index) * (distance < 0 ? -1 : 1), y: start.y))
        }
        view.endFloatingCursor()
    }

    func testCaretModeTurnsTheSlideIntoArrowKeysOnTheMac() {
        let rig = rig(mode: .caret)
        slide(rig.view, by: column * 3)
        XCTAssertEqual(rig.sent(), press(RemoteKeyMap.Key.right) + press(RemoteKeyMap.Key.right) + press(RemoteKeyMap.Key.right))
        XCTAssertTrue(rig.pointerMoves().isEmpty)
    }

    func testCaretModeGoesLeftToo() {
        let rig = rig(mode: .caret)
        slide(rig.view, by: -column * 2)
        XCTAssertEqual(rig.sent(), press(RemoteKeyMap.Key.left) + press(RemoteKeyMap.Key.left))
    }

    /// 键盘条上点亮 ⇧ 再滑：整次拖动都带着 ⇧（边拖边选），松手才熄灭。
    func testArmedShiftSelectsForTheWholeSlideAndClearsAfterwards() {
        let rig = rig(mode: .caret)
        rig.keys.toggle(.shift)
        rig.view.beginFloatingCursor(at: CGPoint(x: 0, y: 0))
        for index in 1...Int(column * 2) { rig.view.updateFloatingCursor(at: CGPoint(x: CGFloat(index), y: 0)) }
        XCTAssertEqual(rig.keys.modifiers, .shift, "拖动中保持点亮")
        rig.view.endFloatingCursor()
        XCTAssertEqual(rig.sent(), press(RemoteKeyMap.Key.right, .shift) + press(RemoteKeyMap.Key.right, .shift))
        XCTAssertEqual(rig.keys.modifiers, [], "按过方向键后松手熄灭")
    }

    /// 按住了但没走够一格就松手：上膛的修饰键留给下一次按键。
    func testArmedModifierSurvivesATrackpadHoldThatPressedNothing() {
        let rig = rig(mode: .caret)
        rig.keys.toggle(.command)
        slide(rig.view, by: column / 2)
        XCTAssertEqual(rig.sent(), [])
        XCTAssertEqual(rig.keys.modifiers, .command)
    }

    func testPointerModeMovesThePointerInsteadOfTyping() {
        let rig = rig(mode: .pointer)
        slide(rig.view, by: 20)
        XCTAssertEqual(rig.sent(), [], "不发方向键")
        XCTAssertEqual(rig.pointerMoves().reduce(0) { $0 + $1.width }, 20, accuracy: 0.001)
    }

    func testPointerModeLeavesArmedModifiersForTheNextClick() {
        let rig = rig(mode: .pointer)
        rig.keys.toggle(.command)
        slide(rig.view, by: 30)
        XCTAssertEqual(rig.keys.modifiers, .command, "⌘ 留给接下来的点击（⌘ 点按）")
    }

    func testWithoutAPointerHandlerItFallsBackToTheCaret() {
        let rig = rig(mode: .pointer, pointerHandler: false)
        slide(rig.view, by: column)
        XCTAssertEqual(rig.sent(), press(RemoteKeyMap.Key.right))
    }

    /// 正在组字（拼音还没上屏）时按住空格：交给输入法自己移动组字里的光标，不往 Mac 发键。
    func testTrackpadIsLeftToTheInputMethodWhileComposing() {
        let rig = rig(mode: .caret)
        rig.view.languageOverride = "zh-Hans"
        rig.view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        slide(rig.view, by: column * 3)
        XCTAssertEqual(rig.sent(), [])
    }

    func testUpdatesWithoutABeginAreIgnored() {
        let rig = rig(mode: .caret)
        rig.view.updateFloatingCursor(at: CGPoint(x: 500, y: 0))
        rig.view.endFloatingCursor()
        XCTAssertEqual(rig.sent(), [])
    }

    /// 方法名必须正好是 UITextInput 里那三个可选方法，系统才会调到（写错一个字母不会报编译错误）。
    func testRespondsToTheSystemFloatingCursorSelectors() {
        let view = RemoteKeyInputView()
        for name in ["beginFloatingCursorAtPoint:", "updateFloatingCursorAtPoint:", "endFloatingCursor"] {
            XCTAssertTrue(view.responds(to: NSSelectorFromString(name)), name)
        }
    }
}
