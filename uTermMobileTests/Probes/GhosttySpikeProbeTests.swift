import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// GhosttyKit 终端在固定场景（393×760、11pt、暗色配色）下的开销读数。读数、方法与环境见 docs/ghostty-eval/ios-spike.md。
///
/// 换引擎之前每个场景都在同一次运行里和旧引擎对照着比；旧引擎的视图类删掉之后只剩 Ghostty 这一列
///（打印行里的 `ghostty/` 前缀留着，和 ios-spike.md 里的历史读数同一个格式），对照组的历史读数在那份文档里。
///
/// 口径：
/// - CPU 按**线程**量（`ThreadCPU`）：主线程用 `CLOCK_THREAD_CPUTIME_ID`，其余线程用 `THREAD_EXTENDED_INFO`。
///   Ghostty 解析在自己的串行队列、渲染线程更新帧、主线程 tick + Metal 提交，只量主线程会把它算得太便宜。
///   每条终端另有一个影子终端在喂字节的那条线程上同步解析（探针里是主线程），它的开销也在这些读数里。
/// - 帧：数 `IOSurfaceLayer.setContents:`（真正交给 Core Animation 的帧）。
/// - 参考节拍：一个独立的 `CADisplayLink`，间隔超过标称 1.5 倍记一次卡顿（= 主线程被占住）。
/// - 模拟器：GPU 是 Mac 的，Metal 的 GPU 时间不在这些线程里；`docs` 里有真机版跑法。
/// 闸门只放结构判据（帧确实交出去了、看不见时不画），不卡绝对毫秒。
@MainActor
final class GhosttySpikeProbeTests: XCTestCase {
    private struct Reading {
        let label: String
        let seconds: Double
        let ticks: Int
        let hitches: Int
        let frames: Int
        let doubleFrameTicks: Int
        let cpu: ThreadCPU.Delta
        var raw = ""

        var line: String {
            let perFrame = frames > 0 ? cpu.totalMS / Double(frames) : 0
            return String(format: "SPIKE %@ secs=%.1f ticks=%d hitch=%d frames=%d double=%d "
                          + "cpu-total=%.1fms(%.1f%%) main=%.1fms(%.1f%%) other=%.1fms per-frame=%.2fms | %@",
                          label, seconds, ticks, hitches, frames, doubleFrameTicks,
                          cpu.totalMS, cpu.totalMS / seconds / 10, cpu.mainMS, cpu.mainMS / seconds / 10, cpu.otherMS,
                          perFrame, cpu.line) + raw
        }
    }

    private func frameTimes() -> [Double] { GhosttyPresentLog.read().times }

    private func resetFrames() { GhosttyPresentLog.reset() }

    /// 量一段：`onTick` 每个显示节拍跑一次（驱动输出 / 滚动），`every100ms` 每 100ms 跑一次。
    private func measure(_ label: String, seconds: Double,
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
        let frames = frameTimes()
        var doubled = 0
        for (a, b) in zip(tickTimes, tickTimes.dropFirst()) where frames.filter({ $0 >= a && $0 < b }).count > 1 {
            doubled += 1
        }
        let nominal = counter.nominalIntervalMS
        let raw = GhosttyPresentLog.rawCounts()
        return Reading(label: "ghostty/\(label)", seconds: seconds, ticks: counter.ticks,
                       hitches: counter.intervals.filter { $0 > nominal * 1.5 }.count,
                       frames: frames.count, doubleFrameTicks: doubled,
                       cpu: ThreadCPU.delta(from: start, to: end, mainID: mainID),
                       raw: " | setContents raw=\(raw.calls) nil=\(raw.nils)")
    }

    // MARK: 稳态：空闲 / Claude 思考 / 整屏刷新

