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

    // MARK: - 切标签

    /// 一个已连接的终端标签，终端视图挂在测试窗口里（不在窗口里的视图当不了第一响应者）。
    private func connectedTab() async throws -> TermTab {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        if window == nil {
            let win = UIWindow(windowScene: try XCTUnwrap(MobileProbeWindow.activeScene()))
            win.rootViewController = UIViewController()
            win.makeKeyAndVisible()
            window = win
        }
        let root = try XCTUnwrap(window?.rootViewController?.view)
        let (tab, _) = MobileFakeTerminal.tab(host: host, .idle)
        let view = tab.controller.terminal.view
        view.frame = CGRect(x: 0, y: CGFloat(root.subviews.count) * 200, width: 390, height: 200)
        root.addSubview(view)
        tab.controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let isConnected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(isConnected)
        return tab
    }

    /// 同一个工作区同一格里的几个已连接终端标签。
    private func workspace(tabs count: Int) async throws -> (MobileWorkspace, [TermTab]) {
        let ws = MobileWorkspace()
        var tabs: [TermTab] = []
        for _ in 0..<count {
            let tab = try await connectedTab()
            ws.open(.terminal(tab))
            tabs.append(tab)
        }
        return (ws, tabs)
    }

    /// 工作区屏的 `syncKeyboard`：先交接，再补一次聚焦（没有键盘可交接时靠它弹）。
    private func sync(_ ws: MobileWorkspace) {
        let owner = ws.activeTab?.terminal
        if !ws.handKeyboard(to: owner) { owner?.controller.focusKeyboard() }
    }

    /// 键盘在别的标签上时切标签：第一响应者当场换主，中间没有「谁都不是第一响应者」的一刻——那一刻键盘会收起，
    /// 50 ms 后再弹回来，新旧两个终端各跟着改一次尺寸（实机反馈：切 session 时键盘和画面来回跳）。
    func testSwitchingTabsHandsTheKeyboardOverWithoutDroppingIt() async throws {
        let (ws, tabs) = try await workspace(tabs: 2)
        let (first, second) = (tabs[0], tabs[1])
        ws.activate(first.id)
        sync(ws)
        XCTAssertTrue(first.controller.terminal.view.isFirstResponder)

        ws.activate(second.id)
        XCTAssertTrue(ws.handKeyboard(to: second), "交接当场完成，不等之后那次补聚焦")

        XCTAssertTrue(second.controller.terminal.view.isFirstResponder)
        XCTAssertTrue(second.controller.keyboardShown)
        XCTAssertFalse(first.controller.keyboardShown)
        XCTAssertFalse(first.controller.ownsKeyboard)
        tabs.forEach { $0.controller.close() }
    }

    /// 同一格里切标签，键盘的收放跟着格走：在一个标签上收起，切到另一个不弹；在另一个上要回来，切回去也还在。
    func testKeyboardStaysAsTheUserLeftItAcrossTabsOfOnePane() async throws {
        let (ws, tabs) = try await workspace(tabs: 2)
        let (first, second) = (tabs[0], tabs[1])
        ws.activate(first.id)
        sync(ws)
        first.controller.collapseKeyboard()

        ws.activate(second.id)
        sync(ws)
        XCTAssertFalse(second.controller.terminal.view.isFirstResponder, "收起的键盘不因为切标签弹回来")

        second.controller.showKeyboard()
        XCTAssertTrue(second.controller.terminal.view.isFirstResponder)
        ws.activate(first.id)
        sync(ws)
        XCTAssertTrue(first.controller.terminal.view.isFirstResponder, "要回来的键盘切标签也不丢")
        tabs.forEach { $0.controller.close() }
    }

    /// 分屏的两格各记各的：一格收起，不影响另一格。
    func testEachPaneKeepsItsOwnKeyboardIntent() async throws {
        let (ws, tabs) = try await workspace(tabs: 2)
        let (first, second) = (tabs[0], tabs[1])
        ws.moveToOtherPane(second.id)
        sync(ws)
        second.controller.collapseKeyboard()

        ws.activate(first.id)
        sync(ws)

        XCTAssertTrue(first.controller.terminal.view.isFirstResponder)
        ws.activate(second.id)
        sync(ws)
        XCTAssertFalse(second.controller.terminal.view.isFirstResponder, "切回来还是收起的")
        tabs.forEach { $0.controller.close() }
    }

    /// 在收起过键盘的格里新开一个终端：用户是来打字的，照常弹。
    func testOpeningANewTerminalBringsTheKeyboardBack() async throws {
        let (ws, tabs) = try await workspace(tabs: 1)
        sync(ws)
        tabs[0].controller.collapseKeyboard()

        let fresh = try await connectedTab()
        ws.open(.terminal(fresh))
        sync(ws)

        XCTAssertTrue(fresh.controller.terminal.view.isFirstResponder)
        (tabs + [fresh]).forEach { $0.controller.close() }
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
