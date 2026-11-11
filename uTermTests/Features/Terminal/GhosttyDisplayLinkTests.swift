import AppKit
import IOSurface
import GhosttyTerminal
import XCTest
@testable import uTerm

/// 渲染器的 display link（按屏幕刷新出帧）。
///
/// 它在 surface 出生时建；当时没有活动显示器（Mac 锁着、显示器睡着，终端是手机远控新开的）就建不成，引擎自己不重试，
/// 要宿主把所在显示器再报一次（`ghostty_surface_set_display_id`）才补建。没有它，渲染线程有消息就画、异步上屏，
/// 和主线程同步画的帧不排队，滚动时旧帧可能晚于新帧上屏——画面上下来回跳（用户实测，只有那一个标签抖）。
@MainActor
final class GhosttyDisplayLinkTests: XCTestCase {
    private var sessions: [TerminalSession] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        sessions.forEach { $0.dispose() }
        sessions = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
        // 实验用例会关 vsync：还原 app 配置。
        GhosttyTerminalConfig.controller.setTerminalConfiguration(GhosttyTerminalConfig.base(settings: TerminalSettings.read()))
        try await super.tearDown()
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @MainActor
    private struct Tab {
        let session: TerminalSession
        let backend: MockBackend
        let window: NSWindow
        let container: GhosttyContainerView
        var view: GhosttySurfaceView { session.ghostty.view }
    }

