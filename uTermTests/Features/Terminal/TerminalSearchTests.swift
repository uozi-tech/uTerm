import AppKit
import Carbon.HIToolbox
import XCTest
@testable import uTerm

/// 两端共用的终端查找状态（`TerminalSearch`）：查找栏上的操作变成哪些绑定动作、引擎报来的事件怎么收、surface 换了之后
/// 重发关键词。纯逻辑，绑定动作记下来不执行。真 surface 上的往来见 `GhosttySearchTests`。
@MainActor
final class TerminalSearchTests: XCTestCase {
    private var actions: [String] = []
    private var accepts = true
    private var search: TerminalSearch!

    override func setUp() async throws {
        try await super.setUp()
        actions = []
        accepts = true
        search = TerminalSearch()
        search.debounceDelay = .milliseconds(20)
        search.perform = { [unowned self] action in
            self.actions.append(action)
            return self.accepts
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    // MARK: 关键词

    func testTypingWhileClosedSendsNothing() {
        search.query = "needle"
        XCTAssertEqual(actions, [])
    }

    func testOpeningWithAnEmptyBoxSendsNothing() {
        search.present()
        XCTAssertTrue(search.isPresented)
        XCTAssertEqual(actions, [], "框里没字时不用发 `search:`（引擎本来就没在找）")
        XCTAssertEqual(search.focusRequest, 1)
    }

    func testLongNeedlesGoOutRightAway() {
        search.present()
        search.query = "nee"
        search.query = "need"
        XCTAssertEqual(actions, ["search:nee", "search:need"])
    }

    func testShortNeedlesWaitAndOnlyTheLastOneGoesOut() async {
        search.present()
        search.query = "n"
        search.query = "ne"
        XCTAssertEqual(actions, [], "不满三个字符的先等一等")
        await settle()
        XCTAssertEqual(actions, ["search:ne"])
    }

    func testGrowingPastTheThresholdCancelsTheWait() async {
        search.present()
        search.query = "ne"
        search.query = "nee"
        await settle()
        XCTAssertEqual(actions, ["search:nee"], "等着发的短关键词被更长的顶掉了")
    }

    func testClearingTheBoxStopsTheSearch() {
        search.present()
        search.query = "needle"
        search.handle(.total(4))
        search.query = ""
        XCTAssertEqual(actions, ["search:needle", "search:"])
        XCTAssertNil(search.total)
        XCTAssertNil(search.counterText)
    }

    func testNeedleKeepsColonsAndSpacesVerbatim() {
        search.present()
        search.query = "a: b=c"
        XCTAssertEqual(actions, ["search:a: b=c"], "Ghostty 按第一个冒号切，后面原样是参数")
    }

    // MARK: 跳转

    func testNextFlushesAWaitingNeedleFirst() {
        search.present()
        search.query = "ne"
        search.next()
        XCTAssertEqual(actions, ["search:ne", "navigate_search:next"])
    }

    func testPreviousNavigatesBackward() {
        search.present()
        search.query = "needle"
        search.previous()
        XCTAssertEqual(actions.last, "navigate_search:previous")
    }

    func testNavigatingWithAnEmptyBoxDoesNothing() {
        search.present()
        search.next()
        XCTAssertEqual(actions, [])
    }

    func testNavigatingWhileClosedOpensTheBar() {
        search.next()
        XCTAssertTrue(search.isPresented)
        XCTAssertEqual(actions, [])
    }

    // MARK: 关掉 / 再打开

    func testDismissEndsTheSearchAndKeepsTheNeedle() {
        search.present()
        search.query = "needle"
        search.handle(.total(3))
        search.handle(.selected(0))
        search.dismiss()
        XCTAssertFalse(search.isPresented)
        XCTAssertEqual(actions, ["search:needle", "end_search"])
        XCTAssertNil(search.total)
        XCTAssertNil(search.selected)
        XCTAssertEqual(search.query, "needle")

        search.present()
        XCTAssertEqual(actions, ["search:needle", "end_search", "search:needle"], "再打开接着找上次的关键词")
    }

    func testPresentingAgainWhileOpenOnlyRefocuses() {
        search.present()
        search.query = "needle"
        search.present()
        XCTAssertEqual(actions, ["search:needle"])
        XCTAssertEqual(search.focusRequest, 2)
    }

    // MARK: 引擎报来的

    func testCountsFollowTheEngine() {
        search.present()
        search.query = "needle"
        search.handle(.total(12))
        XCTAssertEqual(search.counterText, "-/12")
        search.handle(.selected(2))
        XCTAssertEqual(search.counterText, "3/12")
        search.handle(.selected(nil))
        search.handle(.total(nil))
        XCTAssertNil(search.counterText)
        search.handle(.total(0))
        XCTAssertEqual(search.counterText, String(localized: "无结果"))
    }

    func testCountsArrivingAfterCloseAreDropped() {
        search.present()
        search.query = "needle"
        search.dismiss()
        search.handle(.total(5))
        search.handle(.selected(1))
        XCTAssertNil(search.total)
        XCTAssertNil(search.selected)
    }

    func testStartedWithASelectionReplacesTheNeedle() {
        search.present()
        search.query = "old"
        search.handle(.started(needle: "ab"))
        XCTAssertEqual(search.query, "ab")
        XCTAssertEqual(actions, ["search:old", "search:ab"], "选区当关键词时不等，哪怕不满三个字符")
    }

    func testStartedWithoutANeedleJustOpens() {
        search.handle(.started(needle: nil))
        XCTAssertTrue(search.isPresented)
        XCTAssertEqual(actions, [])
    }

    func testEngineEndingTheSearchClosesTheBarWithoutEchoing() {
        search.present()
        search.query = "needle"
        search.handle(.ended)
        XCTAssertFalse(search.isPresented)
        XCTAssertEqual(actions, ["search:needle"], "引擎说停了，不用再发 `end_search`")
    }

    // MARK: surface 的生灭

    func testANewSurfaceGetsTheNeedleAgain() {
        search.present()
        search.query = "needle"
        search.handle(.total(7))
        search.surfaceDetached()
        XCTAssertNil(search.total, "旧 surface 的计数作废")
        search.surfaceAttached()
        XCTAssertEqual(actions, ["search:needle", "search:needle"])
    }

    func testANewSurfaceWhileClosedGetsNothing() {
        search.query = "needle"
        search.surfaceAttached()
        XCTAssertEqual(actions, [])
    }

    func testANeedleThatFoundNoSurfaceIsSentWhenOneAppears() {
        accepts = false
        search.present()
        search.query = "needle"
        accepts = true
        search.surfaceAttached()
        XCTAssertEqual(actions, ["search:needle", "search:needle"])
    }

    // MARK: Mac 的键位与菜单

    private func key(_ code: Int, _ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: UInt16(code))!
    }

    func testMacFindKeys() {
        XCTAssertEqual(GhosttySurfaceView.findCommand(for: key(kVK_ANSI_F, "f", .command)), .show)
        XCTAssertEqual(GhosttySurfaceView.findCommand(for: key(kVK_ANSI_G, "g", .command)), .next)
        XCTAssertEqual(GhosttySurfaceView.findCommand(for: key(kVK_ANSI_G, "G", [.command, .shift])), .previous)
        XCTAssertEqual(GhosttySurfaceView.findCommand(for: key(kVK_ANSI_E, "e", .command)), .useSelection)
        XCTAssertNil(GhosttySurfaceView.findCommand(for: key(kVK_ANSI_F, "f", [.command, .option])))
        XCTAssertNil(GhosttySurfaceView.findCommand(for: key(kVK_ANSI_F, "f", .control)), "⌃F 是给 shell 的")
        XCTAssertNil(GhosttySurfaceView.findCommand(for: key(kVK_ANSI_F, "f", [])))
    }

    func testMacFindMenuTags() {
        XCTAssertEqual(GhosttySurfaceView.findCommand(forMenuTag: NSTextFinder.Action.showFindInterface.rawValue), .show)
        XCTAssertEqual(GhosttySurfaceView.findCommand(forMenuTag: NSTextFinder.Action.nextMatch.rawValue), .next)
        XCTAssertEqual(GhosttySurfaceView.findCommand(forMenuTag: NSTextFinder.Action.previousMatch.rawValue), .previous)
        XCTAssertEqual(GhosttySurfaceView.findCommand(forMenuTag: NSTextFinder.Action.setSearchString.rawValue),
                       .useSelection)
        XCTAssertNil(GhosttySurfaceView.findCommand(forMenuTag: NSTextFinder.Action.replaceAll.rawValue))
        XCTAssertEqual(GhosttySurfaceView.findCommand(forMenuTag: Int(NSFindPanelAction.next.rawValue)), .next)
    }
}
