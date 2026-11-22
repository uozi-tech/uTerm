import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// 甩一下之后 UIKit 自己减速那一段，逐帧上屏的账。user 2026-11-22 在 Duo 上（补丁 #20 的包）说慢滚顺了、甩出去减速时有顿。
///
/// 别的甩动探针（`GhosttyOnScreenScrollTests` / `GhosttyFrameBudgetTests` / `GhosttyTearingTests`）的减速是测试自己的 display link
/// 按三次缓出写 contentOffset，不是 UIKit 的。这里用 `SyntheticFinger` 真的甩（按下、每个显示帧一个 moved、动着抬手），
/// 之后的减速、对齐全是 UIKit 和终端自己的，一直等到停稳。每个显示帧记：
/// - 屏上画面走了多少（IOSurface 条码，CA 提交后读，按参考 link 的 vsync 分桶）；
/// - UIKit 这一帧把 contentOffset 写到了哪（同一时刻读，换成物理像素）——「该走多少」；交给引擎多少（`momentum` / `drag`）；
/// - tick（`tick-draw` 等）、主线程忙时、这一帧的画面是主线程交的还是渲染线程交的、参考 link 两拍隔了多久。
///
/// 判定（只看抬手之后到停稳）。上屏和 UIKit 写的位移整体错开 L 拍（取对不上最少的 L）：
/// - `zero`：UIKit 这一拍走了 ≥ 1 px，画面没动；`double`：画面走了 UIKit 那一拍的 2 倍以上且多 ≥ 2 px；
/// - `miss`：和 UIKit 那一拍差 ≥ 1.5 px；`late`：参考 link 跳拍；
/// - 和自己前后 5 帧平均比（不看 UIKit，参照组也能算）：`stall`（平均 ≥ 1 px 而这一帧 0）、`spike`（≥ 2 倍平均且多 ≥ 2 px）。
/// 分三段：`tail` = UIKit 的位移（前后 5 帧平均）不到 1 px/帧（取整本身就会出 0 / 2，单列）；其余按时间分前一半 `early`、后一半 `mid`。
///
/// 参照组：同样大小、同样内容高度的普通 UIScrollView（`.normal` 减速），同一根手指同样甩，画面 = 它自己的 contentOffset。
///
/// 默认跳过（测量门）：`TEST_RUNNER_UTERM_MEASURE=1`，真机上跑。可调：`UTERM_FLICK_SPEEDS`（默认 300,800,2000,4000 pt/s）、
/// `UTERM_FLICK_RUNS`（每个方向几次，默认 2）、`UTERM_SCROLL_POLICIES`（补丁 #20 的几种做法，默认 moving,moving-link,always，
/// 见 `UTermScrollTrace.ScrollWakeupSyncDraw`；`moving@300` 另设 `wakeupDisplayLinkMinimumSpeed`，`@inf` = 一律不开 link）、`UTERM_FLICK_REFERENCE=0`（不跑参照组）、`UTERM_SLOWDRAG_VARIANT`。
/// 输出 `FLICK-RUN` / `FLICK-SUM` 行，CSV 写进宿主 tmp（`slowdrag/`）并挂附件。
@MainActor
final class GhosttyFlickFrameTests: XCTestCase {
    typealias OnScreen = GhosttyOnScreenScrollTests
    typealias Slow = GhosttySlowDragFrameTests
    typealias Clock = GhosttyFrameBudgetTests.MainLoopClock
    typealias Policy = UTermScrollTrace.ScrollWakeupSyncDraw

    private static let env = ProcessInfo.processInfo.environment
    static var speeds: [Double] {
        env["UTERM_FLICK_SPEEDS"].map { $0.split(separator: ",").compactMap { Double($0) } } ?? [300, 800, 2000, 4000]
    }
    static var runs: Int { env["UTERM_FLICK_RUNS"].flatMap(Int.init) ?? 2 }
    /// 每项 `做法[@速度]`：速度是 `UTermScrollTrace.wakeupDisplayLinkMinimumSpeed`（`inf` = 一律不开 link），不写用默认。
    static var policies: [(name: String, policy: Policy, linkSpeed: Double)] {
        (env["UTERM_SCROLL_POLICIES"] ?? "moving,moving-link,always").split(separator: ",").compactMap { item in
            let parts = item.split(separator: "@")
            guard let policy = Policy(rawValue: String(parts[0])) else { return nil }
            let speed = parts.count > 1 ? (parts[1] == "inf" ? Double.infinity : Double(parts[1]) ?? 0)
                : UTermScrollTrace.defaultWakeupDisplayLinkMinimumSpeed
            return (String(item), policy, speed)
        }
    }
    static var reference: Bool { env["UTERM_FLICK_REFERENCE"] != "0" }
    /// `window`（默认：单独一扇窗里只有终端）或 `workspace`（整个工作区界面，输出走假 SSH 后端经控制器进 Ghostty）。
    static var hostKind: String { env["UTERM_FLICK_HOST"] ?? "window" }
    /// 上玻璃模式（`UTERM_FLICK_GLASS=1`，配 xctrace 录系统的换屏表）：减速期间测试自己不开任何 display link（发手指的 link 抬手就停，
    /// 采样只挂 run loop 的观察者），不把屏幕钉在 120 Hz；不做 App 侧的逐帧账，只把每次提交的时刻、画面位置、contentOffset
    /// 写进 `ios-flick-<变体>-commits.csv`，交给 `flick-glass.py` 和换屏表对。开始前打印 `FLICK-GLASS-READY`，等
    /// `UTERM_FLICK_GLASS_WAIT` 秒（默认 20）让 xctrace 开录，做完打印 `FLICK-GLASS-DONE`。
    static var glass: Bool { env["UTERM_FLICK_GLASS"] == "1" }
    static var variant: String { env["UTERM_SLOWDRAG_VARIANT"].flatMap { $0.isEmpty ? nil : $0 } ?? "head" }
    static let historyLines = 4000
    static let flickSeconds = 0.1
    static let phases = ["early", "mid", "tail"]
    static let flagKinds = ["zero", "double", "miss", "late", "stall", "spike", "tight", "no-present", "multi-present"]
    /// 提交离目标 vsync 不到这么多就算贴着截止（第八轮：render server 在 vsync 前约 0.42 ms 开始合成，提交到开始合成最少隔 0.78 ms）。
    static let tightMarginMS = 1.5