    /// 三档稳态，各跑两轮（看机器负载漂移）。
    func testSteadyStateCost() async throws {
        let gh = try GhosttyProbeHost()
        defer { gh.close() }
        try await gh.waitUntilReady()
        print("SPIKE grid ghostty=\(gh.grid) scale=\(gh.view.window?.screen.nativeScale ?? 0)")

        // 先铺一屏 Claude 跑过一阵的内容。
        let cols = gh.grid.cols, rows = gh.grid.rows
        gh.feedAndWait(TerminalSpikeCorpus.history(lines: 200, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols))
        try await Task.sleep(for: .milliseconds(500))

        func feed(_ text: String) { gh.bridge.feed(Data(text.utf8)) }
        var readings: [Reading] = []
        for round in 0..<2 {
            readings.append(try await measure("idle#\(round)", seconds: 3))
            readings.append(try await measure("claude-10fps#\(round)", seconds: 4, every100ms: { n in
                feed(TerminalSpikeCorpus.claudeFrame(n + 1, cols: cols))
            }))
            // 每个显示节拍整屏都变：`top` / 全屏 TUI 重绘的上界。
            readings.append(try await measure("fullscreen-vsync#\(round)", seconds: 4, onTick: { n in
                feed("\u{1B}[?2026h" + TerminalSpikeCorpus.screen(rows: rows, salt: n) + "\u{1B}[?2026l")
            }))
            // 回到同一屏，下一档从一样的状态开始。
            feed(TerminalSpikeCorpus.history(lines: 40, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols))
            try await Task.sleep(for: .milliseconds(300))
        }
        for reading in readings { print(reading.line) }

        let claude = readings.filter { $0.label.contains("ghostty/claude") }
        XCTAssertTrue(claude.allSatisfy { $0.frames >= 20 }, "有输出时没交帧：\(claude.map(\.frames))")
        let full = readings.filter { $0.label.contains("ghostty/fullscreen") }
        XCTAssertTrue(full.allSatisfy { $0.frames > 60 }, "整屏刷新时没交帧：\(full.map(\.frames))")
        gh.bridge.session.waitForPendingOutput()
        XCTAssertTrue(gh.viewportText.contains("App/File"), "内容没落到屏上：\(gh.viewportText.prefix(200))")
    }

    // MARK: 大量输出

    /// `cat` 2MB：按 16KB 一块尽快喂（`GhosttyTerminalBridge.feed`：影子在喂的线程上同步解析，surface 入队后在自己的
    /// 串行队列上解析）。量从第一块到「最后一行出现在屏上」的墙钟时间与各线程 CPU。
    func testFloodThroughput() async throws {
        let payload = TerminalSpikeCorpus.flood(bytes: 2 * 1024 * 1024)
        let marker = "FLOOD-END-MARKER"
        let tail = Data("\r\n\(marker)\r\n".utf8)
        let chunks = stride(from: 0, to: payload.count, by: 16 * 1024).map {
            payload.subdata(in: $0..<min(payload.count, $0 + 16 * 1024))
        } + [tail]

        for round in 0..<2 {
            let gh = try GhosttyProbeHost()
            defer { gh.close() }
            try await gh.waitUntilReady()
            try await Task.sleep(for: .milliseconds(200))
            resetFrames()
            let fed0 = gh.bridge.shadow.totalFedBytes
            let mainID = ThreadCPU.currentThreadID()
            let cpu0 = ThreadCPU.snapshot()
            let t0 = CACurrentMediaTime()
            // 模拟网络读：块之间不等，在后台线程上喂（生产的入站任务也不在主线程）。
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
            XCTAssertNotNil(parsedAt, "30 秒内没解析完 2MB")
            // 核对没丢字节：影子吃到的字节数 = 喂进去的；surface 的回滚行数到了语料行数或回滚上限（生产配置 1 万行，
            // 2MB 语料两万多行，装不下全部）。最后一屏 surface 和影子逐行比的结果只打印（逐行比的闸门在影子探针里）。
            let lines = payload.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            let fed = gh.bridge.shadow.totalFedBytes - fed0
            let expectedRows = min(lines, GhosttyTerminalBridge.scrollbackLines)
            let diff = GhosttyViewportDiff.firstDifference(surface: gh.viewportText, shadow: gh.bridge.shadow.viewportText())
            print("SPIKE ghostty/flood lines=\(lines) fed=\(fed)B scrollback-total=\(gh.scrollbar?.total ?? 0) shadow-rows=\(gh.bridge.shadow.totalRows) surface-matches-shadow=\(diff ?? "true") raw-setContents=\(GhosttyPresentLog.rawCounts())")
            XCTAssertEqual(fed, payload.count + tail.count, "影子吃到的字节数和喂进去的不一样")
            XCTAssertGreaterThanOrEqual(Int(gh.scrollbar?.total ?? 0), expectedRows, "surface 的回滚行数少于该有的：丢了字节")
        }
    }

