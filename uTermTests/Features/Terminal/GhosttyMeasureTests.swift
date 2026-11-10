import AppKit
import Carbon.HIToolbox
import CoreText
import IOSurface
import QuartzCore
import XCTest
import GhosttyTerminal
import SwiftTerm
@testable import uTerm

/// GhosttyKit 迁移的「测量门」（`docs/ghostty-migration-plan.md` §3，报告 `docs/ghostty-eval/measure-macos.md`）。
///
/// 默认全部跳过：要 `TEST_RUNNER_GHOSTTY_MEASURE=1` 才跑。M14 会临时切系统输入法、动系统剪贴板（跑完还原），
/// M1 / M7 会一次开 20 个窗口，都不适合进日常全量。读数一律打到标准输出，行首 `[GhosttyMeasure]`。
@MainActor
final class GhosttyMeasureTests: XCTestCase {

    override func setUp() async throws {
        try XCTSkipUnless(MeasureEnv.enabled, "测量用例：TEST_RUNNER_GHOSTTY_MEASURE=1 才跑")
    }

    private func log(_ s: String) { print("[GhosttyMeasure] " + s) }

    private func loadavg() -> String {
        var a = [Double](repeating: 0, count: 3)
        getloadavg(&a, 3)
        return String(format: "%.2f %.2f %.2f", a[0], a[1], a[2])
    }

    @discardableResult
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    private func stats(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n=0" }
        let mean = values.reduce(0, +) / Double(values.count)
        return String(format: "n=%d p50=%.2f p95=%.2f max=%.2f mean=%.2f min=%.2f", values.count,
                      ProbeMetrics.percentile(values, 0.5), ProbeMetrics.percentile(values, 0.95),
                      values.max() ?? 0, mean, values.min() ?? 0)
    }

    /// 测量用的独立 Ghostty app（只在 M1 用：要换 scrollback-limit，又不想动 `GhosttyTerminalConfig.controller`）。
    private static func makeController(lines: Int, bytes: String, compression: String) -> GhosttyTerminal.TerminalController {
        let base = GhosttyTerminalConfig.base(settings: TerminalSettings.read())
        let config = GhosttyTerminal.TerminalConfiguration(startingFrom: base) { b in
            b.withCustom("scrollback-limit-lines", String(lines))
            if bytes != "default" { b.withCustom("scrollback-limit-bytes", bytes) }
            if compression != "default" { b.withCustom("scrollback-compression", compression) }
            b.withCursorStyleBlink(false)
        }
        return GhosttyTerminal.TerminalController(configSource: .none, theme: GhosttyTerminalConfig.theme(),
                                                  terminalConfiguration: config)
    }

    /// 外部工具读数的握手：打一行 READY，等外部脚本在同步目录里放 `done-<label>`（或超时）。
    private func holdForExternalTools(_ label: String, seconds: Double) async {
        guard seconds > 0 else { return }
        log("READY pid=\(getpid()) label=\(label)")
        fflush(stdout)
        let marker = (MeasureEnv.syncDirectory ?? "/nonexistent") + "/done-\(label)"
        let ok = await waitUntil(seconds) { FileManager.default.fileExists(atPath: marker) }
        log("RESUME label=\(label) externalDone=\(ok)")
    }

    // MARK: - M1 内存构成

    /// 1 / 6 / 20 个窗格 × 回滚 N 行（填满）。一个进程只量一种配置（`M1_ENGINE` / `M1_PANES` / `M1_LINES`），
    /// 分步打快照：建 app 对象 → 第一个空窗格 → N 个空窗格 → 填满回滚 → 各种降内存的做法。
    func testM1Memory() async throws {
        let engine = try XCTUnwrap(MeasurePane.Engine(rawValue: MeasureEnv.string("M1_ENGINE", "ghostty")))
        let paneCount = MeasureEnv.int("M1_PANES", 1)
        let lines = MeasureEnv.int("M1_LINES", 10_000)
        let content = MeasureEnv.string("M1_CONTENT", "typical")
        // Ghostty 的字节上限：unlimited（只按行数限）/ default（默认 50 MB）/ 具体字节数。
        let limitMode = MeasureEnv.string("M1_GH_LIMIT", "unlimited")
        let compression = MeasureEnv.string("M1_GH_COMPRESSION", "default")
        let hold = MeasureEnv.double("M1_HOLD", 0)
        let variants = MeasureEnv.string("M1_VARIANTS", "1") == "1"
        let label = "\(engine.rawValue)-\(paneCount)x\(lines)-\(content)-\(limitMode)-cmp\(compression)"
        let size = NSRect(x: 0, y: 0, width: 800, height: 500)
        let isGhostty = engine != .swiftterm
        log("M1 start label=\(label) loadavg=\(loadavg()) screenScale=\(NSScreen.main?.backingScaleFactor ?? 0)")
        await sleep(1.0)

        let s0 = MemSnapshot.take()
        log("M1 \(label) s0 \(s0.line)")
        var controller: GhosttyTerminal.TerminalController?
        if isGhostty {
            controller = Self.makeController(lines: lines, bytes: limitMode, compression: compression)
            await sleep(0.5)
        }
        let s1 = MemSnapshot.take()
        log("M1 \(label) step=app-object \(s1.delta(from: s0))")

        var panes: [MeasurePane] = []
        var firstPane: MemSnapshot?
        for i in 0..<paneCount {
            let pane = MeasurePane(engine: engine, frame: size, controller: controller, scrollbackLines: lines)
            pane.window = ProbeWindow.make(contentRect: size, contentView: pane.view, placement: .transparentOnScreen,
                                           onScreenOrigin: NSPoint(x: 40 + (i % 5) * 40, y: 40 + (i / 5) * 40))
            let ready = await waitUntil(10) { pane.isReady }
            XCTAssertTrue(ready, "窗格 \(i) 没建好")
            pane.attachWatchIfNeeded()
            pane.feed(ArraySlice(Array("user@host ~ % ".utf8)))
            if let st = pane.swiftTerm, engine == .swiftterm { st.flushPendingDisplay(); st.displayIfNeeded() }
            _ = await waitUntil(5) { pane.frames > 0 }
            panes.append(pane)
            if i == 0 {
                await sleep(3.0)
                let s = MemSnapshot.take(includeMetal: isGhostty)
                firstPane = s
                log("M1 \(label) step=first-empty-pane \(s.delta(from: s1)) frames=\(pane.frames) offMainKVO=\(pane.watch?.offMainCount ?? -1)")
            }
        }
        await sleep(3.0)
        let s3 = MemSnapshot.take(includeMetal: isGhostty)
        if let firstPane, paneCount > 1 {
            log(String(format: "M1 %@ step=%d-empty-panes %@ perExtraPane=%.1fMB", label, paneCount, s3.delta(from: s1),
                       (s3.footprint - firstPane.footprint) / Double(paneCount - 1)))
        }

        // 填满回滚：每格不折行，行数 = 回滚 + 屏 + 余量。
        let grid = panes[0].engine == .swiftterm
            ? (cols: panes[0].swiftTerm!.getTerminal().cols, rows: panes[0].swiftTerm!.getTerminal().rows)
            : (cols: Int(panes[0].viewport.value?.columns ?? 100), rows: Int(panes[0].viewport.value?.rows ?? 30))
        let total = lines + grid.rows + 10
        let t0 = CACurrentMediaTime()
        let payload = content == "heavy"
            ? MeasureLoad.heavyLines(count: total)
            : MeasureLoad.typicalLines(count: total, cols: grid.cols - 2)
        log(String(format: "M1 %@ payload lines=%d bytes=%.1fMB grid=%dx%d gen=%.2fs", label, total,
                   Double(payload.count) / 1_048_576, grid.cols, grid.rows, CACurrentMediaTime() - t0))
        let fillStart = CACurrentMediaTime()
        let chunk = 1 << 20
        for pane in panes {
            var offset = 0
            while offset < payload.count {
                if isGhostty { _ = await waitUntil(60) { pane.pending < 8 << 20 } }
                let end = min(offset + chunk, payload.count)
                pane.feed(payload[offset..<end])
                offset = end
            }
        }
        _ = await waitUntil(300) { panes.allSatisfy { $0.pending == 0 } }
        for pane in panes where engine == .swiftterm { pane.swiftTerm?.flushPendingDisplay(); pane.swiftTerm?.displayIfNeeded() }
        let fillSeconds = CACurrentMediaTime() - fillStart
        await sleep(2.0)
        let s4early = MemSnapshot.take(includeMetal: isGhostty)
        log("M1 \(label) step=filled+2s \(s4early.delta(from: s3))")
        // Ghostty 空闲时才压缩回滚页：再等一会儿看压缩之后。
        await sleep(8.0)
        let s4 = MemSnapshot.take(includeMetal: isGhostty)
        let retained = panes.map { $0.scrollbackRows ?? -1 }
        let perLineBytes = (s4.footprint - s3.footprint) * 1_048_576 / Double(paneCount * max(1, lines))
        log(String(format: "M1 %@ step=filled+10s %@ fill=%.2fs retainedRows=%@ bytesPerRetainedLine=%.0f", label,
                   s4.delta(from: s3), fillSeconds, String(describing: Array(retained.prefix(3))), perLineBytes))
        log(String(format: "M1 %@ TOTAL vs baseline %@ | totalΔfp=%.1fMB", label, s4.delta(from: s0), s4.footprint - s0.footprint))

        await holdForExternalTools(label, seconds: hold)

        guard variants else { return }
        var rest = Array(panes.dropFirst())
        if isGhostty, !rest.isEmpty {
            rest.forEach { $0.setVisible(false) }
            await sleep(2.0)
            let v1 = MemSnapshot.take(includeMetal: true)
            log("M1 \(label) variant=hidden(setSurfaceVisible false, \(rest.count) panes) \(v1.delta(from: s4))")
            rest.forEach { $0.setVisible(true) }
            rest.forEach { $0.window?.orderOut(nil) }
            await sleep(2.0)
            let v2 = MemSnapshot.take(includeMetal: true)
            log("M1 \(label) variant=window-orderOut \(v2.delta(from: s4))")
            rest.forEach { $0.detachFromWindow() }
            await sleep(2.0)
            let v3 = MemSnapshot.take(includeMetal: true)
            log("M1 \(label) variant=view-detached(surface kept) \(v3.delta(from: s4))")
        }
        if !rest.isEmpty {
            let count = rest.count
            rest.forEach { $0.dispose() }
            // 两个数组都放掉，视图（以及 Ghostty 的 surface）才会真的释放。
            rest.removeAll()
            panes = [panes[0]]
            await sleep(3.0)
            let v4 = MemSnapshot.take(includeMetal: isGhostty)
            log("M1 \(label) variant=released(\(count) panes) \(v4.delta(from: s4))")
        }
        if isGhostty, let controller {
            // 把回滚上限降到 1/10：已有的回滚会不会被裁掉。
            let before = MemSnapshot.take(includeMetal: true)
            let smaller = max(100, lines / 10)
            let base = GhosttyTerminalConfig.base(settings: TerminalSettings.read())
            controller.setTerminalConfiguration(GhosttyTerminal.TerminalConfiguration(startingFrom: base) { b in
                b.withCustom("scrollback-limit-lines", String(smaller))
                b.withCursorStyleBlink(false)
            })
            await sleep(2.0)
            let v5 = MemSnapshot.take(includeMetal: true)
            log("M1 \(label) variant=lines-limit-lowered-to-\(smaller) \(v5.delta(from: before)) retainedRows=\(panes[0].scrollbackRows ?? -1)")
            let more = MeasureLoad.typicalLines(count: 2_000, cols: grid.cols - 2, seed: 7)
            panes[0].feed(more[...])
            _ = await waitUntil(30) { panes[0].pending == 0 }
            await sleep(2.0)
            let v6 = MemSnapshot.take(includeMetal: true)
            log("M1 \(label) variant=limit-lowered+2000-more-lines \(v6.delta(from: before)) retainedRows=\(panes[0].scrollbackRows ?? -1)")
        }
        panes.forEach { $0.dispose() }
    }