    override func setUp() async throws {
        guard Self.env["UTERM_MEASURE"] == "1" else {
            throw XCTSkip("测量门探针：设 UTERM_MEASURE=1 才跑（真机、单独跑）")
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func tearDown() async throws {
        UTermScrollTrace.isEnabled = false
        UTermScrollTrace.scrollWakeupSyncDraw = UTermScrollTrace.defaultScrollWakeupSyncDraw
        UTermScrollTrace.wakeupDisplayLinkMinimumSpeed = UTermScrollTrace.defaultWakeupDisplayLinkMinimumSpeed
    }

    /// 上玻璃模式的采样：只有 run loop 观察者（CA 提交之后），位置或 contentOffset 变了才记一行。
    @MainActor
    final class GlassSampler {
        private(set) var rows: [(time: Double, shown: Double?, offset: Double)] = []
        var read: (@MainActor () -> (Double?, Double))?
        private var observer: CFRunLoopObserver?

        func start() {
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, 2_000_001
            ) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.observe() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
            observe()
        }

        func stop() {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }

        private func observe() {
            guard let (shown, offset) = read?() else { return }
            if let last = rows.last, last.shown == shown, abs(last.offset - offset) < 0.0001 { return }
            rows.append((CACurrentMediaTime(), shown, offset))
        }
    }

    // MARK: 甩

    /// 按下、匀速 `speed` 拖 `flickSeconds`、在最后一个 moved 的同一拍抬手。返回抬手时刻。
    private func flick(speed: Double, direction: Double, startY: CGFloat, x: CGFloat, finger: SyntheticFinger,
                       ticker: Slow.EarlyTicker) async throws -> Double {
        var failure: Error?
        var lift = 0.0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var startTarget: Double?
            var moves = 0
            ticker.step = { link in
                do {
                    guard let start = startTarget else {
                        try finger.down(at: CGPoint(x: x, y: startY))
                        startTarget = link.targetTimestamp
                        return
                    }
                    let elapsed = link.targetTimestamp - start
                    try finger.move(to: CGPoint(x: x, y: startY - CGFloat(direction * speed * elapsed)))
                    moves += 1
                    if elapsed + 0.5 * link.duration >= Self.flickSeconds, moves >= 3 {
                        try finger.up()
                        lift = CACurrentMediaTime()
                        ticker.step = nil
                        done.resume()
                    }
                } catch {
                    failure = error
                    ticker.step = nil
                    done.resume()
                }
            }
        }
        if let failure { throw failure }
        return lift
    }

