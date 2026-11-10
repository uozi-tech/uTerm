import Darwin
import GhosttyTerminal
import ObjectiveC
import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

/// 终端引擎迁移「测量门」的 iOS 真机读数（docs/ghostty-migration-plan.md §3、docs/ghostty-eval/measure-ios.md）。
/// 每一项都在同一次运行里把 GhosttyKit 和 SwiftTerm 对照着量；闸门只放结构判据（真出帧了、真解析了、没丢），
/// 不卡绝对毫秒——读数打印成 `MEASURE …` 行，报告从日志里取。
///
/// 这些用例很重（M9 一条就 20 多分钟），只在真机上按 `-only-testing` 单独跑；`make test-mobile-fast` 不该捎上它们，
/// 所以全部挂在环境变量 `UTERM_MEASURE=1` 后面。
@MainActor
final class GhosttyMeasureProbeTests: XCTestCase {
    private enum Engine: String { case swiftterm, ghostty }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["UTERM_MEASURE"] == "1"
            || UserDefaults.standard.bool(forKey: "UTERM_MEASURE") else {
            throw XCTSkip("测量门探针：设 UTERM_MEASURE=1 才跑（真机、单独跑）")
        }
        UIApplication.shared.isIdleTimerDisabled = true
        SwiftTermDrawLog.install()
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

    /// 一个 SwiftTerm 终端：和 `SwiftTermView.makeUIView` / `SwiftTermProbeHost` 同一套装配。
    private func makeSwiftTerm(frame: CGRect, scrollback: Int) -> (view: MTerminalView, container: MTerminalContainerView) {
        let view = MTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        view.contentInsetAdjustmentBehavior = .never
        view.inputAccessoryView = nil
        view.caretViewTracksFocus = false
        let scheme = MTerminalColors.resolve(dark: true)
        TerminalAppearance.applyColors(to: view, scheme: scheme)
        TerminalAppearance.applyCaretColors(to: view, scheme: scheme, shape: .block)
        view.backgroundColor = scheme.backgroundColor
        view.getTerminal().changeScrollback(scrollback)
        let container = MTerminalContainerView(terminalView: view, fontSize: 11)
        container.frame = frame
        return (view, container)
    }

    private func makeGhostty(frame: CGRect,
                             controller: GhosttyTerminal.TerminalController = GhosttyProbeHost.controller) -> GhosttyTerminalBridge {
        GhosttyTerminalBridge(controller: controller, frame: frame)
    }

