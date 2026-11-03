import SwiftData
import UIKit
import XCTest
@testable import uTermMobile

/// 终端键盘按标签裁决：只有「已连接 + 拥有键盘」的那个会话能当第一响应者。
///
/// 钉的是实机回归：第一个标签已连上、再开第二个标签，建连过程中键盘冒出来——那是 UIKit
/// 收起新建抽屉时把第一个标签的终端恢复成第一响应者，不经过任何我们的聚焦调用。
/// 所以这里直接对终端视图调 `becomeFirstResponder()`（等价于 UIKit 的自动恢复）。
@MainActor
final class MobileTerminalKeyboardTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func host() throws -> (ModelContainer, ServerProfile, HostKeyChallengeRelay) {
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let h = try XCTUnwrap(MobileFixtures.firstServer(in: c))
        return (c, h, HostKeyChallengeRelay())
    }

    /// 把若干控制器的终端视图挂进同一个真窗口（不在窗口里的视图当不了第一响应者）。
    private func mount(_ controllers: [MobileTerminalController]) -> [MTerminalView] {
        let root = UIViewController()
        let win: UIWindow
        if let scene = MobileProbeWindow.activeScene() {
            win = UIWindow(windowScene: scene)
        } else {
            win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        win.rootViewController = root
        win.makeKeyAndVisible()
        window = win
        return controllers.enumerated().map { i, controller in
            let view = MTerminalView(frame: CGRect(x: 0, y: CGFloat(i) * 200, width: 390, height: 200),
                                     font: .monospacedSystemFont(ofSize: 11, weight: .regular))
            view.controller = controller
            controller.attach(view)
            root.view.addSubview(view)
            return view
        }
    }

    func testConnectingTabNeverTakesKeyboardWhileOtherTabIsConnected() async throws {
        let (c, h, relay) = try host()
        let (a, _) = MobileFakeTerminal.controller(.idle)
        let (b, _) = MobileFakeTerminal.controller(
            MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, connectLatency: .seconds(30)))
        let views = mount([a, b])
        a.start(profile: h, container: c, relay: relay)
        b.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(a)
        XCTAssertTrue(connected)

        // 第一个标签：已连接、拥有键盘 → 能弹。
        a.ownsKeyboard = true
        a.focusKeyboard()
        XCTAssertTrue(views[0].isFirstResponder)

        // 开第二个标签：归属移交给正在建连的 B，A 当场收键盘。
        a.ownsKeyboard = false
        b.ownsKeyboard = true
        XCTAssertFalse(views[0].isFirstResponder)

        // B 还在建连：自己的聚焦与 UIKit 的自动恢复都拿不到键盘；A 也不行（已不是归属者）。
        XCTAssertEqual(b.state, .connecting)
        b.focusKeyboard()
        XCTAssertFalse(views[1].isFirstResponder)
        XCTAssertFalse(views[1].becomeFirstResponder())
        XCTAssertFalse(views[0].becomeFirstResponder())
        XCTAssertFalse(views[0].isFirstResponder)

        a.close()
        b.close()
    }

    func testFailedTabDoesNotTakeKeyboard() async throws {
        let (c, h, relay) = try host()
        let (failing, _) = MobileFakeTerminal.controller(
            MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, connectFailure: "connection refused"))
        let views = mount([failing])
        failing.ownsKeyboard = true
        failing.start(profile: h, container: c, relay: relay)
        let failed = await MobileFakeTerminal.waitUntil {
            if case .failed = failing.state { return true }
            return false
        }
        XCTAssertTrue(failed)

        failing.focusKeyboard()
        XCTAssertFalse(views[0].isFirstResponder)
        XCTAssertFalse(views[0].becomeFirstResponder())
    }

    func testLosingConnectionResignsKeyboard() async throws {
        let (c, h, relay) = try host()
        let (a, _) = MobileFakeTerminal.controller(.idle)
        let views = mount([a])
        a.ownsKeyboard = true
        a.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(a)
        XCTAssertTrue(connected)
        a.focusKeyboard()
        XCTAssertTrue(views[0].isFirstResponder)

        a.close()
        XCTAssertFalse(views[0].isFirstResponder)
    }

    /// 输入法：默认要英文键盘；拼音组字时光标处能看到正在拼的字，上屏后叠层收起、字发给终端。
    func testDefaultsToEnglishAndShowsMarkedTextAtTheCursor() async throws {
        let (c, h, relay) = try host()
        let (a, _) = MobileFakeTerminal.controller(.idle)
        let views = mount([a])
        let view = views[0]
        a.ownsKeyboard = true
        a.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(a)
        XCTAssertTrue(connected)
        a.focusKeyboard()

        if UITextInputMode.activeInputModes.contains(where: { $0.primaryLanguage?.hasPrefix("en") == true }) {
            XCTAssertEqual(view.textInputMode?.primaryLanguage?.hasPrefix("en"), true)
        }

        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        let overlay = view.subviews.compactMap { $0 as? UILabel }.first { $0.text == "ni" }
        let label = try XCTUnwrap(overlay, "组字中的文字应当显示在终端上")
        XCTAssertFalse(label.isHidden)
        if let caret = view.textInputCaretFrame {
            XCTAssertEqual(label.frame.minY, caret.minY, accuracy: 0.5, "叠层贴着光标那一行")
            XCTAssertEqual(view.caretRect(for: view.beginningOfDocument), caret, "候选框跟着光标，而不是整个视图")
        }

        view.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(label.text, "你")
        view.unmarkText()
        XCTAssertTrue(label.isHidden, "上屏后叠层收起")
        a.close()
    }
}
