import AppKit
import Carbon.HIToolbox
import XCTest
@testable import uTerm

/// 回滚区查找在真 surface 上的往来：关键词经绑定动作进引擎，搜索线程把总数、选中第几处报回来；回滚里的、
/// surface 放掉重建之后回放进来的内容都找得到；⌘F / ⌘E 从终端视图进来。状态机本身见 `TerminalSearchTests`。
@MainActor
final class GhosttySearchTests: XCTestCase {

    private var rig: GhosttySurfaceRig!
    private var search: TerminalSearch { rig.session.link.search }

    override func setUp() async throws {
        try await super.setUp()
        rig = await GhosttySurfaceRig()
    }

    override func tearDown() async throws {
        search.dismiss()
        rig?.close()
        rig = nil
        try await super.tearDown()
    }

    /// 写 `count` 行带关键词的输出，多到一屏放不下、前面的进了回滚。
    private func feedLines(_ count: Int, marker: String = "needle") async {
        await rig.feed(lines(count, marker: marker))
    }

    private func lines(_ count: Int, marker: String = "needle") -> String {
        var text = ""
        for index in 0..<count { text += "line \(index) \(marker)\r\nfiller \(index)\r\n" }
        return text
    }

    private func waitForTotal(_ expected: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let found = await rig.waitUntil(5) { self.search.total == expected }
        XCTAssertTrue(found, "应当找到 \(expected) 处，引擎报的是 \(String(describing: search.total))", file: file, line: line)
    }

    func testFindsMatchesInScrollbackAndSteps() async {
        await feedLines(60)
        search.present()
        search.query = "needle"
        await waitForTotal(60)
        XCTAssertNil(search.selected, "还没跳过，引擎不选")

        search.next()
        let first = await rig.waitUntil(5) { self.search.selected != nil }
        XCTAssertTrue(first, "跳一下之后引擎报出选中的那一处")
        let afterFirst = search.selected
        search.next()
        let moved = await rig.waitUntil(5) { self.search.selected != afterFirst }
        XCTAssertTrue(moved, "再跳一下选中的换了：\(String(describing: afterFirst)) → \(String(describing: search.selected))")
        search.previous()
        let back = await rig.waitUntil(5) { self.search.selected == afterFirst }
        XCTAssertTrue(back, "往回跳回到上一处")
    }

    func testChangingTheNeedleRecounts() async {
        await feedLines(10)
        await rig.feed("only once: unicorn\r\n")
        search.present()
        search.query = "needle"
        await waitForTotal(10)
        search.query = "unicorn"
        await waitForTotal(1)
        search.query = "nothing-like-this"
        await waitForTotal(0)
        XCTAssertEqual(search.counterText, String(localized: "无结果"))
    }

    func testNewOutputIsFoundWhileSearching() async {
        await feedLines(3)
        search.present()
        search.query = "needle"
        await waitForTotal(3)
        await feedLines(2)
        await waitForTotal(5)
    }

    func testDismissClearsCounts() async {
        await feedLines(4)
        search.present()
        search.query = "needle"
        await waitForTotal(4)
        search.dismiss()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(search.total, "关掉之后搜索线程收尾报来的计数不收")
    }

    /// surface 藏久了被放掉、露出来重建：旧 surface 的查找随它没了，新 surface 收到重发的关键词，回放进来的内容照样找到。
    func testReleasedSurfaceSearchesAgainAfterRebuild() async {
        rig.bridge.hiddenReleaseDelay = .milliseconds(100)
        await feedLines(20)
        search.present()
        search.query = "needle"
        await waitForTotal(20)

        rig.window.contentView = NSView(frame: rig.container.frame)
        let released = await rig.waitUntil(5) { self.rig.bridge.isSurfaceReleased }
        XCTAssertTrue(released)
        XCTAssertNil(search.total, "surface 没了，计数作废")
        // surface 不在：只有影子吃字节（同步解析），重建后由回放带进新 surface。
        rig.session.receiveOutputForTesting(Data(lines(5).utf8))

        rig.window.contentView = rig.container
        rig.container.frame = rig.window.contentView?.bounds ?? rig.container.frame
        rig.container.layoutSubtreeIfNeeded()
        rig.window.makeFirstResponder(rig.view)
        let rebuilt = await rig.waitUntil(5) { !self.rig.bridge.isSurfaceReleased }
        XCTAssertTrue(rebuilt)
        XCTAssertTrue(search.isPresented)
        await waitForTotal(25)
    }

    // MARK: 从终端视图进来

    private func commandKey(_ code: Int, _ characters: String, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : .command,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: UInt16(code))!
    }

    func testCommandFOpensTheBarWithoutSendingBytes() async {
        let before = await rig.sent(expecting: 0, timeout: 0.1).count
        XCTAssertTrue(rig.view.performKeyEquivalent(with: commandKey(kVK_ANSI_F, "f")))
        XCTAssertTrue(search.isPresented)
        XCTAssertEqual(search.focusRequest, 1)
        let after = await rig.sent(expecting: before + 1, timeout: 0.3).count
        XCTAssertEqual(after, before, "⌘F 不发给程序")
    }

    func testCommandEUsesTheSelection() async {
        await rig.feed("\u{1B}[H\u{1B}[2Jalpha beta\r\nbeta gamma\r\nbeta\r\n")
        try? await Task.sleep(for: .milliseconds(100))
        rig.click(col: 7, row: 0, count: 2)   // 双击选中一个词
        let selected = await rig.waitUntil(2) { self.rig.selectedText == "beta" }
        XCTAssertTrue(selected, "自证：选中了「beta」，实际 \(String(describing: rig.selectedText))")

        XCTAssertTrue(rig.view.performKeyEquivalent(with: commandKey(kVK_ANSI_E, "e")))
        let opened = await rig.waitUntil(2) { self.search.isPresented }
        XCTAssertTrue(opened, "引擎把选区当关键词报回来，查找栏打开")
        XCTAssertEqual(search.query, "beta")
        await waitForTotal(3)
    }

    func testCommandEWithoutASelectionPassesThrough() {
        XCTAssertNil(rig.selection)
        XCTAssertFalse(rig.view.performFind(.useSelection), "没有选区：按键交回去")
        XCTAssertFalse(search.isPresented)
    }

    func testContextMenuOffersFind() {
        let menu = rig.view.menu(for: commandKey(kVK_ANSI_F, "f"))
        let item = menu?.items.first { $0.action == #selector(GhosttySurfaceView.showTerminalFind(_:)) }
        XCTAssertNotNil(item)
        XCTAssertTrue(item?.isEnabled ?? false)
    }
}
