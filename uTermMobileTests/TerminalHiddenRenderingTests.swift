import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 看不见的终端不画；回到可见时补出最新内容。字节照常进影子终端，SSH 不受影响。
/// - App 退到后台：画面不再吃字节（GhosttyKit 后台不 tick，接着喂会卡死），回前台从影子回放；
/// - 不在屏上的标签（后台标签、Agent 模式）：不交帧；隔一阵放掉 surface，露出来时重建并从影子回放；
/// - 从没露出过的标签不建 surface；
/// - 关掉的标签连同它的视图、影子一起释放。
///
/// 换引擎之前这份用例数的是旧引擎的 `draw(_:)` 次数、核的是补丁 #18 / #19；现在数 GhosttyKit 交了几帧
///（`GhosttyPresentLog`）、读 surface 与影子里的文字。原来「闪烁光标的重复动画在隐藏时停掉」那条没有对应物
///（光标由引擎画，不是 Core Animation 的重复动画），并进了「隐藏时不交帧」。
@MainActor
final class TerminalHiddenRenderingTests: XCTestCase {
    private var window: UIWindow?
    private static let controller = GhosttyTerminalBridge.makeController(
        fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11))

    override func tearDown() async throws {
        window?.subviews.forEach { $0.removeFromSuperview() }
        window?.isHidden = true
        window = nil
    }

    private func makeWindow() throws -> UIWindow {
        let window = try makeSpikeWindow(size: CGSize(width: 400, height: 600))
        self.window = window
        return window
    }

    /// 挂在真窗口里、surface 已就绪并接上字节的一条终端。
    private func hostedTerminal(isOnScreen: Bool = true) async throws -> (GhosttyTerminalBridge, MTerminalContainerView) {
        let window = try makeWindow()
        let bridge = GhosttyTerminalBridge(controller: Self.controller)
        let container = MTerminalContainerView(terminal: bridge, fontSize: 11, isOnScreen: isOnScreen)
        container.frame = window.bounds
        window.addSubview(container)
        container.layoutIfNeeded()
        if isOnScreen { try await waitUntilFed(bridge) }
        return (bridge, container)
    }

    private func waitUntilFed(_ bridge: GhosttyTerminalBridge, file: StaticString = #filePath, line: UInt = #line) async throws {
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface
        }
        XCTAssertTrue(ready, "surface 没就绪：ready=\(bridge.isSurfaceReady) feeding=\(bridge.outputPump.isFeedingSurface)",
                      file: file, line: line)
        GhosttyPresentLog.installIfPossible()
    }

    private func surfaceText(_ bridge: GhosttyTerminalBridge) -> String {
        bridge.session.waitForPendingOutput()
        return bridge.session.readViewportText() ?? ""
    }

    /// 喂若干拍，每拍之间留够出帧时间，返回期间交了几帧。
    private func presentsWhileFeeding(_ bridge: GhosttyTerminalBridge, ticks: Int, tag: String) async throws -> Int {
        GhosttyPresentLog.reset()
        for tick in 0..<ticks {
            bridge.feed(Data("\(tag) \(tick)\r\n".utf8))
            try await Task.sleep(for: .milliseconds(40))
        }
        return GhosttyPresentLog.read().times.count
    }

    // MARK: App 在后台

    func testAppInBackgroundStopsFeedingTheSurfaceAndCatchesUpOnReturn() async throws {
        let (bridge, _) = try await hostedTerminal()
        let visible = try await presentsWhileFeeding(bridge, ticks: 5, tag: "front")
        XCTAssertGreaterThan(visible, 0, "自证：前台有输出时在交帧")
        XCTAssertTrue(surfaceText(bridge).contains("front 4"))

        bridge.setAppInBackground(true)
        XCTAssertFalse(bridge.outputPump.isFeedingSurface)
        _ = try await presentsWhileFeeding(bridge, ticks: 5, tag: "back")
        XCTAssertTrue(bridge.shadow.viewportText().contains("back 4"), "后台的输出照常进影子")
        XCTAssertFalse(surfaceText(bridge).contains("back"), "后台时画面不吃字节")

        bridge.setAppInBackground(false)
        bridge.outputPump.waitForCatchUp()
        XCTAssertTrue(bridge.outputPump.isFeedingSurface)
        XCTAssertTrue(surfaceText(bridge).contains("back 4"), "回前台把后台期间的输出补出来")
    }

    /// 后台标签回到前台 App 时仍是后台标签：两种「看不见」各管各的，谁都不会误把对方放开。
    func testOffScreenAndAppBackgroundCombine() async throws {
        let (bridge, container) = try await hostedTerminal()
        container.isOnScreen = false
        bridge.setAppInBackground(true)

        bridge.setAppInBackground(false)
        bridge.outputPump.waitForCatchUp()
        XCTAssertFalse(bridge.isOnScreen, "App 回前台不该把后台标签放出来")
        // 回放那一下、隐藏那一刻已经在路上的帧让它交完。
        try await Task.sleep(for: .milliseconds(200))
        let hidden = try await presentsWhileFeeding(bridge, ticks: 5, tag: "hidden")
        XCTAssertEqual(hidden, 0, "后台标签不交帧")

        bridge.setAppInBackground(true)
        container.isOnScreen = true
        XCTAssertFalse(bridge.outputPump.isFeedingSurface, "标签露出来了，但 App 还在后台：画面仍不吃字节")
        bridge.setAppInBackground(false)
        bridge.outputPump.waitForCatchUp()
        XCTAssertTrue(surfaceText(bridge).contains("hidden 4"))
    }

    /// 视图晚于进后台才挂上（外壳切换时重建）：挂上、surface 建好之后也不往里喂，等回前台。
    func testViewAttachedWhileInBackgroundStaysUnfed() async throws {
        let controller = MobileTerminalController(terminal: GhosttyTerminalBridge(controller: Self.controller))
        controller.appVisibilityChanged(inBackground: true)
        let bridge = controller.terminal
        XCTAssertTrue(bridge.isAppInBackground, "控制器把后台状态转给终端")

        let window = try makeWindow()
        let container = MTerminalContainerView(terminal: bridge, fontSize: 11)
        container.frame = window.bounds
        window.addSubview(container)
        container.layoutIfNeeded()
        let built = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { bridge.isSurfaceReady }
        XCTAssertTrue(built)
        bridge.feed(Data("while away\r\n".utf8))
        XCTAssertFalse(bridge.outputPump.isFeedingSurface)

        controller.appVisibilityChanged(inBackground: false)
        bridge.outputPump.waitForCatchUp()
        XCTAssertTrue(surfaceText(bridge).contains("while away"))
    }

    // MARK: 不在屏上

    func testHiddenTerminalPresentsNoFramesAndShowsWhatItMissed() async throws {
        let (bridge, container) = try await hostedTerminal()
        // 闪烁光标：可见时哪怕没有输出引擎也在周期性交帧，隐藏后这些也得停。
        bridge.feed(Data("\u{1B}[1 q$ ".utf8))
        container.isOnScreen = false
        // 隐藏那一刻已经在路上的一帧让它交完。
        try await Task.sleep(for: .milliseconds(150))

        let hidden = try await presentsWhileFeeding(bridge, ticks: 25, tag: "missed")
        XCTAssertEqual(hidden, 0, "不在屏上的终端不交帧")

        GhosttyPresentLog.reset()
        container.isOnScreen = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(GhosttyPresentLog.read().times.count, 0, "露出来要画")
        XCTAssertTrue(surfaceText(bridge).contains("missed 24"), "隐藏期间的输出在露出来时都在")
    }

    /// 隐藏久了放掉 surface（M2：每个 surface 约 14.5 MB 帧缓冲，停画不还）；露出来重建，内容从影子回放回来。
    func testLongHiddenTerminalReleasesItsSurfaceAndRestoresFromTheShadow() async throws {
        let (bridge, container) = try await hostedTerminal()
        bridge.hiddenReleaseDelay = .milliseconds(150)
        bridge.feed(Data("before hiding\r\n".utf8))
        container.isOnScreen = false
        XCTAssertNotNil(bridge.view.surface, "刚隐藏时 surface 还在（马上切回来不用重建）")

        let released = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) { bridge.view.uTermIsSurfaceReleased }
        XCTAssertTrue(released)
        XCTAssertNil(bridge.view.surface)
        XCTAssertFalse(bridge.outputPump.isFeedingSurface)
        bridge.feed(Data("while released\r\n\u{1B}]2;new title\u{07}".utf8))
        XCTAssertTrue(bridge.shadow.viewportText().contains("while released"))
        // 布局变化不会把它建回来。
        container.setNeedsLayout()
        container.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(bridge.view.surface)

        container.isOnScreen = true
        try await waitUntilFed(bridge)
        bridge.outputPump.waitForCatchUp()
        let text = surfaceText(bridge)
        XCTAssertTrue(text.contains("before hiding") && text.contains("while released"), "重建后的画面：\(text.prefix(200))")
        XCTAssertEqual(GhosttyViewportDiff.firstDifference(surface: text, shadow: bridge.shadow.viewportText()), nil)
    }

    /// 放掉再重建时，新 surface 的终端先按出生时的默认网格报一次尺寸。那一次不能传给影子和远端：影子缩一下再放回来，
    /// 备用屏（全屏程序）的内容就被裁掉了，而网格最终没变、程序收不到 SIGWINCH、不会重画。
    func testRestoredSurfaceKeepsTheAlternateScreenAndDoesNotResizeTheRemote() async throws {
        let (bridge, container) = try await hostedTerminal()
        bridge.hiddenReleaseDelay = .milliseconds(100)
        let grid = try XCTUnwrap(bridge.grid)
        // 全屏程序：进备用屏，在最后一行和最右一列各写一个记号。
        bridge.feed(Data("\u{1B}[?1049h\u{1B}[2J\u{1B}[1;1Htop-left\u{1B}[\(grid.rows);1Hbottom-row\u{1B}[3;\(grid.cols - 4)Hright".utf8))
        let before = bridge.shadow.viewportText()
        let reports = bridge.resizeReports
        let sent = bridge.input.latestSize

        container.isOnScreen = false
        let released = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) { bridge.view.uTermIsSurfaceReleased }
        XCTAssertTrue(released)
        container.isOnScreen = true
        try await waitUntilFed(bridge)
        bridge.outputPump.waitForCatchUp()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(bridge.shadow.viewportText(), before, "影子里的备用屏内容被动过")
        XCTAssertTrue(bridge.shadow.isOnAlternateScreen)
        let text = surfaceText(bridge)
        XCTAssertTrue(text.contains("top-left") && text.contains("bottom-row") && text.contains("right"),
                      "重建后的画面丢了内容：\(text)")
        XCTAssertEqual(GhosttyViewportDiff.firstDifference(surface: text, shadow: before), nil)
        XCTAssertEqual(bridge.input.latestSize?.cols, sent?.cols)
        XCTAssertEqual(bridge.input.latestSize?.rows, sent?.rows)
        XCTAssertLessThanOrEqual(bridge.resizeReports - reports, 1, "重建 surface 多报了尺寸：\(bridge.resizeReports - reports) 次")
        XCTAssertEqual(bridge.grid?.cols, grid.cols)
        XCTAssertEqual(bridge.grid?.rows, grid.rows)
    }

    /// 很快切回来：不放 surface，不重建。
    func testQuickReturnKeepsTheSurface() async throws {
        let (bridge, container) = try await hostedTerminal()
        bridge.hiddenReleaseDelay = .milliseconds(300)
        container.isOnScreen = false
        try await Task.sleep(for: .milliseconds(100))
        container.isOnScreen = true
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertFalse(bridge.view.uTermIsSurfaceReleased)
        XCTAssertNotNil(bridge.view.surface)
        XCTAssertTrue(bridge.outputPump.isFeedingSurface)
    }

    /// 从没露出过的标签不建 surface（M7：恢复时只要影子，第一次露出再建）；期间的输出只进影子，露出来时回放。
    func testNeverShownTerminalBuildsNoSurfaceUntilShown() async throws {
        let (bridge, container) = try await hostedTerminal(isOnScreen: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(bridge.view.surface)
        // 没有 surface 也要给远端一个像样的尺寸（按字体度量估的），不能让 PTY 停在 80×24。
        let estimated = bridge.shadow.size
        XCTAssertEqual(bridge.input.latestSize?.cols, UInt16(estimated.cols))
        XCTAssertEqual(bridge.input.latestSize?.rows, UInt16(estimated.rows))
        XCTAssertTrue((50...70).contains(estimated.cols) && (36...48).contains(estimated.rows),
                      "400×600、11pt 估出来的网格不对：\(estimated)")
        bridge.feed(Data("early output\r\n".utf8))
        XCTAssertTrue(bridge.shadow.viewportText().contains("early output"))

        container.isOnScreen = true
        try await waitUntilFed(bridge)
        bridge.outputPump.waitForCatchUp()
        XCTAssertTrue(surfaceText(bridge).contains("early output"))
        let real = try XCTUnwrap(bridge.grid)
        print("HIDDEN estimated=\(estimated) real=\(real)")
        XCTAssertEqual(bridge.shadow.size.cols, real.cols)
        XCTAssertEqual(bridge.shadow.size.rows, real.rows)
        XCTAssertLessThanOrEqual(abs(estimated.cols - real.cols), 2, "估的列数和真实的差太多")
        XCTAssertLessThanOrEqual(abs(estimated.rows - real.rows), 2, "估的行数和真实的差太多")
    }

    // MARK: 外壳切换

    /// 外壳切换时新容器接走旧视图：以新容器为准，不沿用旧容器留下的「不在屏上」。
    func testNewContainerResetsOffScreenLeftByOldOne() async throws {
        let (bridge, container) = try await hostedTerminal()
        container.isOnScreen = false
        XCTAssertFalse(bridge.isOnScreen)

        _ = MTerminalContainerView(terminal: bridge, fontSize: 11)

        XCTAssertTrue(bridge.isOnScreen)
    }

    /// 反过来：新容器接走之后，旧容器才被告知「不在屏上」（外壳切换时旧片最后一次刷新）。
    /// 旧容器已经不摆放这个视图了，不能替新容器决定它画不画——否则画面停在那一刻、再也不刷新。
    func testStaleContainerCannotStopTheAdoptedViewFromDrawing() async throws {
        let (bridge, stale) = try await hostedTerminal()
        let live = MTerminalContainerView(terminal: bridge, fontSize: 11)
        XCTAssertTrue(bridge.view.superview === live)

        stale.isOnScreen = false

        XCTAssertTrue(bridge.isOnScreen, "旧容器改不了新容器里的视图")
        live.isOnScreen = false
        XCTAssertFalse(bridge.isOnScreen, "持有视图的容器照常能停画")
        stale.isOnScreen = true
        XCTAssertFalse(bridge.isOnScreen, "旧容器也放不开")
    }

    // MARK: 不泄漏

    /// 关掉的标签连同终端视图、影子（整份回滚）一起释放：display link、通知、回调都不能把它们留住。
    func testTerminalIsReleasedWhenNoLongerReferenced() async throws {
        weak var releasedView: MGhosttyTerminalView?
        weak var releasedBridge: GhosttyTerminalBridge?
        weak var releasedController: MobileTerminalController?
        do {
            let window = try makeWindow()
            let controller = MobileTerminalController(terminal: GhosttyTerminalBridge(controller: Self.controller))
            let container = MTerminalContainerView(terminal: controller.terminal, fontSize: 11)
            container.frame = window.bounds
            window.addSubview(container)
            container.layoutIfNeeded()
            try await waitUntilFed(controller.terminal)
            controller.terminal.feed(Data("hello\r\n".utf8))
            _ = surfaceText(controller.terminal)
            releasedView = controller.terminal.view
            releasedBridge = controller.terminal
            releasedController = controller
            controller.close()
            container.removeFromSuperview()
        }
        // 排在主队列上的回调（write / resize 跳回主线程的那一下）会短暂持有。
        let gone = await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) {
            releasedView == nil && releasedBridge == nil && releasedController == nil
        }
        XCTAssertTrue(gone, "view=\(releasedView == nil) bridge=\(releasedBridge == nil) controller=\(releasedController == nil)")
    }
}
