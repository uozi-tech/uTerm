import CoreGraphics
import XCTest
@testable import uTerm

/// 手机输入到 CGEvent 的映射。只验纯函数，不 post 事件；滚动 phase 见 `RemoteDesktopFlowTests`。
final class RemoteEventInjectorMappingTests: XCTestCase {

    func testEveryButtonMapsToItsOwnDownAndUp() {
        let cases: [(RemoteMouseButton, CGEventType, CGEventType, CGMouseButton)] = [
            (.left, .leftMouseDown, .leftMouseUp, .left),
            (.right, .rightMouseDown, .rightMouseUp, .right),
            (.other, .otherMouseDown, .otherMouseUp, .center),
        ]
        for (button, down, up, cgButton) in cases {
            XCTAssertEqual(RemoteEventInjector.buttonEvent(button, down: true).0, down)
            XCTAssertEqual(RemoteEventInjector.buttonEvent(button, down: false).0, up)
            XCTAssertEqual(RemoteEventInjector.buttonEvent(button, down: true).1, cgButton)
            XCTAssertEqual(RemoteEventInjector.buttonEvent(button, down: false).1, cgButton)
        }
    }

    func testEachModifierMapsToItsOwnFlag() {
        let cases: [(RemoteKeyModifiers, CGEventFlags)] = [
            (.shift, .maskShift),
            (.control, .maskControl),
            (.option, .maskAlternate),
            (.command, .maskCommand),
            (.capsLock, .maskAlphaShift),
            (.function, .maskSecondaryFn),
        ]
        for (modifier, flag) in cases {
            XCTAssertEqual(RemoteEventInjector.flags(modifier), flag)
        }
        XCTAssertEqual(RemoteEventInjector.flags([]), [])
    }

    func testModifiersCombine() {
        XCTAssertEqual(RemoteEventInjector.flags([.command, .shift]), [.maskCommand, .maskShift])
    }

    /// ⌃← 切换桌面在系统里登记成 ⌃fn←：方向键事件要留着 `CGEvent` 自带的 fn 与小键盘标志。
    func testArrowKeysKeepTheirIntrinsicFunctionAndKeypadFlags() throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let arrow = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: RemoteKeyMap.Key.left, keyDown: true))
        XCTAssertEqual(RemoteEventInjector.keyFlags(intrinsic: arrow.flags, modifiers: .control),
                       [.maskControl, .maskSecondaryFn, .maskNumericPad])
        let letter = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: RemoteKeyMap.Key.v, keyDown: true))
        XCTAssertEqual(RemoteEventInjector.keyFlags(intrinsic: letter.flags, modifiers: .command), [.maskCommand])
    }

    func testIntrinsicFlagsNeverAddModifiers() {
        let intrinsic: CGEventFlags = [.maskSecondaryFn, .maskNumericPad, .maskShift, .maskNonCoalesced]
        XCTAssertEqual(RemoteEventInjector.keyFlags(intrinsic: intrinsic, modifiers: []),
                       [.maskSecondaryFn, .maskNumericPad], "修饰键只来自手机")
    }

    // MARK: - 一次按键成组（macOS 27）

    private func makeInjector() -> RemoteEventInjector {
        RemoteEventInjector(display: RemoteDesktopDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 500),
                                                          pixelWidth: 2000, pixelHeight: 1000))
    }

    private func button(_ button: RemoteMouseButton = .left, down: Bool, clicks: UInt8 = 1,
                        modifiers: RemoteKeyModifiers = []) -> RemoteDesktopInput {
        .button(button, down: down, clickCount: clicks, x: 0.5, y: 0.5, modifiers: modifiers)
    }

    private func number(_ event: CGEvent?) -> Int64? {
        event?.getIntegerValueField(.mouseEventNumber)
    }

    func testClickDownAndUpShareOneEventNumber() throws {
        let injector = makeInjector()
        let down = try XCTUnwrap(injector.mouseEvent(for: button(down: true)))
        let up = try XCTUnwrap(injector.mouseEvent(for: button(down: false)))
        XCTAssertEqual(down.type, .leftMouseDown)
        XCTAssertEqual(up.type, .leftMouseUp)
        XCTAssertNotEqual(number(down), 0, "编号 0 等于没设，交给系统逐个分配")
        XCTAssertEqual(number(down), number(up), "抬起要和这次按下同号，macOS 27 才把它当成这次按键的结束")
    }

    func testDragCarriesThePressNumberClickStateAndModifiers() throws {
        let injector = makeInjector()
        let down = injector.mouseEvent(for: button(down: true, clicks: 2, modifiers: .shift))
        let drag = try XCTUnwrap(injector.mouseEvent(for: .move(x: 0.6, y: 0.5)))
        let up = injector.mouseEvent(for: button(down: false, clicks: 2, modifiers: .shift))
        XCTAssertEqual(drag.type, .leftMouseDragged)
        XCTAssertEqual(number(drag), number(down))
        XCTAssertEqual(number(up), number(down))
        XCTAssertEqual(drag.getIntegerValueField(.mouseEventClickState), 2)
        XCTAssertTrue(drag.flags.contains(.maskShift), "按着 Shift 拖选时拖动事件也要带 Shift")
    }

    func testEachNewPressGetsANewNumber() {
        let injector = makeInjector()
        let first = number(injector.mouseEvent(for: button(down: true)))
        _ = injector.mouseEvent(for: button(down: false))
        let second = number(injector.mouseEvent(for: button(down: true)))
        XCTAssertNotEqual(first, second)
    }

    func testPointerMoveWithoutButtonIsPlainMove() throws {
        let injector = makeInjector()
        _ = injector.mouseEvent(for: button(down: true))
        _ = injector.mouseEvent(for: button(down: false))
        let move = try XCTUnwrap(injector.mouseEvent(for: .move(x: 0.2, y: 0.2)))
        XCTAssertEqual(move.type, .mouseMoved)
    }

    func testSecondButtonDuringDragKeepsTheFirstPressNumber() {
        let injector = makeInjector()
        let down = number(injector.mouseEvent(for: button(down: true)))
        let rightDown = number(injector.mouseEvent(for: button(.right, down: true)))
        _ = injector.mouseEvent(for: button(.right, down: false))
        let drag = number(injector.mouseEvent(for: .move(x: 0.7, y: 0.5)))
        let up = number(injector.mouseEvent(for: button(down: false)))
        XCTAssertEqual(rightDown, down)
        XCTAssertEqual(drag, down)
        XCTAssertEqual(up, down)
    }

    func testNonMouseInputHasNoMouseEvent() {
        XCTAssertNil(makeInjector().mouseEvent(for: .text("a")))
    }

    /// 滚动增量来自手机：非有限值或超出 Int32 的值转换时会让整个 App 崩掉。
    func testScrollDeltaIsClampedBeforeIntConversion() {
        XCTAssertEqual(RemoteEventInjector.clampScroll(.nan), 0)
        XCTAssertEqual(RemoteEventInjector.clampScroll(.infinity), 0)
        XCTAssertEqual(RemoteEventInjector.clampScroll(-.infinity), 0)
        XCTAssertEqual(RemoteEventInjector.clampScroll(1e10), 100_000)
        XCTAssertEqual(RemoteEventInjector.clampScroll(-1e10), -100_000)
        XCTAssertEqual(RemoteEventInjector.clampScroll(12.5), 12.5)
    }
}