    // MARK: 边输出边滚动

    /// 视口在靠底部的两屏里往返（每个显示节拍把这一拍的位移当 precision 滚动发给 surface，同 GhosttyKit 自己的拖动手势），
    /// 同时每 100ms 来一个 Claude 帧。看两件事：每个滚动帧都画了没有（帧数 ≈ 节拍数），一个节拍里有没有画两遍。
    /// 手指真的拖 `UIScrollView` 的那条系统滚动路径不在这里量（见滚动类探针）。
    func testScrollWhileOutput() async throws {
        let gh = try GhosttyProbeHost()
        defer { gh.close() }
        try await gh.waitUntilReady()
        gh.feedAndWait(TerminalSpikeCorpus.history(lines: 400, cols: gh.grid.cols) + TerminalSpikeCorpus.claudeFrame(0, cols: gh.grid.cols))
        try await Task.sleep(for: .milliseconds(400))
        let scale = gh.view.window?.screen.nativeScale ?? 3

        var readings: [Reading] = []
        var ghostOffsets: [UInt64] = []
        for round in 0..<2 {
            for output in [false, true] {
                let label = output ? "scroll+output#\(round)" : "scroll#\(round)"
                let height = Double(gh.view.bounds.height)
                var last = 0.0
                let cols = gh.grid.cols
                let pixelScale = Double(scale)
                let scroll: @MainActor (Int) -> Void = { step in
                    let phase = 0.5 * (1 - cos(Double(step % 120) / 120 * 2 * .pi))
                    let y = height * 2 * phase
                    gh.view.sendMouseScroll(x: 0, y: (y - last) * pixelScale)
                    last = y
                    if step % 10 == 0, let bar = gh.scrollbar { ghostOffsets.append(bar.offset) }
                }
                let emit: @MainActor (Int) -> Void = { n in
                    gh.bridge.feed(Data(TerminalSpikeCorpus.claudeFrame(n + 1, cols: cols).utf8))
                }
                readings.append(try await measure(label, seconds: 4, onTick: scroll, every100ms: output ? emit : nil))
                gh.view.sendMouseScroll(x: 0, y: -last * Double(scale))
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        for reading in readings { print(reading.line) }
        print("SPIKE ghostty scrollbar offsets sampled=\(Set(ghostOffsets).sorted().prefix(40)) total=\(gh.scrollbar?.total ?? 0) len=\(gh.scrollbar?.len ?? 0)")
        XCTAssertGreaterThan(Set(ghostOffsets).count, 5, "视口没跟着滚动量动，量的是静止画面")
        for reading in readings {
            XCTAssertGreaterThan(reading.frames, reading.ticks / 2, "\(reading.label) 滚动时大半节拍没交帧")
        }
    }

    // MARK: 看不见的终端

    /// 后台标签：`setSurfaceVisible(false)` 停画（`GhosttyTerminalBridge.setOnScreen(false)` 当场做的就是这一步；
    /// 隔 `hiddenReleaseDelay` 放掉 surface 的那一半见 `GhosttyBackgroundTests`）。
    /// 停着的时候照常喂 Claude 帧：不该交任何帧；字节照常解析（surface 和影子都是）；露出来补一帧且是最新内容。
    func testHiddenTerminalStopsDrawing() async throws {
        let gh = try GhosttyProbeHost()
        defer { gh.close() }
        try await gh.waitUntilReady()
        gh.feedAndWait(TerminalSpikeCorpus.history(lines: 50, cols: gh.grid.cols))
        try await Task.sleep(for: .milliseconds(300))

        gh.view.setSurfaceVisible(false)
        try await Task.sleep(for: .milliseconds(100))
        let hidden = try await measure("hidden-claude-10fps", seconds: 3, every100ms: { n in
            gh.bridge.feed(Data(TerminalSpikeCorpus.claudeFrame(n + 1, cols: gh.grid.cols).utf8))
        })
        print(hidden.line)
        XCTAssertEqual(hidden.frames, 0, "隐藏后仍在交帧")

        gh.feedAndWait("\r\nHIDDEN-MARKER")
        XCTAssertTrue(gh.viewportText.contains("HIDDEN-MARKER"), "隐藏期间 surface 要照常解析字节")
        XCTAssertTrue(gh.bridge.shadow.viewportText().contains("HIDDEN-MARKER"), "隐藏期间影子要照常解析字节")
        resetFrames()
        gh.view.setSurfaceVisible(true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(GhosttyPresentLog.read().times.count, 0, "露出来要补一帧")
    }

    // MARK: 转屏：重排、SIGWINCH 次数、闪烁

    /// 393×760 ↔ 760×393 来回三次。每次改尺寸后 700ms 内逐帧（显示节拍）截窗口：
    /// 墨迹比例掉到稳态的一半以下记一次「闪白 / 空帧」；同时记网格变了几次、远端会收到几次尺寸。
    /// 视图直接跟着窗口变（不经 `MTerminalContainerView` 的「停稳再提交」），量的是终端自己重排的代价。
    func testRotationReflowAndFlicker() async throws {
        let portrait = CGSize(width: 393, height: 760), landscape = CGSize(width: 760, height: 393)

        let gh = try GhosttyProbeHost(size: portrait)
        defer { gh.close() }
        try await gh.waitUntilReady()
        gh.feedAndWait(TerminalSpikeCorpus.history(lines: 300, cols: gh.grid.cols) + "$ echo 转屏测试 \u{1B}[1mbold\u{1B}[0m")
        let window = gh.window
        func grid() -> String { "\(gh.grid.cols)x\(gh.grid.rows)" }
        func reports() -> Int { gh.bridge.resizeReports }

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
            frames += frameTimes().count
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
                     "ghostty", grids.description, reports() - reports0, frames, cpu,
                     settleMS.map { String(format: "%.0f", $0) }.joined(separator: "/"), minRatio, dips))
        XCTAssertEqual(grids.last, grids.first, "转回竖屏后网格没回到原样")
        // 影子跟着 surface 的终端报的尺寸走：转完两边的网格要一样，最后一屏逐行一致。
        gh.bridge.session.waitForPendingOutput()
        let shadowSize = gh.bridge.shadow.size
        XCTAssertEqual("\(shadowSize.cols)x\(shadowSize.rows)", grid(), "转屏之后影子的网格和 surface 的不一样")
    }

    // MARK: 回显延迟

    /// 远端回显一个字符到它被交给 Core Animation 的时间（不含合成与上屏）。
    /// `feed` → 影子同步解析 + surface 串行队列解析 → 唤醒 → 主线程重画 → present。
    func testEchoLatency() async throws {
        let gh = try GhosttyProbeHost()
        defer { gh.close() }
        try await gh.waitUntilReady()
        gh.feedAndWait("$ ")
        try await Task.sleep(for: .milliseconds(500))

        var latencies: [Double] = []
        for index in 0..<40 {
            // 随机落在显示节拍里的任意相位。
            try await Task.sleep(for: .milliseconds(60 + index % 7 * 3))
            resetFrames()
            let t0 = CACurrentMediaTime()
            let char = String(UnicodeScalar(UInt8(97 + index % 26)))
            gh.bridge.feed(Data(char.utf8))
            while frameTimes().isEmpty, CACurrentMediaTime() - t0 < 0.5 {
                try await Task.sleep(for: .microseconds(500))
            }
            if let first = frameTimes().first { latencies.append((first - t0) * 1000) }
        }
        print(String(format: "SPIKE %@/echo n=%d p50=%.2fms p95=%.2fms max=%.2fms",
                     "ghostty", latencies.count, ProbeMetrics.percentile(latencies, 0.5),
                     ProbeMetrics.percentile(latencies, 0.95), latencies.max() ?? 0))
        XCTAssertEqual(latencies.count, 40, "有回显没出帧")
    }

    private func inkOfWindow(_ window: UIWindow) -> Double {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        return image.cgImage.map(VisionTextProbe.inkFraction) ?? 0
    }
}
