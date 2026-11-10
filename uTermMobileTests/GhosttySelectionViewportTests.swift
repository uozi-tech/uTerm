import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 两处换引擎后留下的行为缺陷（iOS 一侧；Mac 一侧在 `GhosttySelectionEraseTests`、`GhosttyHiddenSurfaceTests`）：
/// 1. 清屏 / 擦回滚 / 换备用屏之后选区还在——Ghostty 引擎 ED 2 / ED 3 不清选区。这里核 Ghostty 自己的选区（指针、
///    `select_all` 拖出来的那种）；本包自己画的触摸选区按「选中的文字变了就收起」复核，用例造不出来（要真手势）。
/// 2. 往上翻着看历史时 App 进后台 / 标签被放掉 surface，期间来了输出，回来后视口跳回底部、选区没了。
///    补得了尾巴（surface 一直在）就原样补，视口、选区都在；只能整屏回放（surface 被放掉了）时按记下的内容找回原处。
@MainActor
final class GhosttySelectionViewportTests: XCTestCase {

    private func ready() async throws -> GhosttyProbeHost {
        let host = try GhosttyProbeHost(size: CGSize(width: 393, height: 600))
        try await host.waitUntilReady()
        return host
    }

    private func waitUntil(_ seconds: Double = 3, _ predicate: @MainActor () -> Bool) async -> Bool {
        await MobileFakeTerminal.waitUntil(timeout: .milliseconds(Int(seconds * 1000)), predicate)
    }

    private func scrollbar(_ host: GhosttyProbeHost) -> (offset: Int, len: Int, total: Int)? {
        host.view.uTermScrollbar.map { (Int($0.offset), Int($0.len), Int($0.total)) }
    }

    // MARK: 1. 擦屏清选区

    /// 写一屏字，等由此引出的「清选区」做完，再全选。
    private func selectAll(_ host: GhosttyProbeHost, file: StaticString = #filePath, line: UInt = #line) async {
        host.feedAndWait("\u{1B}[H\u{1B}[2Jfirst line\r\nsecond line\r\nthird line\r\n")
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(host.view.performBindingAction("select_all"), file: file, line: line)
        let selected = await waitUntil { host.view.selectionRegion != nil }
        XCTAssertTrue(selected, "自证：全选出了选区", file: file, line: line)
    }

    private func assertCleared(by bytes: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let host = try await ready()
        defer { host.close() }
        await selectAll(host, file: file, line: line)
        host.feedAndWait(bytes)
        let cleared = await waitUntil { host.view.selectionRegion == nil }
        XCTAssertTrue(cleared, "\(message)：选区应当清掉", file: file, line: line)
    }

    func testClearScreenClearsTheSelection() async throws {
        try await assertCleared(by: "\u{1B}[H\u{1B}[2J", "ED 2")
    }

    func testEraseScrollbackClearsTheSelection() async throws {
        try await assertCleared(by: "\u{1B}[3J", "ED 3")
    }

    func testEnteringTheAlternateScreenClearsTheSelection() async throws {
        try await assertCleared(by: "\u{1B}[?1049h", "进备用屏")
    }

    func testOrdinaryOutputKeepsTheSelection() async throws {
        let host = try await ready()
        defer { host.close() }
        await selectAll(host)
        let before = host.view.selectionRegion
        host.feedAndWait("\u{1B}[6;1Hmore output\r\n")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(host.view.selectionRegion, "正常输出不清选区")
        XCTAssertEqual(host.view.selectionRegion?.topLeft, before?.topLeft)
    }

    // MARK: 2. 回来时视口留在原处

    /// 灌够回滚，翻到第 `row` 行。
    private func scrollUp(_ host: GhosttyProbeHost, to row: Int, file: StaticString = #filePath, line: UInt = #line) async {
        host.feedAndWait((1...300).map { "history \($0)" }.joined(separator: "\r\n") + "\r\n")
        XCTAssertTrue(host.view.scrollToRow(UInt(row)), file: file, line: line)
        let there = await waitUntil { self.scrollbar(host)?.offset == row }
        XCTAssertTrue(there, "自证：翻到了第 \(row) 行，滚动条 \(String(describing: scrollbar(host)))", file: file, line: line)
    }

