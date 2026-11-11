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
        var surfaceTextLines: [String] { (bridge.viewportText() ?? "").components(separatedBy: "\n") }
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
    private func makeRig(height: CGFloat = 500) async throws -> Rig {
        let rect = NSRect(x: 0, y: 0, width: 800, height: height)
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
            // 影子只跟 surface 的终端在 IO 线程上报的网格走（M4 的前提），比主线程上的网格晚一点到。
            _ = await waitUntil(3) { shadow.size.cols == cols && shadow.size.rows == rows }
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
        let pinned = await waitUntil(3) { rig.bridge.grid?.rows == 60 && rig.session.shadow.size.rows == 60 }
        XCTAssertTrue(pinned, "钉 57×60，Ghostty 的网格是 \(rig.grid)，影子 \(rig.session.shadow.size)")
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

    /// 钉住的终端第 `row` 行（0 起）整行落在窗格里吗（容器不翻转，y 往上）。
    private func rowIsVisible(_ row: Int, in rig: Rig, rows: Int) -> Bool {
        let rowHeight = rig.view.frame.height / CGFloat(rows)
        let top = rig.view.frame.maxY - CGFloat(row) * rowHeight
        let bottom = top - rowHeight
        return bottom >= -0.5 && top <= rig.container.bounds.height + 0.5
    }

    /// 手机接管后在 shell 里 `seq 1 300`：最后一行（300）和提示符所在的光标行都要落在窗格里，不能被裁到窗格底边外。
    /// 窗格高度除不尽一行时，接管前按行填满已经把行高拉过（`adjusted`）；各种余量都要对。
    func testPinnedGridTallerThanThePaneKeepsTheLastLinesVisibleAfterSeq() async throws {
        for (paneRows, rest) in [(0, 0), (8, -2), (12, -1), (9, 3)] {
            try await checkLastLinesVisibleAfterSeq(paneRows: paneRows, rest: rest)
        }
    }

    /// `paneRows` > 0：把窗格改成「paneRows 个自然行 + (自然行高 + rest) 像素」高，让按行填满拉高行距。
    private func checkLastLinesVisibleAfterSeq(paneRows: Int, rest: Int) async throws {
        let rig = try await makeRig()
        defer { rig.close() }
        if paneRows > 0 {
            let scale = rig.window.backingScaleFactor
            let cell = try XCTUnwrap(rig.view.uTermCellPixels).height - CGFloat(rig.view.uTermCellHeightAdjustment)
            let px = cell * CGFloat(paneRows) + (rest < 0 ? cell + CGFloat(rest) * scale : CGFloat(rest) * scale)
            let size = NSSize(width: 816, height: px / scale + GhosttyContainerView.insets.top + GhosttyContainerView.insets.bottom)
            rig.container.setFrameSize(size)
            rig.layout()
            await sleep(0.5)
        }
        let adjustment = rig.view.uTermCellHeightAdjustment
        let paneHeight = rig.container.bounds.height - 30
        let phoneRows = max(60, (rig.bridge.grid?.rows ?? 0) + 15)
        // 接管前窗格里已经有一屏多的历史（回滚区有内容）：Ghostty 放大行数时会把回滚的行拉回屏幕，光标跟着往下挪。
        await emit((1...120).map { "old \($0)\r\n" }.joined() + "$ ", to: rig.backend)
        rig.session.pinRemoteGrid(cols: 57, rows: phoneRows, controller: "测试 iPhone")
        rig.layout()
        let pinned = await waitUntil(3) { rig.bridge.grid?.rows == phoneRows && rig.session.shadow.size.rows == phoneRows }
        XCTAssertTrue(pinned, "钉 57×\(phoneRows)，Ghostty 的网格是 \(rig.grid)，影子 \(rig.session.shadow.size)")
        rig.layout()
        XCTAssertGreaterThan(rig.view.frame.height, rig.container.bounds.height, "用例前提：钉住的终端比窗格高")
        // 接管状态条随后才出现，占掉窗格顶上一截高度（`RemoteControlledTerminal`）。
        rig.container.setFrameSize(NSSize(width: rig.container.frame.width, height: rig.container.frame.height - 30))
        rig.layout()

        await emit("seq 1 300\r\n", to: rig.backend)
        // 真实输出是一片一片到的，光标一路往下走。
        for chunk in stride(from: 1, through: 300, by: 7) {
            await emit((chunk...min(300, chunk + 6)).map { "\($0)\r\n" }.joined(), to: rig.backend)
            await sleep(0.01)
        }
        await emit("$ ", to: rig.backend)
        let atBottom = await waitUntil(3) { rig.session.shadow.cursor.y == phoneRows - 1 }
        XCTAssertTrue(atBottom, "输出后光标应当在最后一行：\(rig.session.shadow.cursor.y)")
        await sleep(0.2)
        rig.container.layoutSubtreeIfNeeded()
        let tag = "窗格 \(paneHeight)pt、行高调整 \(adjustment)"
        // 光标行取画面（Ghostty）上提示符所在的行；影子终端的光标行要和它一致。
        let cursorRow = try XCTUnwrap(rig.surfaceTextLines.lastIndex { $0.hasPrefix("$ ") }, "画面上没有提示符")
        XCTAssertEqual(rig.session.shadow.cursor.y, cursorRow, "影子与画面的光标行不一致")
        XCTAssertTrue(rowIsVisible(cursorRow, in: rig, rows: phoneRows), "\(tag)：光标行 \(cursorRow) 被裁掉了：视图 \(rig.view.frame)，窗格 \(rig.container.bounds)")
        let lines = rig.surfaceTextLines
        let row300 = try XCTUnwrap(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "300" }, "屏幕上没有 300：\(lines.suffix(5))")
        XCTAssertTrue(rowIsVisible(row300, in: rig, rows: phoneRows), "\(tag)：第 300 行（屏幕第 \(row300) 行）被裁掉了：视图 \(rig.view.frame)，窗格 \(rig.container.bounds)")
    }

    /// 手机的软键盘升降会让接管的行数来回变（键盘起来 35 行、收起 60 行）：行数变大时 Ghostty 把回滚的行拉回屏幕，
    /// 光标行随之下移，但这期间没有新输出——光标行要在网格变了之后重新量，不能停在改尺寸前量到的那一行。
    func testPinnedGridFollowsTheCursorWhenThePhoneKeyboardTogglesWithoutOutput() async throws {
        let rig = try await makeRig()
        defer { rig.close() }
        await emit((1...120).map { "old \($0)\r\n" }.joined() + "$ seq 1 300\r\n", to: rig.backend)
        // 键盘起来：手机只有 30 行，比窗格矮。
        rig.session.pinRemoteGrid(cols: 57, rows: 30, controller: "测试 iPhone")
        rig.layout()
        _ = await waitUntil(3) { rig.bridge.grid?.rows == 30 && rig.session.shadow.size.rows == 30 }
        await emit((1...300).map { "\($0)\r\n" }.joined() + "$ ", to: rig.backend)
        await sleep(0.2)
        // 键盘收起：行数变大，没有新输出。
        for phoneRows in [60, 45, 70] {
            rig.session.pinRemoteGrid(cols: 57, rows: phoneRows, controller: "测试 iPhone")
            rig.layout()
            let grown = await waitUntil(3) { rig.bridge.grid?.rows == phoneRows && rig.session.shadow.size.rows == phoneRows }
            XCTAssertTrue(grown, "钉 57×\(phoneRows)，Ghostty 的网格是 \(rig.grid)，影子 \(rig.session.shadow.size)")
            await sleep(0.3)
            rig.container.layoutSubtreeIfNeeded()
            let lines = rig.surfaceTextLines
            let cursorRow = try XCTUnwrap(lines.lastIndex { $0.hasPrefix("$ ") }, "画面上没有提示符")
            let row300 = try XCTUnwrap(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "300" })
            let tag = "手机 \(phoneRows) 行：视图 \(rig.view.frame)，窗格 \(rig.container.bounds)，影子光标 \(rig.session.shadow.cursor.y)，画面光标 \(cursorRow)"
            XCTAssertTrue(rowIsVisible(cursorRow, in: rig, rows: phoneRows), "光标行被裁掉：\(tag)")
            XCTAssertTrue(rowIsVisible(row300, in: rig, rows: phoneRows), "第 300 行被裁掉：\(tag)")
        }
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
