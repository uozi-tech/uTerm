import GhosttyTerminal
import ObjectiveC
import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

/// GhosttyKit vs SwiftTerm，同场景同尺寸（393×760、11pt、暗色配色）在同一次运行里比。
/// 读数、方法与环境见 docs/ghostty-eval/ios-spike.md。
///
/// 口径：
/// - CPU 按**线程**量（`ThreadCPU`）：主线程用 `CLOCK_THREAD_CPUTIME_ID`，其余线程用 `THREAD_EXTENDED_INFO`。
///   SwiftTerm 的解析和绘制都在主线程；Ghostty 解析在自己的串行队列、渲染线程更新帧、主线程 tick + Metal 提交，
///   只量主线程会把 Ghostty 算得太便宜。
/// - 帧：SwiftTerm 数 `draw(_:)`，Ghostty 数 `IOSurfaceLayer.setContents:`（真正交给 Core Animation 的帧）。
/// - 参考节拍：一个独立的 `CADisplayLink`，间隔超过标称 1.5 倍记一次卡顿（= 主线程被占住）。
/// - 每档前先量一段同长度的空闲当基线，宿主 App 自己的开销从这里看。
/// - 模拟器：GPU 是 Mac 的，Metal 的 GPU 时间不在这些线程里；`docs` 里有真机版跑法。
/// 闸门只放结构判据（帧确实交出去了、看不见时不画），不卡绝对毫秒。
@MainActor
final class GhosttySpikeProbeTests: XCTestCase {
    private enum Kind: String { case swiftterm, ghostty }

    private struct Reading {
        let label: String
        let seconds: Double
        let ticks: Int
        let hitches: Int
        let frames: Int
        let doubleFrameTicks: Int
        let cpu: ThreadCPU.Delta
        let drawCPU: [Double]
        var raw = ""

        var line: String {
            let perFrame = frames > 0 ? cpu.totalMS / Double(frames) : 0
            return String(format: "SPIKE %@ secs=%.1f ticks=%d hitch=%d frames=%d double=%d "
                          + "cpu-total=%.1fms(%.1f%%) main=%.1fms(%.1f%%) other=%.1fms per-frame=%.2fms draw-p50=%.2f draw-max=%.2f | %@",
                          label, seconds, ticks, hitches, frames, doubleFrameTicks,
                          cpu.totalMS, cpu.totalMS / seconds / 10, cpu.mainMS, cpu.mainMS / seconds / 10, cpu.otherMS,
                          perFrame, ProbeMetrics.percentile(drawCPU, 0.5), drawCPU.max() ?? 0, cpu.line) + raw
        }
    }

    private func frameTimes(_ kind: Kind) -> [Double] {
        switch kind {
        case .swiftterm: SwiftTermDrawLog.draws.map(\.at)
        case .ghostty: GhosttyPresentLog.read().times
        }
    }

    private func resetFrames() {
        SwiftTermDrawLog.draws.removeAll()
        GhosttyPresentLog.reset()
    }