    private func makeTab(lines: Int = 0) async throws -> Tab {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        sessions.append(session)
        let backend = MockBackend()
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 900)
        let window = ProbeWindow.make(contentRect: rect, contentView: NSView(frame: rect), placement: .transparentOnScreen,
                                      keepsDrawing: true)
        window.appearance = NSAppearance(named: .darkAqua)
        windows.append(window)
        let container = GhosttyContainerView(surface: session.ghostty.view)
        container.isActive = true
        container.frame = NSRect(x: 0, y: 0, width: 816, height: 517)
        window.contentView?.addSubview(container)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        let live = await waitUntil(10) { session.ghostty.isLive && session.ghostty.grid != nil }
        XCTAssertTrue(live, "Ghostty surface 没就绪")
        await session.connect(using: backend)
        if lines > 0 {
            let grid = try XCTUnwrap(session.ghostty.grid)
            var text = ""
            for n in 1 ... lines { text += GhosttyMacScrollTests.line(n, cols: grid.cols) + "\r\n" }
            await backend.emitOutput(Data(text.utf8))
            let fed = await waitUntil(10) { (session.ghostty.viewportText() ?? "").contains("\(lines)") }
            XCTAssertTrue(fed, "语料没喂完")
            try? await Task.sleep(for: .milliseconds(300))
        }
        return Tab(session: session, backend: backend, window: window, container: container)
    }

    private func displayID(of window: NSWindow) -> UInt32? {
        (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: 报显示器

    /// surface 建好之后要把所在显示器报给引擎；显示器可能刚回来的时刻（屏幕唤醒、解锁、窗口重新可见、换屏、
    /// 屏幕参数变化、窗口成为 key）每次都重报——display link 当初没建成的 surface 靠这次调用补建。
    func testDisplayIsReportedForNewSurfaceAndWheneverTheScreenMayHaveComeBack() async throws {
        let tab = try await makeTab()
        let id = try XCTUnwrap(displayID(of: tab.window), "探针窗口不在任何屏幕上")
        var reports = tab.view.uTermDisplayReports
        XCTAssertGreaterThanOrEqual(reports.count, 1, "surface 建好后没有把显示器报给引擎")
        XCTAssertEqual(reports.displayID, id)

        // 布局、尺寸变化不重复报（同一个 surface、同一块屏）。
        let before = reports.count
        tab.container.needsLayout = true
        tab.container.layoutSubtreeIfNeeded()
        tab.view.layout()
        XCTAssertEqual(tab.view.uTermDisplayReports.count, before, "同一个 surface、同一块屏，布局不该重复报")

        func expectReport(_ what: String, _ trigger: () -> Void) {
            let count = tab.view.uTermDisplayReports.count
            trigger()
            reports = tab.view.uTermDisplayReports
            XCTAssertEqual(reports.count, count + 1, "\(what)之后应当重报一次显示器")
            XCTAssertEqual(reports.displayID, id)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        expectReport("屏幕唤醒") { workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil) }
        expectReport("会话重新激活（解锁）") { workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil) }
        expectReport("窗口换屏") {
            NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: tab.window)
        }
        expectReport("屏幕参数变化") {
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        expectReport("窗口成为 key") {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: tab.window)
        }
        if tab.window.occlusionState.contains(.visible) {
            expectReport("窗口重新可见") {
                NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: tab.window)
            }
        }

        // 藏久了放掉 surface 再重建：新 surface 也要报。
        let count = tab.view.uTermDisplayReports.count
        tab.view.uTermReleaseSurface()
        XCTAssertFalse(tab.session.ghostty.isLive, "surface 应当已放掉")
        tab.view.uTermRestoreSurface()
        let rebuilt = await waitUntil(5) { tab.session.ghostty.isLive }
        XCTAssertTrue(rebuilt, "surface 没重建")
        XCTAssertGreaterThan(tab.view.uTermDisplayReports.count, count, "重建的 surface 没有把显示器报给引擎")

        // 视图离开窗口后不再理会屏幕通知。
        GhosttyHostView.dismantleNSView(tab.container, coordinator: ())
        let detached = tab.view.uTermDisplayReports.count
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(tab.view.uTermDisplayReports.count, detached, "不在窗口里的视图不该再报")
    }

    // MARK: 机制实验（默认跳过）

    /// 机制实验：没有 display link 的 surface（这里用 `window-vsync = false` 造，和「建 link 失败」走的是引擎里同一条
    /// 「不按屏幕刷新、渲染线程有消息就画」的路）滚动时，上屏的帧会不会倒退。读每一张上屏帧的第一条行色带，换算成
    /// 视口在内容里的位置（按 27 行一循环取模），单向滚动里出现反向的一步就是「旧帧晚于新帧上屏」。
    /// 对照：同一套动作在正常（有 display link）的 surface 上。
    ///
    /// 只在 `TEST_RUNNER_GHOSTTY_VSYNC_EXPERIMENT=1` 时跑：它断言的是「坏掉的样子」，留作复查机制用。
    func testFramesGoBackwardsWhileScrollingWithoutDisplayLink() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GHOSTTY_VSYNC_EXPERIMENT"] == "1", "机制实验，默认不跑")
        let normal = try await scrollAndCountBackwardFrames(vsync: true)
        let fallback = try await scrollAndCountBackwardFrames(vsync: false)
        print("VSYNC-EXPERIMENT 有 display link：\(normal)\nVSYNC-EXPERIMENT 没有 display link：\(fallback)")
        XCTAssertEqual(normal.backward, 0, "有 display link 时上屏帧不该倒退")
        XCTAssertGreaterThan(fallback.backward, 0, "没有 display link 时预期能看到倒退的帧（机制实验）")
    }

    private struct FrameStats: CustomStringConvertible {
        var frames = 0
        var backward = 0
        var largestBackward = 0
        var offMain = 0
        var sampled = 0
        var trace = ""
        var description: String { "上屏 \(frames) 帧（读到位置 \(sampled) 帧，非主线程设 \(offMain)），倒退 \(backward) 次，最大倒退 \(largestBackward) px\n  位置：\(trace)" }
    }

    private final class PositionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func append(_ value: Int) { lock.withLock { values.append(value) } }
        var all: [Int] { lock.withLock { values } }
    }

    private func scrollAndCountBackwardFrames(vsync: Bool) async throws -> FrameStats {
        let base = GhosttyTerminalConfig.base(settings: TerminalSettings.read())
        GhosttyTerminalConfig.controller.setTerminalConfiguration(
            vsync ? base : base.appending(.custom(key: "window-vsync", value: "false")))
        let tab = try await makeTab(lines: 400)
        let cell = Int(try XCTUnwrap(tab.view.uTermCellPixels).height)
        let cycle = 27 * cell
        let layer = try XCTUnwrap(GhosttyFrameWatch.contentLayer(of: tab.view), "找不到画面图层")
        let watch = GhosttyFrameWatch(layer: layer)
        let log = PositionLog()
        watch.arm { surface in
            // 第一条行色带：编号 k 的行，露出来的高度 h（被滚出去 cell − h）。位置 = k × 行高 + 滚出去的像素，按循环取模。
            if let band = GhosttyMacScrollTests.bands(surface).first(where: { $0.key >= 0 }) {
                log.append((band.key * cell + max(0, cell - band.height)) % cycle)
            }
            return false
        }
        // 触控板式连续往回滚 60 行：每个事件 7 pt，间隔约 4 ms（比一帧密，渲染线程和主线程都有活干）。
        let scale = tab.window.backingScaleFactor
        let steps = Int((CGFloat(60 * cell) / scale / 7).rounded())
        func send(_ points: Int, phase: Int64) throws {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                           wheel1: Int32(points), wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            tab.view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        }
        try send(0, phase: 1)
        for _ in 0 ..< steps {
            try send(7, phase: 2)
            try? await Task.sleep(for: .milliseconds(4))
        }
        try send(0, phase: 4)
        try? await Task.sleep(for: .milliseconds(600))
        watch.disarm()

        // 往回滚：行号变小，位置（取模后）应当只减不增；增了就是倒退。跨循环的那一步按最短距离算。
        var stats = FrameStats(frames: watch.count, offMain: watch.offMainCount)
        let positions = log.all
        stats.sampled = positions.count
        stats.trace = positions.prefix(120).map(String.init).joined(separator: " ")
        for (a, b) in zip(positions, positions.dropFirst()) {
            var delta = (b - a) % cycle
            if delta > cycle / 2 { delta -= cycle }
            if delta < -cycle / 2 { delta += cycle }
            if delta > 0 {
                stats.backward += 1
                stats.largestBackward = max(stats.largestBackward, delta)
            }
        }
        return stats
    }
}
