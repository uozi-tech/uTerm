import AppKit
import XCTest
@testable import uTerm

/// 不在屏上的终端（切走的标签：视图被 SwiftUI 从窗口里卸下）只喂影子终端，surface 停画；隐藏够久放掉 surface；
/// 回到屏上时重建（放掉了的话）并从影子回放，画面与影子一致。真 surface，读 surface 自己的视口文字。
@MainActor
final class GhosttyHiddenSurfaceTests: XCTestCase {

    private var rig: GhosttySurfaceRig!

    override func setUp() async throws {
        try await super.setUp()
        rig = await GhosttySurfaceRig()
    }

    override func tearDown() async throws {
        rig?.close()
        rig = nil
        try await super.tearDown()
    }

    private func hide() {
        rig.window.contentView = NSView(frame: rig.container.frame)
        XCTAssertNil(rig.view.window)
    }

    private func show() {
        rig.window.contentView = rig.container
        rig.container.frame = rig.window.contentView?.bounds ?? rig.container.frame
        rig.container.layoutSubtreeIfNeeded()
        rig.window.makeFirstResponder(rig.view)
    }

    private func assertSurfaceMatchesShadow(containing marker: String, file: StaticString = #filePath, line: UInt = #line) async {
        rig.keepRendering()
        let live = await rig.waitUntil(5) { self.rig.bridge.isLive }
        XCTAssertTrue(live, "回到屏上后 surface 应当重新吃字节", file: file, line: line)
        let shadow = rig.session.shadow
        let same = await rig.waitUntil(5) {
            self.rig.surfaceText == shadow.viewportText() && self.rig.surfaceText.contains(marker)
        }
        XCTAssertTrue(same, "画面应当与影子一致：\n画面 \(rig.surfaceText.suffix(200))\n影子 \(shadow.viewportText().suffix(200))",
                      file: file, line: line)
    }

    /// 隐藏期间来的输出只进影子；露出来把这段补给 surface（补尾巴，不整屏回放），画面与影子一致。
    func testHiddenTerminalOnlyFeedsTheShadowAndCatchesUpWhenShown() async {
        await rig.feed("before\r\n")
        hide()
        XCTAssertFalse(rig.bridge.isOnScreen)
        XCTAssertFalse(rig.bridge.isLive, "不在屏上：surface 不吃字节")
        let shadowOnly = rig.session.outputPump.currentStats.shadowOnlyBytes
        let replays = rig.bridge.seedCount
        rig.session.feedOutput(text: (1...50).map { "hidden \($0)" }.joined(separator: "\r\n"))
        XCTAssertGreaterThan(rig.session.outputPump.currentStats.shadowOnlyBytes, shadowOnly, "隐藏期间的字节只进影子")
        XCTAssertFalse(rig.bridge.isSurfaceReleased, "还没到放掉的时候")

        let tails = rig.session.outputPump.currentStats.tailCatchUps
        show()
        await assertSurfaceMatchesShadow(containing: "hidden 50")
        XCTAssertEqual(rig.session.outputPump.currentStats.tailCatchUps, tails + 1, "露出来补一次尾巴")
        XCTAssertEqual(rig.bridge.seedCount, replays, "surface 一直在：不整屏回放")
    }

    /// 没来新字节：露出来不回放（surface 一直留着、内容没落下）。
    func testShowingAgainWithoutNewOutputDoesNotReplay() async {
        await rig.feed("stay\r\n")
        let replays = rig.bridge.seedCount
        hide()
        show()
        await assertSurfaceMatchesShadow(containing: "stay")
        XCTAssertEqual(rig.bridge.seedCount, replays)
    }

    /// 隐藏超过 `hiddenReleaseDelay` 放掉 surface；露出来重建并回放——哪怕这期间一个字节都没来（新 surface 是空的）。
    /// 全屏程序（备用屏）的内容不能被新 surface 出生时的默认网格裁掉，也不能把默认网格发给远端。
    func testReleasedSurfaceIsRebuiltWithTheAlternateScreenIntact() async throws {
        rig.bridge.hiddenReleaseDelay = .milliseconds(100)
        await rig.feed("\u{1B}[?1049h\u{1B}[2J\u{1B}[3;5Hfull screen app\u{1B}[20;40Hbottom right")
        let shadow = rig.session.shadow
        let size = shadow.size
        let resizesBefore = await rig.backend.resizes.count

        hide()
        let released = await rig.waitUntil(5) { self.rig.bridge.isSurfaceReleased }
        XCTAssertTrue(released, "隐藏够久应当放掉 surface")

        show()
        let rebuilt = await rig.waitUntil(5) { !self.rig.bridge.isSurfaceReleased }
        XCTAssertTrue(rebuilt)
        await assertSurfaceMatchesShadow(containing: "bottom right")
        XCTAssertTrue(shadow.isOnAlternateScreen)
        XCTAssertEqual(shadow.size.cols, size.cols)
        XCTAssertEqual(shadow.size.rows, size.rows)
        XCTAssertTrue(shadow.viewportText().contains("full screen app"), "备用屏的内容不能被裁")
        let resizes = await rig.backend.resizes.dropFirst(resizesBefore)
        XCTAssertTrue(resizes.allSatisfy { Int($0.cols) == size.cols && Int($0.rows) == size.rows },
                      "重建 surface 不该把别的网格发给远端：\(resizes)")
    }

