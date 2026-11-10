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

    /// 隐藏期间来的输出只进影子；露出来回放一次，画面与影子一致。
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

        show()
        await assertSurfaceMatchesShadow(containing: "hidden 50")
        XCTAssertEqual(rig.bridge.seedCount, replays + 1, "露出来回放一次")
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
}
