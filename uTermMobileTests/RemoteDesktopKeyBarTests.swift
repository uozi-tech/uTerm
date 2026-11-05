import SwiftUI
import XCTest
@testable import uTermMobile

/// 远程桌面的键盘条：和终端共用外壳与面板（`MKeyBar`），发的是 Mac 键码。
@MainActor
final class RemoteDesktopKeyBarTests: XCTestCase {
    // async 版 tearDown 跑在主 actor 上；同步版是 nonisolated，碰不了窗口与探针夹具。
    override func tearDown() async throws {
        MobileProbeWindow.closeAll()
        try await super.tearDown()
    }

    private func press(_ code: UInt16, _ modifiers: RemoteKeyModifiers = []) -> [RemoteDesktopInput] {
        [.key(code: code, down: true, modifiers: modifiers), .key(code: code, down: false, modifiers: modifiers)]
    }

    // MARK: - 键

    func testEveryTerminalSymbolHasAMacKey() {
        XCTAssertEqual(RemoteKeyCatalog.symbols.map(\.label), TerminalKeyCatalog.symbols.map(\.label),
                       "符号面板与终端一样全，一个都不能因为查不到键码被丢掉")
        XCTAssertEqual(RemoteKeyCatalog.agentKeys.map(\.label), TerminalKeyCatalog.agentKeys.map(\.label))
    }

    /// 键的 id 是标签，同一个面板里重了 ForEach 会错乱。
    func testLabelsAreUniqueWithinEachGroup() {
        let groups = [RemoteKeyCatalog.primary, RemoteKeyCatalog.repeating, RemoteKeyCatalog.navigation,
                      RemoteKeyCatalog.function, RemoteKeyCatalog.symbols, RemoteKeyCatalog.agentKeys]
        for group in groups {
            XCTAssertEqual(Set(group.map(\.label)).count, group.count, "\(group.map(\.label))")
        }
    }

    func testShiftedSymbolsCarryShift() throws {
        let question = try XCTUnwrap(RemoteKeyCatalog.symbols.first { $0.label == "?" })
        let slash = try XCTUnwrap(RemoteKeyCatalog.symbols.first { $0.label == "/" })
        XCTAssertEqual(question.code, slash.code, "? 和 / 是同一个物理键")
        XCTAssertEqual(question.modifiers, .shift)
        XCTAssertEqual(slash.modifiers, [])
    }

    func testArmedModifiersAddToTheKeysOwn() {
        XCTAssertEqual(RemoteDesktopKeyBar.press(RemoteKeyCatalog.shiftTab, armed: .command),
                       press(RemoteKeyMap.Key.tab, [.shift, .command]))
        XCTAssertEqual(RemoteDesktopKeyBar.press(RemoteKeyCatalog.escape, armed: []), press(RemoteKeyMap.Key.escape))
    }

    // MARK: - 面板与键盘

    func testOpeningAPanelCollapsesTheKeyboardAndClosingBringsItBack() {
        var switcher = MKeyBarPanelSwitch<Int>()
        var panel: Int?
        var calls: [String] = []
        let show = { calls.append("show") }, collapse = { calls.append("collapse") }

        switcher.toggle(1, panel: &panel, softKeyboardUp: true, showKeyboard: show, collapseKeyboard: collapse)
        XCTAssertEqual(panel, 1)
        // 换到另一个面板时键盘已经收起，不能把「之前弹着」改记成没弹。
        switcher.toggle(2, panel: &panel, softKeyboardUp: false, showKeyboard: show, collapseKeyboard: collapse)
        XCTAssertEqual(panel, 2)
        switcher.toggle(2, panel: &panel, softKeyboardUp: false, showKeyboard: show, collapseKeyboard: collapse)

        XCTAssertNil(panel)
        XCTAssertEqual(calls, ["collapse", "show"])
    }

    func testClosingAPanelOpenedWithoutKeyboardLeavesItDown() {
        var switcher = MKeyBarPanelSwitch<Int>()
        var panel: Int?
        var calls: [String] = []
        switcher.toggle(1, panel: &panel, softKeyboardUp: false, showKeyboard: { calls.append("show") },
                        collapseKeyboard: { calls.append("collapse") })
        switcher.toggle(1, panel: &panel, softKeyboardUp: false, showKeyboard: { calls.append("show") },
                        collapseKeyboard: { calls.append("collapse") })
        XCTAssertNil(panel)
        XCTAssertEqual(calls, [])
    }

    private func mountBar(panel: RemoteDesktopKeyBar.Panel?) async throws -> UIHostingController<RemoteDesktopKeyBar> {
        let bar = RemoteDesktopKeyBar(keys: RemoteDesktopKeyState(), keyboardShown: .constant(true), panel: panel) { _ in }
        let (_, host) = MobileProbeWindow.make(size: CGSize(width: 390, height: 500), placement: .visibleOnScreen,
                                               isolateHost: true, rootView: bar)
        try await Task.sleep(for: .milliseconds(300))
        return host
    }

    private func height(_ host: UIHostingController<RemoteDesktopKeyBar>) -> CGFloat {
        host.sizeThatFits(in: CGSize(width: 390, height: 2000)).height
    }

    /// 与终端同一个外壳：软键盘回来，面板让位。
    func testSoftKeyboardCoveringTheScreenClosesThePanel() async throws {
        let collapsed = try await mountBar(panel: nil)
        let rowHeight = height(collapsed)
        MobileProbeWindow.closeAll()

        let host = try await mountBar(panel: .keys)
        XCTAssertGreaterThan(height(host), rowHeight + 40, "面板是开着的")

        let screen = try XCTUnwrap(host.view.window?.screen)
        let frame = CGRect(x: 0, y: screen.bounds.height - 336, width: screen.bounds.width, height: 336)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: screen,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(height(host), rowHeight, accuracy: 1)
    }
}