    /// 切标签的真实路径：SwiftUI 拆掉旧容器、露出来时新建一个容器接走视图；藏着期间 surface 被放掉、窗口还改了大小。
    /// 整个过程 PTY 只该收到一次新尺寸（真实尺寸变了），影子只在旧网格和新网格上（闲置后画面错位的排查）。
    func testTabSwitchThroughANewContainerAfterReleaseOnlyEverShowsRealGrids() async throws {
        rig.bridge.hiddenReleaseDelay = .milliseconds(100)
        await rig.feed("\u{1B}[?1049h\u{1B}[2J\u{1B}[1;1Hfull screen app")
        let shadow = rig.session.shadow
        let old = [shadow.size.cols, shadow.size.rows]
        let resizesBefore = await rig.backend.resizes.count

        rig.container.detachSurface()
        hide()
        let released = await rig.waitUntil(5) { self.rig.bridge.isSurfaceReleased }
        XCTAssertTrue(released)
        rig.window.setContentSize(NSSize(width: 1100, height: 650))

        let container = GhosttyContainerView(surface: rig.view)
        container.isActive = true
        rig.window.contentView = container
        container.frame = rig.window.contentView?.bounds ?? container.frame
        container.layoutSubtreeIfNeeded()
        var seen: [[Int]] = []
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let size = [shadow.size.cols, shadow.size.rows]
            if seen.last != size { seen.append(size); stableSince = Date() }
            if rig.bridge.isLive, Date().timeIntervalSince(stableSince) > 0.5 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let new = [shadow.size.cols, shadow.size.rows]
        XCTAssertGreaterThan(new[0], old[0], "用例前提：窗口拉宽了")
        XCTAssertEqual(seen.filter { $0 != old && $0 != new }, [], "影子只该在旧网格和新网格上：\(seen)")
        let resizes = await rig.backend.resizes.dropFirst(resizesBefore).map { [Int($0.cols), Int($0.rows)] }
        XCTAssertEqual(resizes, [new], "PTY 只该收到新的真实尺寸：\(resizes)")
        XCTAssertTrue(shadow.viewportText().contains("full screen app"))
    }

    /// 放掉之后来了输出，露出来同样对得上；之后的实时字节照常进画面。
    func testReleasedSurfaceCatchesUpWithOutputThatArrivedMeanwhile() async {
        rig.bridge.hiddenReleaseDelay = .milliseconds(100)
        await rig.feed("first\r\n")
        hide()
        let released = await rig.waitUntil(5) { self.rig.bridge.isSurfaceReleased }
        XCTAssertTrue(released)
        rig.session.feedOutput(text: "arrived while released\r\n")

        show()
        await assertSurfaceMatchesShadow(containing: "arrived while released")
        await rig.feed("live again")
        XCTAssertTrue(rig.surfaceText.contains("live again"))
    }

    /// 隐藏又在放掉之前回来：不放掉。
    func testComingBackBeforeTheDelayKeepsTheSurface() async {
        rig.bridge.hiddenReleaseDelay = .milliseconds(300)
        await rig.feed("keep\r\n")
        hide()
        try? await Task.sleep(for: .milliseconds(100))
        show()
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(rig.bridge.isSurfaceReleased)
        await assertSurfaceMatchesShadow(containing: "keep")
    }

    // MARK: 切回来时视口与选区留在原处

    private var scrollbar: (offset: Int, len: Int, total: Int)? {
        rig.view.uTermScrollbar.map { (Int($0.offset), Int($0.len), Int($0.total)) }
    }

    /// 灌够回滚，翻到第 `row` 行，等引擎报来滚动条。
    private func scrollUp(to row: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await rig.feed((1...300).map { "history \($0)" }.joined(separator: "\r\n") + "\r\n")
        XCTAssertTrue(rig.view.scrollToRow(UInt(row)), file: file, line: line)
        rig.keepRendering()
        let there = await rig.waitUntil(3) { self.scrollbar?.offset == row }
        XCTAssertTrue(there, "自证：翻到了第 \(row) 行，滚动条 \(String(describing: scrollbar))", file: file, line: line)
    }

