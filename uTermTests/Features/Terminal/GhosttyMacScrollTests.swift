import AppKit
import GhosttyTerminal
import IOSurface
import XCTest
@testable import uTerm

/// Mac 上 Ghostty 渲染的触控板滚动：停手之后视口有没有回到整行。
///
/// 引擎补丁 0023 让触控板按像素滚，视口可以停在「第几行 + 往下多少像素」；Ghostty 的点击、选区命中都按整数视口算，
/// 停在半行会差一行。本地包在 `AppTerminalView+SmoothScroll.swift` 里做「停手后吸附整行」，这里核三件事：
/// 途中确实是按像素滚的（不是整行跳）、停手后镜像回到整行、画面上第一行的顶边正好在视图顶边（镜像和引擎没差出小数）。
///
/// 量法：每一行铺一条整行宽的底色（27 种循环，相邻行必不同），从 Ghostty 的 IOSurface 读一列像素，
/// 还原出「每个像素行属于第几行文字」。滚动事件用 CGEvent 造（带 phase / momentumPhase），直接交给视图的 `scrollWheel`。
@MainActor
final class GhosttyMacScrollTests: XCTestCase {

    // MARK: 语料与读图

    /// 第 `number` 行（从 1 起）的底色：三个通道各取 3 档，27 行一循环，相邻两行红色通道一定不同。
    nonisolated static func tint(_ number: Int) -> (r: Int, g: Int, b: Int) {
        (60 + 60 * (number % 3), 60 + 60 * ((number / 3) % 3), 60 + 60 * ((number / 9) % 3))
    }

    nonisolated static func line(_ number: Int, cols: Int) -> String {
        let c = tint(number)
        let text = "\(number)"
        return "\u{1B}[48;2;\(c.r);\(c.g);\(c.b)m\(text)\(String(repeating: " ", count: max(0, cols - 1 - text.count)))\u{1B}[K\u{1B}[0m"
    }

    /// 一条色带：属于哪种底色（27 档里的编号，-1 = 不是行色）、像素行范围。
    struct Band: Equatable, CustomStringConvertible {
        var key: Int
        var top: Int
        var bottom: Int
        var height: Int { bottom - top }
        var description: String { "#\(key)[\(top)..<\(bottom)]" }
    }

    /// 读 IOSurface 中间偏右的一列（避开行号文字），按颜色切成带。
    nonisolated static func bands(_ surface: IOSurfaceRef) -> [Band] {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        let bpr = IOSurfaceGetBytesPerRow(surface), bpe = max(4, IOSurfaceGetBytesPerElement(surface))
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let x = w * 3 / 4
        var out: [Band] = []
        for y in 0 ..< h {
            // Ghostty 的 IOSurface 是 BGRA。
            let p = base + y * bpr + x * bpe
            let key = Self.key(r: Int(p[2]), g: Int(p[1]), b: Int(p[0]))
            if let last = out.last, last.key == key {
                out[out.count - 1].bottom = y + 1
            } else {
                out.append(Band(key: key, top: y, bottom: y + 1))
            }
        }
        return out
    }

    /// 颜色 → 27 档编号（每个通道 60 / 120 / 180，归到最近的一档）；不是行色（终端底色、文字）返回 -1。
    /// 不按固定容差比：画面按屏幕的色彩空间出，通道值会挪十几二十（实测 60 那一档在 P3 屏上到 80 多）。
    nonisolated static func key(r: Int, g: Int, b: Int) -> Int {
        func level(_ v: Int) -> Int? { v < 45 || v > 215 ? nil : (v < 100 ? 0 : (v < 150 ? 1 : 2)) }
        guard let lr = level(r), let lg = level(g), let lb = level(b) else { return -1 }
        return lr + lg * 3 + lb * 9
    }

    nonisolated static func key(ofLine number: Int) -> Int {
        (number % 3) + ((number / 3) % 3) * 3 + ((number / 9) % 3) * 9
    }

    // MARK: 夹具

    @MainActor
    private final class Rig {
        let session: TerminalSession
        let backend: CaptureBackend
        let bridge: GhosttyTerminalBridge
        let window: NSWindow
        let cell: Int
        let scale: CGFloat
        /// 一行高多少 pt（整数倍率的屏上是整数；用例按它凑整数 pt 的位移）。
        var rowPoints: Int { Int((CGFloat(cell) / scale).rounded()) }

