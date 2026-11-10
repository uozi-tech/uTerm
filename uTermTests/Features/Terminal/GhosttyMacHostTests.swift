import AppKit
import GhosttyTerminal
import XCTest
@testable import uTerm

/// Mac 上 Ghostty 渲染的窗格宿主（`GhosttyContainerView`）：手机接管时的尺寸、滚动条。
///
/// 钉尺寸的另一半（没有画面的会话、镜像订阅者看到的尺寸）在 `TerminalMirrorTapTests`，视图自己加的行为
/// （⌃↩、贴图、右键菜单）在 `CopyableTerminalViewTests`；这里核的是窗格宿主这一层。
@MainActor
final class GhosttyMacHostTests: XCTestCase {

    @MainActor
    private final class Rig {
        let session: TerminalSession
        let backend: MockBackend
        let bridge: GhosttyTerminalBridge
        let container: GhosttyContainerView
        let window: NSWindow

        init(session: TerminalSession, backend: MockBackend, bridge: GhosttyTerminalBridge,
             container: GhosttyContainerView, window: NSWindow) {
            self.session = session; self.backend = backend; self.bridge = bridge
            self.container = container; self.window = window
        }

        var view: GhosttySurfaceView { bridge.view }
        var grid: String { bridge.grid.map { "\($0.cols)×\($0.rows)" } ?? "-" }

        func layout() { container.needsLayout = true; container.layoutSubtreeIfNeeded() }

        func close() {
            session.dispose()
            window.orderOut(nil)
        }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// 800×500 的 Ghostty 窗格，连着一个假后端；等网格停稳（第一次报上来的常常是中间态）。
    private func makeRig() async throws -> Rig {
        let rect = NSRect(x: 0, y: 0, width: 800, height: 500)
        let session = TerminalSession()
        let backend = MockBackend()
        let bridge = session.ghostty
        let container = GhosttyContainerView(surface: bridge.view)
        container.isActive = true
        let window = ProbeWindow.make(contentRect: rect, contentView: container, placement: .transparentOnScreen, keepsDrawing: true)
        container.frame = window.contentView?.bounds ?? rect
        container.layoutSubtreeIfNeeded()
        let live = await waitUntil(10) { bridge.isLive && bridge.grid != nil }
        XCTAssertTrue(live, "Ghostty surface 没就绪")
        var last = bridge.grid.map { "\($0)" } ?? ""
        var stableSince = Date()
        while Date().timeIntervalSince(stableSince) < 0.4 {
            await sleep(0.02)
            let now = bridge.grid.map { "\($0)" } ?? ""
            if now != last { last = now; stableSince = Date() }
        }
        await session.connect(using: backend)
        return Rig(session: session, backend: backend, bridge: bridge, container: container, window: window)
    }

    private func emit(_ text: String, to backend: MockBackend) async {
        await backend.emitOutput(Data(text.utf8))
    }

    // MARK: 远控接管尺寸

    /// 手机接管：Ghostty 的网格、影子终端、发给 PTY 的尺寸都要正好是手机的行列数；断开后回到按窗格排。
    func testPinnedGridMatchesThePhoneExactly() async throws {
        let rig = try await makeRig()
        defer { rig.close() }
        let original = try XCTUnwrap(rig.bridge.grid)
        let shadow = rig.session.shadow

        for (cols, rows) in [(57, 23), (89, 32), (62, 30), (40, 20), (61, 29)] {
            rig.session.pinRemoteGrid(cols: cols, rows: rows, controller: "测试 iPhone")
            rig.layout()
            let pinned = await waitUntil(3) { rig.bridge.grid?.cols == cols && rig.bridge.grid?.rows == rows }
            XCTAssertTrue(pinned, "钉 \(cols)×\(rows)，Ghostty 的网格是 \(rig.grid)")
            XCTAssertEqual(shadow.size.cols, cols, "影子终端的列数")
            XCTAssertEqual(shadow.size.rows, rows, "影子终端的行数")
            let told = await waitUntil(2) {
                let last = await rig.backend.resizes.last
                return last?.cols == UInt16(cols) && last?.rows == UInt16(rows)
            }
            let resizes = await rig.backend.resizes.suffix(3).map { "\($0.cols)×\($0.rows)" }
            XCTAssertTrue(told, "PTY 应当收到 \(cols)×\(rows)：最近几次是 \(resizes)")
        }
        XCTAssertEqual(rig.session.remoteController, "测试 iPhone")

        rig.session.unpinRemoteGrid()
        XCTAssertNil(rig.session.remoteController)
        let restored = await waitUntil(3) { rig.bridge.grid?.cols == original.cols && rig.bridge.grid?.rows == original.rows }
        XCTAssertTrue(restored, "断开后应当回到 \(original.cols)×\(original.rows)，现在是 \(rig.grid)")
    }