    /// 量一段：`onTick` 每个显示节拍跑一次（驱动输出 / 滚动），`every100ms` 每 100ms 跑一次。
    private func measure(_ label: String, kind: Kind, seconds: Double,
                         onTick: (@MainActor (Int) -> Void)? = nil,
                         every100ms: (@MainActor (Int) -> Void)? = nil) async throws -> Reading {
        let counter = DisplayLinkCounter()
        var tickTimes: [Double] = []
        var step = 0
        counter.onTick = {
            tickTimes.append(CACurrentMediaTime())
            onTick?(step)
            step += 1
        }
        resetFrames()
        let mainID = ThreadCPU.currentThreadID()
        let start = ThreadCPU.snapshot()
        counter.start()
        let t0 = Date()
        var beat = 0
        while Date().timeIntervalSince(t0) < seconds {
            every100ms?(beat)
            beat += 1
            try await Task.sleep(for: .milliseconds(100))
        }
        counter.stop()
        let end = ThreadCPU.snapshot()
        let frames = frameTimes(kind)
        var doubled = 0
        for (a, b) in zip(tickTimes, tickTimes.dropFirst()) where frames.filter({ $0 >= a && $0 < b }).count > 1 {
            doubled += 1
        }
        let nominal = counter.nominalIntervalMS
        let raw = GhosttyPresentLog.rawCounts()
        var reading = Reading(label: "\(kind.rawValue)/\(label)", seconds: seconds, ticks: counter.ticks,
                       hitches: counter.intervals.filter { $0 > nominal * 1.5 }.count,
                       frames: frames.count, doubleFrameTicks: doubled,
                       cpu: ThreadCPU.delta(from: start, to: end, mainID: mainID),
                       drawCPU: kind == .swiftterm ? SwiftTermDrawLog.draws.map(\.cpuMS) : [])
        if kind == .ghostty { reading.raw = " | setContents raw=\(raw.calls) nil=\(raw.nils)" }
        return reading
    }

    // MARK: 稳态：空闲 / Claude 思考 / 整屏刷新