    /// 等到停稳：`moving()` 为 false 且位置 300 ms 没变（最多 7 s）。
    private func waitForRest(position: () -> Double, moving: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 7
        var last = position()
        var stillSince = CACurrentMediaTime()
        while CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            let now = position()
            if abs(now - last) > 0.001 || moving() { stillSince = CACurrentMediaTime() }
            last = now
            if CACurrentMediaTime() - stillSince > 0.3 { return }
        }
    }

    // MARK: 逐帧

    struct Frame {
        let index: Int
        let target: Double
        let interval: Double
        var uikit = 0.0
        var shown = Double.nan
        var sent = 0.0
        var expected = Double.nan
        var smooth = Double.nan
        var uikitSmooth = Double.nan
        var phase = ""
        var rowCross = 0
        var tickDraws = 0
        var tickDrawMS = 0.0
        var wakeups = 0
        var presentsMain = 0
        var presentsOff = 0
        var busyMS = 0.0
        /// 这一拍的新画面（参照组：新的 contentOffset）是在目标 vsync 之前多少 ms 提交的；这一拍没换画面为 nan。
        var marginMS = Double.nan
        var flags: [String] = []
    }

    struct Run {
        let label: String
        let policy: String
        let speed: Int
        let frames: [Frame]
        let window: ClosedRange<Int>
        let lag: Int
        let travelPx: Double
        let durationMS: Double
    }

    /// 一次甩动的逐帧账。`samples` 是每次提交后读到的 (时刻, 画面位置 px, contentOffset pt)。
    private func analyze(label: String, policy: String, speed: Int, targets: [Double], lift: Double,
                         samples: [(time: Double, shown: Double?, offset: Double)], scale: Double,
                         trace: [UTermScrollTrace.Event], presents: [(time: Double, main: Bool)], clock: Clock,
                         isReference: Bool) -> Run? {
        guard targets.count > 20 else { return nil }
        func slot(_ time: Double) -> Int? {
            guard let last = targets.last, time < last, time >= targets[0] - 0.02 else { return nil }
            var lo = 0, hi = targets.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if targets[mid] > time { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
        let intervals = zip(targets, targets.dropFirst()).map { $1 - $0 }
        let nominal = ProbeMetrics.percentile(intervals, 0.5)
        var frames = targets.indices.map { i in
            Frame(index: i, target: targets[i], interval: i > 0 ? targets[i] - targets[i - 1] : nominal)
        }
        var shownAt = [Double?](repeating: nil, count: targets.count)
        var offsetAt = [Double?](repeating: nil, count: targets.count)
        for sample in samples {
            guard let i = slot(sample.time) else { continue }
            if let shown = sample.shown { shownAt[i] = shown }
            offsetAt[i] = sample.offset * scale
        }
        // 每拍最后的画面第一次出现的那次提交（提交后读到的第一个新值）离目标 vsync 多久。
        var firstSeen = [Double?](repeating: nil, count: targets.count)
        var previousValue: Double?
        for sample in samples.sorted(by: { $0.time < $1.time }) {
            let value = isReference ? sample.offset : (sample.shown ?? previousValue ?? .nan)
            defer { previousValue = value }
            guard let i = slot(sample.time), let previousValue, abs(value - previousValue) > 0.0001 else { continue }
            firstSeen[i] = sample.time
        }
        var shownPos = [Double](repeating: .nan, count: targets.count)
        var offsetPos = [Double](repeating: .nan, count: targets.count)
        var carriedShown: Double?, carriedOffset: Double?
        for i in targets.indices {
            if let v = shownAt[i] { carriedShown = v }
            if let v = offsetAt[i] { carriedOffset = v }
            shownPos[i] = carriedShown ?? .nan
            offsetPos[i] = carriedOffset ?? .nan
        }
        var lastRow: Double?
        for event in trace {
            guard let i = slot(event.time) else {
                if event.kind == "row" { lastRow = event.value }
                continue
            }
            switch event.kind {
            case "momentum", "drag": frames[i].sent += event.value
            case "row":
                if let lastRow, lastRow != event.value { frames[i].rowCross += 1 }
                lastRow = event.value
            case "tick-draw":
                frames[i].tickDraws += 1
                frames[i].tickDrawMS += event.value
            case "wakeup-tick": frames[i].wakeups += 1
            default: break
            }
        }
        for present in presents {
            guard let i = slot(present.time) else { continue }
            if present.main { frames[i].presentsMain += 1 } else { frames[i].presentsOff += 1 }
        }
        for i in frames.indices {
            let start = i > 0 ? targets[i - 1] : targets[i] - nominal, end = targets[i]
            frames[i].busyMS = clock.busy.reduce(0) { $0 + max(0, min($1.end, end) - max($1.start, start)) * 1000 }
        }

        // 窗口：抬手那一拍之后，到 UIKit 最后一次动或画面最后一次动。
        guard let liftSlot = slot(lift) else { return nil }
        let first = liftSlot + 1
        var last = first
        for i in first..<targets.count where i > 0 {
            if abs(offsetPos[i] - offsetPos[i - 1]) > 0.01 || abs(shownPos[i] - shownPos[i - 1]) > 0.5 { last = i }
        }
        guard last - first > 10 else { return nil }
        let window = first...last
        let travel = offsetPos[last] - offsetPos[first - 1]
        let sign: Double = travel < 0 ? -1 : 1
        let shownTravel = shownPos[last] - shownPos[first - 1]
        let shownSign: Double = shownTravel < 0 ? -1 : 1
        let sentSign: Double = window.reduce(0) { $0 + frames[$1].sent } < 0 ? -1 : 1
        for i in window {
            frames[i].uikit = (offsetPos[i] - offsetPos[i - 1]) * sign
            frames[i].shown = isReference ? frames[i].uikit : (shownPos[i] - shownPos[i - 1]) * shownSign
            frames[i].sent *= sentSign
        }
        // 前后 5 帧平均。
        func smoothed(_ key: KeyPath<Frame, Double>, _ i: Int) -> Double {
            let range = max(window.lowerBound, i - 2)...min(window.upperBound, i + 2)
            return range.reduce(0) { $0 + frames[$1][keyPath: key] } / Double(range.count)
        }
        for i in window {
            frames[i].smooth = smoothed(\.shown, i)
            frames[i].uikitSmooth = smoothed(\.uikit, i)
        }
        // 整体错开 L 拍。
        var lag = 0, best = Int.max
        for candidate in 0...3 {
            let bad = window.filter { i in
                let source = i - candidate
                guard source >= first - 1 else { return true }
                return abs(frames[i].shown - (source >= first ? frames[source].uikit : 0)) >= 1.5
            }.count
            if bad < best { best = bad; lag = candidate }
        }
        let moving = window.filter { frames[$0].uikitSmooth >= 1 }
        let midpoint = moving.isEmpty ? first : moving[moving.count / 2]
        for i in window {
            let source = i - lag
            let expected = source >= first ? frames[source].uikit : 0
            frames[i].expected = expected
            let expectedSmooth = source >= first ? frames[source].uikitSmooth : frames[first].uikitSmooth
            frames[i].phase = expectedSmooth < 1 ? "tail" : (i < midpoint ? "early" : "mid")
            var flags: [String] = []
            let f = frames[i]
            if expected >= 1, f.shown < 0.5 { flags.append("zero") }
            if expected >= 1, f.shown >= 2 * expected, f.shown - expected >= 2 { flags.append("double") }
            if abs(f.shown - expected) >= 1.5 { flags.append("miss") }
            if f.interval > 1.5 * nominal { flags.append("late") }
            if f.smooth >= 1, f.shown < 0.5 { flags.append("stall") }
            if f.smooth >= 1, f.shown >= 2 * f.smooth, f.shown - f.smooth >= 2 { flags.append("spike") }
            if let seen = firstSeen[i], f.shown >= 0.5 {
                frames[i].marginMS = (targets[i] - seen) * 1000
                if frames[i].marginMS < Self.tightMarginMS { flags.append("tight") }
            }
            if !isReference, f.shown >= 0.5 || expected >= 1 {
                if f.presentsMain + f.presentsOff == 0 { flags.append("no-present") }
                if f.presentsMain + f.presentsOff >= 2 { flags.append("multi-present") }
            }
            frames[i].flags = flags
        }
        let duration = (targets[last] - targets[first]) * 1000
        return Run(label: label, policy: policy, speed: speed, frames: frames, window: window, lag: lag,
                   travelPx: abs(travel), durationMS: duration)
    }

    private func runLine(_ run: Run) -> String {
        var parts: [String] = []
        for phase in Self.phases {
            let frames = run.window.filter { run.frames[$0].phase == phase }
            let counts = Self.flagKinds.map { kind in "\(kind)=\(frames.filter { run.frames[$0].flags.contains(kind) }.count)" }
            parts.append("\(phase)[\(frames.count)] " + counts.joined(separator: " "))
        }
        let all = Array(run.window)
        let draws = all.map { run.frames[$0].tickDraws }.reduce(0, +)
        let drawMS = all.map { run.frames[$0].tickDrawMS }.filter { $0 > 0 }
        let busy = all.map { run.frames[$0].busyMS }
        let pm = all.map { run.frames[$0].presentsMain }.reduce(0, +)
        let po = all.map { run.frames[$0].presentsOff }.reduce(0, +)
        let crossings = all.map { run.frames[$0].rowCross }.reduce(0, +)
        let margins = all.map { run.frames[$0].marginMS }.filter(\.isFinite)
        return String(format: "FLICK-RUN %@ frames=%d travel=%.0fpx dur=%.0fms lag=%d crossings=%d tick-draws=%d draw-ms p50=%.2f max=%.2f "
            + "busy p95=%.2f max=%.2f presents main=%d off=%d margin p5=%.2f p50=%.2f min=%.2f | %@",
            run.label, all.count, run.travelPx, run.durationMS, run.lag, crossings, draws,
            ProbeMetrics.percentile(drawMS, 0.5), drawMS.max() ?? 0, ProbeMetrics.percentile(busy, 0.95), busy.max() ?? 0,
            pm, po, ProbeMetrics.percentile(margins, 0.05), ProbeMetrics.percentile(margins, 0.5), margins.min() ?? 0,
            parts.joined(separator: " | "))
    }

    // MARK: 宿主

    private func windowTerminal(size: CGSize) async throws
        -> (MGhosttyTerminalView, UIWindow, (cols: Int, rows: Int), () -> Void) {
        let host = try GhosttyProbeHost(size: size)
        host.window.removeGestureRecognizer(host.touchWatch)
        try await host.waitUntilReady()
        host.feedAndWait(OnScreen.barcodeHistory(lines: Self.historyLines, cols: host.grid.cols))
        try await Task.sleep(for: .milliseconds(400))
        return (host.view, host.window, (Int(host.grid.cols), Int(host.grid.rows)), { host.close() })
    }

    private func workspaceTerminal(size: CGSize) async throws
        -> (MGhosttyTerminalView, UIWindow, (cols: Int, rows: Int), () -> Void) {
        let session = try await workspaceSession(size: size)
        return (session.view, session.window, session.grid, session.close)
    }

    struct WorkspaceSession {
        let view: MGhosttyTerminalView
        let window: UIWindow
        let bridge: GhosttyTerminalBridge
        let grid: (cols: Int, rows: Int)
        /// 假 SSH 后端往终端里写字节（程序输出）。
        let write: @MainActor (String) async -> Void
        let close: () -> Void
    }

    /// 和 user 手机上的路径只差真手指：SwiftUI 外壳、标签条、键盘条都在，可见窗口。
    private func workspaceSession(size: CGSize) async throws -> WorkspaceSession {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let server = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let store = MobileStore()
        store.showWorkspace = true
        let relay = HostKeyChallengeRelay()
        let script = MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, corpus: .plain)
        let (tab, handles) = MobileFakeTerminal.tab(host: server, script)
        let sessions = MobileWorkspace()
        sessions.open(.terminal(tab))
        sessions.activate(sessions.tabs[0].id)
        let rig = MobileProbeRig(label: "ghostty-flick", size: size, placement: .visibleOnScreen)
        rig.mount(WorkspaceScreen()
            .environment(store).environment(relay).environment(sessions)
            .environment(\.mAccent, M.accent).modelContainer(container))
        tab.controller.start(profile: server, container: container, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(connected)
        let bridge = tab.controller.terminal
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.view.surface != nil && bridge.grid != nil && bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface
        }
        XCTAssertTrue(ready, "Ghostty surface 没建起来")
        let transport = try XCTUnwrap(handles.latest)
        let cols = bridge.grid?.cols ?? 80
        await transport.write(Data(OnScreen.barcodeHistory(lines: Self.historyLines, cols: Int(cols)).utf8))
        _ = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { bridge.view.uTermCellPixels != nil }
        try await Task.sleep(for: .milliseconds(800))
        let window = try XCTUnwrap(bridge.view.window)
        return WorkspaceSession(view: bridge.view, window: window, bridge: bridge, grid: (Int(cols), Int(bridge.grid?.rows ?? 0)),
                                write: { text in await transport.write(Data(text.utf8)) },
                                close: {
                                    tab.controller.close()
                                    MobileProbeWindow.closeAll()
                                })
    }

    // MARK: 用例

    func testFlickFrames() async throws {
        let ticker = Slow.EarlyTicker()
        ticker.start()
        defer { ticker.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = scene.screen.bounds.size
        let (view, window, grid, close) = Self.hostKind == "workspace"
            ? try await workspaceTerminal(size: size) : try await windowTerminal(size: size)
        defer { close() }
        XCTAssertTrue(view.uTermSystemPanWouldBegin, "单指拖动不归系统滚动：量的不是那条路径")
        let cell = try XCTUnwrap(view.uTermCellPixels)
        let layer = try XCTUnwrap(OnScreen.surfaceLayer(in: view.layer), "找不到 IOSurfaceLayer")
        let scrollView = try XCTUnwrap(view.uTermSystemScrollView)
        let finger = try SyntheticFinger(window: window)
        let screen = window.screen
        let scale = Double(screen.nativeScale)
        let meta = String(format: "FLICK-META variant=%@ system=%@ window=%.0fx%.0fpt scale=%.3f native=%.3f max-fps=%d cell=%.0fx%.0fpx "
            + "grid=%dx%d engine=%@", Self.variant, UIDevice.current.systemVersion, size.width, size.height, screen.scale,
            screen.nativeScale, screen.maximumFramesPerSecond, cell.width, cell.height, grid.cols, grid.rows,
            TerminalEngineVersion.current)
        print(meta)
        var summary = [meta]
        var runs: [Run] = []

        // 预热。
        _ = try await flick(speed: 1500, direction: 1, startY: size.height * 0.8, x: size.width / 2, finger: finger, ticker: ticker)
        try await waitForRest(position: { Double(scrollView.contentOffset.y) }, moving: { !view.uTermScrollState.isAtRest })

        var glassCSV = "variant,policy,speed,dir,rep,kind,t_media,shown_px,offset_pt\n"
        if Self.glass {
            ticker.stop()
            print("FLICK-GLASS-READY")
            let wait = Self.env["UTERM_FLICK_GLASS_WAIT"].flatMap(Double.init) ?? 20
            try await Task.sleep(for: .seconds(wait))
            print("FLICK-GLASS-TRACING")
        }

        func measure(policy: String, speed: Double, direction: Double, rep: Int, isReference: Bool,
                     target: UIScrollView, shown: @escaping @MainActor () -> Double?, moving: @escaping () -> Bool) async throws {
            let startY = direction > 0 ? size.height * 0.8 : size.height * 0.2
            if Self.glass {
                let sampler = GlassSampler()
                sampler.read = { (shown(), Double(target.contentOffset.y)) }
                ticker.start()
                sampler.start()
                let begin = CACurrentMediaTime()
                let lift = try await flick(speed: speed, direction: direction, startY: startY, x: size.width / 2,
                                           finger: finger, ticker: ticker)
                // 抬手之后测试不再开任何 display link。
                ticker.stop()
                try await waitForRest(position: { Double(target.contentOffset.y) }, moving: moving)
                sampler.stop()
                let tag = "\(Self.variant),\(policy),\(Int(speed)),\(direction > 0 ? "up" : "down"),\(rep)"
                glassCSV += "\(tag),begin,\(String(format: "%.6f", begin)),nan,nan\n"
                glassCSV += "\(tag),lift,\(String(format: "%.6f", lift)),nan,nan\n"
                for row in sampler.rows {
                    glassCSV += "\(tag),commit,\(String(format: "%.6f", row.time)),"
                        + "\(row.shown.map { String(format: "%.0f", $0) } ?? "nan"),\(String(format: "%.4f", row.offset))\n"
                }
                glassCSV += "\(tag),end,\(String(format: "%.6f", CACurrentMediaTime())),nan,nan\n"
                print("FLICK-GLASS-RUN \(tag) commits=\(sampler.rows.count) dur=\(Int((CACurrentMediaTime() - lift) * 1000))ms")
                return
            }
            let sampler = OnScreen.CommitSampler()
            var samples: [(time: Double, shown: Double?, offset: Double)] = []
            sampler.read = {
                let value = shown()
                samples.append((CACurrentMediaTime(), value, Double(target.contentOffset.y)))
                return value ?? 0
            }
            let clock = Clock()
            UTermScrollTrace.isEnabled = true
            GhosttyPresentLog.reset()
            sampler.start()
            clock.start()
            let lift = try await flick(speed: speed, direction: direction, startY: startY, x: size.width / 2,
                                       finger: finger, ticker: ticker)
            try await waitForRest(position: { Double(target.contentOffset.y) }, moving: moving)
            clock.stop()
            sampler.stop()
            let trace = UTermScrollTrace.drain()
            UTermScrollTrace.isEnabled = false
            let presents = GhosttyPresentLog.readThreads()
            let label = "\(Self.variant) policy=\(policy) v=\(Int(speed)) dir=\(direction > 0 ? "up" : "down") rep=\(rep)"
            guard let run = analyze(label: label, policy: policy, speed: Int(speed), targets: sampler.targets, lift: lift,
                                    samples: samples, scale: scale, trace: trace, presents: presents, clock: clock,
                                    isReference: isReference) else {
                XCTFail("\(label)：没量到减速（targets=\(sampler.targets.count) samples=\(samples.count)）")
                return
            }
            let line = runLine(run)
            print(line)
            summary.append(line)
            runs.append(run)
        }

        for (name, policy, linkSpeed) in Self.policies {
            UTermScrollTrace.scrollWakeupSyncDraw = policy
            UTermScrollTrace.wakeupDisplayLinkMinimumSpeed = linkSpeed
            for speed in Self.speeds {
                for rep in 0..<Self.runs {
                    for direction in [1.0, -1.0] {
                        // 起点：往底部甩的从靠上处起，往顶部甩的从靠下处起，留够减速的行程。
                        let row = direction > 0 ? 600 + rep * 37 : Self.historyLines - 700 - rep * 37
                        _ = view.surface?.scrollToRow(UInt(row))
                        try await Task.sleep(for: .milliseconds(350))
                        var decoder = OnScreen.BarcodeDecoder(cell: cell)
                        try await measure(policy: name, speed: speed, direction: direction, rep: rep, isReference: false,
                                          target: scrollView, shown: { decoder.position(of: layer) },
                                          moving: { !view.uTermScrollState.isAtRest || scrollView.isDecelerating })
                        try await Task.sleep(for: .milliseconds(300))
                    }
                }
            }
        }
        UTermScrollTrace.scrollWakeupSyncDraw = UTermScrollTrace.defaultScrollWakeupSyncDraw
        UTermScrollTrace.wakeupDisplayLinkMinimumSpeed = UTermScrollTrace.defaultWakeupDisplayLinkMinimumSpeed

        if Self.reference {
            // 参照组：同样大小、同样内容高度的普通 UIScrollView，起点同样在中间。
            let frame = scrollView.convert(scrollView.bounds, to: window)
            let plain = UIScrollView(frame: CGRect(origin: frame.origin, size: scrollView.bounds.size))
            plain.contentSize = scrollView.contentSize
            plain.decelerationRate = .normal
            plain.contentInsetAdjustmentBehavior = .never
            plain.showsVerticalScrollIndicator = false
            plain.backgroundColor = .darkGray
            view.isHidden = true
            window.addSubview(plain)
            defer { plain.removeFromSuperview(); view.isHidden = false }
            for speed in Self.speeds {
                for rep in 0..<Self.runs {
                    for direction in [1.0, -1.0] {
                        let row = direction > 0 ? 600 + rep * 37 : Self.historyLines - 700 - rep * 37
                        plain.setContentOffset(CGPoint(x: 0, y: CGFloat(row) * CGFloat(cell.height) / CGFloat(scale)), animated: false)
                        try await Task.sleep(for: .milliseconds(200))
                        try await measure(policy: "reference", speed: speed, direction: direction, rep: rep, isReference: true,
                                          target: plain, shown: { nil }, moving: { plain.isDecelerating || plain.isTracking })
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        }

        // 合起来：每个做法 × 速度，每段每类事件的数量。
        let keys = Array(Set(runs.map { "\($0.policy)|\($0.speed)" })).sorted { a, b in
            let pa = a.split(separator: "|"), pb = b.split(separator: "|")
            return (String(pa[0]), Int(pa[1]) ?? 0) < (String(pb[0]), Int(pb[1]) ?? 0)
        }
        var csv = "variant,policy,speed,dir_rep,frame,t_ms,interval_ms,phase,uikit_px,expected_px,shown_px,smooth_px,sent_px,"
            + "row_cross,tick_draws,tick_draw_ms,wakeups,presents_main,presents_off,busy_ms,margin_ms,flags\n"
        func number(_ v: Double, _ f: String = "%.3f") -> String { v.isFinite ? String(format: f, v) : "nan" }
        for key in keys {
            let group = runs.filter { "\($0.policy)|\($0.speed)" == key }
            var parts: [String] = []
            for phase in Self.phases {
                let frames = group.flatMap { run in run.window.filter { run.frames[$0].phase == phase }.map { run.frames[$0] } }
                let counts = Self.flagKinds.map { kind in "\(kind)=\(frames.filter { $0.flags.contains(kind) }.count)" }
                parts.append("\(phase)[\(frames.count)] " + counts.joined(separator: " "))
            }
            let all = group.flatMap { run in run.window.map { run.frames[$0] } }
            let line = String(format: "FLICK-SUM %@ %@ runs=%d frames=%d lags=%@ tick-draws=%d presents main=%d off=%d | %@",
                              Self.variant, key, group.count, all.count, group.map { String($0.lag) }.joined(separator: "/"),
                              all.map(\.tickDraws).reduce(0, +), all.map(\.presentsMain).reduce(0, +),
                              all.map(\.presentsOff).reduce(0, +), parts.joined(separator: " | "))
            print(line)
            summary.append(line)
        }
        for run in runs {
            let origin = run.frames[run.window.lowerBound].target
            let tag = run.label.components(separatedBy: " ").filter { $0.hasPrefix("dir=") || $0.hasPrefix("rep=") }.joined(separator: "/")
            for i in run.window {
                let f = run.frames[i]
                csv += "\(Self.variant),\(run.policy),\(run.speed),\(tag),\(i),\(number((f.target - origin) * 1000)),\(number(f.interval * 1000)),"
                    + "\(f.phase),\(number(f.uikit)),\(number(f.expected)),\(number(f.shown)),\(number(f.smooth)),\(number(f.sent)),"
                    + "\(f.rowCross),\(f.tickDraws),\(number(f.tickDrawMS)),\(f.wakeups),\(f.presentsMain),\(f.presentsOff),"
                    + "\(number(f.busyMS)),\(number(f.marginMS)),\(f.flags.joined(separator: "|"))\n"
            }
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slowdrag")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if Self.glass { print("FLICK-GLASS-DONE") }
        let outputs = Self.glass ? [("ios-flick-\(Self.variant)-commits.csv", glassCSV)]
            : [("ios-flick-\(Self.variant).csv", csv), ("ios-flick-\(Self.variant)-summary.txt", summary.joined(separator: "\n"))]
        for (name, text) in outputs {
            let url = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            print("FLICK wrote \(url.path)")
            let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    // MARK: 静置之后

    /// 按下、匀速拖 `seconds`、按住 6 帧（松手不甩）、抬起。返回开始拖的时刻。
    private func slowDrag(speed: Double, seconds: Double, startY: CGFloat, x: CGFloat, finger: SyntheticFinger,
                          ticker: Slow.EarlyTicker) async throws -> Double {
        var failure: Error?
        var begin = 0.0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var startTarget: Double?
            var held = 0
            ticker.step = { link in
                do {
                    guard let start = startTarget else {
                        try finger.down(at: CGPoint(x: x, y: startY))
                        startTarget = link.targetTimestamp
                        begin = CACurrentMediaTime()
                        return
                    }
                    let elapsed = link.targetTimestamp - start
                    if elapsed < seconds {
                        try finger.move(to: CGPoint(x: x, y: startY - CGFloat(speed * elapsed)))
                    } else if held < 6 {
                        try finger.hold()
                        held += 1
                    } else {
                        try finger.up()
                        ticker.step = nil
                        done.resume()
                    }
                } catch {
                    failure = error
                    ticker.step = nil
                    done.resume()
                }
            }
        }
        if let failure { throw failure }
        return begin
    }

    /// user：「静置一段时间后，不要出现泄漏或者什么问题导致又变卡了」。工作区界面里：
    /// 量一轮（慢拖 80 pt/s + 甩 2000 pt/s）→ 前台静置 `UTERM_SOAK_IDLE` 秒（默认 600，屏幕常亮，每 10 s 来一行程序输出）
    /// → 再量一轮 → 退后台 `UTERM_SOAK_BACKGROUND` 秒（默认 70，过了 60 s 放掉 surface 的时限）→ 回前台再量一轮。
    /// 静置期间记：推迟 wakeup 的次数、轮询次数、display link 起了几次、同步重画几次、主线程 CPU、内存（phys_footprint）。
    /// 后台：标签不在屏上（`setOnScreen(false)`，容器隐藏时同一个入口）+ 应用的前后台通知（协调器按它停 tick）。
    func testSoakIdle() async throws {
        let idleSeconds = Self.env["UTERM_SOAK_IDLE"].flatMap(Double.init) ?? 600
        let backgroundSeconds = Self.env["UTERM_SOAK_BACKGROUND"].flatMap(Double.init) ?? 70
        let ticker = Slow.EarlyTicker()
        ticker.start()
        defer { ticker.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = scene.screen.bounds.size
        let session = try await workspaceSession(size: size)
        defer { session.close() }
        let view = session.view
        let finger = try SyntheticFinger(window: session.window)
        let scale = Double(session.window.screen.nativeScale)
        var lines: [String] = [String(format: "SOAK-META variant=%@ idle=%.0fs background=%.0fs policy=%@ link-speed=%.0f",
                                      Self.variant, idleSeconds, backgroundSeconds,
                                      UTermScrollTrace.scrollWakeupSyncDraw.rawValue, UTermScrollTrace.wakeupDisplayLinkMinimumSpeed)]
        print(lines[0])

        /// 一次手势的逐帧账，返回一行摘要和「出事」的帧数。
        func record(_ label: String, gesture: () async throws -> Double, from offset: Double) async throws -> (String, Int) {
            let scrollView = try XCTUnwrap(view.uTermSystemScrollView)
            let cell = try XCTUnwrap(view.uTermCellPixels)
            let layer = try XCTUnwrap(OnScreen.surfaceLayer(in: view.layer), "找不到 IOSurfaceLayer")
            var decoder = OnScreen.BarcodeDecoder(cell: cell)
            let sampler = OnScreen.CommitSampler()
            var samples: [(time: Double, shown: Double?, offset: Double)] = []
            sampler.read = {
                let value = decoder.position(of: layer)
                samples.append((CACurrentMediaTime(), value, Double(scrollView.contentOffset.y)))
                return value ?? 0
            }
            let clock = Clock()
            UTermScrollTrace.isEnabled = true
            GhosttyPresentLog.reset()
            sampler.start()
            clock.start()
            let start = try await gesture()
            try await waitForRest(position: { Double(scrollView.contentOffset.y) },
                                  moving: { !view.uTermScrollState.isAtRest || scrollView.isDecelerating })
            clock.stop()
            sampler.stop()
            let trace = UTermScrollTrace.drain()
            UTermScrollTrace.isEnabled = false
            guard let run = analyze(label: label, policy: "soak", speed: 0, targets: sampler.targets, lift: start + offset,
                                    samples: samples, scale: scale, trace: trace, presents: GhosttyPresentLog.readThreads(),
                                    clock: clock, isReference: false) else {
                XCTFail("\(label)：没量到")
                return ("\(label) -", 0)
            }
            let frames = run.window.map { run.frames[$0] }
            let kinds = ["zero", "double", "stall", "spike", "late"]
            let counts = kinds.map { kind in frames.filter { $0.flags.contains(kind) }.count }
            let bad = frames.filter { f in f.flags.contains { ["zero", "double", "late"].contains($0) } }.count
            let summary = "\(label)[frames=\(frames.count) " + zip(kinds, counts).map { "\($0)=\($1)" }.joined(separator: " ")
                + " tick-draws=\(trace.filter { $0.kind == "tick-draw" }.count) deferred=\(trace.filter { $0.kind == "wakeup-deferred" }.count)"
                + " link-starts=\(trace.filter { $0.kind == "link-start" }.count)]"
            return (summary, bad)
        }

        func round(_ name: String) async throws {
            _ = view.surface?.scrollToRow(1500)
            try await Task.sleep(for: .milliseconds(400))
            let (drag, dragBad) = try await record("drag80", gesture: {
                try await slowDrag(speed: 80, seconds: 1.6, startY: size.height * 0.8, x: size.width / 2, finger: finger, ticker: ticker)
            }, from: 0.35)
            try await Task.sleep(for: .milliseconds(300))
            _ = view.surface?.scrollToRow(600)
            try await Task.sleep(for: .milliseconds(400))
            let (fling, flingBad) = try await record("flick2000", gesture: {
                try await flick(speed: 2000, direction: 1, startY: size.height * 0.8, x: size.width / 2, finger: finger, ticker: ticker)
            }, from: 0)
            let line = String(format: "SOAK-ROUND %@ %@ %@ bad=%d/%d footprint=%.1fMB", name, drag, fling, dragBad, flingBad,
                              ProbeMetrics.footprintMB())
            print(line)
            lines.append(line)
        }

        /// 静置 `seconds`：测试自己不开 display link；每 10 s 写一行输出。
        func idle(_ name: String, seconds: Double, output: Bool) async throws {
            ticker.stop()
            defer { ticker.start() }
            let footprint0 = ProbeMetrics.footprintMB()
            let cpu0 = ThreadCPU.current()
            let wall0 = CACurrentMediaTime()
            UTermScrollTrace.isEnabled = true
            var written = 0
            while CACurrentMediaTime() - wall0 < seconds {
                if output {
                    await session.write("soak output \(written) \(Date())\r\n")
                    written += 1
                }
                try await Task.sleep(for: .seconds(min(10, max(0.1, seconds - (CACurrentMediaTime() - wall0)))))
            }
            let trace = UTermScrollTrace.drain()
            UTermScrollTrace.isEnabled = false
            let cpu = (ThreadCPU.current() - cpu0) * 1000
            let wall = CACurrentMediaTime() - wall0
            func count(_ kind: String) -> Int { trace.filter { $0.kind == kind }.count }
            let line = String(format: "SOAK-IDLE %@ wall=%.0fs lines=%d wakeups=%d deferred=%d polls=%d link-starts=%d tick-app=%d "
                + "tick-draws=%d trace-events=%d main-cpu=%.0fms (%.2f ms/s) footprint %.1f→%.1fMB released=%@",
                name, wall, written, count("wakeup-tick"), count("wakeup-deferred"), count("wakeup-poll"), count("link-start"),
                count("tick-app"), count("tick-draw"), trace.count, cpu, cpu / wall, footprint0, ProbeMetrics.footprintMB(),
                view.uTermIsSurfaceReleased ? "yes" : "no")
            print(line)
            lines.append(line)
        }

        try await round("start")
        try await idle("foreground", seconds: idleSeconds, output: true)
        try await round("after-idle")
        // 后台：标签不在屏上 + 应用进后台；过了 surface 放掉的时限再回来。
        session.bridge.setOnScreen(false)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: UIApplication.shared)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        try await idle("background", seconds: backgroundSeconds, output: true)
        let releasedInBackground = view.uTermIsSurfaceReleased
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        session.bridge.setOnScreen(true)
        let deadline = CACurrentMediaTime() + 5
        while CACurrentMediaTime() < deadline,
              !(view.surface != nil && session.bridge.isSurfaceReady && session.bridge.outputPump.isFeedingSurface) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(1500))
        let line = "SOAK-RESTORE released-in-background=\(releasedInBackground) surface=\(view.surface != nil) "
            + "ready=\(session.bridge.isSurfaceReady)"
        print(line)
        lines.append(line)
        try await round("after-background")
        try await idle("final-rest", seconds: 20, output: false)

        let text = lines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "ios-soak-\(Self.variant).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(releasedInBackground || backgroundSeconds < 60, "后台 \(backgroundSeconds) s 没放掉 surface：没走到放掉 / 重建那条路")
    }
}