        init(session: TerminalSession, backend: CaptureBackend, bridge: GhosttyTerminalBridge, window: NSWindow,
             cell: Int, scale: CGFloat) {
            self.session = session; self.backend = backend; self.bridge = bridge; self.window = window
            self.cell = cell; self.scale = scale
        }

        var view: GhosttySurfaceView { bridge.view }
        var state: AppTerminalView.UTermScrollState { view.uTermScrollState }
        /// 视口第一行显示的是第几行文字（从 1 起）；读不到时为 nil。
        var firstLine: Int? { viewportLines.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        var viewportLines: [String] { (bridge.viewportText() ?? "").components(separatedBy: "\n") }

        func bands() -> [Band] {
            GhosttyFrameWatch.currentSurface(of: view).map(GhosttyMacScrollTests.bands) ?? []
        }

        /// 到现在为止交给视图的位移合计（pt）。
        private(set) var sentPoints = 0

        /// 往回滚方向一共走了几行（按交出去的位移算，四舍五入到最近的整行）。
        var rowsScrolled: Int { Int((Double(sentPoints) * Double(scale) / Double(cell)).rounded()) }

        /// 一个触控板滚动事件。`points` 正 = 手指往下拨（往回滚方向）。CGEvent 的精确位移只能是整数 pt。
        func scroll(_ points: Int, phase: Int64 = 0, momentum: Int64 = 0) throws {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                           wheel1: Int32(points), wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            XCTAssertTrue(event.hasPreciseScrollingDeltas, "造出来的滚动事件不是精确滚动")
            XCTAssertEqual(event.scrollingDeltaY, CGFloat(points), accuracy: 0.01, "造出来的滚动事件位移不对")
            sentPoints += points
            view.scrollWheel(with: event)
        }

        func close() {
            session.dispose()
            window.orderOut(nil)
        }
    }

    // CGScrollPhase / CGMomentumScrollPhase 的取值。
    private let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4
    private let momentumBegin: Int64 = 1, momentumContinue: Int64 = 2, momentumEnd: Int64 = 3

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// 一段手势收尾后等它停稳：吸附走完，并且引擎报来的行号跟上了镜像（渲染线程出过那一帧，读图才作数）。
    /// 测试窗口被遮挡时显示节拍会停、画面不出新帧，这里就等不到——那是环境问题，报出来。
    private func settle(_ rig: Rig, _ label: String, file: StaticString = #filePath, line: UInt = #line) async {
        let rested = await waitUntil(3) { rig.state.isAtRest && rig.view.uTermScrollbarOffset == rig.state.row }
        XCTAssertTrue(rested, "\(label)：没停稳，或者画面没跟上（镜像 \(rig.state)，引擎行号 \(String(describing: rig.view.uTermScrollbarOffset))）",
                      file: file, line: line)
        await sleep(0.15)
    }

    /// 800×500 的 Ghostty 终端，喂 `lines` 行带底色的编号行（最后停在一个空的提示行上）。
    private func makeRig(lines: Int = 300) async throws -> Rig {
        let rect = NSRect(x: 0, y: 0, width: 800, height: 500)
        let session = TerminalSession()
        let backend = CaptureBackend()
        let bridge = session.ghostty
        let container = GhosttyContainerView(surface: bridge.view)
        container.isActive = true
        let window = ProbeWindow.make(contentRect: rect, contentView: container, placement: .transparentOnScreen)
        // 配色跟着视图的日夜走；钉成深色，底色和 27 档行色分得开。
        window.appearance = NSAppearance(named: .darkAqua)
        container.frame = window.contentView?.bounds ?? rect
        container.layoutSubtreeIfNeeded()
        let live = await waitUntil(10) { bridge.isLive && bridge.grid != nil }
        XCTAssertTrue(live, "Ghostty surface 没就绪")
        // 第一次报上来的网格常常是按挂上那一刻的尺寸算的（实测先报 53×21），等它停稳再喂，不然语料按错的列数垫空格。
        var last = bridge.grid.map { "\($0)" } ?? ""
        var stableSince = Date()
        while Date().timeIntervalSince(stableSince) < 0.4 {
            await sleep(0.02)
            let now = bridge.grid.map { "\($0)" } ?? ""
            if now != last { last = now; stableSince = Date() }
        }
        await session.connect(using: backend)
        let grid = try XCTUnwrap(bridge.grid)
        var text = ""
        for n in 1 ... lines { text += Self.line(n, cols: grid.cols) + "\r\n" }
        backend.emit(Data(text.utf8))
        let cell = try XCTUnwrap(bridge.view.uTermCellPixels)
        let rig = Rig(session: session, backend: backend, bridge: bridge, window: window,
                      cell: Int(cell.height), scale: window.backingScaleFactor)
        // 喂完：视口里看得到最后一行（它下面是空的提示行）。
        let fed = await waitUntil(10) { rig.viewportLines.contains { $0.trimmingCharacters(in: .whitespaces) == "\(lines)" } }
        XCTAssertTrue(fed, "语料没喂完：第一行是 \(String(describing: rig.firstLine))")
        await sleep(0.3)
        return rig
    }