    /// 等所有 surface 建好、网格报上来并停稳。
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
        let missing = bridges.filter { $0.view.surface == nil || $0.grid == nil }.count
        XCTAssertEqual(missing, 0, "有 \(missing) 个 Ghostty surface 没就绪")
    }

    private func resetFrames() {
        SwiftTermDrawLog.draws.removeAll()
        SwiftTermDrawLog.perView.removeAll()
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

    private func measure(seconds: Double, engine: Engine,
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
        let frames: [Int] = engine == .swiftterm
            ? SwiftTermDrawLog.perView.values.sorted(by: >)
            : GhosttyPresentLog.perLayerCounts()
        return Window(ticks: counter.ticks,
                      hitches: counter.intervals.filter { $0 > counter.nominalIntervalMS * 1.5 }.count,
                      cpu: ThreadCPU.delta(from: start, to: end, mainID: mainID),
                      framesPerTerminal: frames, nominalMS: counter.nominalIntervalMS,
                      seconds: CACurrentMediaTime() - t0)
    }

    private final class ScrollbarSink: TerminalSurfaceScrollbarDelegate, TerminalSurfaceTitleDelegate {
        var scrollbar: TerminalScrollbar?
        var titles = 0
        var lastTitle = ""
        func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) { self.scrollbar = scrollbar }
        func terminalDidChangeTitle(_ title: String) { titles += 1; lastTitle = title }
    }

    // MARK: - M2 内存：1 / 4 / 8 个终端，每个回滚 10k 行

    /// 布局：1 个 = 整屏；4 / 8 个 = 上下两格分屏可见（各半屏）+ 其余是隐藏标签（半屏尺寸、停画）。
    /// 每个终端灌 10,000 行带色 diff（含中文）进回滚。SwiftTerm 的回滚上限临时开到 10,000（生产是 1,000）；
    /// Ghostty 用默认 `scrollback-limit`（10 MB），实测装得下 10k 行（读滚动条 total 核对）。
    /// 每档之前先拆干净、等 1.5 s 量基线，读「增量」。SwiftTerm 全部跑完再跑 Ghostty（Ghostty 第一档含 app 初始化）。
    func testM2Memory() async throws {
        let screen = sceneSize
        print("MEASURE m2 screen=\(screen) load=\(loadavg()) start \(MemoryProbe.read())")
        for engine in [Engine.swiftterm, .ghostty] {
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
                var totals: [Int] = []
                var keep: [AnyObject] = []
                let t0 = CACurrentMediaTime()
                switch engine {
                case .swiftterm:
                    var views: [MTerminalView] = []
                    for index in order {
                        let (view, container) = makeSwiftTerm(frame: frame(index), scrollback: 10_000)
                        window.addSubview(container)
                        container.layoutIfNeeded()
                        container.isOnScreen = index < 2
                        keep.append(container)
                        views.append(view)
                    }
                    for view in views {
                        let cols = view.getTerminal().cols
                        view.feed(text: TerminalSpikeCorpus.history(lines: 10_000, cols: cols)
                                  + TerminalSpikeCorpus.claudeFrame(0, cols: cols))
                        totals.append(view.getTerminal().buffer.yDisp + view.getTerminal().rows)
                    }
                case .ghostty:
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
                    totals = sinks.map { Int($0.scrollbar?.total ?? 0) }
                    keep.append(contentsOf: bridges)
                    keep.append(contentsOf: sinks)
                }
                let fillMS = (CACurrentMediaTime() - t0) * 1000
                try await Task.sleep(for: .milliseconds(1500))
                let after = MemoryProbe.read()
                let parts = MemoryProbe.delta(MemoryProbe.breakdown(), partsBefore)
                let delta = after.footprint - before.footprint
                print(String(format: "MEASURE m2 %@ n=%d fill=%.0fms Δfootprint=%.1fMB per-terminal=%.2fMB Δgraphics=%.1fMB available=%.0fMB limit≈%.0fMB rows=%@ | Δparts %@",
                             engine.rawValue, count, fillMS, delta, delta / Double(count), after.graphics - before.graphics,
                             after.available, after.limit, totals.description, MemoryProbe.describe(parts)))
                print("MEASURE m2 \(engine.rawValue) n=\(count) after \(after)")
                // Ghostty 隐藏的 surface 不刷新滚动条回调（停画时不发），只核可见的那两个（数组末尾）。
                let checked = engine == .ghostty ? Array(totals.suffix(min(2, count))) : totals
                XCTAssertTrue(checked.allSatisfy { $0 >= 10_000 }, "\(engine) n=\(count) 回滚没装下 10k 行：\(totals)")
                // 拆掉，看能不能还回去（#18：关掉的终端视图能否释放）。
                for case let container as MTerminalContainerView in keep { container.removeFromSuperview() }
                for case let bridge as GhosttyTerminalBridge in keep { bridge.view.removeFromSuperview() }
                keep.removeAll()
                window.isHidden = true
                try await Task.sleep(for: .milliseconds(1500))
                let released = MemoryProbe.read()
                print(String(format: "MEASURE m2 %@ n=%d released: footprint=%.1fMB (baseline %.1fMB, kept %.1fMB)",
                             engine.rawValue, count, released.footprint, before.footprint, released.footprint - before.footprint))
            }
        }
    }

    // MARK: - M6 打字回显

    /// 真输入路径：`insertText`（软键盘落字的公开入口，两边的视图都是 UIKeyInput）→ 终端把字节交给宿主 →
    /// `TerminalInputChannel` → 假后端原样回显（`MobileFakeTerminalTransport.echoesInput`）→ 输出路径 → 出帧。
    /// SwiftTerm 走生产的 `MobileTerminalController`（输出泵 + 刚按过键立即绘制），Ghostty 走 `GhosttyTerminalBridge.bind`。
    /// 计时：调 `insertText` 之前到这个终端交出下一帧（SwiftTerm `draw(_:)` / Ghostty `setContents:`）。
    /// 硬件键 `pressesBegan` 要真 `UIPress`，XCTest 造不出来（spike 已记），这里不量，留给 M16 手感。
    func testM6TypingEcho() async throws {
        let screen = sceneSize
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        print("MEASURE m6 load=\(loadavg())")

        // SwiftTerm：生产控制器 + 假传输。
        let (controller, handles) = MobileFakeTerminal.controller(.idle)
        let window = try makeSpikeWindow(size: screen)
        window.makeKey()
        let (stView, stContainer) = makeSwiftTerm(frame: CGRect(origin: .zero, size: screen),
                                                  scrollback: RemoteConstants.snapshotScrollback)
        stView.controller = controller
        let coordinator = SwiftTermView.Coordinator(controller: controller)
        stView.terminalDelegate = coordinator
        controller.attach(stView)
        window.addSubview(stContainer)
        stContainer.layoutIfNeeded()
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        controller.ownsKeyboard = true
        XCTAssertTrue(stView.becomeFirstResponder(), "SwiftTerm 拿不到键盘")
        stView.feed(text: "$ ")

        // Ghostty：同一个假传输类型，走 bridge.bind。
        let ghTransport = MobileFakeTerminalTransport(script: .idle)
        try await ghTransport.connect()
        let gh = makeGhostty(frame: CGRect(origin: .zero, size: screen))
        let ghWindow = try makeSpikeWindow(size: screen)
        ghWindow.addSubview(gh.view)
        try await waitReady([gh])
        gh.bind(ghTransport)
        gh.feed(Data("$ ".utf8))

        var results: [Engine: [Double]] = [:]
        var lost: [String] = []
        for round in 0..<2 {
            for engine in [Engine.swiftterm, .ghostty] {
                // 只让被测的那扇窗在最上面、拿键盘。
                switch engine {
                case .swiftterm:
                    window.windowLevel = .alert + 2; ghWindow.windowLevel = .alert + 1
                    window.makeKey()
                    _ = stView.becomeFirstResponder()
                case .ghostty:
                    ghWindow.windowLevel = .alert + 2; window.windowLevel = .alert + 1
                    ghWindow.makeKey()
                    XCTAssertTrue(gh.view.becomeFirstResponder(), "Ghostty 拿不到键盘")
                }
                try await Task.sleep(for: .milliseconds(600))
                for index in 0..<40 {
                    try await Task.sleep(for: .milliseconds(70 + index % 7 * 3))
                    resetFrames()
                    let char = String(UnicodeScalar(UInt8(97 + (index + round * 7) % 26)))
                    let t0 = CACurrentMediaTime()
                    switch engine {
                    case .swiftterm: stView.insertText(char)
                    case .ghostty: gh.view.insertText(char)
                    }
                    func frameAt() -> Double? {
                        switch engine {
                        case .swiftterm: SwiftTermDrawLog.draws.first(where: { $0.at >= t0 })?.at
                        case .ghostty: GhosttyPresentLog.read().times.first(where: { $0 >= t0 })
                        }
                    }
                    while frameAt() == nil, CACurrentMediaTime() - t0 < 0.5 {
                        try await Task.sleep(for: .microseconds(300))
                    }
                    if let at = frameAt() { results[engine, default: []].append((at - t0) * 1000) }
                    // 这一下到后端没有（有丢键就记下是第几下、什么字、离上一下多久）。
                    try await Task.sleep(for: .milliseconds(30))
                    let written = engine == .swiftterm ? (await handles.latest?.writtenBytes ?? 0) : await ghTransport.writtenBytes
                    let expected = round * 40 + index + 1
                    if written < expected - lost.filter({ $0.hasPrefix(engine.rawValue) }).count {
                        lost.append("\(engine.rawValue)#\(round)/\(index)'\(char)'")
                    }
                }
            }
        }
        let stEcho = await handles.latest?.writtenBytes ?? 0
        let ghEcho = await ghTransport.writtenBytes
        for engine in [Engine.swiftterm, .ghostty] {
            let values = results[engine] ?? []
            print(String(format: "MEASURE m6 %@ typing-echo n=%d p50=%.2fms p95=%.2fms max=%.2fms",
                         engine.rawValue, values.count, ProbeMetrics.percentile(values, 0.5),
                         ProbeMetrics.percentile(values, 0.95), values.max() ?? 0))
        }
        print("MEASURE m6 bytes-reached-backend swiftterm=\(stEcho) ghostty=\(ghEcho) lost=\(lost) gh-writes=\(await ghTransport.writes.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "|"))")
        XCTAssertEqual(results[.swiftterm]?.count, 80)
        XCTAssertEqual(results[.ghostty]?.count, 80)
        XCTAssertEqual(stEcho, 80, "SwiftTerm 的按键没全到后端")
        XCTAssertEqual(ghEcho, 80, "Ghostty 的按键没全到后端")
        let ghText = gh.session.readViewportText() ?? ""
        XCTAssertTrue(ghText.contains("$ a"), "Ghostty 回显没上屏：\(ghText.prefix(80))")
        controller.close()
        gh.unbind()
        stContainer.removeFromSuperview(); gh.view.removeFromSuperview()
        window.isHidden = true; ghWindow.isHidden = true
    }

    // MARK: - M7 开标签与恢复

    /// (a) 新开一个终端到它交出第一帧（各 10 次交替；Ghostty 第一次含 app 初始化，单独列）。
    /// (b) 一次建 8 / 20 个终端（1 个可见整屏、其余隐藏标签），每个回放 2 MB 带色日志：总耗时、footprint 峰值（5 ms 采样）。
    ///     SwiftTerm 用最快的同步 `feed`（不经节拍泵），回滚是生产的 1,000 行；Ghostty `receive` 后等全部解析完，
    ///     回滚是默认的 10 MB——两边留的历史不一样多，内存读数要带着这一条看。
    func testM7OpenAndRestore() async throws {
        let screen = sceneSize
        let full = CGRect(origin: .zero, size: screen)
        print("MEASURE m7 load=\(loadavg())")
        // (a)
        var open: [Engine: [Double]] = [:]
        for round in 0..<10 {
            for engine in [Engine.ghostty, .swiftterm] {
                let window = try makeSpikeWindow(size: screen)
                try await Task.sleep(for: .milliseconds(200))
                resetFrames()
                let t0 = CACurrentMediaTime()
                var bridge: GhosttyTerminalBridge?
                var stContainer: MTerminalContainerView?
                switch engine {
                case .swiftterm:
                    let (view, container) = makeSwiftTerm(frame: full, scrollback: RemoteConstants.snapshotScrollback)
                    window.addSubview(container)
                    view.feed(text: "Last login: Mon Nov  9 10:00:00\r\n$ ")
                    stContainer = container
                case .ghostty:
                    let made = makeGhostty(frame: full)
                    window.addSubview(made.view)
                    made.feed(Data("Last login: Mon Nov  9 10:00:00\r\n$ ".utf8))
                    bridge = made
                }
                var first: Double?
                while first == nil, CACurrentMediaTime() - t0 < 3 {
                    GhosttyPresentLog.installIfPossible()
                    switch engine {
                    case .swiftterm: first = SwiftTermDrawLog.draws.first?.at
                    case .ghostty: first = GhosttyPresentLog.read().times.first
                    }
                    if first == nil { try await Task.sleep(for: .milliseconds(1)) }
                }
                if let first { open[engine, default: []].append((first - t0) * 1000) }
                if round == 0 { print(String(format: "MEASURE m7 open-first %@ round0=%.1fms", engine.rawValue, ((first ?? t0) - t0) * 1000)) }
                try await Task.sleep(for: .milliseconds(150))
                bridge?.view.removeFromSuperview()
                stContainer?.removeFromSuperview()
                window.isHidden = true
            }
        }
        for engine in [Engine.swiftterm, .ghostty] {
            let values = open[engine] ?? []
            let warm = Array(values.dropFirst())
            print(String(format: "MEASURE m7 open-to-first-frame %@ n=%d first=%.1fms warm p50=%.1fms p95=%.1fms max=%.1fms",
                         engine.rawValue, values.count, values.first ?? 0, ProbeMetrics.percentile(warm, 0.5),
                         ProbeMetrics.percentile(warm, 0.95), warm.max() ?? 0))
        }

        // (b)
        let payload = TerminalSpikeCorpus.flood(bytes: 2 * 1024 * 1024)
        let bytes = [UInt8](payload)
        for count in [8, 20] {
            for engine in [Engine.swiftterm, .ghostty] {
                try await Task.sleep(for: .milliseconds(1500))
                let before = MemoryProbe.read()
                let window = try makeSpikeWindow(size: screen)
                let sampler = FootprintSampler()
                let cpu0 = ProcessCPU.seconds()
                let t0 = CACurrentMediaTime()
                var keep: [AnyObject] = []
                var firstVisibleFrame: Double?
                resetFrames()
                switch engine {
                case .swiftterm:
                    var views: [MTerminalView] = []
                    for index in 0..<count {
                        let (view, container) = makeSwiftTerm(frame: full, scrollback: RemoteConstants.snapshotScrollback)
                        window.addSubview(container)
                        container.layoutIfNeeded()
                        container.isOnScreen = index == count - 1
                        keep.append(container); views.append(view)
                    }
                    for view in views {
                        // 按 256 KB 一段喂、段间让一下主线程（不然 20×2MB 的几十秒里窗口一帧都不画）。
                        for start in stride(from: 0, to: bytes.count, by: 256 * 1024) {
                            view.feed(byteArray: bytes[start..<min(bytes.count, start + 256 * 1024)])
                            await Task.yield()
                        }
                    }
                    // 喂完之后可见的那个再画一次才算看得见。
                    let fed = CACurrentMediaTime()
                    while CACurrentMediaTime() - fed < 1, SwiftTermDrawLog.draws.last.map({ $0.at >= fed }) != true {
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    firstVisibleFrame = max(fed, SwiftTermDrawLog.draws.last?.at ?? fed)
                case .ghostty:
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
                    firstVisibleFrame = GhosttyPresentLog.read().times.last
                    keep.append(contentsOf: bridges)
                }
                let wall = ((firstVisibleFrame ?? CACurrentMediaTime()) - t0) * 1000
                let cpu = (ProcessCPU.seconds() - cpu0) * 1000
                try await Task.sleep(for: .milliseconds(500))
                let peak = sampler.stop()
                let after = MemoryProbe.read()
                print(String(format: "MEASURE m7 restore %@ n=%d x2MB total=%.0fms cpu=%.0fms peak=%.1fMB(Δ%.1f, %d samples) settled-Δ=%.1fMB available=%.0fMB",
                             engine.rawValue, count, wall, cpu, peak.peakMB, peak.peakMB - before.footprint, peak.samples,
                             after.footprint - before.footprint, after.available))
                for case let container as MTerminalContainerView in keep { container.removeFromSuperview() }
                for case let bridge as GhosttyTerminalBridge in keep { bridge.view.removeFromSuperview() }
                keep.removeAll()
                window.isHidden = true
            }
        }
    }

    // MARK: - M8 多终端并发输出

    /// 上下两格分屏可见 + 2 个后台标签，4 个终端同时来 Claude 式输出（每 100 ms 一个同步帧，相位错开）。
    /// 另一档：两格可见的整屏每个显示节拍都变（全屏 TUI 上界），后台两个照常 Claude。A B A B 各 8 秒。
    func testM8ConcurrentOutput() async throws {
        let screen = sceneSize
        let top = CGRect(x: 0, y: 0, width: screen.width, height: screen.height / 2)
        let bottom = CGRect(x: 0, y: screen.height / 2, width: screen.width, height: screen.height / 2)
        print("MEASURE m8 load=\(loadavg())")
        let stWindow = try makeSpikeWindow(size: screen)
        var stViews: [MTerminalView] = []
        var stContainers: [MTerminalContainerView] = []
        for index in [2, 3, 0, 1] {
            let (view, container) = makeSwiftTerm(frame: index == 1 ? bottom : top, scrollback: RemoteConstants.snapshotScrollback)
            stWindow.addSubview(container)
            container.layoutIfNeeded()
            container.isOnScreen = index < 2
            stViews.append(view); stContainers.append(container)
        }
        let ghWindow = try makeSpikeWindow(size: screen)
        var bridges: [GhosttyTerminalBridge] = []
        for index in [2, 3, 0, 1] {
            let bridge = makeGhostty(frame: index == 1 ? bottom : top)
            ghWindow.addSubview(bridge.view)
            if index >= 2 { bridge.view.setSurfaceVisible(false) }
            bridges.append(bridge)
        }
        try await waitReady(bridges)
        for view in stViews {
            view.feed(text: TerminalSpikeCorpus.history(lines: 300, cols: view.getTerminal().cols)
                      + TerminalSpikeCorpus.claudeFrame(0, cols: view.getTerminal().cols))
        }
        for bridge in bridges {
            let cols = bridge.grid?.cols ?? 58
            bridge.feed(Data((TerminalSpikeCorpus.history(lines: 300, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols)).utf8))
        }
        try await Task.sleep(for: .milliseconds(800))

        var lines: [String] = []
        for round in 0..<2 {
            for engine in [Engine.swiftterm, .ghostty] {
                (engine == .swiftterm ? stWindow : ghWindow).windowLevel = .alert + 2
                (engine == .swiftterm ? ghWindow : stWindow).windowLevel = .alert + 1
                // 被测的那一侧以外的终端都停画，免得混进读数。
                for container in stContainers.suffix(2) { container.isOnScreen = engine == .swiftterm }
                for bridge in bridges.suffix(2) { bridge.view.setSurfaceVisible(engine == .ghostty) }
                try await Task.sleep(for: .milliseconds(500))
                func feed(_ terminal: Int, _ text: String) {
                    switch engine {
                    case .swiftterm: stViews[terminal].feedPaced(ArraySlice(Array(text.utf8)), backlogged: false)
                    case .ghostty: bridges[terminal].feed(Data(text.utf8))
                    }
                }
                func cols(_ terminal: Int) -> Int {
                    engine == .swiftterm ? stViews[terminal].getTerminal().cols : (bridges[terminal].grid?.cols ?? 58)
                }
                func rows(_ terminal: Int) -> Int {
                    engine == .swiftterm ? stViews[terminal].getTerminal().rows : (bridges[terminal].grid?.rows ?? 25)
                }
                let claude = try await measure(seconds: 8, engine: engine, every100ms: { beat in
                    for terminal in 0..<4 { feed(terminal, TerminalSpikeCorpus.claudeFrame(beat * 4 + terminal + 1, cols: cols(terminal))) }
                })
                lines.append("MEASURE m8 \(engine.rawValue)/4x-claude#\(round) " + claude.line)
                let fullscreen = try await measure(seconds: 8, engine: engine, onTick: { step in
                    for terminal in 2..<4 {
                        feed(terminal, "\u{1B}[?2026h" + TerminalSpikeCorpus.screen(rows: rows(terminal), salt: step + terminal) + "\u{1B}[?2026l")
                    }
                }, every100ms: { beat in
                    for terminal in 0..<2 { feed(terminal, TerminalSpikeCorpus.claudeFrame(beat * 2 + terminal + 1, cols: cols(terminal))) }
                })
                lines.append("MEASURE m8 \(engine.rawValue)/2x-fullscreen+2x-claude#\(round) " + fullscreen.line)
            }
        }
        lines.forEach { print($0) }
        stContainers.forEach { $0.removeFromSuperview() }
        bridges.forEach { $0.view.removeFromSuperview() }
        stWindow.isHidden = true; ghWindow.isHidden = true
    }

    // MARK: - M9 功耗：10 分钟 Claude 式输出

    /// 一个整屏终端，每 100 ms 一个 Claude 同步帧，各跑 10 分钟（先 SwiftTerm 后 Ghostty，中间歇 60 s 让机器回温）。
    /// 读：进程 CPU 时间（getrusage，含已退出线程）、各线程 CPU、出帧、`thermalState` 每 30 s 采一次。
    /// 时长可用 `UTERM_MEASURE_M9_SECONDS` 改（默认 600）。同时在 Mac 上录 Power Profiler（见报告）。
    func testM9Power() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["UTERM_MEASURE_M9_SECONDS"] ?? "") ?? 600
        let screen = sceneSize
        let full = CGRect(origin: .zero, size: screen)
        print("MEASURE m9 load=\(loadavg()) seconds=\(seconds) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) battery=\(UIDevice.current.batteryLevel) start-wall=\(Date())")
        UIDevice.current.isBatteryMonitoringEnabled = true
        // 空闲基线 60 s（宿主自己的开销）。
        let idleCPU0 = ProcessCPU.seconds()
        try await Task.sleep(for: .seconds(60))
        let idleMS = (ProcessCPU.seconds() - idleCPU0) * 1000
        print(String(format: "MEASURE m9 idle-baseline 60s cpu=%.0fms (%.2f%%)", idleMS, idleMS / 600))

        for engine in [Engine.swiftterm, .ghostty] {
            let window = try makeSpikeWindow(size: screen)
            var stView: MTerminalView?
            var bridge: GhosttyTerminalBridge?
            switch engine {
            case .swiftterm:
                let (view, container) = makeSwiftTerm(frame: full, scrollback: RemoteConstants.snapshotScrollback)
                window.addSubview(container)
                container.layoutIfNeeded()
                view.feed(text: TerminalSpikeCorpus.history(lines: 300, cols: view.getTerminal().cols))
                stView = view
            case .ghostty:
                let made = makeGhostty(frame: full)
                window.addSubview(made.view)
                try await waitReady([made])
                made.feed(Data(TerminalSpikeCorpus.history(lines: 300, cols: made.grid?.cols ?? 58).utf8))
                bridge = made
            }
            try await Task.sleep(for: .seconds(2))
            let cols = stView?.getTerminal().cols ?? bridge?.grid?.cols ?? 58
            var thermal: [Int] = [ProcessInfo.processInfo.thermalState.rawValue]
            let cpu0 = ProcessCPU.seconds()
            let battery0 = UIDevice.current.batteryLevel
            print("MEASURE m9 \(engine.rawValue) begin wall=\(Date())")
            let window10 = try await measure(seconds: seconds, engine: engine, every100ms: { beat in
                let frame = TerminalSpikeCorpus.claudeFrame(beat + 1, cols: cols)
                if let stView { stView.feedPaced(ArraySlice(Array(frame.utf8)), backlogged: false) }
                bridge?.feed(Data(frame.utf8))
                if beat % 300 == 299 { thermal.append(ProcessInfo.processInfo.thermalState.rawValue) }
            })
            let cpuMS = (ProcessCPU.seconds() - cpu0) * 1000
            print("MEASURE m9 \(engine.rawValue) end wall=\(Date())")
            print(String(format: "MEASURE m9 %@ %.0fs process-cpu=%.0fms (%.2f%%, net of idle ≈%.2f%%) thermal=%@ battery %.2f→%.2f | %@",
                         engine.rawValue, window10.seconds, cpuMS, cpuMS / window10.seconds / 10,
                         cpuMS / window10.seconds / 10 - idleMS / 600, thermal.description, battery0,
                         UIDevice.current.batteryLevel, window10.line))
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
            if engine == .swiftterm { try await Task.sleep(for: .seconds(60)) }
        }
    }

    // MARK: - M10 后台

    /// 单元测试宿主不能真的退后台，这里模拟：发 `UIApplication.didEnterBackgroundNotification`（GhosttyKit 自己的生命周期
    /// 监听据此 `setApplicationActive(false)`、停 display link、wakeup 不再 tick；uTerm 的控制器据此切后台节拍）+
    /// Ghostty 再 `setSurfaceVisible(false)`。和真后台的区别：进程不会被挂起、主线程照常转，系统也不收内存；
    /// 真后台里只有 `BGContinuedProcessingTask` 续命时才会继续收输出，那时主线程也在转——与这里同一情形。
    ///
    /// 期间每 100 ms 来一个 Claude 帧，**带 OSC 0 标题**（Claude Code 思考时会改标题；标题要进 ghostty 的 app mailbox，
    /// mailbox 只有 64 格、只有 tick 才清——这是会不会卡住解析的关键）；中途再来一段 4 MB 洪流。
    /// 每 10 s 记：footprint、Ghostty 未解析字节、Ghostty 收到的标题数。回前台后量：多久交出含最新标记的一帧。
    /// 时长 `UTERM_MEASURE_M10_SECONDS`（默认 300）。
    func testM10Background() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["UTERM_MEASURE_M10_SECONDS"] ?? "") ?? 300
        // 对照组：`UTERM_MEASURE_M10_TITLES=0` 时 Claude 帧不带 OSC 0 标题（看卡住的是不是 mailbox）。
        let withTitles = ProcessInfo.processInfo.environment["UTERM_MEASURE_M10_TITLES"] != "0"
        let screen = sceneSize
        let full = CGRect(origin: .zero, size: screen)
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        print("MEASURE m10 load=\(loadavg()) seconds=\(seconds) titles=\(withTitles)")

        // SwiftTerm：生产控制器（自己监听进出后台、切节拍、停画）+ 可控输出的后端。
        let stBackend = ScriptedBackend()
        let controller = MobileTerminalController(transportFactory: MobileTerminalTransportFactory { _ in stBackend })
        let stWindow = try makeSpikeWindow(size: screen)
        let (stView, stContainer) = makeSwiftTerm(frame: full, scrollback: RemoteConstants.snapshotScrollback)
        stView.controller = controller
        let coordinator = SwiftTermView.Coordinator(controller: controller)
        stView.terminalDelegate = coordinator
        controller.attach(stView)
        stWindow.addSubview(stContainer)
        stContainer.layoutIfNeeded()
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let stConnected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(stConnected)

        // Ghostty。
        let ghBackend = ScriptedBackend()
        try await ghBackend.connect()
        let ghWindow = try makeSpikeWindow(size: screen)
        let gh = makeGhostty(frame: full)
        let sink = ScrollbarSink()
        gh.view.delegate = sink
        ghWindow.addSubview(gh.view)
        try await waitReady([gh])
        gh.bind(ghBackend)
        let cols = gh.grid?.cols ?? 58
        try await Task.sleep(for: .milliseconds(500))

        func emit(_ text: String) {
            stBackend.yield(Data(text.utf8))
            ghBackend.yield(Data(text.utf8))
        }
        func claude(_ n: Int) -> String {
            (withTitles ? "\u{1B}]0;\(["✢", "✳", "✶", "✻", "✽"][n % 5]) Claude Code · 第 \(n) 帧\u{07}" : "")
                + TerminalSpikeCorpus.claudeFrame(n, cols: cols)
        }
        // 前台先确认标题能到。
        for n in 0..<5 { emit(claude(n)); try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(300))
        let titlesForeground = sink.titles
        print("MEASURE m10 foreground titles=\(titlesForeground) last=\(sink.lastTitle)")

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
                stBackend.yield(flood); ghBackend.yield(flood)
                print("MEASURE m10 flood 4MB at \(Int(elapsed))s")
            }
            maxPending = max(maxPending, gh.session.pendingOutputByteCount)
            if elapsed >= nextReport {
                nextReport += 10
                let m = MemoryProbe.read()
                // app-state：真机上假的后台通知之外，系统自己也可能发真的进出前台（0 = active，2 = background）；
                // gh-bg / replays 看 bridge 有没有被真通知翻回前台过。
                print(String(format: "MEASURE m10 t=%3.0fs footprint=%.1fMB(Δ%.1f) gh-pending=%d gh-titles=%d st-draws=%d gh-presents=%d shadow-only=%d shadow-resident=%.1fMB shadow-rows=%d app-state=%d gh-bg=%@ replays=%d",
                             elapsed, m.footprint, m.footprint - memory0.footprint, gh.session.pendingOutputByteCount,
                             sink.titles, SwiftTermDrawLog.draws.count, GhosttyPresentLog.read().times.count,
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
        let drawsInBackground = SwiftTermDrawLog.draws.count
        let presentsInBackground = GhosttyPresentLog.read().times.count
        print(String(format: "MEASURE m10 background end: frames-sent=%d Δfootprint=%.1fMB gh-pending-max=%d gh-pending-end=%d gh-titles-in-bg=%d st-draws-in-bg=%d gh-presents-in-bg=%d",
                     beat, memoryBG.footprint - memory0.footprint, maxPending, pendingAtEnd, titlesInBackground,
                     drawsInBackground, presentsInBackground))
        let routed = gh.router.currentStats
        print(String(format: "MEASURE m10 shadow at background end: shadow-only=%d dropped-surface=%d shadow-resident=%.1fMB shadow-rows=%d shadow-has-marker=%@",
                     routed.shadowOnlyBytes, routed.droppedSurfaceBytes, Double(gh.shadow.residentBytes) / 1_048_576,
                     gh.shadow.totalRows, String(gh.shadow.viewportText().contains(marker))))

        // 回前台。
        resetFrames()
        let back = CACurrentMediaTime()
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        gh.view.setSurfaceVisible(true)
        func stShows() -> Bool {
            let t = stView.getTerminal()
            return (0..<t.rows).contains { t.getLine(row: $0)?.translateToString().contains(marker) == true }
        }
        var stAt: Double?, ghAt: Double?, ghParsedAt: Double?
        while CACurrentMediaTime() - back < 10, stAt == nil || ghAt == nil {
            if stAt == nil, stShows(), let draw = SwiftTermDrawLog.draws.last?.at, draw >= back { stAt = draw }
            if ghParsedAt == nil, gh.session.pendingOutputByteCount == 0,
               gh.session.readViewportText()?.contains(marker) == true { ghParsedAt = CACurrentMediaTime() }
            if let ghParsedAt, ghAt == nil, let present = GhosttyPresentLog.read().times.last, present >= ghParsedAt { ghAt = present }
            try await Task.sleep(for: .milliseconds(2))
        }
        print(String(format: "MEASURE m10 foreground catch-up: swiftterm=%@ ghostty=%@ (parsed %@) titles-after=%d",
                     stAt.map { String(format: "%.0fms", ($0 - back) * 1000) } ?? "never",
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
        XCTAssertNotNil(stAt, "SwiftTerm 回前台没补出最新画面")
        XCTAssertNotNil(ghAt, "Ghostty 回前台没补出最新画面")
        controller.close()
        gh.unbind()
        stContainer.removeFromSuperview(); gh.view.removeFromSuperview()
        stWindow.isHidden = true; ghWindow.isHidden = true
    }

    // MARK: - M12 系统等宽字体

    /// `font-family` 依次试几个名字，看格子尺寸、截图是不是还和默认（内嵌 JetBrains Mono）一样——一样就是没取到、回退了。
    /// SwiftTerm 的参照是 `UIFont.monospacedSystemFont`（SF Mono）。截图作为附件导出（xcresult）。
    func testM12SystemMonospaceFont() async throws {
        let size = CGSize(width: 440, height: 300)
        let sample = "\u{1B}[2J\u{1B}[H0Oo1lIi g@{}[]\r\n中文 →✓ ─│╭╮\r\nThe quick brown fox 0123456789\r\n"
        let system = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        print("MEASURE m12 UIFont.monospacedSystemFont fontName=\(system.fontName) familyName=\(system.familyName) advance=\(("0" as NSString).size(withAttributes: [.font: system]).width)pt lineHeight=\(system.lineHeight)")
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
        // SwiftTerm 参照。
        let window = try makeSpikeWindow(size: size)
        let (view, container) = makeSwiftTerm(frame: CGRect(origin: .zero, size: size), scrollback: 100)
        let scheme = MTerminalColors.resolve(dark: true)
        view.backgroundColor = scheme.backgroundColor
        window.addSubview(container)
        container.layoutIfNeeded()
        view.feed(text: sample)
        try await Task.sleep(for: .milliseconds(400))
        let renderer = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: size))
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let crop = image.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: 1320, height: 200))
        let attachment = XCTAttachment(data: crop.map { UIImage(cgImage: $0).pngData() ?? Data() } ?? Data(), uniformTypeIdentifier: "public.png")
        attachment.name = "m12-swiftterm-sfmono"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("MEASURE m12 swiftterm grid=\(view.getTerminal().cols)x\(view.getTerminal().rows) in \(size)")
        container.removeFromSuperview()
        window.isHidden = true
    }

    // MARK: - M15 Kitty 图形

    /// 经 host-managed IO 喂 Kitty 图形协议（APC `_G`，PNG 直传 + 分块），确认：显示、应答、滚出屏、滚回来、清屏释放、内存回收。
    /// SwiftTerm 同样喂一遍作对照（它不认 Kitty 协议）。
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

        // SwiftTerm 对照。
        let st = try SwiftTermProbeHost(size: sceneSize)
        defer { st.close() }
        st.view.feed(text: "\u{1B}[2J\u{1B}[H$ kitty icat red.png\r\n" + KittyCorpus.direct(red, id: 1, columns: 10, rows: 5) + "\r\n$ ")
        try await Task.sleep(for: .milliseconds(400))
        let renderer = UIGraphicsImageRenderer(bounds: st.window.bounds)
        let stImage = renderer.image { _ in st.window.drawHierarchy(in: st.window.bounds, afterScreenUpdates: true) }
        let stRed = stImage.cgImage.map { PixelProbe.fraction(of: $0, near: (255, 0, 0)) } ?? 0
        let stAttachment = XCTAttachment(image: stImage)
        stAttachment.name = "m15-swiftterm-kitty"; stAttachment.lifetime = .keepAlways
        add(stAttachment)
        let stText = (0..<4).compactMap { st.view.getTerminal().getLine(row: $0)?.translateToString() }.joined(separator: "|")
        print(String(format: "MEASURE m15 swiftterm red=%.4f text=%@", stRed, String(stText.prefix(160))))

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