    /// 手机的行数比窗格多：光标在屏幕顶上时贴顶（内容不被裁掉），输出把光标推到屏幕底之后贴底，清屏后跟回顶上。
    func testPinnedGridTallerThanThePaneFollowsTheCursor() async throws {
        let rig = try await makeRig()
        defer { rig.close() }
        await emit("\u{1B}[2J\u{1B}[Hwelcome\r\n> ", to: rig.backend)
        rig.session.pinRemoteGrid(cols: 57, rows: 60, controller: "测试 iPhone")
        rig.layout()
        let pinned = await waitUntil(3) { rig.bridge.grid?.rows == 60 }
        XCTAssertTrue(pinned, "钉 57×60，Ghostty 的网格是 \(rig.grid)")
        rig.layout()
        XCTAssertGreaterThan(rig.view.frame.height, rig.container.bounds.height, "用例前提：钉住的终端比窗格高")
        XCTAssertEqual(rig.view.frame.maxY, rig.container.bounds.height, accuracy: 0.5, "光标在屏幕顶上：顶边贴着窗格顶")

        await emit((1...80).map { "line \($0)\r\n" }.joined(), to: rig.backend)
        let atBottom = await waitUntil(3) { rig.session.shadow.cursor.y == 59 }
        XCTAssertTrue(atBottom, "80 行输出后光标应当在最后一行")
        await sleep(0.1)
        rig.container.layoutSubtreeIfNeeded()
        XCTAssertEqual(rig.view.frame.minY, 6, accuracy: 0.5, "光标到了屏幕底：底边贴着窗格底")

        await emit("\u{1B}[2J\u{1B}[H> ", to: rig.backend)
        let atTop = await waitUntil(3) { rig.session.shadow.cursor.y == 0 }
        XCTAssertTrue(atTop)
        await sleep(0.1)
        rig.container.layoutSubtreeIfNeeded()
        XCTAssertEqual(rig.view.frame.maxY, rig.container.bounds.height, accuracy: 0.5, "清屏后光标回到顶上：窗格跟回顶上")
    }

    // MARK: 滚动条

    private func scrollEvent(points: Int, phase: Int64) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                       wheel1: Int32(points), wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// 没滚动时不显示；滚了就浮现，位置跟着视口走（在活动区时贴轨道底，滚到回滚顶部时贴轨道顶），停手 1 s 后淡出。
    func testScrollIndicatorShowsWhileScrollingAndTracksTheViewport() async throws {
        let rig = try await makeRig()
        defer { rig.close() }
        let indicator = rig.container.scrollIndicator
        XCTAssertFalse(indicator.isShown, "没有回滚、没滚动：不显示")

        await emit((1...300).map { "line \($0)\r\n" }.joined(), to: rig.backend)
        let hasHistory = await waitUntil(5) { (rig.view.uTermScrollbarOffset ?? 0) > 0 }
        XCTAssertTrue(hasHistory, "喂了 300 行应当有回滚（\(ProbeWindow.visibility(rig.window))）")
        await sleep(0.2)
        XCTAssertFalse(indicator.isShown, "有回滚但没滚动：不显示")

        // 滚一下：浮现，在活动区时滑块贴着轨道底。
        rig.view.scrollWheel(with: try scrollEvent(points: 0, phase: 1))
        rig.view.scrollWheel(with: try scrollEvent(points: 1, phase: 2))
        XCTAssertTrue(indicator.isShown, "滚动时应当浮现")
        let track = rig.view.frame.intersection(rig.container.bounds)
        XCTAssertEqual(indicator.frame.maxX, rig.container.bounds.maxX - 3, accuracy: 0.5, "滑块贴着窗格右边缘")
        XCTAssertGreaterThanOrEqual(indicator.frame.height, 24)
        XCTAssertLessThan(indicator.frame.height, track.height / 2, "300 行里的一屏：滑块远小于轨道")
        XCTAssertEqual(indicator.frame.minY, track.minY, accuracy: 2, "在活动区（最底下）：滑块贴轨道底")

        // 一路滚到回滚顶部：滑块到轨道顶。
        for _ in 0 ..< 60 {
            rig.view.scrollWheel(with: try scrollEvent(points: 200, phase: 2))
            await sleep(0.005)
        }
        rig.view.scrollWheel(with: try scrollEvent(points: 0, phase: 4))
        let atTop = await waitUntil(3) { rig.view.uTermScrollbarOffset == 0 }
        XCTAssertTrue(atTop, "应当滚到了回滚顶部")
        rig.container.layoutSubtreeIfNeeded()
        XCTAssertEqual(indicator.frame.maxY, track.maxY, accuracy: 2, "在回滚顶部：滑块贴轨道顶")
        XCTAssertTrue(indicator.isShown)

        // 停手 1 s 后淡出。
        await sleep(1.4)
        XCTAssertFalse(indicator.isShown, "停手 1 s 后应当淡出")
    }
}