    /// 画面上第一条行色带：顶边在 0、高度正好一行、颜色是 `line` 那一行的。
    private func assertAligned(_ rig: Rig, firstLine line: Int, _ label: String, file: StaticString = #filePath, line codeLine: UInt = #line) {
        let bands = rig.bands().filter { $0.key >= 0 }
        guard let first = bands.first else { return XCTFail("\(label)：读不到行色带", file: file, line: codeLine) }
        XCTAssertEqual(first.top, 0, "\(label)：第一行的顶边不在视图顶边（\(bands.prefix(3))）", file: file, line: codeLine)
        XCTAssertEqual(first.height, rig.cell, "\(label)：第一行不是整行高（\(bands.prefix(3))）", file: file, line: codeLine)
        XCTAssertEqual(first.key, Self.key(ofLine: line), "\(label)：第一行不是第 \(line) 行（\(bands.prefix(3))）", file: file, line: codeLine)
    }

    // MARK: 用例

    /// 手指拨 `tenths / 10` 行的距离后抬起、没有惯性：途中停在半行上，抬手后吸附到最近的整行。
    private func checkLift(tenths: Int, landsOn expectedRows: Int) async throws {
        let rig = try await makeRig()
        defer { rig.close() }
        let start = try XCTUnwrap(rig.firstLine)
        assertAligned(rig, firstLine: start, "滚动之前")

        let total = rig.rowPoints * tenths / 10
        let steps = 8
        try rig.scroll(0, phase: began)
        for step in 0 ..< steps {
            try rig.scroll(total * (step + 1) / steps - total * step / steps, phase: changed)
            await sleep(0.012)
        }
        XCTAssertEqual(rig.rowsScrolled, expectedRows, "用例凑的位移不对：\(rig.sentPoints) pt，行高 \(rig.rowPoints) pt")
        // 途中：镜像带着小数，画面上第一行被切了一截（确实是按像素滚的）。
        await sleep(0.05)
        let midBands = rig.bands().filter { $0.key >= 0 }
        XCTAssertNotEqual(rig.state.fractionPixels, 0, "拨了 \(rig.sentPoints) pt，镜像里应当带着小数")
        XCTAssertNotEqual(midBands.first?.height, rig.cell, "途中第一行应当被切掉一截（\(midBands.prefix(2))）")

        try rig.scroll(0, phase: ended)
        await settle(rig, "抬手后")
        XCTAssertEqual(rig.firstLine, start - expectedRows, "拨了 \(rig.sentPoints) pt，应当停在往回 \(expectedRows) 行处")
        assertAligned(rig, firstLine: start - expectedRows, "抬手吸附之后")
        // 之后不再动。
        await sleep(0.4)
        XCTAssertTrue(rig.state.isAtRest)
        assertAligned(rig, firstLine: start - expectedRows, "停稳 0.4 s 后")
    }

    func testLiftSnapsBackToNearerRow() async throws {
        try await checkLift(tenths: 33, landsOn: 3)
    }

    func testLiftSnapsForwardToNearerRow() async throws {
        try await checkLift(tenths: 37, landsOn: 4)
    }

