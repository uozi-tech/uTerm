import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 键盘条的边界：连发的第二次按压、系统收键盘、分屏时键盘归谁、面板与键盘互斥。
@MainActor
final class MobileTerminalKeyboardFlowTests: XCTestCase {
    private var window: UIWindow?

    // async 版 tearDown 跑在主 actor 上；同步版是 nonisolated，碰不了窗口与探针夹具。
    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        MobileProbeWindow.closeAll()
        try await super.tearDown()
    }

    /// 已连接、各自挂在同一个真窗口里的终端（不在窗口里的视图当不了第一响应者）。
    private func connected(_ count: Int) async throws -> [(controller: MobileTerminalController, view: MGhosttyTerminalView)] {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let scene = try XCTUnwrap(MobileProbeWindow.activeScene())
        let root = UIViewController()
        let win = UIWindow(windowScene: scene)
        win.rootViewController = root
        win.makeKeyAndVisible()
        window = win
        var result: [(MobileTerminalController, MGhosttyTerminalView)] = []
        for i in 0..<count {
            let (controller, _) = MobileFakeTerminal.controller(.idle)
            let view = controller.terminal.view
            view.frame = CGRect(x: 0, y: CGFloat(i) * 200, width: 390, height: 200)
            root.view.addSubview(view)
            controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
            let isConnected = await MobileFakeTerminal.waitUntilConnected(controller)
            XCTAssertTrue(isConnected)
            result.append((controller, view))
        }
        return result
    }

    // MARK: - 连发

    func testAQuickTapAfterRepeatingCountsAsATapAgain() async throws {
        let repeater = KeyRepeater()
        var sent = 0
        repeater.press { sent += 1 }
        let deadline = ContinuousClock.now + .seconds(3)
        while sent < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        repeater.release()
        XCTAssertTrue(repeater.didRepeat)
        let afterHold = sent

        repeater.press { sent += 1 }
        XCTAssertFalse(repeater.didRepeat, "新的一次按压要复位，否则松手时 Button 不发这一次，轻点被吞")
        repeater.release()
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertFalse(repeater.didRepeat)
        XCTAssertEqual(sent, afterHold, "轻点交给 Button，连发不发")
    }

    func testReleasingDuringTheDelayNeverRepeats() async throws {
        let repeater = KeyRepeater()
        var sent = 0
        repeater.press { sent += 1 }
        try await Task.sleep(for: .milliseconds(200))
        repeater.release()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(sent, 0)
        XCTAssertFalse(repeater.didRepeat)
    }

    func testPressingAgainWithoutReleaseDoesNotDoubleRepeat() async throws {
        let repeater = KeyRepeater()
        var first = 0, second = 0
        repeater.press { first += 1 }
        repeater.press { second += 1 }
        let deadline = ContinuousClock.now + .seconds(3)
        while second < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        repeater.release()
        XCTAssertEqual(first, 0, "被顶替的那次不能接着发")
        XCTAssertGreaterThanOrEqual(second, 2)
    }

    // MARK: - 系统收键盘

    /// 系统把键盘收走（失焦但用户没点收起）不算用户收起：之后的自动聚焦照常弹回。
    func testKeyboardTakenBySystemComesBackOnNextAutoFocus() async throws {
        let term = try await connected(1)[0]
        term.controller.ownsKeyboard = true
        term.controller.focusKeyboard()
        XCTAssertTrue(term.controller.keyboardShown)

        _ = term.view.resignFirstResponder()
        XCTAssertFalse(term.controller.keyboardShown, "按钮图标跟着真实状态走")

        term.controller.focusKeyboard()
        XCTAssertTrue(term.view.isFirstResponder)
        XCTAssertTrue(term.controller.keyboardShown)
        term.controller.close()
    }

    /// 用户收起之后系统来回抢焦点也不算要回键盘：只有视图真的成为第一响应者才算。
    func testSystemResignAfterCollapseKeepsItCollapsed() async throws {
        let term = try await connected(1)[0]
        term.controller.ownsKeyboard = true
        term.controller.focusKeyboard()
        term.controller.collapseKeyboard()

        term.controller.keyboardFocusChanged(false)
        term.controller.focusKeyboard()

        XCTAssertFalse(term.view.isFirstResponder)
        term.controller.close()
    }

    // MARK: - 分屏

    /// 点没聚焦那一格的键盘按钮：归属到它之前不抢键盘，归属一到就弹。
    func testShowingKeyboardInAnUnownedPaneWaitsForOwnership() async throws {
        let terms = try await connected(2)
        let (front, other) = (terms[0], terms[1])
        front.controller.ownsKeyboard = true
        front.controller.focusKeyboard()
        XCTAssertTrue(front.view.isFirstResponder)

        other.controller.showKeyboard()
        XCTAssertFalse(other.view.isFirstResponder)
        XCTAssertTrue(front.view.isFirstResponder, "还没归它，不能把别的格的键盘抢走")

        front.controller.ownsKeyboard = false
        other.controller.ownsKeyboard = true
        other.controller.focusKeyboard()
        XCTAssertTrue(other.view.isFirstResponder)
        XCTAssertFalse(front.view.isFirstResponder)
        XCTAssertFalse(front.controller.keyboardShown)
        terms.forEach { $0.controller.close() }
    }

    /// 收起只记在点的那一格：另一格拿到归属照常弹。
    func testCollapsingOnePaneLeavesTheOtherPaneAlone() async throws {
        let terms = try await connected(2)
        let (first, second) = (terms[0], terms[1])
        first.controller.ownsKeyboard = true
        first.controller.focusKeyboard()
        first.controller.collapseKeyboard()

        first.controller.ownsKeyboard = false
        second.controller.ownsKeyboard = true
        second.controller.focusKeyboard()
        XCTAssertTrue(second.view.isFirstResponder)

        second.controller.ownsKeyboard = false
        first.controller.ownsKeyboard = true
        first.controller.focusKeyboard()
        XCTAssertFalse(first.view.isFirstResponder, "切回来还是收起的")
        terms.forEach { $0.controller.close() }
    }

    // MARK: - 面板与键盘

    private func mountBar(panel: TerminalKeyBar.Panel?) async throws -> UIHostingController<TerminalKeyBar> {
        let (controller, _) = MobileFakeTerminal.controller(.idle)
        let bar = TerminalKeyBar(controller: controller, panel: panel)
        let (_, host) = MobileProbeWindow.make(size: CGSize(width: 390, height: 500), placement: .visibleOnScreen,
                                               isolateHost: true, rootView: bar)
        try await Task.sleep(for: .milliseconds(300))
        return host
    }

    private func height(_ host: UIHostingController<TerminalKeyBar>) -> CGFloat {
        host.sizeThatFits(in: CGSize(width: 390, height: 2000)).height
    }

    private func postKeyboard(height: CGFloat, in host: UIHostingController<TerminalKeyBar>) async throws {
        let screen = try XCTUnwrap(host.view.window?.screen)
        let frame = CGRect(x: 0, y: screen.bounds.height - height, width: screen.bounds.width, height: height)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: screen,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])
        try await Task.sleep(for: .milliseconds(200))
    }

    func testSoftKeyboardCoveringTheScreenClosesThePanel() async throws {
        let collapsed = try await mountBar(panel: nil)
        let rowHeight = height(collapsed)
        MobileProbeWindow.closeAll()

        let host = try await mountBar(panel: .keys)
        XCTAssertGreaterThan(height(host), rowHeight + 40, "面板是开着的")

        try await postKeyboard(height: 336, in: host)

        XCTAssertEqual(height(host), rowHeight, accuracy: 1, "键盘和面板同时只出现一个")
    }

    func testExternalKeyboardShortcutBarLeavesThePanelOpen() async throws {
        let host = try await mountBar(panel: .prompts)
        let open = height(host)

        try await postKeyboard(height: 55, in: host)

        XCTAssertEqual(height(host), open, accuracy: 1, "外接键盘不占屏，面板不用让位")
    }
}
