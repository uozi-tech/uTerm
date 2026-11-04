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
}