    /// 抬手后系统接着发惯性：惯性途中不吸附，惯性结束那一刻吸附。
    func testMomentumSnapsWhenItEnds() async throws {
        let rig = try await makeRig()
        defer { rig.close() }
        let start = try XCTUnwrap(rig.firstLine)
        let row = rig.rowPoints
        try rig.scroll(0, phase: began)
        for _ in 0 ..< 4 { try rig.scroll(row / 2, phase: changed); await sleep(0.012) }
        try rig.scroll(0, phase: ended)
        // 惯性：再走 11 步、每步 0.4 行上下，抬手那一下的「稍后吸附」应当被作废。
        let step = row * 2 / 5
        try rig.scroll(step, momentum: momentumBegin)
        for _ in 0 ..< 10 {
            try rig.scroll(step, momentum: momentumContinue)
            await sleep(0.012)
        }
        await sleep(0.12)
        let expected = rig.rowsScrolled
        XCTAssertFalse(rig.state.isSnapping, "惯性还没结束就开始吸附了")
        XCTAssertNotEqual(rig.state.fractionPixels, 0, "惯性途中应当带着小数（走了 \(rig.sentPoints) pt，行高 \(row) pt）")
        try rig.scroll(0, momentum: momentumEnd)
        await settle(rig, "惯性结束后")
        XCTAssertEqual(rig.firstLine, start - expected, "一共走了 \(rig.sentPoints) pt，应当停在往回 \(expected) 行处")
        assertAligned(rig, firstLine: start - expected, "惯性结束吸附之后")
    }

    /// 拨过回滚顶部再回来、拨回活动区：到头后镜像和引擎都不留小数。
    func testEdgesLeaveNoFraction() async throws {
        let rig = try await makeRig(lines: 60)
        defer { rig.close() }
        let bottom = try XCTUnwrap(rig.firstLine)
        let row = rig.rowPoints
        // 一口气拨过顶（位移远超回滚的长度）。
        try rig.scroll(0, phase: began)
        for _ in 0 ..< 60 { try rig.scroll(row * 2 + 3, phase: changed); await sleep(0.008) }
        try rig.scroll(0, phase: ended)
        await settle(rig, "拨过顶之后")
        XCTAssertEqual(rig.state.row, 0, "应当停在回滚顶部：\(rig.state)")
        XCTAssertEqual(rig.bridge.view.uTermScrollbarOffset, 0, "引擎应当在回滚顶部")
        // 新开的终端回滚顶上就是第 1 行：surface 挂上时影子还是空的，不拿空屏的快照去对齐（否则顶上多出一屏空行）。
        XCTAssertEqual(rig.firstLine, 1, "回滚顶部应当是第 1 行：\(rig.viewportLines.prefix(3))")
        assertAligned(rig, firstLine: 1, "拨过顶之后")
        // 从顶上往下拨七行多再抬手：吸附到整行。
        let before = rig.sentPoints
        try rig.scroll(0, phase: began)
        for _ in 0 ..< 5 { try rig.scroll(-(row * 3 / 2 + 1), phase: changed); await sleep(0.012) }
        await sleep(0.05)
        XCTAssertNotEqual(rig.state.fractionPixels, 0, "途中镜像里应当带着小数")
        try rig.scroll(0, phase: ended)
        await settle(rig, "从顶上拨下来之后")
        let down = Int((Double(before - rig.sentPoints) * Double(rig.scale) / Double(rig.cell)).rounded())
        XCTAssertEqual(rig.firstLine, 1 + down, "从顶上拨下 \(before - rig.sentPoints) pt，应当停在第 \(1 + down) 行")
        assertAligned(rig, firstLine: 1 + down, "从顶上拨下来之后")
        // 拨回活动区（过头）。
        try rig.scroll(0, phase: began)
        for _ in 0 ..< 60 { try rig.scroll(-(row * 2 + 3), phase: changed); await sleep(0.008) }
        try rig.scroll(0, phase: ended)
        await settle(rig, "拨回底部之后")
        XCTAssertEqual(rig.firstLine, bottom, "应当回到活动区底部")
        assertAligned(rig, firstLine: bottom, "拨回底部之后")
    }
}