    // MARK: - M6 打字回显延迟

    /// 真键盘事件（`NSEvent.keyEvent` → 窗口 `sendEvent`）→ 后端本地回环原样 echo → 出帧。
    ///
    /// - bare：没有 `TerminalSession`。SwiftTerm 的 `send` 回调里直接 `feed`；Ghostty 的 write 回调里直接 `receive`。
    /// - session：真 `TerminalSession` + `EchoBackend`：输入走 `TerminalInputChannel`，回显走输出泵
    ///   （Ghostty 是 spike 的形态：先喂影子 SwiftTerm，再转给 Ghostty）。
    ///
    /// 出帧：Ghostty 以 IOSurface 设成图层 contents、且光标已经移到下一格为准；SwiftTerm 以 `draw(_:)` 返回、
    /// 且缓冲区光标已经过了这一格为准。
    func testM6EchoLatency() async throws {
        let samples = MeasureEnv.int("M6_SAMPLES", 60)
        let rounds = MeasureEnv.int("M6_ROUNDS", 3)
        let configs = MeasureEnv.string("M6_CONFIGS", "swiftterm-bare,ghostty-bare,ghostty-bare-novsync,swiftterm-session,ghostty-session")
            .split(separator: ",").map(String.init)
        log("M6 start loadavg=\(loadavg()) samples=\(samples)x\(rounds) screenMaxFPS=\(ProbeWindow.fastestScreen?.maximumFramesPerSecond ?? 0)")
        let cell = try await ghosttyCellPixels()
        log("M6 ghostty cell px=\(cell.w)x\(cell.h)")
        var all: [String: [Double]] = [:]
        var breakdown: [String: [String: [Double]]] = [:]
        for round in 0..<rounds {
            let order = round % 2 == 0 ? configs : configs.reversed()
            for config in order {
                let r = try await runEcho(config, samples: samples, cell: cell)
                all[config, default: []] += r.latencies
                for (k, v) in r.parts { breakdown[config, default: [:]][k, default: []] += v }
                log("M6 round=\(round) config=\(config) \(stats(r.latencies)) misses=\(r.misses)")
            }
        }
        for config in configs {
            log("M6 RESULT config=\(config) latency(ms) \(stats(all[config] ?? []))")
            for (k, v) in (breakdown[config] ?? [:]).sorted(by: { $0.key < $1.key }) {
                log("M6 RESULT config=\(config) part=\(k)(ms) \(stats(v))")
            }
        }
        log("M6 end loadavg=\(loadavg())")
    }

    /// 同一份 Ghostty 配置下的格子像素（从一个临时 surface 的 resize 回调读）。
    private func ghosttyCellPixels() async throws -> (w: Int, h: Int) {
        let pane = MeasurePane(engine: .ghostty, frame: NSRect(x: 0, y: 0, width: 400, height: 200), controller: nil, scrollbackLines: 100)
        pane.window = ProbeWindow.make(contentRect: pane.view.frame, contentView: pane.view, placement: .transparentOnScreen)
        defer { pane.dispose() }
        _ = await waitUntil(10) { pane.viewport.value != nil }
        let v = try XCTUnwrap(pane.viewport.value)
        let pt = try XCTUnwrap(GhosttyGeometry.cellPoints(try XCTUnwrap(pane.ghostty)))
        let scale = pane.window!.backingScaleFactor
        log("ghostty viewport=\(v) cellPt=\(pt) scale=\(scale)")
        return (Int((pt.width * scale).rounded()), Int((pt.height * scale).rounded()))
    }

