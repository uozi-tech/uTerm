import UIKit
import XCTest
@testable import uTermMobile

/// 长按空格键把键盘当触控板：从系统键盘自己的长按处理（`_UIKeyboardTextSelectionInteraction`，键盘窗口里挂着的
/// 私有交互）喂一遍 began / changed / ended，确认系统真的转到我们的 floating cursor 三个方法。
///
/// `RemoteKeyboardTrackpadInputTests` 和 `GhosttyFloatingCursorTests` 直接调那三个方法，系统不调它们（选择器写错、
/// 系统改走别的路）时照样是绿的；这里补上系统那一段。手指按到空格键上判成长按那一步（键盘布局里的手势）还是测不到。
/// 2026-11-26 模拟器（iOS 27.2）与 Duo 真机都通过。找不到这个私有交互时跳过，不判失败。
@MainActor
final class KeyboardTrackpadSystemPathTests: XCTestCase {
    private func pump(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

    private func keyboardSelectionInteraction() throws -> NSObject {
        guard let impl = (NSClassFromString("UIKeyboardImpl") as? NSObject.Type)?
            .perform(NSSelectorFromString("activeInstance"))?.takeUnretainedValue() as? UIView else {
            throw XCTSkip("没有 UIKeyboardImpl.activeInstance")
        }
        var stack: [UIView] = [impl]
        if let window = impl.window { stack.append(window) }
        while let view = stack.popLast() {
            if let found = view.interactions.first(where: {
                NSStringFromClass(type(of: $0)).contains("KeyboardTextSelectionInteraction")
            }) as? NSObject {
                return found
            }
            stack.append(contentsOf: view.subviews)
        }
        throw XCTSkip("键盘上找不到 _UIKeyboardTextSelectionInteraction（系统换了实现）")
    }

    /// 按住后横着滑 `distance` 点。
    private func longPressSlide(by distance: CGFloat) async throws {
        let interaction = try keyboardSelectionInteraction()
        typealias Gesture = @convention(c) (NSObject, Selector, Int, CGPoint, Int) -> Void
        let selector = NSSelectorFromString("longPressGestureWithState:withTranslation:touchCount:")
        guard interaction.responds(to: selector) else { throw XCTSkip("长按入口改名了") }
        let call = unsafeBitCast(interaction.method(for: selector), to: Gesture.self)
        call(interaction, selector, UIGestureRecognizer.State.began.rawValue, .zero, 1)
        try await pump(0.1)
        for step in 1...Int(distance) {
            call(interaction, selector, UIGestureRecognizer.State.changed.rawValue, CGPoint(x: CGFloat(step), y: 0), 1)
            try await pump(0.008)
        }
        call(interaction, selector, UIGestureRecognizer.State.ended.rawValue, CGPoint(x: distance, y: 0), 1)
        try await pump(0.5)
    }

    func testRemoteDesktopKeyboardGetsTheSystemTrackpad() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let view = RemoteKeyInputView(frame: CGRect(x: 0, y: 700, width: 400, height: 48))
        view.keys = RemoteDesktopKeyState()
        var sent: [RemoteDesktopInput] = []
        view.send = { sent.append($0) }
        window.addSubview(view)
        XCTAssertTrue(view.becomeFirstResponder())
        defer { view.dismissKeyboard() }
        try await pump(1)
        try await longPressSlide(by: 80)
        let rights = sent.filter { $0 == .key(code: RemoteKeyMap.Key.right, down: true, modifiers: []) }.count
        XCTAssertGreaterThan(rights, 0, "系统的长按没有转到输入视图：\(sent)")
        XCTAssertFalse(sent.contains { if case .key(RemoteKeyMap.Key.left, _, _) = $0 { true } else { false } })
    }

    func testTerminalGetsTheSystemTrackpad() async throws {
        let host = try GhosttyProbeHost()
        defer { host.close() }
        host.window.makeKey()
        try await host.waitUntilReady()
        XCTAssertTrue(host.view.becomeFirstResponder())
        try await pump(1)
        host.bridge.inputLog = []
        try await longPressSlide(by: 80)
        let text = String(decoding: host.bridge.inputLog?.flatMap { [UInt8]($0) } ?? [], as: UTF8.self)
        XCTAssertTrue(text.contains("\u{1B}[C"), "系统的长按没有转成 →：\(text.debugDescription)")
        XCTAssertFalse(text.contains("\u{1B}[D"))
    }
}