    /// 三档稳态，两个终端交替各跑两轮（A B A B，抵消机器负载漂移）。
    func testSteadyStateCost() async throws {
        SwiftTermDrawLog.install()
        let st = try SwiftTermProbeHost()
        let gh = try GhosttyProbeHost()
        defer { st.close(); gh.close() }
        try await gh.waitUntilReady()
        print("SPIKE grid swiftterm=\(st.grid) ghostty=\(gh.grid) scale=\(gh.view.window?.screen.nativeScale ?? 0)")

        // 两边都先铺一屏 Claude 跑过一阵的内容。
        let stRows = st.grid.rows, ghRows = gh.grid.rows
        st.view.feed(text: TerminalSpikeCorpus.history(lines: 200, cols: st.grid.cols) + TerminalSpikeCorpus.claudeFrame(0, cols: st.grid.cols))
        st.view.flushPendingDisplay()
        gh.feedAndWait(TerminalSpikeCorpus.history(lines: 200, cols: gh.grid.cols) + TerminalSpikeCorpus.claudeFrame(0, cols: gh.grid.cols))
        try await Task.sleep(for: .milliseconds(500))

        var readings: [Reading] = []
        for round in 0..<2 {
            for kind in [Kind.swiftterm, .ghostty] {
                let cols = kind == .swiftterm ? st.grid.cols : gh.grid.cols
                let rows = kind == .swiftterm ? stRows : ghRows
                func feed(_ text: String) {
                    switch kind {
                    case .swiftterm: st.view.feedPaced(ArraySlice(Array(text.utf8)), backlogged: false)
                    case .ghostty: gh.bridge.feed(Data(text.utf8))
                    }
                }
                readings.append(try await measure("idle#\(round)", kind: kind, seconds: 3))
                readings.append(try await measure("claude-10fps#\(round)", kind: kind, seconds: 4, every100ms: { n in
                    feed(TerminalSpikeCorpus.claudeFrame(n + 1, cols: cols))
                }))
                // 每个显示节拍整屏都变：`top` / 全屏 TUI 重绘的上界。
                readings.append(try await measure("fullscreen-vsync#\(round)", kind: kind, seconds: 4, onTick: { n in
                    feed("\u{1B}[?2026h" + TerminalSpikeCorpus.screen(rows: rows, salt: n) + "\u{1B}[?2026l")
                }))
                // 回到同一屏，下一档从一样的状态开始。
                feed(TerminalSpikeCorpus.history(lines: 40, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols))
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        for reading in readings { print(reading.line) }

        let claude = readings.filter { $0.label.contains("ghostty/claude") }
        XCTAssertTrue(claude.allSatisfy { $0.frames >= 20 }, "Ghostty 有输出时没交帧：\(claude.map(\.frames))")
        let full = readings.filter { $0.label.contains("ghostty/fullscreen") }
        XCTAssertTrue(full.allSatisfy { $0.frames > 60 }, "Ghostty 整屏刷新时没交帧：\(full.map(\.frames))")
        XCTAssertTrue(gh.viewportText.contains("App/File"), "Ghostty 的内容没落到屏上：\(gh.viewportText.prefix(200))")
    }

    // MARK: 大量输出

    /// `cat` 2MB：SwiftTerm 走生产的 `TerminalOutputPump`（按 `.foreground` 节拍、积压时降帧），
    /// Ghostty 按 16KB 一块尽快 `receive`。量从第一块到「最后一行出现在屏上」的墙钟时间与各线程 CPU。
    func testFloodThroughput() async throws {
        SwiftTermDrawLog.install()
        let payload = TerminalSpikeCorpus.flood(bytes: 2 * 1024 * 1024)
        let marker = "FLOOD-END-MARKER"
        let tail = Data("\r\n\(marker)\r\n".utf8)
        let chunks = stride(from: 0, to: payload.count, by: 16 * 1024).map {
            payload.subdata(in: $0..<min(payload.count, $0 + 16 * 1024))
        } + [tail]

        for round in 0..<2 {
            // SwiftTerm
            do {
                let st = try SwiftTermProbeHost()
                defer { st.close() }
                try await Task.sleep(for: .milliseconds(200))
                let pump = TerminalOutputPump(pacing: .foreground)
                pump.terminalView = st.view
                let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
                resetFrames()
                let mainID = ThreadCPU.currentThreadID()
                let cpu0 = ThreadCPU.snapshot()
                let t0 = CACurrentMediaTime()
                pump.reset()
                pump.start(stream)
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
                func shown() -> Bool {
                    let t = st.view.getTerminal()
                    return (0..<t.rows).contains { t.getLine(row: $0)?.translateToString().contains(marker) == true }
                }
                while !(shown() && !pump.buffer.hasBufferedBytes), CACurrentMediaTime() - t0 < 30 {
                    try await Task.sleep(for: .milliseconds(2))
                }
                let wall = (CACurrentMediaTime() - t0) * 1000
                // 等最后一帧画出来。
                try await Task.sleep(for: .milliseconds(120))
                let cpu = ThreadCPU.delta(from: cpu0, to: ThreadCPU.snapshot(), mainID: mainID)
                print(String(format: "SPIKE swiftterm/flood-2MB#%d wall=%.0fms draws=%d cpu-total=%.0fms main=%.0fms other=%.0fms | %@",
                             round, wall, SwiftTermDrawLog.draws.count, cpu.totalMS, cpu.mainMS, cpu.otherMS, cpu.line))
                XCTAssertTrue(shown(), "SwiftTerm 没把最后一行画出来")
                pump.reset()
            }
            // Ghostty
            do {
                let gh = try GhosttyProbeHost()
                defer { gh.close() }
                try await gh.waitUntilReady()
                try await Task.sleep(for: .milliseconds(200))
                resetFrames()
                let mainID = ThreadCPU.currentThreadID()
                let cpu0 = ThreadCPU.snapshot()
                let t0 = CACurrentMediaTime()
                // 模拟网络读：块之间不等，和 SwiftTerm 侧一次把全部块塞进流相同。
                let bridge = gh.bridge
                Task.detached { for chunk in chunks { bridge.feed(chunk) } }
                var parsedAt: Double?
                while CACurrentMediaTime() - t0 < 30 {
                    if parsedAt == nil, gh.bridge.session.pendingOutputByteCount == 0, gh.viewportText.contains(marker) {
                        parsedAt = CACurrentMediaTime()
                    }
                    // 解析完之后再等到下一帧交出去，才算看得见。
                    if let parsedAt, GhosttyPresentLog.read().times.last.map({ $0 > parsedAt }) == true { break }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let wall = (CACurrentMediaTime() - t0) * 1000
                try await Task.sleep(for: .milliseconds(120))
                let cpu = ThreadCPU.delta(from: cpu0, to: ThreadCPU.snapshot(), mainID: mainID)
                print(String(format: "SPIKE ghostty/flood-2MB#%d wall=%.0fms presents=%d cpu-total=%.0fms main=%.0fms other=%.0fms | %@",
                             round, wall, GhosttyPresentLog.read().times.count, cpu.totalMS, cpu.mainMS, cpu.otherMS, cpu.line))
                XCTAssertNotNil(parsedAt, "Ghostty 30 秒内没解析完 2MB")
                // 核对没丢字节：回滚里的行数应当 ≈ 语料行数（Ghostty 默认 scrollback 10MB，装得下）。
                let lines = payload.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
                print("SPIKE ghostty/flood lines=\(lines) scrollback-total=\(gh.scrollbar?.total ?? 0) raw-setContents=\(GhosttyPresentLog.rawCounts())")
                XCTAssertGreaterThanOrEqual(Int(gh.scrollbar?.total ?? 0), lines, "Ghostty 的回滚行数少于语料行数：丢了字节")
            }
        }
    }

    // MARK: 边输出边滚动（补丁 #21 的场景）

    private nonisolated(unsafe) static var fingerDown = false
    /// 同 `TerminalScrollWhileOutputProbeTests.installTracking`：代码设滚动位置时让 SwiftTerm 认为手指按着，
    /// 不然每个 Claude 帧结束它都把视图拽回底部，量的就不是手指拖动了。
    private static let installTracking: Void = {
        let selector = #selector(getter: UIScrollView.isTracking)
        let base = class_getInstanceMethod(UIScrollView.self, selector)!
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(base), to: Getter.self)
        let tracking: @convention(block) (AnyObject) -> Bool = { view in fingerDown || original(view, selector) }
        class_addMethod(SwiftTerm.TerminalView.self, selector, imp_implementationWithBlock(tracking),
                        method_getTypeEncoding(base))
    }()

    /// 手指在靠底部的两屏里往返（每个显示节拍推一步），同时每 100ms 来一个 Claude 帧。
    /// 看两件事：每个滚动帧都画了没有（帧数 ≈ 节拍数），一个节拍里有没有画两遍。
    func testScrollWhileOutput() async throws {
        SwiftTermDrawLog.install()
        _ = Self.installTracking
        let st = try SwiftTermProbeHost()
        let gh = try GhosttyProbeHost()
        defer { st.close(); gh.close() }
        try await gh.waitUntilReady()
        st.view.feed(text: TerminalSpikeCorpus.history(lines: 400, cols: st.grid.cols) + TerminalSpikeCorpus.claudeFrame(0, cols: st.grid.cols))
        st.view.flushPendingDisplay()
        gh.feedAndWait(TerminalSpikeCorpus.history(lines: 400, cols: gh.grid.cols) + TerminalSpikeCorpus.claudeFrame(0, cols: gh.grid.cols))
        try await Task.sleep(for: .milliseconds(400))
        let scale = gh.view.window?.screen.nativeScale ?? 3

        var readings: [Reading] = []
        var ghostOffsets: [UInt64] = []
        for round in 0..<2 {
            for output in [false, true] {
                // SwiftTerm：直接推 contentOffset（同既有探针）。
                let bottom = max(0, st.view.contentSize.height - st.view.bounds.height)
                let amplitude = min(bottom, st.view.bounds.height * 2)
                let label = output ? "scroll+output#\(round)" : "scroll#\(round)"
                let stCols = st.grid.cols
                let stScroll: @MainActor (Int) -> Void = { step in
                    let phase = 0.5 * (1 - cos(Double(step % 120) / 120 * 2 * .pi))
                    st.view.setContentOffset(CGPoint(x: 0, y: bottom - amplitude * CGFloat(phase)), animated: false)
                    st.view.layoutIfNeeded()
                }
                let stOutput: @MainActor (Int) -> Void = { n in
                    let frame = TerminalSpikeCorpus.claudeFrame(n + 1, cols: stCols)
                    st.view.feedPaced(ArraySlice(Array(frame.utf8)), backlogged: false)
                }
                Self.fingerDown = true
                let stReading = try await measure(label, kind: .swiftterm, seconds: 4,
                                                  onTick: stScroll, every100ms: output ? stOutput : nil)
                readings.append(stReading)
                Self.fingerDown = false
                st.view.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)

                // Ghostty：手指拖动 = 每拍把这一拍的位移当 precision 滚动发给 surface（同 GhosttyKit 自己的拖动手势）。
                let height = Double(gh.view.bounds.height)
                var last = 0.0
                let ghCols = gh.grid.cols
                let pixelScale = Double(scale)
                let ghScroll: @MainActor (Int) -> Void = { step in
                    let phase = 0.5 * (1 - cos(Double(step % 120) / 120 * 2 * .pi))
                    let y = height * 2 * phase
                    gh.view.sendMouseScroll(x: 0, y: (y - last) * pixelScale)
                    last = y
                    if step % 10 == 0, let bar = gh.scrollbar { ghostOffsets.append(bar.offset) }
                }
                let ghOutput: @MainActor (Int) -> Void = { n in
                    let frame = TerminalSpikeCorpus.claudeFrame(n + 1, cols: ghCols)
                    gh.bridge.feed(Data(frame.utf8))
                }
                let ghReading = try await measure(label, kind: .ghostty, seconds: 4,
                                                  onTick: ghScroll, every100ms: output ? ghOutput : nil)
                readings.append(ghReading)
                gh.view.sendMouseScroll(x: 0, y: -last * Double(scale))
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        for reading in readings { print(reading.line) }
        print("SPIKE ghostty scrollbar offsets sampled=\(Set(ghostOffsets).sorted().prefix(40)) total=\(gh.scrollbar?.total ?? 0) len=\(gh.scrollbar?.len ?? 0)")
        XCTAssertGreaterThan(Set(ghostOffsets).count, 5, "Ghostty 的视口没跟着手指动，量的是静止画面")
        for reading in readings where reading.label.hasPrefix("ghostty") {
            XCTAssertGreaterThan(reading.frames, reading.ticks / 2, "\(reading.label) 滚动时大半节拍没交帧")
        }
    }

    // MARK: 看不见的终端

    /// 后台标签：SwiftTerm 由 `MTerminalView.isOffScreen` 停画（uTerm 本地实现），Ghostty 用 `setSurfaceVisible(false)`（原生）。
    /// 停着的时候照常喂 Claude 帧：不该交任何帧；字节照常解析；露出来补一帧且是最新内容。
    func testHiddenTerminalStopsDrawing() async throws {
        SwiftTermDrawLog.install()
        let st = try SwiftTermProbeHost()
        let gh = try GhosttyProbeHost()
        defer { st.close(); gh.close() }
        try await gh.waitUntilReady()
        gh.feedAndWait(TerminalSpikeCorpus.history(lines: 50, cols: gh.grid.cols))
        st.view.feed(text: TerminalSpikeCorpus.history(lines: 50, cols: st.grid.cols))
        try await Task.sleep(for: .milliseconds(300))

        st.container.isOnScreen = false
        gh.view.setSurfaceVisible(false)
        try await Task.sleep(for: .milliseconds(100))
        let stHidden = try await measure("hidden-claude-10fps", kind: .swiftterm, seconds: 3, every100ms: { n in
            st.view.feedPaced(ArraySlice(Array(TerminalSpikeCorpus.claudeFrame(n + 1, cols: st.grid.cols).utf8)), backlogged: false)
        })
        let ghHidden = try await measure("hidden-claude-10fps", kind: .ghostty, seconds: 3, every100ms: { n in
            gh.bridge.feed(Data(TerminalSpikeCorpus.claudeFrame(n + 1, cols: gh.grid.cols).utf8))
        })
        print(stHidden.line)
        print(ghHidden.line)
        XCTAssertEqual(ghHidden.frames, 0, "Ghostty 隐藏后仍在交帧")
        XCTAssertEqual(stHidden.frames, 0, "SwiftTerm 隐藏后仍在画")

        gh.feedAndWait("\r\nHIDDEN-MARKER")
        XCTAssertTrue(gh.viewportText.contains("HIDDEN-MARKER"), "隐藏期间字节要照常解析")
        resetFrames()
        gh.view.setSurfaceVisible(true)
        st.container.isOnScreen = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(GhosttyPresentLog.read().times.count, 0, "Ghostty 露出来要补一帧")
        XCTAssertGreaterThan(SwiftTermDrawLog.draws.count, 0, "SwiftTerm 露出来要补画")
    }

    // MARK: 转屏：重排、SIGWINCH 次数、闪烁

    /// 393×760 ↔ 760×393 来回三次。每次改尺寸后 700ms 内逐帧（显示节拍）截窗口：
    /// 墨迹比例掉到稳态的三成以下记一次「闪白 / 空帧」；同时记网格变了几次、远端会收到几次尺寸。
    func testRotationReflowAndFlicker() async throws {
        SwiftTermDrawLog.install()
        let portrait = CGSize(width: 393, height: 760), landscape = CGSize(width: 760, height: 393)

        for kind in [Kind.swiftterm, .ghostty] {
            let window: UIWindow
            let grid: () -> String
            let reports: () -> Int
            let closer: () -> Void
            let sizeCounter = SizeChangeCounter()
            switch kind {
            case .swiftterm:
                let st = try SwiftTermProbeHost(size: portrait)
                st.view.terminalDelegate = sizeCounter
                st.view.feed(text: TerminalSpikeCorpus.history(lines: 300, cols: st.grid.cols) + "$ echo 转屏测试 \u{1B}[1mbold\u{1B}[0m")
                window = st.window
                grid = { "\(st.grid.cols)x\(st.grid.rows)" }
                reports = { sizeCounter.count }
                closer = { st.close() }
            case .ghostty:
                let gh = try GhosttyProbeHost(size: portrait)
                try await gh.waitUntilReady()
                gh.feedAndWait(TerminalSpikeCorpus.history(lines: 300, cols: gh.grid.cols) + "$ echo 转屏测试 \u{1B}[1mbold\u{1B}[0m")
                window = gh.window
                grid = { "\(gh.grid.cols)x\(gh.grid.rows)" }
                reports = { gh.bridge.resizeReports }
                closer = { gh.close() }
            }
            defer { closer() }
            try await Task.sleep(for: .milliseconds(600))
            let reports0 = reports()
            var grids: [String] = [grid()]
            let mainID = ThreadCPU.currentThreadID()
            // 第一遍：只量 CPU、帧数、网格停稳要多久（不截图，截图本身很贵）。
            var frames = 0
            var cpu = 0.0
            var settleMS: [Double] = []
            for size in [landscape, portrait, landscape, portrait, landscape, portrait] {
                resetFrames()
                let before = grid()
                let cpu0 = ThreadCPU.snapshot()
                let t0 = CACurrentMediaTime()
                window.frame = CGRect(origin: .zero, size: size)
                var changedAt: Double?
                while CACurrentMediaTime() - t0 < 0.7 {
                    try await Task.sleep(for: .milliseconds(4))
                    if changedAt == nil, grid() != before { changedAt = CACurrentMediaTime() }
                    if grids.last != grid() { grids.append(grid()) }
                }
                if let changedAt { settleMS.append((changedAt - t0) * 1000) }
                frames += frameTimes(kind).count
                cpu += ThreadCPU.delta(from: cpu0, to: ThreadCPU.snapshot(), mainID: mainID).totalMS
            }
            // 第二遍：每个显示节拍截一次窗口，和这次转完停稳后的墨迹比，掉到一半以下记一次空帧 / 闪烁。
            var dips = 0
            var minRatio = 1.0
            for size in [landscape, portrait, landscape, portrait] {
                window.frame = CGRect(origin: .zero, size: size)
                var inks: [Double] = []
                let t0 = CACurrentMediaTime()
                while CACurrentMediaTime() - t0 < 0.7 {
                    try await Task.sleep(for: .milliseconds(16))
                    inks.append(inkOfWindow(window))
                }
                try await Task.sleep(for: .milliseconds(300))
                let settled = max(inkOfWindow(window), 0.0001)
                for ink in inks {
                    minRatio = min(minRatio, ink / settled)
                    if ink < settled * 0.5 { dips += 1 }
                }
            }
            print(String(format: "SPIKE %@/rotate x6 grids=%@ remote-resizes=%d frames=%d cpu=%.0fms grid-change-after=%@ms | flicker x4: min-ink-ratio=%.2f dips=%d",
                         kind.rawValue, grids.description, reports() - reports0, frames, cpu,
                         settleMS.map { String(format: "%.0f", $0) }.joined(separator: "/"), minRatio, dips))
            XCTAssertEqual(grids.last, grids.first, "\(kind) 转回竖屏后网格没回到原样")
        }
    }

    // MARK: 回显延迟

    /// 远端回显一个字符到它被交给 Core Animation 的时间（不含合成与上屏，那段两边一样）。
    /// SwiftTerm：`feedPaced` → 节流后的 `draw`；Ghostty：`receive` → 串行队列解析 → 唤醒 → display link → present。
    func testEchoLatency() async throws {
        SwiftTermDrawLog.install()
        let st = try SwiftTermProbeHost()
        let gh = try GhosttyProbeHost()
        defer { st.close(); gh.close() }
        try await gh.waitUntilReady()
        st.view.feed(text: "$ ")
        gh.feedAndWait("$ ")
        try await Task.sleep(for: .milliseconds(500))

        for kind in [Kind.swiftterm, .ghostty] {
            var latencies: [Double] = []
            for index in 0..<40 {
                // 随机落在显示节拍里的任意相位。
                try await Task.sleep(for: .milliseconds(60 + index % 7 * 3))
                resetFrames()
                let t0 = CACurrentMediaTime()
                let char = String(UnicodeScalar(UInt8(97 + index % 26)))
                switch kind {
                case .swiftterm: st.view.feedPaced(ArraySlice(Array(char.utf8)), backlogged: false)
                case .ghostty: gh.bridge.feed(Data(char.utf8))
                }
                while frameTimes(kind).isEmpty, CACurrentMediaTime() - t0 < 0.5 {
                    try await Task.sleep(for: .microseconds(500))
                }
                if let first = frameTimes(kind).first { latencies.append((first - t0) * 1000) }
            }
            print(String(format: "SPIKE %@/echo n=%d p50=%.2fms p95=%.2fms max=%.2fms",
                         kind.rawValue, latencies.count, ProbeMetrics.percentile(latencies, 0.5),
                         ProbeMetrics.percentile(latencies, 0.95), latencies.max() ?? 0))
            XCTAssertEqual(latencies.count, 40, "\(kind) 有回显没出帧")
        }
    }

    private func inkOfWindow(_ window: UIWindow) -> Double {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        return image.cgImage.map(VisionTextProbe.inkFraction) ?? 0
    }
}

/// 数 SwiftTerm 报了几次网格尺寸（= 远端会收到几次 SIGWINCH，`TerminalInputChannel` 还会去重）。
private final class SizeChangeCounter: TerminalViewDelegate {
    var count = 0
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { count += 1 }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}
