import Darwin
import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 终端引擎迁移「测量门」的 iOS 真机读数（docs/ghostty-migration-plan.md §3、docs/ghostty-eval/measure-ios.md）。
/// 闸门只放结构判据（真出帧了、真解析了、没丢），不卡绝对毫秒——读数打印成 `MEASURE …` 行，报告从日志里取。
///
/// 换引擎之前每一项都在同一次运行里和旧引擎对照着量；旧引擎的视图类删掉之后只剩 Ghostty 这一列
///（打印行里的 `ghostty` 标签留着，和 measure-ios.md 里的历史读数同一个格式）。对照组的历史读数在那份文档里。
///
/// 这些用例很重（M9 一条就 20 多分钟），只在真机上按 `-only-testing` 单独跑；`make test-mobile-fast` 不该捎上它们，
/// 所以全部挂在环境变量 `UTERM_MEASURE=1` 后面。
@MainActor
final class GhosttyMeasureProbeTests: XCTestCase {
    /// 打印行里的引擎标签（历史读数里另一列是旧引擎）。
    private static let engineLabel = "ghostty"

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["UTERM_MEASURE"] == "1"
            || UserDefaults.standard.bool(forKey: "UTERM_MEASURE") else {
            throw XCTSkip("测量门探针：设 UTERM_MEASURE=1 才跑（真机、单独跑）")
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - 共用宿主

    private var sceneSize: CGSize {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.bounds.size ?? CGSize(width: 440, height: 956)
    }

    private func loadavg() -> String {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) == 3 ? String(format: "%.2f %.2f %.2f", load[0], load[1], load[2]) : "?"
    }

    private func makeGhostty(frame: CGRect,
                             controller: GhosttyTerminal.TerminalController = GhosttyProbeHost.controller) -> GhosttyTerminalBridge {
        GhosttyTerminalBridge(controller: controller, frame: frame)
    }