    /// 进后台（surface 停喂，留着）、期间来了输出、回前台：补尾巴，视口和选区都在原处。
    func testBackgroundKeepsTheScrolledViewportAndSelection() async throws {
        let host = try await ready()
        defer { host.close() }
        let bridge = host.bridge
        await scrollUp(host, to: 100)
        let before = host.viewportText
        XCTAssertTrue(host.view.performBindingAction("select_all"))
        let selection = host.view.selectionRegion
        XCTAssertNotNil(selection)
        let tails = bridge.outputPump.currentStats.tailCatchUps, replays = bridge.outputPump.currentStats.replays

        bridge.setAppInBackground(true)
        bridge.feed(Data(((1...40).map { "while away \($0)" }.joined(separator: "\r\n") + "\r\n").utf8))
        bridge.setAppInBackground(false)
        bridge.outputPump.waitForCatchUp()
        bridge.session.waitForPendingOutput()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(bridge.outputPump.currentStats.tailCatchUps, tails + 1, "补了一次尾巴")
        XCTAssertEqual(bridge.outputPump.currentStats.replays, replays, "没整屏回放")
        XCTAssertEqual(scrollbar(host)?.offset, 100, "视口停在原处")
        XCTAssertEqual(host.viewportText, before, "看到的还是进后台前那几行")
        XCTAssertEqual(host.view.selectionRegion, selection, "选区还在")
    }

    /// 进后台前在底部：回来仍在底部，看得到期间的新内容。
    func testBackgroundAtTheBottomFollowsNewOutput() async throws {
        let host = try await ready()
        defer { host.close() }
        let bridge = host.bridge
        host.feedAndWait((1...100).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n")
        bridge.setAppInBackground(true)
        bridge.feed(Data("fresh after background\r\n".utf8))
        bridge.setAppInBackground(false)
        bridge.outputPump.waitForCatchUp()
        bridge.session.waitForPendingOutput()
        let shown = await waitUntil { host.viewportText.contains("fresh after background") }
        XCTAssertTrue(shown)
        let bar = scrollbar(host)
        XCTAssertTrue(bar.map { $0.offset + $0.len >= $0.total } ?? false, "仍在底部：\(String(describing: bar))")
    }

    /// 标签不在屏上久了、surface 被放掉（只能整屏回放），期间来了输出：露出来后按记下的内容找回原处。
    func testReleasedSurfaceRestoresTheScrolledViewport() async throws {
        let host = try await ready()
        defer { host.close() }
        let bridge = host.bridge
        bridge.hiddenReleaseDelay = .milliseconds(100)
        await scrollUp(host, to: 120)
        let before = host.viewportText

        bridge.setOnScreen(false)
        let released = await waitUntil(5) { bridge.view.uTermIsSurfaceReleased }
        XCTAssertTrue(released, "隐藏够久应当放掉 surface")
        XCTAssertTrue(bridge.keeper.hasMark, "放掉之前记下了视口")
        bridge.feed(Data(((1...40).map { "while released \($0)" }.joined(separator: "\r\n") + "\r\n").utf8))
        let replays = bridge.outputPump.currentStats.replays

        bridge.setOnScreen(true)
        let rebuilt = await waitUntil(5) { bridge.isSurfaceReady && bridge.outputPump.currentStats.replays > replays }
        XCTAssertTrue(rebuilt, "重建后整屏回放")
        let restored = await waitUntil(5) { self.scrollbar(host)?.offset == 120 }
        XCTAssertTrue(restored, "视口找回原处：\(String(describing: scrollbar(host)))，算出 \(String(describing: bridge.keeper.lastRestoredRow))")
        bridge.session.waitForPendingOutput()
        XCTAssertEqual(host.viewportText, before, "看到的还是放掉前那几行")
    }

    /// surface 被放掉前在底部：回来仍在底部。
    func testReleasedSurfaceAtTheBottomStaysAtTheBottom() async throws {
        let host = try await ready()
        defer { host.close() }
        let bridge = host.bridge
        bridge.hiddenReleaseDelay = .milliseconds(100)
        host.feedAndWait((1...100).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n")
        bridge.setOnScreen(false)
        let released = await waitUntil(5) { bridge.view.uTermIsSurfaceReleased }
        XCTAssertTrue(released)
        XCTAssertFalse(bridge.keeper.hasMark, "在底部不记位置")
        bridge.feed(Data("fresh after release\r\n".utf8))
        bridge.setOnScreen(true)
        let shown = await waitUntil(5) {
            bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface && host.viewportText.contains("fresh after release")
        }
        XCTAssertTrue(shown)
        let bar = scrollbar(host)
        XCTAssertTrue(bar.map { $0.offset + $0.len >= $0.total } ?? false, "仍在底部：\(String(describing: bar))")
    }

    /// 期间没来输出：不追，记下的位置作废，视口不动。
    func testBackgroundWithoutOutputLeavesTheViewportAlone() async throws {
        let host = try await ready()
        defer { host.close() }
        let bridge = host.bridge
        await scrollUp(host, to: 80)
        let stats = bridge.outputPump.currentStats
        bridge.setAppInBackground(true)
        bridge.setAppInBackground(false)
        bridge.outputPump.waitForCatchUp()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(scrollbar(host)?.offset, 80)
        XCTAssertEqual(bridge.outputPump.currentStats.replays, stats.replays)
        XCTAssertFalse(bridge.keeper.hasMark)
    }
}