    private nonisolated final class TimeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CFTimeInterval?
        var value: CFTimeInterval? { lock.withLock { stored } }
        func setIfEmpty(_ t: CFTimeInterval) { lock.withLock { if stored == nil { stored = t } } }
        func reset() { lock.withLock { stored = nil } }
    }

    private func runEcho(_ config: String, samples: Int, cell: (w: Int, h: Int)) async throws
        -> (latencies: [Double], parts: [String: [Double]], misses: Int) {
        let rect = NSRect(x: 0, y: 0, width: 800, height: 500)
        let isGhostty = config.hasPrefix("ghostty")
        let isSession = config.hasSuffix("session")
        defer {
            if config.hasSuffix("novsync") {
                GhosttyTerminalConfig.controller.setTerminalConfiguration(GhosttyTerminalConfig.base(settings: TerminalSettings.read()))
            }
        }
        var window: NSWindow!
        var keyTarget: NSView!
        var session: TerminalSession?
        var backend: EchoBackend?
        var stView: SwiftTerm.TerminalView?
        var ghView: GhosttySurfaceView?
        var bareIO: InMemoryTerminalSession?
        var barePane: MeasurePane?
        let echoDelegate = ProbeTerminalDelegate()
        let writeTime = TimeBox(), backendTime = TimeBox()
        var drawHit: CFTimeInterval?
        var pendingCol: Int?

        if isSession {
            let s = TerminalSession()
            session = s
            let b = EchoBackend()
            b.onWrite = { _ in backendTime.setIfEmpty(CACurrentMediaTime()) }
            backend = b
            if isGhostty {
                let bridge = s.enableGhostty()
                let container = GhosttyContainerView(surface: bridge.view)
                container.isActive = true
                window = ProbeWindow.make(contentRect: rect, contentView: container, placement: .transparentOnScreen)
                container.frame = window.contentView?.bounds ?? rect
                container.layoutSubtreeIfNeeded()
                _ = await waitUntil(10) { bridge.isLive && bridge.grid != nil }
                bridge.onWriteForTesting = { _ in writeTime.setIfEmpty(CACurrentMediaTime()) }
                ghView = bridge.view
            } else {
                window = ProbeWindow.make(contentRect: rect, contentView: s.terminalView, placement: .transparentOnScreen)
                stView = s.terminalView
            }
            await s.connect(using: b)
        } else if isGhostty {
            // ghostty-bare-novsync：window-vsync = false（Ghostty 文档：降低输入延迟、代价是可能撕裂；只影响新 surface）。
            let controller = GhosttyTerminalConfig.controller
            if config.hasSuffix("novsync") {
                controller.setTerminalConfiguration(GhosttyTerminal.TerminalConfiguration(
                    startingFrom: GhosttyTerminalConfig.base(settings: TerminalSettings.read())) { $0.withCustom("window-vsync", "false") })
            }
            let pane = MeasurePane(engine: .ghostty, frame: rect, controller: controller, scrollbackLines: 1000)
            let ioBox = pane.ioBox
            ioBox.onWrite = { data in
                writeTime.setIfEmpty(CACurrentMediaTime())
                ioBox.io?.receive(data)
            }
            window = ProbeWindow.make(contentRect: rect, contentView: pane.view, placement: .transparentOnScreen)
            _ = await waitUntil(10) { pane.viewport.value != nil }
            ghView = pane.ghostty
            bareIO = pane.io
            barePane = pane
        } else {
            let st = CopyableTerminalView(frame: rect)
            TerminalTheme.apply(to: st, settings: TerminalSettings.read(), dark: true)
            echoDelegate.onSend = { [weak st] data in st?.feed(byteArray: data) }
            st.terminalDelegate = echoDelegate
            window = ProbeWindow.make(contentRect: rect, contentView: st, placement: .transparentOnScreen)
            stView = st
        }
        keyTarget = ghView ?? stView
        window.makeFirstResponder(keyTarget)
        defer {
            if let stView { SwiftTermDrawProbe.unhook(stView) }
            session?.dispose()
            barePane?.dispose()
            window.orderOut(nil)
        }

        var watch: GhosttyFrameWatch?
        if let ghView {
            _ = await waitUntil(5) { GhosttyFrameWatch.contentLayer(of: ghView) != nil }
            watch = GhosttyFrameWatch(layer: try XCTUnwrap(GhosttyFrameWatch.contentLayer(of: ghView)))
        }
        if let stView {
            SwiftTermDrawProbe.hook(stView) { v in
                guard drawHit == nil, let col = pendingCol else { return }
                let cursor = v.getTerminal().getCursorLocation()
                if cursor.y == 0, cursor.x > col { drawHit = CACurrentMediaTime() }
            }
        }

        func emit(_ s: String) {
            let bytes = Array(s.utf8)
            if let backend { backend.emit(Data(bytes)) }
            else if let bareIO { bareIO.receive(Data(bytes)) }
            else { stView?.feed(byteArray: bytes[...]) }
        }

        let letters: [Character] = Array("asdfghjkl")
        var latencies: [Double] = []
        var parts: [String: [Double]] = [:]
        var misses = 0
        var i = 0
        let perLine = 30
        while latencies.count + misses < samples {
            if i % perLine == 0 {
                emit("\u{1B}[2J\u{1B}[H$ ")
                await sleep(0.2)
            }
            let col = 2 + i % perLine
            let ch = letters[i % letters.count]
            i += 1
            writeTime.reset(); backendTime.reset(); drawHit = nil
            pendingCol = col
            if let watch {
                let x = (col + 1) * cell.w, w = cell.w, h = cell.h
                watch.arm { surface in SurfacePixels.inkFraction(surface, x: x, y: 0, width: w, height: h) > 0.03 }
            }
            let t0 = CACurrentMediaTime()
            RealEvents.press(window: window, characters: String(ch), keyCode: RealEvents.keyCode(for: ch))
            let hit = await waitUntil(1.0) { (watch?.hitTime ?? drawHit) != nil }
            pendingCol = nil
            watch?.disarm()
            if hit, let t1 = watch?.hitTime ?? drawHit {
                latencies.append((t1 - t0) * 1000)
                if let w = writeTime.value { parts["event→ghosttyWrite", default: []].append((w - t0) * 1000) }
                if let b = backendTime.value { parts["event→backendWrite", default: []].append((b - t0) * 1000) }
                if let b = backendTime.value { parts["backendWrite→frame", default: []].append((t1 - b) * 1000) }
                else if let w = writeTime.value { parts["ghosttyWrite→frame", default: []].append((t1 - w) * 1000) }
            } else {
                misses += 1
            }
            // 30–60 ms 的随机间隔：不与显示器节拍锁相。
            await sleep(0.03 + Double((i * 7919) % 31) / 1000)
        }
        return (latencies, parts, misses)
    }

    // MARK: - M7 开标签与恢复

    /// 新开一个窗格到首帧（同一个窗口里依次开 8 个，前一个移出窗口，像切标签）。第一个是进程里的冷启动。
    func testM7OpenPane() async throws {
        let engine = try XCTUnwrap(MeasurePane.Engine(rawValue: MeasureEnv.string("M7_ENGINE", "ghostty")))
        let count = MeasureEnv.int("M7_COUNT", 8)
        let rect = NSRect(x: 0, y: 0, width: 800, height: 500)
        let host = NSView(frame: rect)
        let window = ProbeWindow.make(contentRect: rect, contentView: host, placement: .transparentOnScreen)
        defer { window.orderOut(nil) }
        await sleep(0.5)
        log("M7 open start engine=\(engine.rawValue) loadavg=\(loadavg())")
        var panes: [MeasurePane] = []
        var toFrame: [Double] = []
        var toSurface: [Double] = []
        for i in 0..<count {
            let t0 = CACurrentMediaTime()
            let pane = MeasurePane(engine: engine, frame: rect, controller: nil, scrollbackLines: TerminalSettings.read().scrollback)
            panes.last?.view.removeFromSuperview()
            host.addSubview(pane.view)
            pane.feed(ArraySlice(Array("\u{1B}[32muser@host\u{1B}[0m ~/Workspace % ".utf8)))
            var tSurface: CFTimeInterval?
            var tFrame: CFTimeInterval?
            _ = await waitUntil(10) {
                if engine == .swiftterm {
                    if pane.draws > 0 { tFrame = CACurrentMediaTime() }
                    return tFrame != nil
                }
                if tSurface == nil, pane.viewport.value != nil { tSurface = CACurrentMediaTime() }
                pane.attachWatchIfNeeded()
                if let s = GhosttyFrameWatch.currentSurface(of: pane.view),
                   SurfacePixels.inkFraction(s, x: 0, y: 0, width: 600, height: 60) > 0.002 {
                    tFrame = pane.watch?.lastFrameTime ?? CACurrentMediaTime()
                }
                return tFrame != nil
            }
            let ms = ((tFrame ?? .nan) - t0) * 1000
            toFrame.append(ms)
            if let tSurface { toSurface.append((tSurface - t0) * 1000) }
            log(String(format: "M7 open engine=%@ pane=%d toFirstFrame=%.1fms toSurface=%.1fms", engine.rawValue, i, ms,
                       ((tSurface ?? .nan) - t0) * 1000))
            panes.append(pane)
            await sleep(0.3)
        }
        log("M7 open RESULT engine=\(engine.rawValue) cold=\(String(format: "%.1f", toFrame.first ?? -1))ms warm(ms) \(stats(Array(toFrame.dropFirst())))")
        if !toSurface.isEmpty { log("M7 open RESULT engine=\(engine.rawValue) toSurface(ms) \(stats(toSurface))") }
        panes.forEach { $0.dispose() }
    }

    /// 冷启动恢复：一次建 20 个窗格（各自一个可见窗口），每个回放 5 MB 历史。总耗时与足迹峰值。
    func testM7Restore20() async throws {
        let engine = try XCTUnwrap(MeasurePane.Engine(rawValue: MeasureEnv.string("M7_ENGINE", "ghostty")))
        let count = MeasureEnv.int("M7_PANES", 20)
        let historyMB = MeasureEnv.int("M7_HISTORY_MB", 5)
        let rect = NSRect(x: 0, y: 0, width: 800, height: 500)
        let history = GhosttySpikeTests.makeLoad(bytes: historyMB << 20)
        let scrollback = TerminalSettings.read().scrollback
        await sleep(1.0)
        log("M7 restore start engine=\(engine.rawValue) panes=\(count) history=\(historyMB)MB scrollbackLines=\(scrollback) loadavg=\(loadavg())")
        let base = MemSnapshot.take()
        let sampler = FootprintSampler()
        sampler.start()
        let main0 = ProbeMetrics.threadCPUSeconds(), proc0 = Self.processCPUSeconds()
        let t0 = CACurrentMediaTime()
        var panes: [MeasurePane] = []
        for i in 0..<count {
            let pane = MeasurePane(engine: engine, frame: rect, controller: nil, scrollbackLines: scrollback)
            pane.window = ProbeWindow.make(contentRect: rect, contentView: pane.view, placement: .transparentOnScreen,
                                           onScreenOrigin: NSPoint(x: 40 + (i % 5) * 40, y: 40 + (i / 5) * 40))
            panes.append(pane)
        }
        _ = await waitUntil(30) { panes.allSatisfy(\.isReady) }
        let tCreated = CACurrentMediaTime()
        panes.forEach { $0.attachWatchIfNeeded() }
        // 轮转喂：每个窗格每轮 64 KiB，SwiftTerm 每轮让主 run loop 画一次（近似输出泵的节奏）。
        let chunk = 64 * 1024
        var offset = 0
        while offset < history.count {
            let end = min(offset + chunk, history.count)
            for pane in panes {
                if engine != .swiftterm { _ = await waitUntil(60) { pane.pending < 4 << 20 } }
                pane.feed(history[offset..<end])
            }
            offset = end
            if engine != .ghostty, (offset / chunk) % 8 == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        let tFed = CACurrentMediaTime()
        _ = await waitUntil(120) { panes.allSatisfy { $0.pending == 0 } }
        let framesAtDone = panes.map(\.frames)
        if engine == .swiftterm { panes.forEach { $0.swiftTerm?.needsDisplay = true } }
        _ = await waitUntil(10) { zip(panes, framesAtDone).allSatisfy { $0.frames > $1 } }
        let t1 = CACurrentMediaTime()
        let main1 = ProbeMetrics.threadCPUSeconds(), proc1 = Self.processCPUSeconds()
        let peak = sampler.stop()
        let end = MemSnapshot.take(includeMetal: engine != .swiftterm)
        log(String(format: "M7 restore RESULT engine=%@ panes=%d total=%.2fs create=%.2fs feedLoop=%.2fs drain+frame=%.2fs mainCPU=%.2fs procCPU=%.2fs peakΔfp=%.0fMB endΔfp=%.0fMB | %@",
                   engine.rawValue, count, t1 - t0, tCreated - t0, tFed - tCreated, t1 - tFed, main1 - main0, proc1 - proc0,
                   peak - base.footprint, end.footprint - base.footprint, end.delta(from: base)))
        panes.forEach { $0.dispose() }
    }

    // MARK: - M8 多窗格并发输出

    /// 一个窗口 2×2 四个窗格。场景 claude：每格每 100 ms 一个 DEC 2026 同步帧（重画底部活动区、隔帧滚动）；
    /// 场景 fullscreen：每格每 16.7 ms 一次整屏重写。各 10 s，量全进程 CPU、主线程 CPU、各窗格出帧数。
    func testM8Concurrent() async throws {
        let engine = try XCTUnwrap(MeasurePane.Engine(rawValue: MeasureEnv.string("M8_ENGINE", "ghostty")))
        let seconds = MeasureEnv.double("M8_SECONDS", 10)
        let scenarios = MeasureEnv.string("M8_SCENARIOS", "claude,fullscreen").split(separator: ",").map(String.init)
        let paneSize = NSSize(width: 800, height: 500)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: paneSize.width * 2, height: paneSize.height * 2))
        let window = ProbeWindow.make(contentRect: host.frame, contentView: host, placement: .transparentOnScreen)
        defer { window.orderOut(nil) }
        var panes: [MeasurePane] = []
        for i in 0..<4 {
            let frame = NSRect(x: CGFloat(i % 2) * paneSize.width, y: CGFloat(i / 2) * paneSize.height,
                               width: paneSize.width, height: paneSize.height)
            let pane = MeasurePane(engine: engine, frame: frame, controller: nil, scrollbackLines: TerminalSettings.read().scrollback)
            host.addSubview(pane.view)
            panes.append(pane)
        }
        _ = await waitUntil(10) { panes.allSatisfy(\.isReady) }
        // 第一次 resize 回调是视图还没排好时的尺寸（spike 坑 1），等网格停稳。
        await sleep(1.0)
        panes.forEach { $0.attachWatchIfNeeded() }
        let grid = engine == .swiftterm
            ? (panes[0].swiftTerm!.getTerminal().cols, panes[0].swiftTerm!.getTerminal().rows)
            : (Int(panes[0].viewport.value!.columns), Int(panes[0].viewport.value!.rows))
        log("M8 start engine=\(engine.rawValue) grid=\(grid.0)x\(grid.1) loadavg=\(loadavg())")
        // 先铺满一屏，给活动区留位置。
        let prefill = MeasureLoad.typicalLines(count: grid.1 + 20, cols: grid.0 - 2)
        panes.forEach { $0.feed(prefill[...]) }
        await sleep(1.0)

        for scenario in scenarios {
            // idle：不喂字节，看空闲时出不出帧；plain：每 100 ms 一行普通文字（不带同步更新），与 claude 对照。
            let interval = scenario == "fullscreen" ? 1.0 / 60 : 0.1
            let counter = TickCounter()
            let frames0 = panes.map(\.frames)
            let main0 = ProbeMetrics.threadCPUSeconds(), proc0 = Self.processCPUSeconds()
            let t0 = CACurrentMediaTime()
            var timers: [Timer] = []
            for (i, pane) in panes.enumerated() {
                // 各窗格错开相位。
                let start = Date().addingTimeInterval(interval * Double(i) / 4)
                let cols = grid.0, rows = grid.1
                let timer = Timer(fire: start, interval: interval, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let tick = counter.ticks[i]
                        let frame: [UInt8] = switch scenario {
                        case "claude": MeasureLoad.claudeFrame(tick: tick, cols: cols)
                        case "fullscreen": MeasureLoad.fullScreenFrame(tick: tick, cols: cols, rows: rows)
                        case "plain": Array("plain line \(tick)\r\n".utf8)
                        default: []
                        }
                        if frame.isEmpty { return }
                        counter.ticks[i] += 1
                        counter.bytes += frame.count
                        pane.feed(frame[...])
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                timers.append(timer)
            }
            await sleep(seconds)
            timers.forEach { $0.invalidate() }
            let t1 = CACurrentMediaTime()
            let main1 = ProbeMetrics.threadCPUSeconds(), proc1 = Self.processCPUSeconds()
            let wall = t1 - t0
            let fps = zip(panes.map(\.frames), frames0).map { Double($0 - $1) / wall }
            log(String(format: "M8 RESULT engine=%@ scenario=%@ wall=%.1fs inputFrames/s/pane=%.1f bytes=%.1fMB procCPU=%.1f%% mainCPU=%.1f%% paneFPS=[%@] backlog=%d",
                       engine.rawValue, scenario, wall, Double(counter.ticks.reduce(0, +)) / wall / 4, Double(counter.bytes) / 1_048_576,
                       (proc1 - proc0) / wall * 100, (main1 - main0) / wall * 100,
                       fps.map { String(format: "%.1f", $0) }.joined(separator: ","), panes.map(\.pending).reduce(0, +)))
            await sleep(1.0)
        }
        panes.forEach { $0.dispose() }
    }

    // MARK: - M12 系统等宽字体

    private struct GlyphScore { var font: String; var score: Double }

    /// 一行字符逐格的墨量矩阵（按包围盒裁、重采样到 12×18、去均值归一）。`image` 是整张位图，`cell` 是格子像素。
    private nonisolated static func glyphVectors(_ image: CGImage, text: [Character], originX: Int, originY _: Int,
                                                 cellW: Int, cellH: Int) -> [[Double]?] {
        let width = image.width, height = image.height
        var gray = [UInt8](repeating: 0, count: width * height)
        let ctx = CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext 的内存是自上而下的（第 0 行 = 图像顶端）。
        let bg = Int(gray[(height - 2) * width + (width - 2)])
        // 字所在的那一条：从上往下第一行有墨的像素行（CIImage 转出来的方向不一定，所以不假定在第 0 行）。
        var firstInk = 0
        scan: for y in 0..<height {
            for x in 0..<min(width, originX + cellW * text.count) where abs(Int(gray[y * width + x]) - bg) > 40 {
                firstInk = y
                break scan
            }
        }
        let originY = max(0, firstInk - 4)
        var out: [[Double]?] = []
        for (i, _) in text.enumerated() {
            let x0 = originX + i * cellW, y0 = originY
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in y0..<min(height, y0 + cellH) {
                for x in x0..<min(width, x0 + cellW) where abs(Int(gray[y * width + x]) - bg) > 40 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { out.append(nil); continue }
            let gw = 12, gh = 18
            var v = [Double](repeating: 0, count: gw * gh)
            for gy in 0..<gh {
                for gx in 0..<gw {
                    let sx = minX + (maxX - minX) * gx / max(1, gw - 1)
                    let sy = minY + (maxY - minY) * gy / max(1, gh - 1)
                    v[gy * gw + gx] = Double(abs(Int(gray[sy * width + sx]) - bg)) / 255
                }
            }
            let mean = v.reduce(0, +) / Double(v.count)
            v = v.map { $0 - mean }
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            out.append(norm > 0 ? v.map { $0 / norm } : nil)
        }
        return out
    }

    /// CoreText 按某个字体画同一行（白字黑底，格宽 = Ghostty 的格宽，2x）。
    private static func referenceImage(font: NSFont, text: [Character], cellW: Int, cellH: Int, scale: CGFloat) -> CGImage {
        let width = cellW * text.count + 8, height = cellH + 8
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let scaled = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
        for (i, ch) in text.enumerated() {
            NSAttributedString(string: String(ch), attributes: [.font: scaled, .foregroundColor: NSColor.white])
                .draw(at: NSPoint(x: CGFloat(i * cellW), y: 4 - scaled.descender))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    private static func similarity(_ a: [[Double]?], _ b: [[Double]?]) -> Double {
        var sum = 0.0, n = 0
        for (x, y) in zip(a, b) {
            guard let x, let y else { continue }
            sum += zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
            n += 1
        }
        return n > 0 ? sum / Double(n) : 0
    }

    /// `font-family` 各种写法下 Ghostty 实际用的字体：读格子像素，再把画出来的字形与 CoreText 用候选字体
    /// 画的同一行逐字比形状（包围盒归一后的相关系数），取最像的那个。另存截图附件。
    func testM12Font() async throws {
        let text = Array("0@grlia$&%fjyQWm37{")
        let controller = GhosttyTerminalConfig.controller
        let original = GhosttyTerminalConfig.base(settings: TerminalSettings.read())
        defer { controller.setTerminalConfiguration(original) }
        let families = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        log("M12 families containing SF/Mono: \(families.filter { $0.hasPrefix("SF") || $0.contains("Mono") || $0 == "Menlo" })")
        let systemMono = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        log("M12 SwiftTerm font=\(systemMono.fontName) family=\(systemMono.familyName ?? "-") advance=\(systemMono.maximumAdvancement.width)")

        func references() -> [(String, NSFont)] {
            var refs: [(String, NSFont)] = [("system-mono-medium(SwiftTerm)", systemMono)]
            if let f = NSFontManager.shared.font(withFamily: "JetBrains Mono", traits: [], weight: 6, size: 12) { refs.append(("JetBrains Mono", f)) }
            if let f = NSFont(name: "Menlo-Regular", size: 12) { refs.append(("Menlo", f)) }
            if let f = NSFont(name: "SFMono-Medium", size: 12) { refs.append(("SF Mono Medium(registered)", f)) }
            return refs
        }

        var cases: [(String, [String])] = [
            ("spike-chain", GhosttyTerminalConfig.fontFamilies()),
            (".AppleSystemUIFontMonospaced", [".AppleSystemUIFontMonospaced"]),
            ("SF Mono", ["SF Mono"]),
            ("SFMono-Regular", ["SFMono-Regular"]),
            (".SF NS Mono", [".SF NS Mono"]),
            ("SF NS Mono", ["SF NS Mono"]),
            ("Menlo", ["Menlo"]),
            ("JetBrains Mono", ["JetBrains Mono"]),
            ("NoSuchFontXYZ(=内置默认)", ["NoSuchFontXYZ"]),
        ]
        let terminalFonts = "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts"
        let sfMonoFiles = ((try? FileManager.default.contentsOfDirectory(atPath: terminalFonts)) ?? [])
            .filter { $0.hasPrefix("SF-Mono-") }.map { URL(fileURLWithPath: terminalFonts).appendingPathComponent($0) }
        var registered = false
        var index = 0
        while index < cases.count {
            let (name, fams) = cases[index]
            index += 1
            controller.setTerminalConfiguration(GhosttyTerminal.TerminalConfiguration(startingFrom: original) { b in
                b.withCustom("font-family", "")
                for f in fams { b.withFontFamily(f) }
                b.withCursorStyleBlink(false)
            })
            let pane = MeasurePane(engine: .ghostty, frame: NSRect(x: 0, y: 0, width: 640, height: 120), controller: controller, scrollbackLines: 100)
            pane.window = ProbeWindow.make(contentRect: pane.view.frame, contentView: pane.view, placement: .transparentOnScreen)
            _ = await waitUntil(10) { pane.viewport.value != nil }
            pane.feed(ArraySlice(Array(("\u{1B}[2J\u{1B}[H\u{1B}[97m" + String(text) + "\u{1B}[0m").utf8)))
            _ = await waitUntil(5) {
                guard let s = GhosttyFrameWatch.currentSurface(of: pane.view) else { return false }
                return SurfacePixels.inkFraction(s, x: 0, y: 0, width: 300, height: 30) > 0.01
            }
            await sleep(0.3)
            let cellPt = try XCTUnwrap(GhosttyGeometry.cellPoints(try XCTUnwrap(pane.ghostty)))
            let scale = pane.window!.backingScaleFactor
            let cw = Int((cellPt.width * scale).rounded()), chh = Int((cellPt.height * scale).rounded())
            let surface = try XCTUnwrap(GhosttyFrameWatch.currentSurface(of: pane.view))
            let image = try XCTUnwrap(SurfacePixels.cgImage(surface))
            let gv = Self.glyphVectors(image, text: text, originX: 0, originY: 0, cellW: cw, cellH: chh)
            let scores = references().map { ref -> GlyphScore in
                let refImage = Self.referenceImage(font: ref.1, text: text, cellW: cw, cellH: chh + 8, scale: pane.window!.backingScaleFactor)
                let rv = Self.glyphVectors(refImage, text: text, originX: 0, originY: 0, cellW: cw, cellH: chh + 16)
                return GlyphScore(font: ref.0, score: Self.similarity(gv, rv))
            }.sorted { $0.score > $1.score }
            log(String(format: "M12 RESULT case=%@ families=%@ cell=%dx%dpx bestMatch=%@ scores=%@", name, fams.description, cw, chh,
                       scores.first?.font ?? "-", scores.map { String(format: "%@:%.3f", $0.font, $0.score) }.joined(separator: " ")))
            let attachment = XCTAttachment(image: NSImage(cgImage: image, size: .zero))
            attachment.name = "M12-ghostty-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            pane.dispose()
            await sleep(0.3)

            if index == cases.count, !registered, !sfMonoFiles.isEmpty {
                // 进程内注册 Terminal.app 自带的 SF Mono（系统没装 SF Mono 这个族，只有隐藏的 .AppleSystemUIFontMonospaced）。
                var errors: Unmanaged<CFArray>?
                let ok = CTFontManagerRegisterFontsForURLs(sfMonoFiles as CFArray, .process, &errors)
                registered = true
                let nowHas = ((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []).contains("SF Mono")
                log("M12 registered \(sfMonoFiles.count) SF-Mono files from Terminal.app ok=\(ok) familyVisible=\(nowHas)")
                cases += [("SF Mono(registered)", ["SF Mono"]), ("SFMono-Medium(registered)", ["SFMono-Medium"])]
            }
        }

        // SwiftTerm 现状截图（同一行），附件里与 Ghostty 并排看。
        let st = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 120))
        TerminalTheme.apply(to: st, settings: TerminalSettings.read(), dark: true)
        let stWindow = ProbeWindow.make(contentRect: st.frame, contentView: st, placement: .transparentOnScreen)
        defer { stWindow.orderOut(nil) }
        st.feed(text: "\u{1B}[2J\u{1B}[H\u{1B}[97m" + String(text) + "\u{1B}[0m")
        st.flushPendingDisplay()
        st.displayIfNeeded()
        let rep = try XCTUnwrap(st.bitmapImageRepForCachingDisplay(in: st.bounds))
        st.cacheDisplay(in: st.bounds, to: rep)
        let attachment = XCTAttachment(image: NSImage(cgImage: rep.cgImage!, size: .zero))
        attachment.name = "M12-swiftterm-current"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - M14 Mac 真事件输入

    private struct InputResult { var engine: String; var item: String; var verdict: String; var detail: String }

    /// 两个引擎各走一遍真 `TerminalSession`（SwiftTerm 视图 / Ghostty 桥），全部用真 NSEvent。
    /// 动了系统剪贴板与当前输入法，结束时还原。
    func testM14Input() async throws {
        let general = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (general.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        let savedSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        defer {
            TISSelectInputSource(savedSource)
            general.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, d) in pairs { item.setData(d, forType: t) }
                return item
            }
            if !items.isEmpty { general.writeObjects(items) }
            log("M14 restored pasteboard items=\(items.count) inputSource=\(Self.sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) ?? "?")")
        }
        let cell = try await ghosttyCellPixels()
        var results: [InputResult] = []
        for engine in ["swiftterm", "ghostty"] {
            results += try await runInput(engine: engine, ghosttyCell: cell)
        }
        for r in results {
            log("M14 RESULT engine=\(r.engine) item=\(r.item) verdict=\(r.verdict) detail=\(r.detail)")
        }
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    private func runInput(engine: String, ghosttyCell: (w: Int, h: Int)) async throws -> [InputResult] {
        var out: [InputResult] = []
        func record(_ item: String, _ ok: Bool?, _ detail: String) {
            out.append(InputResult(engine: engine, item: item, verdict: ok == nil ? "测不了" : (ok! ? "通过" : "不通过"), detail: detail))
        }
        let rect = NSRect(x: 0, y: 0, width: 800, height: 500)
        let session = TerminalSession()
        let backend = CaptureBackend()
        let privateBoard = NSPasteboard(name: NSPasteboard.Name("uterm-measure-\(UUID().uuidString)"))
        defer { privateBoard.releaseGlobally() }
        let window: NSWindow
        let view: NSView
        var bridge: GhosttyTerminalBridge?
        let isGhostty = engine == "ghostty"
        var settings = TerminalSettings.read()
        settings.copyOnSelect = false
        if isGhostty {
            GhosttyTerminalBridge.apply(settings: settings)
            let b = session.enableGhostty()
            bridge = b
            let container = GhosttyContainerView(surface: b.view)
            container.isActive = true
            window = ProbeWindow.make(contentRect: rect, contentView: container, placement: .transparentOnScreen)
            container.frame = window.contentView?.bounds ?? rect
            container.layoutSubtreeIfNeeded()
            _ = await waitUntil(10) { b.isLive && b.grid != nil }
            b.view.pasteboard = privateBoard
            view = b.view
        } else {
            let st = try XCTUnwrap(session.terminalView as? CopyableTerminalView)
            st.pasteboard = privateBoard
            window = ProbeWindow.make(contentRect: rect, contentView: st, placement: .transparentOnScreen)
            view = st
        }
        defer {
            session.dispose()
            window.orderOut(nil)
            if isGhostty { GhosttyTerminalBridge.apply(settings: TerminalSettings.read()) }
        }
        await session.connect(using: backend)
        window.makeFirstResponder(view)
        log("M14 engine=\(engine) window isKey=\(window.isKeyWindow) firstResponder=\(window.firstResponder === view) appActive=\(NSApp.isActive)")

        func screenText() -> [String] {
            if let bridge { return (bridge.viewportText() ?? "").components(separatedBy: "\n") }
            let t = session.terminalView.getTerminal()
            return (0..<t.rows).map { t.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        }
        func show(_ s: String) async {
            backend.emit(Data(s.utf8))
            await sleep(0.3)
        }
        func written() async -> Data { await backend.written }
        func clearWritten() async { await backend.clear() }
        func press(_ chars: String, _ ignoring: String? = nil, _ code: Int, _ mods: NSEvent.ModifierFlags = [],
                   menu: Selector? = nil) -> String {
            let down = RealEvents.key(.keyDown, window: window, characters: chars, ignoring: ignoring, keyCode: code, modifiers: mods)
            var path = "sendEvent"
            if !mods.intersection([.command, .control]).isEmpty, window.performKeyEquivalent(with: down) {
                path = "performKeyEquivalent"
            } else if let menu {
                // 真 App 里 ⌘C / ⌘V 先经主菜单「编辑」，动作发给第一响应者。测试宿主激活不了、窗口不是 key，
                // 菜单那一步走不到，这里照菜单的做法把动作直接发给第一响应者。
                path = NSApp.sendAction(menu, to: window.firstResponder, from: nil) ? "menu-action" : "menu-action(unhandled)"
            } else {
                window.sendEvent(down)
            }
            window.sendEvent(RealEvents.key(.keyUp, window: window, characters: chars, ignoring: ignoring, keyCode: code, modifiers: mods))
            return path
        }
        let ghosttyPt = bridge.flatMap { GhosttyGeometry.cellPoints($0.view) }
        log("M14 engine=\(engine) ghosttyCellPt=\(String(describing: ghosttyPt))")
        func cellPoint(_ col: Int, _ row: Int, fraction: CGFloat = 0.5) -> NSPoint {
            let p: NSPoint
            if isGhostty, let ghosttyPt {
                let x = (CGFloat(col) + fraction) * ghosttyPt.width
                let yTop = (CGFloat(row) + 0.5) * ghosttyPt.height
                p = NSPoint(x: x, y: view.bounds.height - yTop)
            } else {
                let font = TerminalSettings.textFont()
                let cw = NSAttributedString(string: "W", attributes: [.font: font]).size().width
                let ch = font.ascender - font.descender + font.leading
                let yTop = (CGFloat(row) + 0.5) * ch
                p = NSPoint(x: (CGFloat(col) + fraction) * cw, y: view.isFlipped ? yTop : view.bounds.height - yTop)
            }
            return view.convert(p, to: nil)
        }
        func selectionText() -> String? {
            if let bridge {
                guard let region = bridge.view.selectionRegion else { return nil }
                let lines = screenText()
                var parts: [String] = []
                for r in region.topLeft.row...region.bottomRight.row where r < lines.count {
                    let chars = Array(lines[r])
                    let from = r == region.topLeft.row ? region.topLeft.column : 0
                    let to = r == region.bottomRight.row ? region.bottomRight.column : chars.count - 1
                    if from < chars.count { parts.append(String(chars[from...min(to, chars.count - 1)])) }
                }
                return parts.joined(separator: "\n")
            }
            return session.terminalView.getSelection()
        }
        func click(_ col: Int, _ row: Int, count: Int) async {
            for k in 1...count {
                window.sendEvent(RealEvents.mouse(.leftMouseDown, window: window, at: cellPoint(col, row), clickCount: k))
                window.sendEvent(RealEvents.mouse(.leftMouseUp, window: window, at: cellPoint(col, row), clickCount: k))
                await sleep(0.05)
            }
            await sleep(0.3)
        }
        func drag(from: (Int, Int), to: (Int, Int)) async {
            window.sendEvent(RealEvents.mouse(.leftMouseDown, window: window, at: cellPoint(from.0, from.1, fraction: 0.1)))
            for step in 1...6 {
                let col = from.0 + (to.0 - from.0) * step / 6
                window.sendEvent(RealEvents.mouse(.leftMouseDragged, window: window, at: cellPoint(col, to.1, fraction: 0.9)))
                await sleep(0.02)
            }
            window.sendEvent(RealEvents.mouse(.leftMouseUp, window: window, at: cellPoint(to.0, to.1, fraction: 0.9)))
            await sleep(0.3)
        }
        func dataDesc(_ d: Data) -> String { String(decoding: d, as: UTF8.self).debugDescription }

        // 1. 普通键入
        await clearWritten()
        _ = press("a", nil, kVK_ANSI_A)
        await sleep(0.3)
        var w = await written()
        record("键入 a", w == Data("a".utf8), dataDesc(w))

        // 2. 方向键与 DECCKM
        await clearWritten()
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        _ = press(up, up, kVK_UpArrow, [.numericPad, .function])
        await sleep(0.3)
        w = await written()
        record("↑（普通模式）", w == Data("\u{1B}[A".utf8), dataDesc(w))
        await show("\u{1B}[?1h")
        await clearWritten()
        _ = press(up, up, kVK_UpArrow, [.numericPad, .function])
        await sleep(0.3)
        w = await written()
        record("↑（DECCKM 开）", w == Data("\u{1B}OA".utf8), dataDesc(w))
        await show("\u{1B}[?1l")

        // 3. ⌃↩
        await clearWritten()
        let ctrlReturnPath = press("\r", "\r", kVK_Return, [.control])
        await sleep(0.3)
        w = await written()
        record("⌃↩", w == Data("\r".utf8), "\(dataDesc(w)) path=\(ctrlReturnPath)（uTerm 现状发 \\r）")

        // 4. 选择：拖选 / 双击 / 三击
        await show("\u{1B}[2J\u{1B}[Hhello world foo bar\r\nsecond line here\r\n")
        await drag(from: (0, 0), to: (10, 0))
        let dragSel = selectionText()
        // 判据：拖过的那一段被选中（首尾一格的取舍两个引擎不同、也受测试里格宽换算影响，不计较）。
        record("鼠标拖选", (dragSel?.count ?? 0) >= 8 && "hello world foo bar".contains(dragSel ?? "#"), "selection=\(dragSel.debugDescription)")
        await sleep(0.6)
        await click(7, 0, count: 2)
        let wordSel = selectionText()
        record("双击选词", wordSel == "world", "selection=\(wordSel.debugDescription)")
        await sleep(0.6)
        await click(7, 0, count: 3)
        let lineSel = selectionText()
        record("三击选行", lineSel?.trimmingCharacters(in: .whitespaces) == "hello world foo bar", "selection=\(lineSel.debugDescription)")

        // 5. ⌘C（接着三击的选区）
        NSPasteboard.general.clearContents()
        let copyPath = press("c", "c", kVK_ANSI_C, [.command], menu: #selector(NSText.copy(_:)))
        await sleep(0.3)
        let copied = NSPasteboard.general.string(forType: .string)
        record("⌘C", copied?.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world foo bar",
               "pasteboard=\(copied.debugDescription) path=\(copyPath)")

        // 6. ⌘V 文字
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("pasted-text", forType: .string)
        await clearWritten()
        let pastePath = press("v", "v", kVK_ANSI_V, [.command], menu: #selector(NSText.paste(_:)))
        await sleep(0.4)
        w = await written()
        record("⌘V 文字", String(decoding: w, as: UTF8.self).contains("pasted-text"), "\(dataDesc(w)) path=\(pastePath)")

        // 7. 选中即复制
        if let bridge {
            var s = TerminalSettings.read()
            s.copyOnSelect = true
            GhosttyTerminalBridge.apply(settings: s)
            await sleep(0.3)
            _ = bridge
        } else {
            (view as? CopyableTerminalView)?.copyOnSelect = true
        }
        NSPasteboard.general.clearContents()
        await click(0, 1, count: 1)
        await drag(from: (0, 1), to: (5, 1))
        let autoCopied = NSPasteboard.general.string(forType: .string)
        let autoSel = selectionText()
        record("选中即复制", autoCopied != nil && autoCopied == autoSel && "second line here".contains(autoCopied ?? "#"),
               "pasteboard=\(autoCopied.debugDescription) selection=\(autoSel.debugDescription)")

        // 8. 右键菜单（先有选区，再无选区）
        let rightDown = RealEvents.mouse(.rightMouseDown, window: window, at: cellPoint(2, 1))
        let withSelection = view.menu(for: rightDown)?.items.map(\.title).filter { !$0.isEmpty } ?? []
        await click(30, 5, count: 1)
        let noSelection = view.menu(for: RealEvents.mouse(.rightMouseDown, window: window, at: cellPoint(30, 5)))?.items.map(\.title).filter { !$0.isEmpty } ?? []
        let wantMenu = ["拷贝", "粘贴", "全选"]
        record("右键菜单", withSelection == wantMenu && noSelection == wantMenu,
               "有选区=\(withSelection) 无选区=\(noSelection)（现状：复制/粘贴/全选）")

        // 9. 贴图（剪贴板只有图片，⌘V → TerminalSession+ImagePaste → 后端收图 → 粘贴路径）
        privateBoard.clearContents()
        privateBoard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        await clearWritten()
        let imagePath = press("v", "v", kVK_ANSI_V, [.command], menu: #selector(NSText.paste(_:)))
        await sleep(0.5)
        w = await written()
        let delivered = await backend.delivered
        record("贴图 ⌘V", delivered == 1 && String(decoding: w, as: UTF8.self).contains("/tmp/shot.png"),
               "delivered=\(delivered) written=\(dataDesc(w)) path=\(imagePath)")
        privateBoard.clearContents()

        // 10. 输入法客户端协议：按输入法的调用顺序直接调视图的 NSTextInputClient（组字 → 改组字 → 上屏）。
        // 不经过真输入法，只验证视图这一侧怎么处理组字与上屏。
        await show("\u{1B}[2J\u{1B}[H$ ")
        await clearWritten()
        if let client = view as? NSTextInputClient {
            let none = NSRange(location: NSNotFound, length: 0)
            client.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            client.setMarkedText("ni'h", selectedRange: NSRange(location: 4, length: 0), replacementRange: none)
            await sleep(0.2)
            let marked = client.hasMarkedText()
            let rect = client.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
            let duringMarked = await written()
            client.insertText("你好", replacementRange: none)
            await sleep(0.3)
            let afterCommit = await written()
            let stillMarked = client.hasMarkedText()
            record("输入法客户端（模拟组字/上屏）", marked && duringMarked.isEmpty && afterCommit == Data("你好".utf8) && !stillMarked,
                   "marked=\(marked) 组字时写出=\(dataDesc(duringMarked)) 上屏后=\(dataDesc(afterCommit)) stillMarked=\(stillMarked) 候选框锚点(屏幕)=\(NSStringFromRect(rect))")
        } else {
            record("输入法客户端（模拟组字/上屏）", nil, "视图不是 NSTextInputClient")
        }

        // 11. 拼音输入法组字与上屏（真输入法）
        out.append(try await runPinyin(engine: engine, window: window, view: view, backend: backend, press: press))
        return out
    }

    private func runPinyin(engine: String, window: NSWindow, view: NSView, backend: CaptureBackend,
                           press: (String, String?, Int, NSEvent.ModifierFlags, Selector?) -> String) async throws -> InputResult {
        let candidates = ["com.apple.inputmethod.SCIM.ITABC", "com.tencent.inputmethod.wetype.pinyin", "com.sogou.inputmethod.sogou.pinyin"]
        let enabled = (TISCreateInputSourceList(nil, false).takeRetainedValue() as? [TISInputSource]) ?? []
        guard let source = candidates.lazy.compactMap({ id in enabled.first { Self.sourceID($0) == id } }).first else {
            return InputResult(engine: engine, item: "拼音输入法", verdict: "测不了", detail: "没有启用的拼音输入源")
        }
        let id = Self.sourceID(source) ?? "?"
        let before = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        defer { TISSelectInputSource(before) }
        let status = TISSelectInputSource(source)
        await sleep(0.5)
        let current = Self.sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) ?? "?"
        // 输入法只服务前台 App 的 key 窗口。测试宿主由 xcodebuild 拉起，激活不了（`NSApp.isActive` 恒 false，
        // 上一轮试过 `NSApp.activate` 也被系统拒绝），所以这一项多半测不了；照样发真按键，把现象记下来。
        let activeState = "appActive=\(NSApp.isActive) isKey=\(window.isKeyWindow)"
        view.inputContext?.activate()
        await backend.clear()
        var markedSeen = false
        for ch in "nihao" {
            _ = press(String(ch), nil, RealEvents.keyCode(for: ch), [], nil)
            await sleep(0.15)
            if (view as? NSTextInputClient)?.hasMarkedText() == true { markedSeen = true }
        }
        let markedBeforeCommit = (view as? NSTextInputClient)?.hasMarkedText() == true
        let midWrite = await backend.written
        _ = press(" ", " ", kVK_Space, [], nil)
        await sleep(0.6)
        let committed = await backend.written
        let text = String(decoding: committed, as: UTF8.self)
        let hasCJK = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        // 还没上屏就有字节进了后端 = 输入法没截住按键，字母直接发给了程序。
        let leaked = !midWrite.isEmpty
        _ = press("\u{1B}", "\u{1B}", kVK_Escape, [], nil)
        await sleep(0.2)
        let ok = hasCJK && markedSeen && !leaked
        let verdict = ok ? "通过" : (NSApp.isActive ? "不通过" : "测不了")
        return InputResult(engine: engine, item: "拼音输入法(\(id))",
                           verdict: verdict,
                           detail: "select=\(status) current=\(current) \(activeState) markedSeen=\(markedSeen) markedBeforeCommit=\(markedBeforeCommit) leakedBeforeCommit=\(String(decoding: midWrite, as: UTF8.self).debugDescription) committed=\(text.debugDescription)")
    }

    // MARK: - M15 Kitty 图形

    private static func png(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: width * 4, bitsPerPixel: 32)!
        let p = rep.bitmapData!
        for i in 0..<(width * height) { p[i * 4] = rgb.0; p[i * 4 + 1] = rgb.1; p[i * 4 + 2] = rgb.2; p[i * 4 + 3] = 255 }
        return rep.representation(using: .png, properties: [:])!
    }

    private static func raw(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8), alpha: Bool, noise: Bool = false) -> Data {
        let bpp = alpha ? 4 : 3
        var d = Data(count: width * height * bpp)
        var rng = MeasureLoad.RNG(state: 42)
        d.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            for i in 0..<(width * height) {
                let n = noise ? UInt8(truncatingIfNeeded: rng.next()) : 0
                p[i * bpp] = rgb.0 ^ n; p[i * bpp + 1] = rgb.1 ^ n; p[i * bpp + 2] = rgb.2 ^ n
                if alpha { p[i * bpp + 3] = 255 }
            }
        }
        return d
    }

    /// Kitty APC：`ESC _ G <control> ; <base64> ESC \`，超过 `chunk` 字节就按 m=1 / m=0 分块。
    private static func kitty(_ control: String, payload: Data, chunk: Int = 4096) -> [UInt8] {
        let b64 = Array(payload.base64EncodedString().utf8)
        var out = [UInt8]()
        out.reserveCapacity(b64.count + b64.count / chunk * 16 + 64)
        if b64.count <= chunk {
            out += Array("\u{1B}_G\(control);".utf8) + b64 + Array("\u{1B}\\".utf8)
            return out
        }
        var offset = 0
        var first = true
        while offset < b64.count {
            let end = min(offset + chunk, b64.count)
            let more = end < b64.count ? 1 : 0
            out += Array((first ? "\u{1B}_G\(control),m=\(more);" : "\u{1B}_Gm=\(more);").utf8)
            out += b64[offset..<end]
            out += Array("\u{1B}\\".utf8)
            offset = end
            first = false
        }
        return out
    }

    private static let diacritics: [Character] = ["\u{0305}", "\u{030D}", "\u{030E}", "\u{0310}", "\u{0312}", "\u{033D}", "\u{033E}", "\u{033F}"]

    /// 经 host-managed IO 喂 Kitty 图形序列：查询应答、PNG 直传、小图分块、原始 RGB 大图 256 块、
    /// Unicode 占位符；随后滚出屏 / 滚回来 / 清屏 / 删除，读像素与内存。SwiftTerm 同一串字节对照。
    func testM15Kitty() async throws {
        for engine in [MeasurePane.Engine.ghostty, .swiftterm] {
            try await runKitty(engine)
        }
    }

    private func runKitty(_ engine: MeasurePane.Engine) async throws {
        let rect = NSRect(x: 0, y: 0, width: 800, height: 500)
        let pane = MeasurePane(engine: engine, frame: rect, controller: nil, scrollbackLines: 3000)
        let replies = TimeBoxData()
        pane.ioBox.onWrite = { replies.append($0) }
        var stReplies = Data()
        let replyDelegate = ProbeTerminalDelegate()
        replyDelegate.onSend = { stReplies.append(contentsOf: $0) }
        pane.swiftTerm?.terminalDelegate = replyDelegate
        pane.window = ProbeWindow.make(contentRect: rect, contentView: pane.view, placement: .transparentOnScreen)
        defer { pane.dispose() }
        _ = await waitUntil(10) { pane.isReady }
        pane.attachWatchIfNeeded()
        let name = engine.rawValue

        func send(_ bytes: [UInt8]) async {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + (1 << 20), bytes.count)
                pane.feed(bytes[offset..<end])
                offset = end
                if pane.io != nil { _ = await waitUntil(30) { pane.pending < 8 << 20 } }
            }
            _ = await waitUntil(60) { pane.pending == 0 }
            await sleep(0.4)
        }
        func send(_ s: String) async { await send(Array(s.utf8)) }
        func counts() -> [String: Int] {
            let colors: [(String, (Int, Int, Int))] = [("magenta", (255, 0, 255)), ("cyan", (0, 255, 255)),
                                                         ("yellow", (255, 255, 0)), ("green", (0, 255, 0))]
            if engine == .swiftterm, let st = pane.swiftTerm {
                st.flushPendingDisplay(); st.displayIfNeeded()
                guard let rep = st.bitmapImageRepForCachingDisplay(in: st.bounds) else { return [:] }
                st.cacheDisplay(in: st.bounds, to: rep)
                return Dictionary(uniqueKeysWithValues: colors.map { ($0.0, BitmapPixels.colorCount(rep, rgb: $0.1, tolerance: 30)) })
            }
            guard let s = GhosttyFrameWatch.currentSurface(of: pane.view) else { return [:] }
            return Dictionary(uniqueKeysWithValues: colors.map { ($0.0, SurfacePixels.colorCount(s, rgb: $0.1, tolerance: 30).count) })
        }
        func desc(_ c: [String: Int]) -> String { c.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }

        log("M15 start engine=\(name) loadavg=\(loadavg())")
        // 1. 查询
        await send(Self.kitty("i=31,s=1,v=1,a=q,t=d,f=24", payload: Data([0, 0, 0])))
        let reply = engine == .swiftterm ? stReplies : replies.value
        log("M15 RESULT engine=\(name) item=query reply=\(String(decoding: reply, as: UTF8.self).debugDescription)")

        // 2. PNG 直传（洋红 96×96，在 1;1）
        await send("\u{1B}[2J\u{1B}[H")
        await send(Self.kitty("a=T,f=100,t=d,i=1,q=2", payload: Self.png(width: 96, height: 96, rgb: (255, 0, 255))))
        // 3. 小图分块（青 96×96 PNG，切成 64 字节一块），在 1;30
        await send("\u{1B}[1;30H")
        await send(Self.kitty("a=T,f=100,t=d,i=2,q=2", payload: Self.png(width: 96, height: 96, rgb: (0, 255, 255)), chunk: 64))
        // 4. 原始 RGB 大图（黄 320×320 = 300 KB，base64 4096 字节一块 ≈ 100 块），在 1;60
        await send("\u{1B}[1;60H")
        await send(Self.kitty("a=T,f=24,s=320,v=320,t=d,i=3,q=2", payload: Self.raw(width: 320, height: 320, rgb: (255, 255, 0), alpha: false)))
        // 5. Unicode 占位符（绿 64×32 原始 RGB，虚拟放置 6 列 × 3 行），在 14;1
        await send(Self.kitty("a=t,f=24,s=64,v=32,t=d,i=7,q=2", payload: Self.raw(width: 64, height: 32, rgb: (0, 255, 0), alpha: false)))
        await send("\u{1B}_Ga=p,U=1,i=7,c=6,r=3,q=2\u{1B}\\")
        var placeholder = "\u{1B}[14;1H\u{1B}[38;5;7m"
        for r in 0..<3 {
            for c in 0..<6 { placeholder += "\u{10EEEE}" + String(Self.diacritics[r]) + String(Self.diacritics[c]) }
            placeholder += "\u{1B}[0m\r\n\u{1B}[38;5;7m"
        }
        placeholder += "\u{1B}[0m"
        await send(placeholder)
        let shown = counts()
        log("M15 RESULT engine=\(name) item=displayed \(desc(shown))")

        // 6. 滚出屏：300 行文字
        await send(Array((0..<300).map { "scroll line \($0)\r\n" }.joined().utf8))
        let scrolled = counts()
        log("M15 RESULT engine=\(name) item=after-300-lines \(desc(scrolled))")
        if let gh = pane.ghostty {
            gh.performBindingAction("scroll_to_top")
            await sleep(0.5)
            log("M15 RESULT engine=\(name) item=scroll_to_top \(desc(counts()))")
            gh.performBindingAction("scroll_to_bottom")
            await sleep(0.3)
        } else if let st = pane.swiftTerm {
            st.scroll(toPosition: 0)
            await sleep(0.3)
            log("M15 RESULT engine=\(name) item=scroll_to_top \(desc(counts()))")
            st.scroll(toPosition: 1)
        }

        // 7. 内存：6 张 1024×1024 RGBA 噪声（每张解码后 4 MB），然后滚出屏 / ED2 / 删除全部 / RIS
        await send("\u{1B}c")
        await sleep(1.0)
        let m0 = MemSnapshot.take(includeMetal: engine != .swiftterm)
        for k in 0..<6 {
            await send("\u{1B}[\(1 + (k % 2) * 4);\(1 + (k / 2) * 20)H")
            await send(Self.kitty("a=T,f=32,s=1024,v=1024,t=d,i=\(100 + k),q=2", payload: Self.raw(width: 1024, height: 1024, rgb: (k % 2 == 0 ? 200 : 40, 90, 160), alpha: true, noise: true)))
        }
        await sleep(1.0)
        let m1 = MemSnapshot.take(includeMetal: engine != .swiftterm)
        log("M15 RESULT engine=\(name) item=mem-6-images \(m1.delta(from: m0))")
        await send(Array((0..<300).map { "line \($0)\r\n" }.joined().utf8))
        await sleep(1.0)
        let m2 = MemSnapshot.take(includeMetal: engine != .swiftterm)
        log("M15 RESULT engine=\(name) item=mem-scrolled-off \(m2.delta(from: m0))")
        await send("\u{1B}[2J")
        await sleep(1.0)
        let m3 = MemSnapshot.take(includeMetal: engine != .swiftterm)
        log("M15 RESULT engine=\(name) item=mem-after-ED2 \(m3.delta(from: m0))")
        await send("\u{1B}_Ga=d,d=A,q=2\u{1B}\\")
        await sleep(1.0)
        let m4 = MemSnapshot.take(includeMetal: engine != .swiftterm)
        log("M15 RESULT engine=\(name) item=mem-after-delete-all \(m4.delta(from: m0))")
        await send("\u{1B}c")
        await sleep(1.5)
        let m5 = MemSnapshot.take(includeMetal: engine != .swiftterm)
        log("M15 RESULT engine=\(name) item=mem-after-RIS \(m5.delta(from: m0))")
        // 第二轮同样 6 张：看是复用（不再涨）还是泄漏（再涨一份）。
        for k in 0..<6 {
            await send("\u{1B}[\(1 + (k % 2) * 4);\(1 + (k / 2) * 20)H")
            await send(Self.kitty("a=T,f=32,s=1024,v=1024,t=d,i=\(200 + k),q=2", payload: Self.raw(width: 1024, height: 1024, rgb: (k % 2 == 0 ? 200 : 40, 90, 160), alpha: true, noise: true)))
        }
        await sleep(1.0)
        let m6 = MemSnapshot.take(includeMetal: engine != .swiftterm)
        log("M15 RESULT engine=\(name) item=mem-second-6-images \(m6.delta(from: m0))")
        await send("\u{1B}c")
        await sleep(1.5)
        let m7 = MemSnapshot.take(includeMetal: engine != .swiftterm)
        log("M15 RESULT engine=\(name) item=mem-second-RIS \(m7.delta(from: m0))")
        await holdForExternalTools("m15-\(name)", seconds: MeasureEnv.double("M15_HOLD", 0))
    }

    private nonisolated final class TimeBoxData: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        var value: Data { lock.withLock { stored } }
        func append(_ d: Data) { lock.withLock { stored.append(d) } }
    }
}


/// 记录 SwiftTerm 视图发往「后端」的字节（M6 的 bare 回环、M15 的应答）。
@MainActor
private final class ProbeTerminalDelegate: @preconcurrency TerminalViewDelegate {
    var onSend: ((ArraySlice<UInt8>) -> Void)?
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { onSend?(data) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func bell(source: SwiftTerm.TerminalView) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

@MainActor
private final class TickCounter {
    var ticks = [Int](repeating: 0, count: 4)
    var bytes = 0
}