    /// 往上翻着、选中一段，切走，期间来了输出，切回来：视口停在原处、选区还在（补尾巴，surface 一直留着）。
    func testScrolledViewportAndSelectionSurviveHiddenOutput() async {
        await scrollUp(to: 100)
        let before = rig.surfaceText
        rig.drag(fromCol: 0, row: 2, toCol: 6)
        let selected = await rig.waitUntil(2) { self.rig.selection != nil }
        XCTAssertTrue(selected, "自证：拖出了选区")
        let selection = rig.selection

        hide()
        rig.session.feedOutput(text: (1...40).map { "while away \($0)" }.joined(separator: "\r\n") + "\r\n")
        show()
        await assertCaughtUp()
        XCTAssertEqual(scrollbar?.offset, 100, "视口停在原处")
        XCTAssertEqual(rig.surfaceText, before, "看到的还是切走前那几行")
        XCTAssertEqual(rig.selection, selection, "选区留在同一处内容上")
        XCTAssertTrue(rig.view.performBindingAction("scroll_to_bottom"))
        let latest = await rig.waitUntil(3) { self.rig.surfaceText.contains("while away 40") }
        XCTAssertTrue(latest, "期间的输出补进去了")
    }

    /// 切走前在底部：切回来仍在底部（跟随输出），看得到期间的新内容。
    func testViewportAtTheBottomFollowsHiddenOutput() async {
        await rig.feed((1...100).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n")
        hide()
        rig.session.feedOutput(text: "fresh after hide\r\n")
        show()
        await assertSurfaceMatchesShadow(containing: "fresh after hide")
        let bottom = await rig.waitUntil(3) { self.scrollbar.map { $0.offset + $0.len >= $0.total } ?? false }
        XCTAssertTrue(bottom, "仍在底部：\(String(describing: scrollbar))")
    }

    /// surface 被放掉了（只能整屏回放，视口被复位带到底部）：回来后按切走前记下的内容找回原处；选区没法恢复
    /// （C 接口不能设选区），不留错位的高亮。
    func testScrolledViewportIsRestoredAfterTheSurfaceWasReleased() async {
        rig.bridge.hiddenReleaseDelay = .milliseconds(100)
        await scrollUp(to: 120)
        let before = rig.surfaceText
        rig.drag(fromCol: 0, row: 1, toCol: 6)
        _ = await rig.waitUntil(2) { self.rig.selection != nil }

        hide()
        let released = await rig.waitUntil(5) { self.rig.bridge.isSurfaceReleased }
        XCTAssertTrue(released)
        rig.session.feedOutput(text: (1...40).map { "while released \($0)" }.joined(separator: "\r\n") + "\r\n")
        let replays = rig.bridge.seedCount
        show()
        let rebuilt = await rig.waitUntil(5) { !self.rig.bridge.isSurfaceReleased && self.rig.bridge.seedCount > replays }
        XCTAssertTrue(rebuilt, "重建后整屏回放")
        rig.keepRendering()
        let restored = await rig.waitUntil(5) { self.scrollbar?.offset == 120 }
        XCTAssertTrue(restored, "视口找回原处：\(String(describing: scrollbar))，keeper 算出 \(String(describing: rig.bridge.keeper.lastRestoredRow))")
        XCTAssertEqual(rig.surfaceText, before, "看到的还是切走前那几行")
        XCTAssertNil(rig.selection, "选区恢复不了：不留错位的高亮")
    }

    /// surface 被放掉、切走前在底部：回来仍在底部，看得到期间的新内容。
    func testViewportAtTheBottomStaysAtTheBottomAfterRelease() async {
        rig.bridge.hiddenReleaseDelay = .milliseconds(100)
        await rig.feed((1...100).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n")
        hide()
        let released = await rig.waitUntil(5) { self.rig.bridge.isSurfaceReleased }
        XCTAssertTrue(released)
        rig.session.feedOutput(text: "fresh after release\r\n")
        show()
        await assertSurfaceMatchesShadow(containing: "fresh after release")
        try? await Task.sleep(for: .milliseconds(200))
        let bar = scrollbar
        XCTAssertTrue(bar.map { $0.offset + $0.len >= $0.total } ?? false, "仍在底部：\(String(describing: bar))")
        XCTAssertNil(rig.bridge.keeper.lastRestoredRow, "在底部时不记位置、不滚")
    }

    /// 期间没来输出：surface 一直在原处，不追也不动视口。
    func testScrolledViewportWithoutHiddenOutputIsUntouched() async {
        await scrollUp(to: 80)
        let before = rig.surfaceText
        let stats = rig.session.outputPump.currentStats
        hide()
        show()
        rig.keepRendering()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(scrollbar?.offset, 80)
        XCTAssertEqual(rig.surfaceText, before)
        XCTAssertEqual(rig.session.outputPump.currentStats.replays, stats.replays)
        XCTAssertEqual(rig.session.outputPump.currentStats.tailCatchUps, stats.tailCatchUps)
        XCTAssertFalse(rig.bridge.keeper.hasMark, "记下的位置用不上，回来时丢掉")
    }

    private func assertCaughtUp(file: StaticString = #filePath, line: UInt = #line) async {
        rig.keepRendering()
        let live = await rig.waitUntil(5) { self.rig.bridge.isLive && !self.rig.session.outputPump.surfaceNeedsCatchUp }
        XCTAssertTrue(live, "回到屏上后 surface 应当追上并重新吃字节", file: file, line: line)
        rig.session.surfaceIO.waitForPendingOutput()
        try? await Task.sleep(for: .milliseconds(100))
    }
}