    /// 等所有 surface 建好、网格报上来并停稳，而且画面已经接上实时字节（就绪之前喂的只进影子、之后靠回放补，
    /// 探针要量的是「喂进去 → surface 解析 → 出帧」，所以先等闸门开）。
    private func waitReady(_ bridges: [GhosttyTerminalBridge], timeout: Double = 8) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline, bridges.contains(where: { $0.view.surface == nil || $0.grid == nil }) {
            GhosttyPresentLog.installIfPossible()
            try await Task.sleep(for: .milliseconds(20))
        }
        GhosttyPresentLog.installIfPossible()
        var last = bridges.map { "\(String(describing: $0.grid))" }
        var stableSince = CACurrentMediaTime()
        while CACurrentMediaTime() < deadline, CACurrentMediaTime() - stableSince < 0.3 {
            try await Task.sleep(for: .milliseconds(20))
            let now = bridges.map { "\(String(describing: $0.grid))" }
            if now != last { last = now; stableSince = CACurrentMediaTime() }
        }
        func notFeeding(_ bridge: GhosttyTerminalBridge) -> Bool { !(bridge.isSurfaceReady && bridge.router.isFeedingSurface) }
        while CACurrentMediaTime() < deadline, bridges.contains(where: notFeeding) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let missing = bridges.filter { $0.view.surface == nil || $0.grid == nil || notFeeding($0) }.count
        XCTAssertEqual(missing, 0, "有 \(missing) 个 Ghostty surface 没就绪")
    }

    private func resetFrames() {
        GhosttyPresentLog.reset()
    }

    /// 一段时间里：显示节拍、卡顿、各线程 CPU、各终端出帧。
    private struct Window {
        let ticks: Int
        let hitches: Int
        let cpu: ThreadCPU.Delta
        let framesPerTerminal: [Int]
        let nominalMS: Double
        let seconds: Double

        var line: String {
            String(format: "secs=%.0f ticks=%d nominal=%.2fms hitch=%d frames=%@ cpu-total=%.0fms(%.1f%%) main=%.0fms(%.1f%%) other=%.0fms | %@",
                   seconds, ticks, nominalMS, hitches, framesPerTerminal.description,
                   cpu.totalMS, cpu.totalMS / seconds / 10, cpu.mainMS, cpu.mainMS / seconds / 10, cpu.otherMS, cpu.line)
        }
    }

    private func measure(seconds: Double,
                         onTick: (@MainActor (Int) -> Void)? = nil,
                         every100ms: (@MainActor (Int) -> Void)? = nil) async throws -> Window {
        let counter = DisplayLinkCounter()
        var step = 0
        counter.onTick = { onTick?(step); step += 1 }
        resetFrames()
        let mainID = ThreadCPU.currentThreadID()
        let start = ThreadCPU.snapshot()
        counter.start()
        let t0 = CACurrentMediaTime()
        var beat = 0
        while CACurrentMediaTime() - t0 < seconds {
            every100ms?(beat)
            beat += 1
            // 按绝对时刻排下一拍，长跑不漂。
            let next = t0 + Double(beat) * 0.1
            let wait = max(0, next - CACurrentMediaTime())
            try await Task.sleep(for: .milliseconds(Int(wait * 1000)))
        }
        counter.stop()
        let end = ThreadCPU.snapshot()
        let frames = GhosttyPresentLog.perLayerCounts()
        return Window(ticks: counter.ticks,
                      hitches: counter.intervals.filter { $0 > counter.nominalIntervalMS * 1.5 }.count,
                      cpu: ThreadCPU.delta(from: start, to: end, mainID: mainID),
                      framesPerTerminal: frames, nominalMS: counter.nominalIntervalMS,
                      seconds: CACurrentMediaTime() - t0)
    }

    private final class ScrollbarSink: TerminalSurfaceScrollbarDelegate, TerminalSurfaceTitleDelegate {
        var scrollbar: TerminalScrollbar?
        /// surface 的 title delegate 报来的标题数。
        var titles = 0
        var lastTitle = ""
        /// 影子终端解析出来的标题数（`GhosttyTerminalBridge.onEvent`，生产上标题只认这一路）。
        var shadowTitles = 0
        func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) { self.scrollbar = scrollbar }
        func terminalDidChangeTitle(_ title: String) { titles += 1; lastTitle = title }
    }

    // MARK: - M2 内存：1 / 4 / 8 个终端，每个回滚 10k 行

    /// 布局：1 个 = 整屏；4 / 8 个 = 上下两格分屏可见（各半屏）+ 其余是隐藏标签（半屏尺寸、停画）。
    /// 每个终端灌 10,000 行带色 diff（含中文）进回滚。回滚上限是生产的配置（`GhosttyTerminalBridge.scrollback`：1 万行，
    /// surface 与影子同一份），读滚动条 total 和影子的总行数核对装下了。
    /// 每档之前先拆干净、等 1.5 s 量基线，读「增量」（第一档含 ghostty app 初始化）。
    ///
    /// 隐藏标签在这里是「surface 留着、只停画」（`setSurfaceVisible(false)`），是一个隐藏终端占用的上界；生产上隐藏标签过了
    /// `hiddenReleaseDelay` 会放掉 surface、从没露出过的根本不建（`GhosttyTerminalBridge.setOnScreen`），那时只剩影子的常驻。
    /// 每个终端都带一个影子终端，增量里含它（另列 `shadow-resident`）。
    func testM2Memory() async throws {
        let screen = sceneSize
        let engine = Self.engineLabel
        print("MEASURE m2 screen=\(screen) load=\(loadavg()) start \(MemoryProbe.read())")
        for count in [1, 4, 8] {
            try await Task.sleep(for: .milliseconds(1500))
            let before = MemoryProbe.read()
            let partsBefore = MemoryProbe.breakdown()
            let window = try makeSpikeWindow(size: screen)
            let full = CGRect(origin: .zero, size: screen)
            let top = CGRect(x: 0, y: 0, width: screen.width, height: screen.height / 2)
            let bottom = CGRect(x: 0, y: screen.height / 2, width: screen.width, height: screen.height / 2)
            func frame(_ index: Int) -> CGRect {
                if count == 1 { return full }
                return index == 1 ? bottom : top   // 0 = 上格，1 = 下格，其余隐藏标签叠在上格
            }
            // 隐藏的先加，可见的两格盖在最上面。
            let order = count == 1 ? [0] : Array(2..<count) + [0, 1]
            let t0 = CACurrentMediaTime()
            var bridges: [GhosttyTerminalBridge] = []
            var sinks: [ScrollbarSink] = []
            for index in order {
                let bridge = makeGhostty(frame: frame(index))
                let sink = ScrollbarSink()
                bridge.view.delegate = sink
                window.addSubview(bridge.view)
                bridges.append(bridge)
                sinks.append(sink)
                if index >= 2 { bridge.view.setSurfaceVisible(false) }
            }
            try await waitReady(bridges)
            for bridge in bridges {
                let cols = bridge.grid?.cols ?? 58
                bridge.feed(Data((TerminalSpikeCorpus.history(lines: 10_000, cols: cols)
                                  + TerminalSpikeCorpus.claudeFrame(0, cols: cols)).utf8))
            }
            for bridge in bridges { bridge.session.waitForPendingOutput() }
            try await Task.sleep(for: .milliseconds(300))
            let totals = sinks.map { Int($0.scrollbar?.total ?? 0) }
            let shadowRows = bridges.map(\.shadow.totalRows)
            let shadowMB = bridges.reduce(0.0) { $0 + Double($1.shadow.residentBytes) } / 1_048_576
            let fillMS = (CACurrentMediaTime() - t0) * 1000
            try await Task.sleep(for: .milliseconds(1500))
            let after = MemoryProbe.read()
            let parts = MemoryProbe.delta(MemoryProbe.breakdown(), partsBefore)
            let delta = after.footprint - before.footprint
            print(String(format: "MEASURE m2 %@ n=%d fill=%.0fms Δfootprint=%.1fMB per-terminal=%.2fMB Δgraphics=%.1fMB available=%.0fMB limit≈%.0fMB rows=%@ | Δparts %@",
                         engine, count, fillMS, delta, delta / Double(count), after.graphics - before.graphics,
                         after.available, after.limit, totals.description, MemoryProbe.describe(parts)))
            print(String(format: "MEASURE m2 %@ n=%d shadow-rows=%@ shadow-resident=%.1fMB (per-terminal %.2fMB)",
                         engine, count, shadowRows.description, shadowMB, shadowMB / Double(count)))
            print("MEASURE m2 \(engine) n=\(count) after \(after)")
            // 隐藏的 surface 不刷新滚动条回调（停画时不发），滚动条只核可见的那两个（数组末尾）；影子每个都核。
            let checked = Array(totals.suffix(min(2, count)))
            XCTAssertTrue(checked.allSatisfy { $0 >= 10_000 }, "n=\(count) surface 的回滚没装下 10k 行：\(totals)")
            XCTAssertTrue(shadowRows.allSatisfy { $0 >= 10_000 }, "n=\(count) 影子的回滚没装下 10k 行：\(shadowRows)")
            // 拆掉，看能不能还回去（#18：关掉的终端视图能否释放）。
            bridges.forEach { $0.view.removeFromSuperview() }
            bridges.removeAll()
            sinks.removeAll()
            window.isHidden = true
            try await Task.sleep(for: .milliseconds(1500))
            let released = MemoryProbe.read()
            print(String(format: "MEASURE m2 %@ n=%d released: footprint=%.1fMB (baseline %.1fMB, kept %.1fMB)",
                         engine, count, released.footprint, before.footprint, released.footprint - before.footprint))
        }
    }

    // MARK: - M6 打字回显

    /// 真输入路径：`insertText`（软键盘落字的公开入口，视图是 UIKeyInput）→ 终端把字节交给宿主 →
    /// `TerminalInputChannel` → 假后端原样回显（`MobileFakeTerminalTransport.echoesInput`）→ 输出路径 → 出帧。
    /// 后端接在 `GhosttyTerminalBridge.bind` 上（生产的 `MobileTerminalController` 接后端调的同一个入口）。
    /// 计时：调 `insertText` 之前到这个终端交出下一帧（`setContents:`）。
    /// 硬件键 `pressesBegan` 要真 `UIPress`，XCTest 造不出来（spike 已记），这里不量，留给 M16 手感。
    func testM6TypingEcho() async throws {
        let screen = sceneSize
        let engine = Self.engineLabel
        print("MEASURE m6 load=\(loadavg())")

        let transport = MobileFakeTerminalTransport(script: .idle)
        try await transport.connect()
        let gh = makeGhostty(frame: CGRect(origin: .zero, size: screen))
        let window = try makeSpikeWindow(size: screen)
        window.addSubview(gh.view)
        try await waitReady([gh])
        gh.bind(transport)
        gh.feed(Data("$ ".utf8))

        var results: [Double] = []
        var lost: [String] = []
        for round in 0..<2 {
            window.makeKey()
            XCTAssertTrue(gh.view.becomeFirstResponder(), "终端拿不到键盘")
            try await Task.sleep(for: .milliseconds(600))
            for index in 0..<40 {
                try await Task.sleep(for: .milliseconds(70 + index % 7 * 3))
                resetFrames()
                let char = String(UnicodeScalar(UInt8(97 + (index + round * 7) % 26)))
                let t0 = CACurrentMediaTime()
                gh.view.insertText(char)
                func frameAt() -> Double? { GhosttyPresentLog.read().times.first(where: { $0 >= t0 }) }
                while frameAt() == nil, CACurrentMediaTime() - t0 < 0.5 {
                    try await Task.sleep(for: .microseconds(300))
                }
                if let at = frameAt() { results.append((at - t0) * 1000) }
                // 这一下到后端没有（有丢键就记下是第几下、什么字）。
                try await Task.sleep(for: .milliseconds(30))
                let written = await transport.writtenBytes
                let expected = round * 40 + index + 1
                if written < expected - lost.count { lost.append("#\(round)/\(index)'\(char)'") }
            }
        }
        let echoed = await transport.writtenBytes
        print(String(format: "MEASURE m6 %@ typing-echo n=%d p50=%.2fms p95=%.2fms max=%.2fms",
                     engine, results.count, ProbeMetrics.percentile(results, 0.5),
                     ProbeMetrics.percentile(results, 0.95), results.max() ?? 0))
        print("MEASURE m6 bytes-reached-backend \(engine)=\(echoed) lost=\(lost) writes=\(await transport.writes.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "|"))")
        XCTAssertEqual(results.count, 80)
        XCTAssertEqual(echoed, 80, "按键没全到后端")
        let text = gh.session.readViewportText() ?? ""
        XCTAssertTrue(text.contains("$ a"), "回显没上屏：\(text.prefix(80))")
        XCTAssertTrue(gh.shadow.viewportText().contains("$ a"), "回显没进影子终端")
        gh.unbind()
        gh.view.removeFromSuperview()
        window.isHidden = true
    }

    // MARK: - M7 开标签与恢复

    /// (a) 新开一个终端到它交出第一帧，10 次（第一次含 ghostty app 初始化，单独列）。另列「到内容上屏」：
    ///     挂上窗口就喂的那段字节先进影子，surface 建好、网格对上之后由回放补进去（`GhosttyTerminalBridge.surfaceAttached`），
    ///     所以第一帧可能还是空屏；`content` = surface 的视口里读得到这段文字，`content-frame` = 那之后的第一帧。
    /// (b) 一次建 8 / 20 个终端（1 个可见整屏、其余隐藏标签），每个回放 2 MB 带色日志：总耗时、footprint 峰值（5 ms 采样）。
    ///     `receive` 后等全部解析完；回滚是生产的 1 万行。隐藏标签同 M2：surface 留着、只停画。
    func testM7OpenAndRestore() async throws {
        let screen = sceneSize
        let full = CGRect(origin: .zero, size: screen)
        let engine = Self.engineLabel
        print("MEASURE m7 load=\(loadavg())")
        // (a)
        var open: [Double] = []
        var content: [Double] = []
        var contentFrame: [Double] = []
        for round in 0..<10 {
            let window = try makeSpikeWindow(size: screen)
            try await Task.sleep(for: .milliseconds(200))
            resetFrames()
            let t0 = CACurrentMediaTime()
            let bridge = makeGhostty(frame: full)
            window.addSubview(bridge.view)
            bridge.feed(Data("Last login: Mon Nov  9 10:00:00\r\n$ ".utf8))
            var first: Double?, shown: Double?, shownFrame: Double?
            while first == nil || shownFrame == nil, CACurrentMediaTime() - t0 < 3 {
                GhosttyPresentLog.installIfPossible()
                let presents = GhosttyPresentLog.read().times
                if first == nil { first = presents.first }
                if shown == nil, bridge.isSurfaceReady, bridge.router.isFeedingSurface,
                   bridge.session.readViewportText()?.contains("Last login") == true {
                    shown = CACurrentMediaTime()
                }
                if let shown, shownFrame == nil { shownFrame = presents.first(where: { $0 >= shown }) }
                if first == nil || shownFrame == nil { try await Task.sleep(for: .milliseconds(1)) }
            }
            if let first { open.append((first - t0) * 1000) }
            if let shown { content.append((shown - t0) * 1000) }
            if let shownFrame { contentFrame.append((shownFrame - t0) * 1000) }
            if round == 0 {
                print(String(format: "MEASURE m7 open-first %@ round0=%.1fms content=%.1fms", engine,
                             ((first ?? t0) - t0) * 1000, ((shown ?? t0) - t0) * 1000))
            }
            try await Task.sleep(for: .milliseconds(150))
            bridge.view.removeFromSuperview()
            window.isHidden = true
        }
        for (name, values) in [("open-to-first-frame", open), ("open-to-content", content), ("open-to-content-frame", contentFrame)] {
            let warm = Array(values.dropFirst())
            print(String(format: "MEASURE m7 %@ %@ n=%d first=%.1fms warm p50=%.1fms p95=%.1fms max=%.1fms",
                         name, engine, values.count, values.first ?? 0, ProbeMetrics.percentile(warm, 0.5),
                         ProbeMetrics.percentile(warm, 0.95), warm.max() ?? 0))
        }
        // 第一轮的第一帧可能赶在帧计数的钩子装上之前（`IOSurfaceLayer` 这个类第一个 surface 建出来才注册），容它漏一次。
        XCTAssertGreaterThanOrEqual(open.count, 9, "有终端 3 秒内没交出第一帧")
        XCTAssertEqual(content.count, 10, "有终端 3 秒内内容没进 surface")

        // (b)
        let payload = TerminalSpikeCorpus.flood(bytes: 2 * 1024 * 1024)
        for count in [8, 20] {
            try await Task.sleep(for: .milliseconds(1500))
            let before = MemoryProbe.read()
            let window = try makeSpikeWindow(size: screen)
            let sampler = FootprintSampler()
            let cpu0 = ProcessCPU.seconds()
            let t0 = CACurrentMediaTime()
            resetFrames()
            var bridges: [GhosttyTerminalBridge] = []
            for index in 0..<count {
                let bridge = makeGhostty(frame: full)
                window.addSubview(bridge.view)
                if index != count - 1 { bridge.view.setSurfaceVisible(false) }
                bridges.append(bridge)
            }
            try await waitReady(bridges, timeout: 15)
            for bridge in bridges { bridge.feed(payload) }
            for bridge in bridges { bridge.session.waitForPendingOutput() }
            let parsed = CACurrentMediaTime()
            while CACurrentMediaTime() - parsed < 1,
                  GhosttyPresentLog.read().times.last.map({ $0 >= parsed }) != true {
                try await Task.sleep(for: .milliseconds(2))
            }
            let firstVisibleFrame = GhosttyPresentLog.read().times.last
            let wall = ((firstVisibleFrame ?? CACurrentMediaTime()) - t0) * 1000
            let cpu = (ProcessCPU.seconds() - cpu0) * 1000
            try await Task.sleep(for: .milliseconds(500))
            let peak = sampler.stop()
            let after = MemoryProbe.read()
            print(String(format: "MEASURE m7 restore %@ n=%d x2MB total=%.0fms cpu=%.0fms peak=%.1fMB(Δ%.1f, %d samples) settled-Δ=%.1fMB available=%.0fMB",
                         engine, count, wall, cpu, peak.peakMB, peak.peakMB - before.footprint, peak.samples,
                         after.footprint - before.footprint, after.available))
            XCTAssertTrue(bridges.allSatisfy { $0.shadow.totalFedBytes >= payload.count }, "有终端没吃完 2 MB")
            bridges.forEach { $0.view.removeFromSuperview() }
            bridges.removeAll()
            window.isHidden = true
        }
    }

    // MARK: - M8 多终端并发输出

    /// 上下两格分屏可见 + 2 个后台标签，4 个终端同时来 Claude 式输出（每 100 ms 一个同步帧，相位错开）。
    /// 另一档：两格可见的整屏每个显示节拍都变（全屏 TUI 上界），后台两个照常 Claude。两档各 8 秒，跑两轮。
    func testM8ConcurrentOutput() async throws {
        let screen = sceneSize
        let top = CGRect(x: 0, y: 0, width: screen.width, height: screen.height / 2)
        let bottom = CGRect(x: 0, y: screen.height / 2, width: screen.width, height: screen.height / 2)
        let engine = Self.engineLabel
        print("MEASURE m8 load=\(loadavg())")
        let window = try makeSpikeWindow(size: screen)
        // 顺序 [2, 3, 0, 1]：前两个是后台标签（停画），后两个是可见的上、下格。
        var bridges: [GhosttyTerminalBridge] = []
        for index in [2, 3, 0, 1] {
            let bridge = makeGhostty(frame: index == 1 ? bottom : top)
            window.addSubview(bridge.view)
            if index >= 2 { bridge.view.setSurfaceVisible(false) }
            bridges.append(bridge)
        }
        try await waitReady(bridges)
        for bridge in bridges {
            let cols = bridge.grid?.cols ?? 58
            bridge.feed(Data((TerminalSpikeCorpus.history(lines: 300, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols)).utf8))
        }
        try await Task.sleep(for: .milliseconds(800))

        func feed(_ terminal: Int, _ text: String) { bridges[terminal].feed(Data(text.utf8)) }
        func cols(_ terminal: Int) -> Int { bridges[terminal].grid?.cols ?? 58 }
        func rows(_ terminal: Int) -> Int { bridges[terminal].grid?.rows ?? 25 }
        var lines: [String] = []
        for round in 0..<2 {
            try await Task.sleep(for: .milliseconds(500))
            let fedBefore = bridges.map(\.shadow.totalFedBytes)
            let claude = try await measure(seconds: 8, every100ms: { beat in
                for terminal in 0..<4 { feed(terminal, TerminalSpikeCorpus.claudeFrame(beat * 4 + terminal + 1, cols: cols(terminal))) }
            })
            lines.append("MEASURE m8 \(engine)/4x-claude#\(round) " + claude.line)
            let fullscreen = try await measure(seconds: 8, onTick: { step in
                for terminal in 2..<4 {
                    feed(terminal, "\u{1B}[?2026h" + TerminalSpikeCorpus.screen(rows: rows(terminal), salt: step + terminal) + "\u{1B}[?2026l")
                }
            }, every100ms: { beat in
                for terminal in 0..<2 { feed(terminal, TerminalSpikeCorpus.claudeFrame(beat * 2 + terminal + 1, cols: cols(terminal))) }
            })
            lines.append("MEASURE m8 \(engine)/2x-fullscreen+2x-claude#\(round) " + fullscreen.line)
            // 结构判据：四个终端都真的吃到了字节，可见的两格真的出了帧。
            let fedAfter = bridges.map(\.shadow.totalFedBytes)
            XCTAssertTrue(zip(fedBefore, fedAfter).allSatisfy { $0 < $1 }, "有终端没吃到输出：\(fedBefore) → \(fedAfter)")
            XCTAssertGreaterThanOrEqual(fullscreen.framesPerTerminal.count, 2, "可见的两格没都出帧：\(fullscreen.framesPerTerminal)")
        }
        lines.forEach { print($0) }
        bridges.forEach { $0.view.removeFromSuperview() }
        window.isHidden = true
    }

    // MARK: - M9 功耗：10 分钟 Claude 式输出

    /// 一个整屏终端，每 100 ms 一个 Claude 同步帧，跑 10 分钟。
    /// 读：进程 CPU 时间（getrusage，含已退出线程）、各线程 CPU、出帧、`thermalState` 每 30 s 采一次。
    /// 时长可用 `UTERM_MEASURE_M9_SECONDS` 改（默认 600）。同时在 Mac 上录 Power Profiler（见报告）。
    func testM9Power() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["UTERM_MEASURE_M9_SECONDS"] ?? "") ?? 600
        let screen = sceneSize
        let full = CGRect(origin: .zero, size: screen)
        let engine = Self.engineLabel
        print("MEASURE m9 load=\(loadavg()) seconds=\(seconds) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) battery=\(UIDevice.current.batteryLevel) start-wall=\(Date())")
        UIDevice.current.isBatteryMonitoringEnabled = true
        // 空闲基线 60 s（宿主自己的开销）。
        let idleCPU0 = ProcessCPU.seconds()
        try await Task.sleep(for: .seconds(60))
        let idleMS = (ProcessCPU.seconds() - idleCPU0) * 1000
        print(String(format: "MEASURE m9 idle-baseline 60s cpu=%.0fms (%.2f%%)", idleMS, idleMS / 600))

        let window = try makeSpikeWindow(size: screen)
        let bridge = makeGhostty(frame: full)
        window.addSubview(bridge.view)
        try await waitReady([bridge])
        let cols = bridge.grid?.cols ?? 58
        bridge.feed(Data(TerminalSpikeCorpus.history(lines: 300, cols: cols).utf8))
        try await Task.sleep(for: .seconds(2))
        var thermal: [Int] = [ProcessInfo.processInfo.thermalState.rawValue]
        let cpu0 = ProcessCPU.seconds()
        let battery0 = UIDevice.current.batteryLevel
        print("MEASURE m9 \(engine) begin wall=\(Date())")
        let window10 = try await measure(seconds: seconds, every100ms: { beat in
            bridge.feed(Data(TerminalSpikeCorpus.claudeFrame(beat + 1, cols: cols).utf8))
            if beat % 300 == 299 { thermal.append(ProcessInfo.processInfo.thermalState.rawValue) }
        })
        let cpuMS = (ProcessCPU.seconds() - cpu0) * 1000
        print("MEASURE m9 \(engine) end wall=\(Date())")
        print(String(format: "MEASURE m9 %@ %.0fs process-cpu=%.0fms (%.2f%%, net of idle ≈%.2f%%) thermal=%@ battery %.2f→%.2f | %@",
                     engine, window10.seconds, cpuMS, cpuMS / window10.seconds / 10,
                     cpuMS / window10.seconds / 10 - idleMS / 600, thermal.description, battery0,
                     UIDevice.current.batteryLevel, window10.line))
        XCTAssertGreaterThan(window10.framesPerTerminal.first ?? 0, 0, "整段时间一帧都没交")
        bridge.view.removeFromSuperview()
        window.isHidden = true
    }

    // MARK: - M10 后台

    /// 单元测试宿主不能真的退后台，这里模拟：发 `UIApplication.didEnterBackgroundNotification`（GhosttyKit 自己的生命周期
    /// 监听据此 `setApplicationActive(false)`、停 display link、wakeup 不再 tick；`GhosttyTerminalBridge` 据此改成只喂影子）+
    /// 再 `setSurfaceVisible(false)`。和真后台的区别：进程不会被挂起、主线程照常转，系统也不收内存；
    /// 真后台里只有 `BGContinuedProcessingTask` 续命时才会继续收输出，那时主线程也在转——与这里同一情形。
    ///
    /// 期间每 100 ms 来一个 Claude 帧，**带 OSC 0 标题**（Claude Code 思考时会改标题；标题要进 ghostty 的 app mailbox，
    /// mailbox 只有 64 格、只有 tick 才清——surface 在后台接着吃字节会卡死解析，所以后台只喂影子）；中途再来一段 4 MB 洪流。
    /// 每 10 s 记：footprint、surface 未解析字节、surface 报的标题数、影子解析出的标题数。回前台后量：多久交出含最新标记的一帧。
    /// 时长 `UTERM_MEASURE_M10_SECONDS`（默认 300）。
    func testM10Background() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["UTERM_MEASURE_M10_SECONDS"] ?? "") ?? 300
        // 对照组：`UTERM_MEASURE_M10_TITLES=0` 时 Claude 帧不带 OSC 0 标题（看卡住的是不是 mailbox）。
        let withTitles = ProcessInfo.processInfo.environment["UTERM_MEASURE_M10_TITLES"] != "0"
        let screen = sceneSize
        let full = CGRect(origin: .zero, size: screen)
        print("MEASURE m10 load=\(loadavg()) seconds=\(seconds) titles=\(withTitles)")

        let backend = ScriptedBackend()
        try await backend.connect()
        let window = try makeSpikeWindow(size: screen)
        let gh = makeGhostty(frame: full)
        let sink = ScrollbarSink()
        gh.view.delegate = sink
        // 生产上标题只认影子解析出来的（`onEvent`）；surface 的 title delegate 在这里只用来数它收到了几条。
        gh.onEvent = { [sink] event in
            if case .titleChanged = event { sink.shadowTitles += 1 }
        }
        window.addSubview(gh.view)
        try await waitReady([gh])
        gh.bind(backend)
        let cols = gh.grid?.cols ?? 58
        try await Task.sleep(for: .milliseconds(500))

        func emit(_ text: String) { backend.yield(Data(text.utf8)) }
        func claude(_ n: Int) -> String {
            (withTitles ? "\u{1B}]0;\(["✢", "✳", "✶", "✻", "✽"][n % 5]) Claude Code · 第 \(n) 帧\u{07}" : "")
                + TerminalSpikeCorpus.claudeFrame(n, cols: cols)
        }
        // 前台先确认标题能到。
        for n in 0..<5 { emit(claude(n)); try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(300))
        let titlesForeground = sink.titles
        let shadowTitlesForeground = sink.shadowTitles
        print("MEASURE m10 foreground titles=\(titlesForeground) shadow-titles=\(shadowTitlesForeground) last=\(sink.lastTitle) shadow-title=\(gh.shadow.title)")
        if withTitles { XCTAssertGreaterThan(shadowTitlesForeground, 0, "前台影子没解析出标题") }

        let memory0 = MemoryProbe.read()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        gh.view.setSurfaceVisible(false)
        resetFrames()
        let t0 = CACurrentMediaTime()
        var beat = 0
        var flooded = false
        var maxPending = 0
        var nextReport = 10.0
        let flood = TerminalSpikeCorpus.flood(bytes: 4 * 1024 * 1024)
        while CACurrentMediaTime() - t0 < seconds {
            emit(claude(beat + 10))
            beat += 1
            let elapsed = CACurrentMediaTime() - t0
            if !flooded, elapsed > seconds / 2 {
                flooded = true
                backend.yield(flood)
                print("MEASURE m10 flood 4MB at \(Int(elapsed))s")
            }
            maxPending = max(maxPending, gh.session.pendingOutputByteCount)
            if elapsed >= nextReport {
                nextReport += 10
                let m = MemoryProbe.read()
                // app-state：真机上假的后台通知之外，系统自己也可能发真的进出前台（0 = active，2 = background）；
                // gh-bg / replays 看 bridge 有没有被真通知翻回前台过。
                print(String(format: "MEASURE m10 t=%3.0fs footprint=%.1fMB(Δ%.1f) gh-pending=%d gh-titles=%d shadow-titles=%d gh-presents=%d shadow-only=%d shadow-resident=%.1fMB shadow-rows=%d app-state=%d gh-bg=%@ replays=%d",
                             elapsed, m.footprint, m.footprint - memory0.footprint, gh.session.pendingOutputByteCount,
                             sink.titles, sink.shadowTitles, GhosttyPresentLog.read().times.count,
                             gh.router.currentStats.shadowOnlyBytes, Double(gh.shadow.residentBytes) / 1_048_576, gh.shadow.totalRows,
                             UIApplication.shared.applicationState.rawValue, String(gh.isAppInBackground), gh.router.currentStats.replays))
            }
            let next = t0 + Double(beat) * 0.1
            try await Task.sleep(for: .milliseconds(Int(max(0, next - CACurrentMediaTime()) * 1000)))
        }
        let marker = "BACK-MARKER-\(beat)"
        emit("\r\n\(marker)\r\n")
        try await Task.sleep(for: .milliseconds(200))
        let memoryBG = MemoryProbe.read()
        let pendingAtEnd = gh.session.pendingOutputByteCount
        let titlesInBackground = sink.titles - titlesForeground
        let shadowTitlesInBackground = sink.shadowTitles - shadowTitlesForeground
        let presentsInBackground = GhosttyPresentLog.read().times.count
        print(String(format: "MEASURE m10 background end: frames-sent=%d Δfootprint=%.1fMB gh-pending-max=%d gh-pending-end=%d gh-titles-in-bg=%d shadow-titles-in-bg=%d gh-presents-in-bg=%d",
                     beat, memoryBG.footprint - memory0.footprint, maxPending, pendingAtEnd, titlesInBackground,
                     shadowTitlesInBackground, presentsInBackground))
        let routed = gh.router.currentStats
        let shadowHasMarker = gh.shadow.viewportText().contains(marker)
        print(String(format: "MEASURE m10 shadow at background end: shadow-only=%d dropped-surface=%d shadow-resident=%.1fMB shadow-rows=%d shadow-has-marker=%@",
                     routed.shadowOnlyBytes, routed.droppedSurfaceBytes, Double(gh.shadow.residentBytes) / 1_048_576,
                     gh.shadow.totalRows, String(shadowHasMarker)))
        XCTAssertTrue(shadowHasMarker, "后台期间的输出没进影子终端")

        // 回前台。
        resetFrames()
        let back = CACurrentMediaTime()
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        gh.view.setSurfaceVisible(true)
        var ghAt: Double?, ghParsedAt: Double?
        while CACurrentMediaTime() - back < 10, ghAt == nil {
            if ghParsedAt == nil, gh.session.pendingOutputByteCount == 0,
               gh.session.readViewportText()?.contains(marker) == true { ghParsedAt = CACurrentMediaTime() }
            if let ghParsedAt, ghAt == nil, let present = GhosttyPresentLog.read().times.last, present >= ghParsedAt { ghAt = present }
            try await Task.sleep(for: .milliseconds(2))
        }
        print(String(format: "MEASURE m10 foreground catch-up: %@=%@ (parsed %@) titles-after=%d",
                     Self.engineLabel,
                     ghAt.map { String(format: "%.0fms", ($0 - back) * 1000) } ?? "never",
                     ghParsedAt.map { String(format: "%.0fms", ($0 - back) * 1000) } ?? "never",
                     sink.titles - titlesForeground))
        let replayed = gh.router.currentStats
        print(String(format: "MEASURE m10 replay: count=%d snapshot=%dB stream=%dB build=%.1fms (%@) grid=%dx%d unwrapped=%@ error=%@ surface-matches-shadow=%@",
                     replayed.replays, replayed.lastSnapshotBytes, replayed.lastReplayBytes, replayed.lastReplayBuildSeconds * 1000,
                     replayed.lastReplayPhases, gh.shadow.size.cols, gh.shadow.size.rows,
                     String(replayed.lastReplayUnwrapped), replayed.lastReplayError ?? "-",
                     GhosttyViewportDiff.firstDifference(surface: gh.session.readViewportText() ?? "",
                                                         shadow: gh.shadow.viewportText()) ?? "true"))
        try await Task.sleep(for: .seconds(2))
        print("MEASURE m10 after foreground \(MemoryProbe.read()) gh-pending=\(gh.session.pendingOutputByteCount)")
        XCTAssertNotNil(ghAt, "回前台没补出最新画面")
        gh.unbind()
        gh.view.removeFromSuperview()
        window.isHidden = true
    }

    // MARK: - M12 系统等宽字体

    /// `font-family` 依次试几个名字，看格子尺寸、截图是不是还和默认（内嵌 JetBrains Mono）一样——一样就是没取到、回退了。
    /// 参照是 `UIFont.monospacedSystemFont`（SF Mono）：UIKit 直接用它把同样的三行画一张图（不经终端引擎）。
    /// 截图作为附件导出（xcresult）。
    func testM12SystemMonospaceFont() async throws {
        let size = CGSize(width: 440, height: 300)
        let sampleLines = ["0Oo1lIi g@{}[]", "中文 →✓ ─│╭╮", "The quick brown fox 0123456789"]
        let sample = "\u{1B}[2J\u{1B}[H" + sampleLines.map { $0 + "\r\n" }.joined()
        let system = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: system]).width
        print("MEASURE m12 UIFont.monospacedSystemFont fontName=\(system.fontName) familyName=\(system.familyName) advance=\(advance)pt lineHeight=\(system.lineHeight)")
        let candidates: [String?] = [nil, "SF Mono", ".SF Mono", "SFMono-Regular", system.fontName, system.familyName,
                                     ".AppleSystemUIFontMonospaced", "Menlo", "Courier New"]
        var reference: Data?
        for name in candidates {
            let controller = GhosttyTerminal.TerminalController { builder in
                if let name { builder.withFontFamily(name) }
                builder.withFontSize(GhosttyTerminalBridge.ghosttyFontSize(points: 11))
                builder.withBackground("#000000")
                builder.withForeground("#FFFFFF")
            }
            let window = try makeSpikeWindow(size: size)
            let bridge = makeGhostty(frame: CGRect(origin: .zero, size: size), controller: controller)
            window.addSubview(bridge.view)
            try await waitReady([bridge])
            bridge.feed(Data(sample.utf8))
            bridge.session.waitForPendingOutput()
            try await Task.sleep(for: .milliseconds(400))
            let image = bridge.view.snapshotImage()
            let crop = image?.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: 1320, height: 200))
            let png = crop.map { UIImage(cgImage: $0).pngData() ?? Data() } ?? Data()
            if name == nil { reference = png }
            let sameAsDefault = name != nil && png == reference
            print("MEASURE m12 ghostty font-family=\(name ?? "(default)") grid=\(String(describing: bridge.grid)) same-pixels-as-default=\(sameAsDefault) issue=\(controller.lastConfigurationIssue ?? "-")")
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "m12-ghostty-\(name ?? "default")"
            attachment.lifetime = .keepAlways
            add(attachment)
            bridge.view.removeFromSuperview()
            window.isHidden = true
        }
        // 参照：UIKit 用系统等宽字体直接画同样的三行（黑底白字、3x，和上面裁出来的 1320×200 像素同一块大小）。
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let bounds = CGRect(x: 0, y: 0, width: 440, height: 200.0 / 3)
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            UIColor.black.setFill()
            context.fill(bounds)
            for (row, line) in sampleLines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 0, y: CGFloat(row) * system.lineHeight),
                                        withAttributes: [.font: system, .foregroundColor: UIColor.white])
            }
        }
        let attachment = XCTAttachment(data: image.pngData() ?? Data(), uniformTypeIdentifier: "public.png")
        attachment.name = "m12-uikit-sfmono"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(String(format: "MEASURE m12 uikit-reference cell=%.2fx%.2fpt grid=%dx%d in %@",
                     advance, system.lineHeight, Int(size.width / advance), Int(size.height / system.lineHeight), "\(size)"))
    }

    // MARK: - M15 Kitty 图形

    /// 经 host-managed IO 喂 Kitty 图形协议（APC `_G`，PNG 直传 + 分块），确认：显示、应答、滚出屏、滚回来、清屏释放、内存回收。
    /// 旧引擎不认 Kitty 协议（换引擎之前这里还喂它一遍作对照，读数在 measure-ios.md）。
    func testM15KittyGraphics() async throws {
        let host = try GhosttyProbeHost(size: sceneSize)
        defer { host.close() }
        try await host.waitUntilReady()
        host.bridge.inputLog = []
        let sink = ScrollbarSink()
        host.view.delegate = sink
        let red = KittyCorpus.png(width: 96, height: 96, rgb: (255, 0, 0))
        let blue = KittyCorpus.png(width: 96, height: 96, rgb: (0, 0, 255))
        func shot() -> CGImage? { host.view.snapshotImage()?.cgImage }
        func redFraction() -> Double { shot().map { PixelProbe.fraction(of: $0, near: (255, 0, 0)) } ?? 0 }
        func blueFraction() -> Double { shot().map { PixelProbe.fraction(of: $0, near: (0, 0, 255)) } ?? 0 }

        host.feedAndWait("\u{1B}[2J\u{1B}[H$ kitty icat red.png\r\n" + KittyCorpus.direct(red, id: 1, columns: 10, rows: 5) + "\r\n$ ")
        try await Task.sleep(for: .milliseconds(400))
        let redShown = redFraction()
        host.feedAndWait("\r\n$ kitty icat blue.png\r\n" + KittyCorpus.chunked(blue, id: 2, columns: 10, rows: 5) + "\r\n$ ")
        try await Task.sleep(for: .milliseconds(400))
        let blueShown = blueFraction()
        try await Task.sleep(for: .milliseconds(100))
        let replies = String(decoding: (host.bridge.inputLog ?? []).flatMap { [UInt8]($0) }, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}", with: "⎋")
        print(String(format: "MEASURE m15 shown direct red=%.4f chunked blue=%.4f replies=%@ png=%dB/%dB",
                     redShown, blueShown, replies, red.count, blue.count))
        let attachment = XCTAttachment(image: host.view.snapshotImage() ?? UIImage())
        attachment.name = "m15-kitty-shown"; attachment.lifetime = .keepAlways
        add(attachment)

        // 滚出屏、再滚回来。
        host.feedAndWait((0..<200).map { "line \($0)\r\n" }.joined())
        try await Task.sleep(for: .milliseconds(300))
        let afterScrollOut = (redFraction(), blueFraction())
        let scale = Double(host.view.window?.screen.nativeScale ?? 3)
        for _ in 0..<40 { host.view.sendMouseScroll(x: 0, y: 120 * scale); try await Task.sleep(for: .milliseconds(16)) }
        try await Task.sleep(for: .milliseconds(400))
        let scrolledBack = (redFraction(), blueFraction(), sink.scrollbar.map { "\($0.offset)/\($0.total)" } ?? "?")
        print(String(format: "MEASURE m15 scrolled-out red=%.4f blue=%.4f | scrolled-back red=%.4f blue=%.4f viewport=%@",
                     afterScrollOut.0, afterScrollOut.1, scrolledBack.0, scrolledBack.1, scrolledBack.2))
        host.feedAndWait("x")   // 打字回到底部之外的另一种：来输出不动视口；这里直接滚回底部。
        for _ in 0..<60 { host.view.sendMouseScroll(x: 0, y: -200 * scale); try await Task.sleep(for: .milliseconds(8)) }

        // 内存：大图（噪点 PNG，压不小）显示 → 删除。字节先在测试这边编好（Data），喂之前量基线，
        // 喂的过程 5 ms 采一次峰值；显示后 1 s / 4 s、删除后 2 s 各读一次，带 VM 分账。
        var cleared = (0.0, 0.0)
        for (side, mode) in [(1024, "chunked"), (2048, "chunked"), (2048, "direct")] {
            let png = KittyCorpus.png(width: side, height: side, rgb: (0, 255, 0), noise: true)
            let bytes = Data(("\r\n" + (mode == "direct" ? KittyCorpus.direct(png, id: 3, columns: 40, rows: 20)
                                                         : KittyCorpus.chunked(png, id: 3, columns: 40, rows: 20)) + "\r\n").utf8)
            try await Task.sleep(for: .seconds(1))
            let m0 = MemoryProbe.read()
            let parts0 = MemoryProbe.breakdown()
            let sampler = FootprintSampler()
            host.bridge.feed(bytes)
            host.bridge.session.waitForPendingOutput()
            try await Task.sleep(for: .seconds(1))
            let m1 = MemoryProbe.read()
            try await Task.sleep(for: .seconds(3))
            let m1b = MemoryProbe.read()
            let parts1 = MemoryProbe.delta(MemoryProbe.breakdown(), parts0)
            let peak = sampler.stop()
            let greenShown = shot().map { PixelProbe.fraction(of: $0, near: (0, 255, 0)) } ?? 0
            host.feedAndWait("\u{1B}[2J\u{1B}[3J\u{1B}[H" + KittyCorpus.deleteAll + "$ ")
            try await Task.sleep(for: .seconds(2))
            let m2 = MemoryProbe.read()
            cleared = (redFraction(), blueFraction())
            print(String(format: "MEASURE m15 big %dx%d %@ png=%.1fMB rgba=%.1fMB apc=%.1fMB | footprint %.1f → peak %.1f (Δ%.1f) → +1s Δ%.1f → +4s Δ%.1f (graphics Δ%.1f) → deleted Δ%.1f (graphics Δ%.1f) | visible-noise=%.3f | Δparts %@",
                         side, side, mode, Double(png.count) / 1048576, Double(side * side * 4) / 1048576, Double(bytes.count) / 1048576,
                         m0.footprint, peak.peakMB, peak.peakMB - m0.footprint, m1.footprint - m0.footprint,
                         m1b.footprint - m0.footprint, m1b.graphics - m0.graphics, m2.footprint - m0.footprint,
                         m2.graphics - m0.graphics, greenShown, MemoryProbe.describe(parts1)))
        }

        XCTAssertGreaterThan(redShown, 0.001, "Kitty 直传的图没显示")
        XCTAssertGreaterThan(blueShown, 0.001, "Kitty 分块的图没显示")
        XCTAssertLessThan(cleared.0 + cleared.1, 0.0005, "清屏 + 删除后图还在")
    }
}

/// 输出完全由测试驱动的后端：`yield` 直接进 `outputStream`；写入丢弃。
actor ScriptedBackend: TerminalBackend {
    nonisolated let outputStream: AsyncStream<Data>
    nonisolated let exitStream: AsyncStream<Void>
    private nonisolated let output: AsyncStream<Data>.Continuation
    private let exit: AsyncStream<Void>.Continuation

    init() {
        var out: AsyncStream<Data>.Continuation!
        outputStream = AsyncStream(bufferingPolicy: .unbounded) { out = $0 }
        output = out
        var ex: AsyncStream<Void>.Continuation!
        exitStream = AsyncStream { ex = $0 }
        exit = ex
    }

    nonisolated func yield(_ data: Data) { output.yield(data) }
    func connect() async throws {}
    func write(_ data: Data) async {}
    func resize(cols: UInt16, rows: UInt16) async {}
    func close() async { output.finish(); exit.finish() }
}
