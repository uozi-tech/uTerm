import AppKit
import IOSurface
import GhosttyTerminal
import XCTest
@testable import uTerm

/// 被手机接管过（钉尺寸 → 尺寸来回变 → 期间藏起 / 切回 → 解除）的标签，之后在 Mac 上用触控板滚动不能抖；
/// 拿一个从没被钉过的标签对照。
///
/// 「抖」= 单向连续滚动里任何一项来回反复：视图 frame、行高调整、按行填满的下移量、引擎报的视口首行、
/// 平滑滚动镜像的位置（首行 × 行高 + 小数）、画面上第一条行色带对应的内容位置。
@MainActor
final class GhosttyPinnedScrollJitterTests: XCTestCase {
    private var sessions: [TerminalSession] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        sessions.forEach { $0.dispose() }
        sessions = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
        try await super.tearDown()
    }

    // MARK: 夹具

    nonisolated static func key(ofLine number: Int) -> Int { GhosttyMacScrollTests.key(ofLine: number) }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
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
    private final class Tab {
        let session: TerminalSession
        let backend: MockBackend
        let window: NSWindow
        var container: GhosttyContainerView
        let size: NSSize

        init(session: TerminalSession, backend: MockBackend, window: NSWindow, container: GhosttyContainerView, size: NSSize) {
            self.session = session; self.backend = backend; self.window = window; self.container = container; self.size = size
        }

        var view: GhosttySurfaceView { session.ghostty.view }
        var cell: Int { Int(view.uTermCellPixels?.height ?? 0) }

        func layout() { container.needsLayout = true; container.layoutSubtreeIfNeeded() }

        /// 标签切走：SwiftUI 拆掉容器（视图离开窗口）。
        func hide() {
            GhosttyHostView.dismantleNSView(container, coordinator: ())
        }

        /// 切回：SwiftUI 新建一个容器把视图挂回来。
        func show() {
            let fresh = GhosttyContainerView(surface: view)
            fresh.isActive = true
            fresh.frame = NSRect(origin: .zero, size: size)
            window.contentView?.addSubview(fresh)
            container = fresh
            layout()
        }

        /// 画面上（IOSurface）此刻显示的：尺寸、第一条行色带的顶边与颜色编号。
        func shown() -> String {
            guard let surface = GhosttyFrameWatch.currentSurface(of: view) else { return "无画面" }
            let band = GhosttyMacScrollTests.bands(surface).first { $0.key >= 0 }
            return "\(IOSurfaceGetWidth(surface))×\(IOSurfaceGetHeight(surface)) \(band.map { "#\($0.key)@\($0.top)" } ?? "-")"
        }

        /// 记一帧的全部状态。
        func sample() -> Sample {
            let state = view.uTermScrollState
            let bar = view.uTermScrollbar
            return Sample(frame: view.frame, adjustment: view.uTermCellHeightAdjustment,
                          rowFillOffset: session.link.rowFillOffset, scrollbarOffset: bar.map { Int($0.offset) },
                          scrollbarTotal: bar.map { Int($0.total) }, row: state.row, fraction: state.fractionPixels,
                          cell: cell, grid: session.surfaceIO.surfaceGrid.map { "\($0.columns)×\($0.rows)" } ?? "-",
                          masks: container.layer?.masksToBounds ?? false,
                          firstLine: (session.ghostty.viewportText() ?? "").components(separatedBy: "\n").first
                            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
                          shown: shown())
        }
    }

    struct Sample: CustomStringConvertible {
        var frame: NSRect
        var adjustment: Int
        var rowFillOffset: CGFloat
        var scrollbarOffset: Int?
        var scrollbarTotal: Int?
        var row: Int
        var fraction: Int
        var cell: Int
        var grid: String
        var masks: Bool
        var firstLine: Int?
        var shown: String
        /// 视口顶边在整个缓冲区里的像素位置（镜像）。
        var position: Int { row * cell + fraction }
        var description: String {
            "frame=(\(frame.minX),\(frame.minY) \(frame.width)×\(frame.height)) adj=\(adjustment) fill=\(rowFillOffset) bar=\(scrollbarOffset.map(String.init) ?? "-")/\(scrollbarTotal.map(String.init) ?? "-") pos=\(row)+\(fraction) cell=\(cell) grid=\(grid) mask=\(masks) first=\(firstLine.map(String.init) ?? "-")(#\(firstLine.map(GhosttyPinnedScrollJitterTests.key(ofLine:)) ?? -1)) shown=\(shown)"
        }
    }

    /// `pinOnBirth`：像手机远控时新开的本机终端——会话连上、窗格刚挂上（还在等尺寸停稳、surface 还没建）时手机就接入钉了尺寸。
    private func makeTab(paneHeight: CGFloat = 517, pinOnBirth: (cols: Int, rows: Int)? = nil) async throws -> Tab {
        let size = NSSize(width: 816, height: paneHeight)
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
        container.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(container)
        let tab = Tab(session: session, backend: backend, window: window, container: container, size: size)
        if let pinOnBirth {
            await session.connect(using: backend)
            tab.layout()
            session.pinRemoteGrid(cols: pinOnBirth.cols, rows: pinOnBirth.rows, controller: "测试 iPhone")
        } else {
            tab.layout()
        }
        let live = await waitUntil(10) { session.ghostty.isLive && session.ghostty.grid != nil }
        XCTAssertTrue(live, "Ghostty surface 没就绪")
        await settle(tab)
        if pinOnBirth == nil { await session.connect(using: backend) }
        let grid = try XCTUnwrap(session.ghostty.grid)
        var text = ""
        for n in 1 ... 400 { text += GhosttyMacScrollTests.line(n, cols: grid.cols) + "\r\n" }
        // 像 Claude Code 经典界面：最后一段是输入框和状态行。
        text += "> \r\n  status"
        await backend.emitOutput(Data(text.utf8))
        let fed = await waitUntil(10) { (session.ghostty.viewportText() ?? "").contains("400") }
        XCTAssertTrue(fed, "语料没喂完")
        await settle(tab)
        return tab
    }

    /// 尺寸、格子、视图位置连续 0.3 s 不变。
    private func settle(_ tab: Tab) async {
        func snap() -> String { "\(tab.sample())" }
        var last = snap()
        var since = Date()
        let deadline = Date().addingTimeInterval(5)
        while Date().timeIntervalSince(since) < 0.3, Date() < deadline {
            await sleep(0.02)
            let now = snap()
            if now != last { last = now; since = Date() }
        }
    }

    private func pin(_ tab: Tab, _ cols: Int, _ rows: Int) async {
        tab.session.pinRemoteGrid(cols: cols, rows: rows, controller: "测试 iPhone")
        if tab.view.window != nil { tab.layout() }
        _ = await waitUntil(3) { tab.session.shadow.size.cols == cols && tab.session.shadow.size.rows == rows }
        await settle(tab)
    }

    /// 接管期间经历的事：钉的尺寸比窗格高 / 矮来回变、期间切走 / 切回（含藏久了 surface 被放掉）、钉住时滚过回滚，最后解除。
    private func takeOverAndRelease(_ tab: Tab, unpinWhileHidden: Bool = false) async throws {
        tab.session.ghostty.hiddenReleaseDelay = .milliseconds(100)
        await pin(tab, 57, 60)          // 竖屏：比窗格高
        try await gesture(tab, rows: 6, record: false)
        await pin(tab, 57, 20)          // 转横屏：比窗格矮
        await pin(tab, 89, 32)
        tab.hide()
        await sleep(0.3)                // 藏久了，surface 被放掉
        await pin(tab, 57, 58)          // 藏着时手机转屏
        tab.show()
        await settle(tab)
        await pin(tab, 62, 30)
        tab.hide()
        await sleep(0.05)
        tab.show()
        await settle(tab)
        try await gesture(tab, rows: 4, record: false)
        await pin(tab, 57, 12)          // 比窗格矮
        if unpinWhileHidden {
            tab.hide()
            await sleep(0.3)
            tab.session.unpinRemoteGrid()
            await sleep(0.1)
            tab.show()
        } else {
            tab.session.unpinRemoteGrid()
        }
        await settle(tab)
        await sleep(0.3)
        await settle(tab)
    }

    // MARK: 滚动

    /// 一段往回滚的触控板手势（拖 + 惯性 + 停手），返回途中逐帧的状态。
    @discardableResult
    private func gesture(_ tab: Tab, rows: Int, record: Bool = true, direction: Int = 1) async throws -> [Sample] {
        var samples: [Sample] = []
        let scale = tab.window.backingScaleFactor
        let rowPoints = max(1, Int((CGFloat(tab.cell) / scale).rounded()))
        let total = rowPoints * rows
        func send(_ points: Int, phase: Int64 = 0, momentum: Int64 = 0) throws {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                           wheel1: Int32(points * direction), wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points * direction))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            tab.view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        }
        func tick() async {
            await sleep(0.008)
            if record { samples.append(tab.sample()) }
        }
        try send(0, phase: 1)
        let drag = total * 2 / 3, steps = 16
        for step in 0 ..< steps {
            try send(drag * (step + 1) / steps - drag * step / steps, phase: 2)
            await tick()
        }
        try send(0, phase: 4)
        let rest = total - drag, momentumSteps = 10
        try send(0, momentum: 1)
        for step in 0 ..< momentumSteps {
            try send(rest * (step + 1) / momentumSteps - rest * step / momentumSteps, momentum: 2)
            await tick()
        }
        try send(0, momentum: 3)
        for _ in 0 ..< 40 { await tick() }
        return samples
    }

    /// 鼠标滚轮（离散、每格一行）往回滚 `notches` 格（`direction` -1 = 往活动区），每格之间采几帧。
    private func wheel(_ tab: Tab, notches: Int, direction: Int = 1) async throws -> [Sample] {
        var samples: [Sample] = []
        for _ in 0 ..< notches {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                           wheel1: Int32(direction), wheel2: 0, wheel3: 0))
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            XCTAssertFalse(event.hasPreciseScrollingDeltas, "造出来的应当是离散滚轮事件")
            tab.view.scrollWheel(with: event)
            for _ in 0 ..< 4 {
                await sleep(0.008)
                samples.append(tab.sample())
            }
        }
        for _ in 0 ..< 30 {
            await sleep(0.008)
            samples.append(tab.sample())
        }
        return samples
    }

    /// 单向滚动里出现来回反复的项；没有就是空数组。
    private func reversals(_ samples: [Sample], direction: Int = 1) -> [String] {
        var problems: [String] = []
        guard let first = samples.first else { return ["没有采样"] }
        for (i, s) in samples.enumerated() {
            if s.frame != first.frame { problems.append("#\(i) frame 变了：\(first.frame) → \(s.frame)") }
            if s.adjustment != first.adjustment { problems.append("#\(i) 行高调整变了：\(first.adjustment) → \(s.adjustment)") }
            if s.rowFillOffset != first.rowFillOffset { problems.append("#\(i) 下移量变了：\(first.rowFillOffset) → \(s.rowFillOffset)") }
            if s.cell != first.cell { problems.append("#\(i) 行高变了：\(first.cell) → \(s.cell)") }
        }
        // 往回滚：镜像位置只减不增（往活动区方向反之）；引擎行号同理。
        for (a, b) in zip(samples, samples.dropFirst()) {
            if (b.position - a.position) * direction > 0 { problems.append("镜像位置往回跳：\(a.position) → \(b.position)") }
            if let x = a.scrollbarOffset, let y = b.scrollbarOffset, (y - x) * direction > 0 {
                problems.append("引擎行号往回跳：\(x) → \(y)")
            }
        }
        return problems
    }

    // MARK: 用例

    /// 被接管过的标签和从没接管过的标签：解除之后状态一致，连续滚动不抖。
    func testScrollAfterTakeoverDoesNotJitter() async throws {
        let control = try await makeTab()
        let taken = try await makeTab()
        try await takeOverAndRelease(taken)

        let a = control.sample(), b = taken.sample()
        XCTAssertNil(taken.view.pinnedFrameSize, "解除后不该还钉着")
        XCTAssertEqual(b.frame, a.frame, "解除后视图位置应当和没接管过的一样：\n对照 \(a)\n接管过 \(b)")
        XCTAssertEqual(b.adjustment, a.adjustment, "行高调整：\n对照 \(a)\n接管过 \(b)")
        XCTAssertEqual(b.rowFillOffset, a.rowFillOffset, "按行填满下移量：\n对照 \(a)\n接管过 \(b)")
        XCTAssertEqual(b.grid, a.grid, "网格：\n对照 \(a)\n接管过 \(b)")
        XCTAssertEqual(b.masks, a.masks, "裁剪：\n对照 \(a)\n接管过 \(b)")

        print("JITTER 解除后 对照 \(a)\nJITTER 解除后 接管过 \(b)")
        for (name, tab) in [("对照", control), ("接管过", taken)] {
            // 先回到活动区底部（接管期间往回滚过），再往下拨：什么都不该动。
            _ = try await wheel(tab, notches: 400, direction: -1)
            let overshoot = try await gesture(tab, rows: 3, direction: -1)
            print("JITTER \(name) 底部往下拨：\(overshoot.first.map(String.init(describing:)) ?? "-") … \(overshoot.last.map(String.init(describing:)) ?? "-")")
            let still = reversals(overshoot, direction: -1)
            XCTAssertTrue(still.isEmpty, "\(name)在底部往下拨抖了：\(still.prefix(8))\n\(overshoot.map(\.description).joined(separator: "\n"))")
            XCTAssertEqual(Set(overshoot.map(\.position)).count, 1, "\(name)在底部往下拨，位置不该动：\(overshoot.map(\.position))")
            let up = try await gesture(tab, rows: 9)
            let upProblems = reversals(up)
            XCTAssertTrue(upProblems.isEmpty, "\(name)往回滚抖了：\(upProblems.prefix(8))\n\(up.map(\.description).joined(separator: "\n"))")
            let down = try await gesture(tab, rows: 5, direction: -1)
            let downProblems = reversals(down, direction: -1)
            XCTAssertTrue(downProblems.isEmpty, "\(name)往下滚抖了：\(downProblems.prefix(8))\n\(down.map(\.description).joined(separator: "\n"))")
            // 一路拨回底部、过头。
            let home = try await gesture(tab, rows: 12, direction: -1)
            let homeProblems = reversals(home, direction: -1)
            XCTAssertTrue(homeProblems.isEmpty, "\(name)拨回底部抖了：\(homeProblems.prefix(8))\n\(home.map(\.description).joined(separator: "\n"))")
            print("JITTER \(name) 回到底部：\(home.last.map(String.init(describing:)) ?? "-")")
        }
    }

    /// 远控时在手机上新建的本机终端（出生就被钉住，surface 在钉住期间才第一次建）：接管结束后用鼠标滚轮上下滚，
    /// 视图位置、行高调整、下移量都不动，视口首行单向走。对照：Mac 上新建、同样被接管过再解除的标签。
    func testTabBornPinnedScrollsWithWheelWithoutJitterAfterRelease() async throws {
        // 窗格可用高 = 20 行自然行高 + 25 px：按行填满要把格子拉高 1 px（行高调整非 0）。
        let mac = try await makeTab(paneHeight: 298.5)
        let born = try await makeTab(paneHeight: 298.5, pinOnBirth: (57, 58))
        XCTAssertNotNil(born.view.pinnedFrameSize, "用例前提：出生就被钉住")
        XCTAssertNotEqual(mac.sample().adjustment, 0, "用例前提：行高调整非 0（\(mac.sample())）")
        try await takeOverAndRelease(mac)
        try await takeOverAndRelease(born, unpinWhileHidden: true)
        for (name, tab) in [("Mac 新建", mac), ("手机新建", born)] {
            let pty = await tab.backend.resizes.last.map { "\($0.cols)×\($0.rows)" } ?? "-"
            let all = await tab.backend.resizes.map { "\($0.cols)×\($0.rows)" }
            print("JITTER \(name) PTY \(all) 影子 \(tab.session.shadow.size) surface \(tab.sample().grid)")
            XCTAssertEqual(pty, tab.sample().grid, "\(name)解除后 PTY 的尺寸应当是窗格的网格（PTY 收过 \(all)）")
        }
        // 回到活动区底部再比。
        for tab in [mac, born] { _ = try await wheel(tab, notches: 400, direction: -1) }
        let a = mac.sample(), b = born.sample()
        print("JITTER 解除后 Mac 新建 \(a)\nJITTER 解除后 手机新建 \(b)")
        XCTAssertNil(born.view.pinnedFrameSize, "解除后不该还钉着")
        XCTAssertEqual(b.frame, a.frame, "解除后视图位置：\nMac 新建 \(a)\n手机新建 \(b)")
        XCTAssertEqual(b.adjustment, a.adjustment, "行高调整：\nMac 新建 \(a)\n手机新建 \(b)")
        XCTAssertEqual(b.rowFillOffset, a.rowFillOffset, "下移量：\nMac 新建 \(a)\n手机新建 \(b)")
        XCTAssertEqual(b.grid, a.grid, "网格：\nMac 新建 \(a)\n手机新建 \(b)")
        for (name, tab) in [("Mac 新建", mac), ("手机新建", born)] {
            let up = try await wheel(tab, notches: 12)
            print(up.map { "JITTER \(name) 上 \($0)" }.joined(separator: "\n"))
            let upProblems = reversals(up)
            XCTAssertTrue(upProblems.isEmpty, "\(name)滚轮往回滚抖了：\(upProblems.prefix(8))\n\(up.map(\.description).joined(separator: "\n"))")
            let down = try await wheel(tab, notches: 8, direction: -1)
            let downProblems = reversals(down, direction: -1)
            XCTAssertTrue(downProblems.isEmpty, "\(name)滚轮往下滚抖了：\(downProblems.prefix(8))\n\(down.map(\.description).joined(separator: "\n"))")
        }
    }

    /// 滚轮往回滚的同时程序在底部不停换行（Claude 界面和终端对不上行时每次刷新都会这样）：视口里的内容不该来回跳。
    func testWheelWhileProgramScrollsTheScreen() async throws {
        let tab = try await makeTab()
        _ = try await wheel(tab, notches: 20)
        let feeding = Task { [backend = tab.backend] in
            var n = 0
            while !Task.isCancelled {
                n += 1
                await backend.emitOutput(Data("\u{1B}[?2026h\r\ntick \(n)\u{1B}[?2026l".utf8))
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        let up = try await wheel(tab, notches: 10)
        let down = try await wheel(tab, notches: 6, direction: -1)
        feeding.cancel()
        let lines = (up + down).map { $0.firstLine.map(String.init) ?? "-" }
        print("JITTER 边输出边滚 首行：\(lines.joined(separator: " "))")
        var flips = 0
        for (a, b) in zip(up, up.dropFirst()) {
            if let x = a.firstLine, let y = b.firstLine, y > x { flips += 1 }
        }
        XCTAssertEqual(flips, 0, "往回滚时首行往回跳了 \(flips) 次：\(lines)")
    }

    // MARK: 钉着时 surface 被放掉

    /// 钉着的标签藏久了（surface 被放掉），切回来重建 surface：网格仍是手机的行列数。重建的 surface 行高调整归 0，
    /// 按旧格子算的钉住尺寸会多出一行；藏着时手机又转了屏（钉了新尺寸）的话，视图还留在旧尺寸上。
    func testPinnedGridSurvivesSurfaceReleaseAndRepinWhileHidden() async throws {
        // 行高调整非 0 的窗格（见上一个用例）。
        let tab = try await makeTab(paneHeight: 298.5)
        XCTAssertNotEqual(tab.sample().adjustment, 0, "用例前提：行高调整非 0（\(tab.sample())）")
        tab.session.ghostty.hiddenReleaseDelay = .milliseconds(100)
        func check(_ cols: Int, _ rows: Int, _ label: String) async {
            let ok = await waitUntil(3) {
                tab.session.surfaceIO.surfaceGrid.map { Int($0.columns) == cols && Int($0.rows) == rows } ?? false
                    && tab.session.shadow.size.cols == cols && tab.session.shadow.size.rows == rows
            }
            let pty = await tab.backend.resizes.last.map { "\($0.cols)×\($0.rows)" } ?? "-"
            XCTAssertTrue(ok, "\(label)：网格应当是 \(cols)×\(rows)，surface \(tab.sample().grid)、影子 \(tab.session.shadow.size)")
            XCTAssertEqual(pty, "\(cols)×\(rows)", "\(label)：PTY 的尺寸")
        }
        await pin(tab, 89, 32)
        await check(89, 32, "钉住")
        tab.hide()
        await sleep(0.3)
        XCTAssertTrue(tab.session.ghostty.isSurfaceReleased, "用例前提：surface 已放掉")
        tab.show()
        await settle(tab)
        await check(89, 32, "藏久了切回（重建的 surface 行高调整归 0）")
        tab.hide()
        await sleep(0.3)
        XCTAssertTrue(tab.session.ghostty.isSurfaceReleased, "用例前提：surface 已放掉")
        await pin(tab, 57, 30)
        tab.show()
        await settle(tab)
        await check(57, 30, "藏着时手机转屏，切回")
        tab.session.unpinRemoteGrid()
        await settle(tab)
        await check(106, 20, "解除")
    }
}
