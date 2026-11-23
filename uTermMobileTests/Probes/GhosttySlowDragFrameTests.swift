import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// 慢滚（单指按着、慢慢拖过回滚区）逐帧上屏的账：user 在 Duo 上说慢滚「有点卡」。
///
/// 真的合成触摸（`SyntheticFinger`：UIKit 自己的拖动手势、系统滚动那个借来的 UIScrollView 的 `scrollViewDidScroll`
/// 按像素挪引擎视口），手指匀速拖（默认 40 / 80 / 150 / 300 pt/s，两个方向，每次约 2 s），每个显示帧记：
/// - 屏上画面实际走了多少（`GhosttyOnScreenScrollTests.BarcodeDecoder` 从提交后的 IOSurface 解条码，按参考 link 的 vsync 分桶）；
/// - 手指这一帧走了多少、交给引擎多少（`drag`）、视口跨没跨行（`row`）；
/// - 主线程的 tick（`tick-app` / `tick-refresh` / `tick-draw` 同步整帧重画 / `wakeup-tick`）、主线程忙时、
///   这一帧是主线程交的画面还是渲染线程交的（`GhosttyPresentLog.readThreads`）；
/// - 参考 link 两拍之间隔了多久（> 1.5 拍 = 跳拍）。
///
/// 判定（只看手指匀速拖动的那一段，开头 12 帧不算）：
/// - 上屏位置和「交给引擎的累计位移」（整体错开 L 拍，L 取对不上最少的那个）的残差，偏离中位数 ≥ 1 px：`behind` / `ahead`；
/// - 一帧上屏比该显示的少 / 多 1.5 px 以上：`drop` / `jump`（每帧步长 ≥ 1 px 时才有意义）；
/// - 手指动了、上屏 0：`zero`（40 pt/s 时每帧不到 1 px，取整本身就会有，只当参考）；
/// - 手指动了、UIKit 这一帧没交给引擎：`input-gap`；交了平常的 1.6 倍以上：`input-double`；
/// - 参考 link 跳拍：`late`。
/// 每类事件再看它旁边（这一帧及之前 L+1 帧）有没有跨行、有没有主线程同步重画，和所有帧的基准比。
///
/// 手指事件两种发法（`UTERM_SLOWDRAG_FEEDS`，默认 `vsync,timer`）：
/// - `vsync`：每个显示帧一次，在一条比引擎的 display link 先加进 run loop 的 link 里发（真手指的触摸也是在 display link
///   之前派发）；
/// - `timer`：120 Hz 的定时器，不对齐显示帧（一帧里可能 0 个或 2 个事件），看 UIKit 拖动这一路会不会把它变成 0 / 2 步。
///
/// `testSlowDragFrames` 默认跳过（测量门）：`TEST_RUNNER_UTERM_MEASURE=1` 打开，真机上跑。另外可调：
/// `UTERM_SLOWDRAG_SPEEDS`（逗号分隔 pt/s）、`UTERM_SLOWDRAG_SECONDS`（默认 2）、`UTERM_SLOWDRAG_RUNS`（每个方向几次，默认 2）、
/// `UTERM_SLOWDRAG_DECODE=0`（不解条码，看测量本身占多少）、`UTERM_SLOWDRAG_VARIANT`（写进 CSV 的变体名，默认 `head`）。
/// 输出：`SLOWDRAG-RUN` / `SLOWDRAG-SUM` / `SLOWDRAG-BAD` 行，CSV 写进测试宿主的 tmp（`slowdrag/`）并挂成 XCTest 附件。
@MainActor
final class GhosttySlowDragFrameTests: XCTestCase {
    typealias OnScreen = GhosttyOnScreenScrollTests
    typealias Clock = GhosttyFrameBudgetTests.MainLoopClock

    private static let env = ProcessInfo.processInfo.environment
    static var speeds: [Double] {
        env["UTERM_SLOWDRAG_SPEEDS"].map { $0.split(separator: ",").compactMap { Double($0) } } ?? [40, 80, 150, 300]
    }
    static var seconds: Double { env["UTERM_SLOWDRAG_SECONDS"].flatMap(Double.init) ?? 2 }
    static var runs: Int { env["UTERM_SLOWDRAG_RUNS"].flatMap(Int.init) ?? 2 }
    static var decodes: Bool { env["UTERM_SLOWDRAG_DECODE"] != "0" }
    static var variant: String { env["UTERM_SLOWDRAG_VARIANT"].flatMap { $0.isEmpty ? nil : $0 } ?? "head" }
    static var feeds: [Feed] {
        (env["UTERM_SLOWDRAG_FEEDS"] ?? "vsync,timer").split(separator: ",").compactMap { Feed(rawValue: String($0)) }
    }

    enum Feed: String { case vsync, timer }

    /// 补丁 #20 的几种做法（`UTermScrollTrace.ScrollWakeupSyncDraw`），`UTERM_SCROLL_POLICIES`，默认只跑包里的默认值。
    static var policies: [UTermScrollTrace.ScrollWakeupSyncDraw] {
        (env["UTERM_SCROLL_POLICIES"] ?? UTermScrollTrace.defaultScrollWakeupSyncDraw.rawValue).split(separator: ",")
            .compactMap { UTermScrollTrace.ScrollWakeupSyncDraw(rawValue: String($0)) }
    }

    /// 手指拖之前先走这么久（UIKit 的拖动要先过一段起拖距离），不算进统计。
    static let leadIn = 0.4
    static let historyLines = 3000

    override func setUp() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func tearDown() async throws {
        UTermScrollTrace.isEnabled = false
        UTermScrollTrace.scrollWakeupSyncDraw = UTermScrollTrace.defaultScrollWakeupSyncDraw
    }

    // MARK: 发手指事件的 link

    /// 一直开着的 display link。在宿主建 surface 之前加进 run loop，回调排在引擎的 link 前面（引擎的 link 闲下来就拆掉、
    /// 再要帧时重建，重建的排在它后面）。
    @MainActor
    final class EarlyTicker: NSObject {
        private var link: CADisplayLink?
        var step: (@MainActor (CADisplayLink) -> Void)?

        func start() {
            link?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func frame(_ link: CADisplayLink) { step?(link) }
    }

    /// 120 Hz 的定时器（不对齐显示帧），`tick` 返回 false 时停。
    @MainActor
    final class TimerFeed: NSObject {
        private var tick: (@MainActor () -> Bool)?
        private var timer: Timer?
        private var done: CheckedContinuation<Void, Never>?

        func run(interval: Double, _ tick: @escaping @MainActor () -> Bool) async {
            self.tick = tick
            await withCheckedContinuation { continuation in
                done = continuation
                let timer = Timer(timeInterval: interval, target: self, selector: #selector(fire), userInfo: nil, repeats: true)
                timer.tolerance = 0
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        }

        @objc private func fire() {
            guard tick?() != true else { return }
            timer?.invalidate()
            timer = nil
            tick = nil
            done?.resume()
            done = nil
        }
    }

    struct Move { let time: Double; let y: Double }

    /// 按下、匀速拖 `leadIn + seconds`、按住 6 帧（速度落到 0，松手不甩）、抬起。返回每个 moved 的时刻和手指位置、抬手时刻。
    private func drag(feed: Feed, speed: Double, direction: Double, seconds: Double, startY: CGFloat, x: CGFloat,
                      finger: SyntheticFinger, ticker: EarlyTicker) async throws -> (moves: [Move], dragEnd: Double) {
        var moves: [Move] = []
        var failure: Error?
        var dragEnd = 0.0
        let total = Self.leadIn + seconds
        func position(_ elapsed: Double) -> CGFloat { startY - CGFloat(direction * speed * min(elapsed, total)) }

        switch feed {
        case .vsync:
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                var startTarget: Double?
                var held = 0
                ticker.step = { link in
                    do {
                        guard let start = startTarget else {
                            try finger.down(at: CGPoint(x: x, y: startY))
                            startTarget = link.targetTimestamp
                            return
                        }
                        let elapsed = link.targetTimestamp - start
                        if elapsed < total {
                            let y = position(elapsed)
                            try finger.move(to: CGPoint(x: x, y: y))
                            moves.append(Move(time: CACurrentMediaTime(), y: Double(y)))
                            dragEnd = CACurrentMediaTime()
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
        case .timer:
            try finger.down(at: CGPoint(x: x, y: startY))
            let start = CACurrentMediaTime()
            var held = 0
            await TimerFeed().run(interval: 1.0 / 120) {
                do {
                    let elapsed = CACurrentMediaTime() - start
                    if elapsed < total {
                        let y = position(elapsed)
                        try finger.move(to: CGPoint(x: x, y: y))
                        moves.append(Move(time: CACurrentMediaTime(), y: Double(y)))
                        dragEnd = CACurrentMediaTime()
                        return true
                    }
                    if held < 6 { try finger.hold(); held += 1; return true }
                    try finger.up()
                } catch {
                    failure = error
                }
                return false
            }
        }
        if let failure { throw failure }
        return (moves, dragEnd)
    }

    // MARK: 逐帧的账

    struct FrameRow {
        let index: Int
        let target: Double
        let interval: Double
        var moves = 0
        /// 手指这一帧走了多少（pt，顺着拖动方向为正）。
        var finger = 0.0
        var drags = 0
        /// 这一帧交给引擎的像素（顺着拖动方向为正）。
        var sent = 0.0
        var shown = Double.nan
        var shownPos = Double.nan
        var sentCum = 0.0
        var expectedPos = Double.nan
        var resid = Double.nan
        var rowCross = 0
        var tickDraws = 0
        var tickDrawMS = 0.0
        var tickAppMS = 0.0
        var tickRefreshMS = 0.0
        var wakeups = 0
        var wakeupMS = 0.0
        var presentsMain = 0
        var presentsOff = 0
        var busyMS = 0.0
        var decodeMS = 0.0
        var drawBeforeMove = false
        var flags: [String] = []
    }

    struct RunResult {
        let label: String
        let rows: [FrameRow]
        let window: ClosedRange<Int>
        let lag: Int
        let nominal: Double
        let expectedStep: Double
        let lines: [String]
    }

    static let flagKinds = ["late", "behind", "ahead", "drop", "jump", "zero", "input-gap", "input-double"]

    private func analyze(label: String, targets: [Double], moves: [Move], dragEnd: Double, direction: Double,
                         trace: [UTermScrollTrace.Event], samples: [OnScreen.CommitSampler.Sample],
                         decodeSpans: [(Double, Double)], presents: [(time: Double, main: Bool)],
                         clock: Clock) -> RunResult? {
        guard targets.count > 30 else { return nil }
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
        var rows = targets.indices.map { i in
            FrameRow(index: i, target: targets[i], interval: i > 0 ? targets[i] - targets[i - 1] : nominal)
        }
        var previousY: Double?
        for move in moves {
            defer { previousY = move.y }
            guard let i = slot(move.time) else { continue }
            rows[i].moves += 1
            if let previousY { rows[i].finger += (previousY - move.y) * direction }
        }
        // 引擎收到的、跨行、tick。
        var lastRow: Double?
        var drags: [(Int, Double)] = []
        for event in trace {
            guard let i = slot(event.time) else {
                if event.kind == "row" { lastRow = event.value }
                continue
            }
            switch event.kind {
            case "drag":
                rows[i].drags += 1
                drags.append((i, event.value))
            case "row":
                if let lastRow, lastRow != event.value { rows[i].rowCross += 1 }
                lastRow = event.value
            case "tick-draw":
                rows[i].tickDraws += 1
                rows[i].tickDrawMS += event.value
                let firstMove = moves.first { slot($0.time) == i }?.time
                if let firstMove, event.time < firstMove { rows[i].drawBeforeMove = true }
            case "tick-app": rows[i].tickAppMS += event.value
            case "tick-refresh": rows[i].tickRefreshMS += event.value
            case "wakeup-tick":
                rows[i].wakeups += 1
                rows[i].wakeupMS += event.value
            default: break
            }
        }
        let sentSign: Double = drags.reduce(0) { $0 + $1.1 } < 0 ? -1 : 1
        for (i, value) in drags { rows[i].sent += value * sentSign }
        for present in presents {
            guard let i = slot(present.time) else { continue }
            if present.main { rows[i].presentsMain += 1 } else { rows[i].presentsOff += 1 }
        }
        for (start, ms) in decodeSpans { if let i = slot(start) { rows[i].decodeMS += ms } }
        for i in rows.indices {
            let windowStart = i > 0 ? targets[i - 1] : targets[i] - nominal, windowEnd = targets[i]
            func overlap(_ a: Double, _ b: Double) -> Double { max(0, min(b, windowEnd) - max(a, windowStart)) * 1000 }
            rows[i].busyMS = clock.busy.reduce(0) { $0 + overlap($1.start, $1.end) }
        }
        // 上屏位置：每拍取最后一次提交，没读到的拍沿用上一拍。
        var position = [Double?](repeating: nil, count: targets.count)
        for sample in samples { if let i = slot(sample.time) { position[i] = sample.value } }
        var carried: Double?
        for i in rows.indices {
            if let value = position[i] { carried = value }
            rows[i].shownPos = carried ?? .nan
        }

        // 窗口：引擎收到第一步之后 12 帧，到手指最后一次匀速移动。
        guard let firstDrag = drags.first?.0, let last = slot(dragEnd) else { return nil }
        let first = firstDrag + 12
        guard last - first > 30 else { return nil }
        let window = first...last
        var cum = 0.0
        for i in rows.indices {
            cum += rows[i].sent
            rows[i].sentCum = cum
        }
        let shownDelta = rows[last].shownPos - rows[first].shownPos
        let shownSign: Double = shownDelta < 0 ? -1 : 1
        let decoded = Self.decodes && !shownDelta.isNaN
        if decoded {
            for i in window where i > 0 {
                rows[i].shown = (rows[i].shownPos - rows[i - 1].shownPos) * shownSign
            }
        }

        // 整体错开 L 拍：残差 = 上屏位置 − L 拍之前的累计位移，取偏离中位数 ≥ 1 px 最少的 L。
        func residuals(_ lag: Int) -> [Double] {
            window.map { i in
                let source = i - lag
                guard source >= 0, !rows[i].shownPos.isNaN else { return .nan }
                return (rows[i].shownPos - rows[first].shownPos) * shownSign - rows[source].sentCum
            }
        }
        var lag = 0
        if decoded {
            var best = Int.max
            for candidate in 0...3 {
                let r = residuals(candidate).filter { !$0.isNaN }
                let median = ProbeMetrics.percentile(r, 0.5)
                let bad = r.filter { abs($0 - median) >= 1 }.count
                if bad < best { best = bad; lag = candidate }
            }
            let r = residuals(lag)
            let median = ProbeMetrics.percentile(r.filter { !$0.isNaN }, 0.5)
            for (offset, i) in window.enumerated() {
                rows[i].resid = r[offset] - median
                rows[i].expectedPos = rows[max(0, i - lag)].sentCum + median
            }
        }
        let sentSteps = window.map { rows[$0].sent }.filter { $0 > 0.01 }
        let medianSent = ProbeMetrics.percentile(sentSteps, 0.5)
        let expectedStep = window.map { rows[$0].sent }.reduce(0, +) / Double(window.count)
        for i in window {
            var flags: [String] = []
            if rows[i].interval > 1.5 * nominal { flags.append("late") }
            if decoded {
                let expected = i - lag >= 0 ? rows[i - lag].sent : 0
                if rows[i].resid <= -1 { flags.append("behind") }
                if rows[i].resid >= 1 { flags.append("ahead") }
                if expected - rows[i].shown >= 1.5 { flags.append("drop") }
                if rows[i].shown - expected >= 1.5 { flags.append("jump") }
                if rows[i].shown < 0.5, rows[i].finger > 0.01 { flags.append("zero") }
            }
            if rows[i].finger > 0.01, rows[i].drags == 0 { flags.append("input-gap") }
            if medianSent > 0, rows[i].sent >= 1.6 * medianSent { flags.append("input-double") }
            rows[i].flags = flags
        }

        // 账：每类事件里，旁边（本帧及之前 lag+1 帧）有跨行 / 主线程同步重画的比例，和全部帧的基准比。
        func near(_ i: Int, _ key: KeyPath<FrameRow, Int>) -> Bool {
            (max(0, i - lag - 1)...i).contains { rows[$0][keyPath: key] > 0 }
        }
        let all = Array(window)
        func pctNear(_ frames: [Int], _ key: KeyPath<FrameRow, Int>) -> String {
            frames.isEmpty ? "-" : String(format: "%.0f%%", 100 * Double(frames.filter { near($0, key) }.count) / Double(frames.count))
        }
        var counts: [String] = []
        for kind in Self.flagKinds {
            let frames = all.filter { rows[$0].flags.contains(kind) }
            counts.append("\(kind)=\(frames.count)")
        }
        let crossings = all.map { rows[$0].rowCross }.reduce(0, +)
        let draws = all.map { rows[$0].tickDraws }.reduce(0, +)
        let drawMS = all.map { rows[$0].tickDrawMS }.filter { $0 > 0 }
        let busy = all.map { rows[$0].busyMS }
        let presentsMain = all.map { rows[$0].presentsMain }.reduce(0, +)
        let presentsOff = all.map { rows[$0].presentsOff }.reduce(0, +)
        let drawFirst = all.filter { rows[$0].drawBeforeMove }.count
        var lines: [String] = []
        lines.append(String(format: "SLOWDRAG-RUN %@ frames=%d nominal=%.2fms step=%.2fpx lag=%d %@ crossings=%d tick-draws=%d "
            + "draw-ms p50=%.2f max=%.2f busy p50=%.2f p95=%.2f max=%.2f presents main=%d off=%d draw-before-move=%d "
            + "| behind near-cross=%@ near-draw=%@ | late near-cross=%@ near-draw=%@ | base near-cross=%@ near-draw=%@",
            label, all.count, nominal * 1000, expectedStep, lag, counts.joined(separator: " "), crossings, draws,
            ProbeMetrics.percentile(drawMS, 0.5), drawMS.max() ?? 0, ProbeMetrics.percentile(busy, 0.5),
            ProbeMetrics.percentile(busy, 0.95), busy.max() ?? 0, presentsMain, presentsOff, drawFirst,
            pctNear(all.filter { rows[$0].flags.contains("behind") }, \.rowCross),
            pctNear(all.filter { rows[$0].flags.contains("behind") }, \.tickDraws),
            pctNear(all.filter { rows[$0].flags.contains("late") }, \.rowCross),
            pctNear(all.filter { rows[$0].flags.contains("late") }, \.tickDraws),
            pctNear(all, \.rowCross), pctNear(all, \.tickDraws)))
        // 出事的帧逐帧列（前后各一帧），最多 16 处。
        let bad = all.filter { i in rows[i].flags.contains { ["late", "behind", "ahead", "drop", "jump"].contains($0) } }
        for i in bad.prefix(16) {
            let around = (max(window.lowerBound, i - 2)...min(window.upperBound, i + 1)).map { j in
                let r = rows[j]
                return String(format: "#%d%@ sh=%.0f se=%.2f res=%.1f row=%d draw=%d(%.1fms) pm=%d po=%d busy=%.1f iv=%.1f",
                              j, j == i ? "*" : "", r.shown, r.sent, r.resid, r.rowCross, r.tickDraws, r.tickDrawMS,
                              r.presentsMain, r.presentsOff, r.busyMS, r.interval * 1000)
            }
            lines.append("SLOWDRAG-BAD \(label) [\(rows[i].flags.joined(separator: ","))] " + around.joined(separator: " | "))
        }
        return RunResult(label: label, rows: rows, window: window, lag: lag, nominal: nominal, expectedStep: expectedStep,
                         lines: lines)
    }

    // MARK: 用例

    /// 回归（不挂测量门，模拟器也跑）：手指拖着跨过好几行，引擎每跨一行的 wakeup 都不在主线程同步重画（`tick-draw` 0 次）、
    /// 也不 refresh（`tick-refresh` 0 次：同一个位置不多画一帧），display link 全程续着不反复起停，画面照样跟着走。
    /// 补丁 #20：Duo 内屏上那次同步重画要等渲染线程手上那一帧（8.4 ms ≈ 一拍），每跨一行掉一帧；link 按速度停的那一版
    /// 减速尾段帧间隔 8 / 17 ms 交替、屏上速度忽快忽慢。
    func testDragAcrossRowsDoesNotSyncDraw() async throws {
        let ticker = EarlyTicker()
        ticker.start()
        defer { ticker.stop() }
        let size = CGSize(width: 440, height: 700)
        let host = try GhosttyProbeHost(size: size)
        defer { host.close() }
        host.window.removeGestureRecognizer(host.touchWatch)
        try await host.waitUntilReady()
        host.feedAndWait(OnScreen.barcodeHistory(lines: 1000, cols: host.grid.cols))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(host.view.uTermSystemPanWouldBegin, "单指拖动不归系统滚动")
        _ = host.view.surface?.scrollToRow(500)
        try await Task.sleep(for: .milliseconds(300))
        let finger = try SyntheticFinger(window: host.window)
        let rowBefore = host.view.uTermScrollState.row
        UTermScrollTrace.isEnabled = true
        _ = try await drag(feed: .vsync, speed: 150, direction: 1, seconds: 1, startY: 600, x: 220,
                           finger: finger, ticker: ticker)
        let trace = UTermScrollTrace.drain()
        UTermScrollTrace.isEnabled = false
        let rows = trace.filter { $0.kind == "row" }.map(\.value)
        let crossings = zip(rows, rows.dropFirst()).filter { $0 != $1 }.count
        // 只看手指真在动的那一段（第一步到最后一步）：停住（松手前按住的那几帧）之后补的那次同步重画是该有的。
        let dragTimes = trace.filter { $0.kind == "drag" }.map(\.time)
        let moving = (dragTimes.first ?? 0)...(dragTimes.last ?? 0)
        let draws = trace.filter { $0.kind == "tick-draw" && moving.contains($0.time) }.count
        let deferred = trace.filter { $0.kind == "wakeup-deferred" }.count
        let refreshes = trace.filter { $0.kind == "tick-refresh" && moving.contains($0.time) }.count
        let linkStarts = trace.filter { $0.kind == "link-start" && moving.contains($0.time) }.count
        print("SLOWDRAG-REGRESSION crossings=\(crossings) tick-draws=\(draws) (all \(trace.filter { $0.kind == "tick-draw" }.count)) wakeup-deferred=\(deferred) "
            + "tick-refresh=\(refreshes) link-starts=\(linkStarts) tick-app=\(trace.filter { $0.kind == "tick-app" }.count) drags=\(trace.filter { $0.kind == "drag" }.count)")
        XCTAssertGreaterThanOrEqual(crossings, 5, "拖动没跨过几行，量的不是那条路径")
        XCTAssertEqual(draws, 0, "手指拖着时引擎的 wakeup 在主线程同步重画了")
        XCTAssertEqual(refreshes, 0, "手指拖着时引擎的 wakeup 还在 refresh（同一个位置多画一帧）")
        // 默认做法（hold）：每次 didScroll 把 display link 续上，不按速度停；拖动中途不该反复起停，也不走推迟那条路。
        XCTAssertLessThanOrEqual(linkStarts, 1, "拖动中途 display link 反复起停")
        XCTAssertEqual(deferred, 0, "默认做法不该再推迟 wakeup 的 tick")
        XCTAssertGreaterThan(host.view.uTermScrollState.row, rowBefore + 4, "视口没跟着手指走")
        // 停下之后 wakeup 照旧同步重画：喂一行输出（滚动条变了 → wakeup），等着看 tick-draw。
        try await Task.sleep(for: .milliseconds(800))
        UTermScrollTrace.isEnabled = true
        host.feedAndWait("tail\r\n")
        let deadline = CACurrentMediaTime() + 1
        var restDraws = 0
        while CACurrentMediaTime() < deadline, restDraws == 0 {
            try await Task.sleep(for: .milliseconds(50))
            restDraws += UTermScrollTrace.drain().filter { $0.kind == "tick-draw" }.count
        }
        UTermScrollTrace.isEnabled = false
        XCTAssertGreaterThan(restDraws, 0, "停下之后引擎的 wakeup 不再同步重画了（只该在系统滚动动着时跳过）")
    }

    /// 回归（不挂测量门，模拟器也跑）：引擎补丁（上游的 0023） 的端到端——带编号地滚一步，带着这一步的那一帧交到图层的记号要在
    /// 合理的时间里立起来（真机上一两毫秒，模拟器慢得多，这里只核「等得到」），视口确实挪了这么多。
    /// 记号立不起来的话，iOS 的系统滚动每一帧都白等到超时。
    func testTrackedScrollReportsItsFrame() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 700))
        defer { host.close() }
        host.window.removeGestureRecognizer(host.touchWatch)
        try await host.waitUntilReady()
        host.feedAndWait(OnScreen.barcodeHistory(lines: 400, cols: host.grid.cols))
        try await Task.sleep(for: .milliseconds(400))
        _ = host.view.surface?.scrollToRow(200)
        try await Task.sleep(for: .milliseconds(300))
        let before = host.view.uTermScrollState
        var delays: [Double] = []
        for _ in 0..<5 {
            let delay = try XCTUnwrap(host.view.uTermTrackedScrollPresentDelay(pixels: 3, timeout: 2),
                                      "带编号的滚动之后，那一帧交到图层的记号 2 s 都没立起来")
            delays.append(delay)
            try await Task.sleep(for: .milliseconds(50))
        }
        let after = host.view.uTermScrollState
        let cell = try XCTUnwrap(host.view.uTermCellPixels).height
        let moved = Double(after.row - before.row) * Double(cell) + (after.fraction - before.fraction)
        print("TRACKED-SCROLL delays-ms=\(delays.map { String(format: "%.2f", $0 * 1000) }) moved=\(moved)")
        XCTAssertEqual(abs(moved), 15, accuracy: 0.5, "带编号的滚动没把视口挪 5 × 3 像素")
    }

    /// 回归（不挂测量门）：静止时，系统滚动「忙」的标志卡住（这里是 contentOffset 越界停着：UIKit 不会自己弹回，
    /// 终端也不在忙的时候对齐），引擎的 wakeup 不能因此被推迟——照常同步重画、不留 50 ms 一次的轮询。
    /// 补丁 #20 第一版按 `systemScrollIsBusy` 推迟，这种状态下每个 wakeup 都不同步重画、轮询一直跑。
    func testStuckBusyStateDoesNotDeferWakeupsAtRest() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 700))
        defer { host.close() }
        host.window.removeGestureRecognizer(host.touchWatch)
        try await host.waitUntilReady()
        host.feedAndWait(OnScreen.barcodeHistory(lines: 400, cols: host.grid.cols))
        try await Task.sleep(for: .milliseconds(400))
        let scrollView = try XCTUnwrap(host.view.uTermSystemScrollView)
        // 越界停着，最后一步很慢（速度远低于 `wakeupDisplayLinkMinimumSpeed`）。
        scrollView.contentOffset.y = -40
        try await Task.sleep(for: .milliseconds(40))
        scrollView.contentOffset.y = -39.9
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertLessThan(scrollView.contentOffset.y, 0, "前提：越界停着")
        UTermScrollTrace.isEnabled = true
        // 程序改标题（OSC 0）：走 app 邮箱 → wakeup，不改回滚的长度（改了 contentSize 的话 UIKit 自己把越界的 contentOffset
        // 拉回范围里，卡住的状态就自己好了）。
        for line in 0..<5 {
            host.feedAndWait("\u{1B}]0;soak \(line)\u{07}")
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(1500))
        let trace = UTermScrollTrace.drain()
        func count(_ kind: String, _ events: [UTermScrollTrace.Event]) -> Int { events.filter { $0.kind == kind }.count }
        // 再静置 1 s：不该还有轮询。
        try await Task.sleep(for: .milliseconds(1000))
        let later = UTermScrollTrace.drain()
        UTermScrollTrace.isEnabled = false
        print("SLOWDRAG-STUCK offset=\(scrollView.contentOffset.y) wakeups=\(count("wakeup-tick", trace)) "
            + "deferred=\(count("wakeup-deferred", trace)) polls=\(count("wakeup-poll", trace)) tick-draws=\(count("tick-draw", trace)) "
            + "link-starts=\(count("link-start", trace)) later-polls=\(count("wakeup-poll", later))")
        XCTAssertGreaterThan(count("wakeup-tick", trace), 0, "前提：改标题触发了 wakeup")
        XCTAssertLessThan(scrollView.contentOffset.y, 0, "前提：全程越界停着")
        XCTAssertEqual(count("wakeup-deferred", trace), 0, "静止时 wakeup 被推迟了（越界停着被当成在滚）")
        XCTAssertGreaterThan(count("tick-draw", trace), 0, "静止时 wakeup 没同步重画")
        XCTAssertEqual(count("wakeup-poll", later), 0, "静止 1.5 s 之后推迟的轮询还在跑")
    }

    func testSlowDragFrames() async throws {
        guard Self.env["UTERM_MEASURE"] == "1" else {
            throw XCTSkip("测量门探针：设 UTERM_MEASURE=1 才跑（真机、单独跑）")
        }
        // 先开发手指事件的 link，再建宿主（它的 link 排在后面）。
        let ticker = EarlyTicker()
        ticker.start()
        defer { ticker.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = scene.screen.bounds.size
        let host = try GhosttyProbeHost(size: size)
        defer { host.close() }
        // 合成的触摸会被它当成有人碰了真机。
        host.window.removeGestureRecognizer(host.touchWatch)
        try await host.waitUntilReady()
        host.feedAndWait(OnScreen.barcodeHistory(lines: Self.historyLines, cols: host.grid.cols))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(host.view.uTermSystemPanWouldBegin, "单指拖动不归系统滚动：量的不是那条路径")
        let cell = try XCTUnwrap(host.view.uTermCellPixels)
        let layer = try XCTUnwrap(OnScreen.surfaceLayer(in: host.view.layer), "找不到 IOSurfaceLayer")
        let finger = try SyntheticFinger(window: host.window)
        let screen = host.window.screen
        let meta = String(format: "SLOWDRAG-META variant=%@ device=%@ system=%@ window=%.0fx%.0fpt scale=%.3f native=%.3f "
            + "max-fps=%d cell=%.0fx%.0fpx grid=%dx%d decode=%@ engine=%@",
            Self.variant, UIDevice.current.name, UIDevice.current.systemVersion, size.width, size.height,
            screen.scale, screen.nativeScale, screen.maximumFramesPerSecond, cell.width, cell.height,
            host.grid.cols, host.grid.rows, Self.decodes ? "on" : "off", TerminalEngineVersion.current)
        print(meta)

        var csv = "variant,feed,speed,dir,rep,frame,t_ms,interval_ms,moves,finger_pt,drags,sent_px,shown_px,shown_pos,"
            + "expected_pos,resid_px,row_cross,tick_draws,tick_draw_ms,tick_app_ms,tick_refresh_ms,wakeups,wakeup_ms,"
            + "presents_main,presents_off,busy_ms,decode_ms,draw_before_move,in_window,flags\n"
        var summary: [String] = [meta]
        var aggregate: [String: [(RunResult, Int)]] = [:]
        func number(_ v: Double, _ f: String = "%.3f") -> String { v.isFinite ? String(format: f, v) : "nan" }

        // 预热：起 link、编管线。
        _ = try await drag(feed: .vsync, speed: 200, direction: 1, seconds: 0.4, startY: size.height * 0.7,
                           x: size.width / 2, finger: finger, ticker: ticker)
        try await Task.sleep(for: .milliseconds(600))

        for policy in Self.policies {
        UTermScrollTrace.scrollWakeupSyncDraw = policy
        let variant = Self.policies.count > 1 || policy != UTermScrollTrace.defaultScrollWakeupSyncDraw
            ? "\(Self.variant)-\(policy.rawValue)" : Self.variant
        for feed in Self.feeds {
            for speed in Self.speeds {
                for rep in 0..<Self.runs {
                    for direction in [1.0, -1.0] {
                        // 回滚中间，行内的小数错开一点。
                        _ = host.view.surface?.scrollToRow(UInt(1500 + rep * 41 + (direction > 0 ? 0 : 17)))
                        try await Task.sleep(for: .milliseconds(350))
                        // 行程不超过屏高的 0.7。
                        let seconds = max(0.6, min(Self.seconds, Double(size.height) * 0.7 / speed - Self.leadIn))
                        let startY = direction > 0 ? size.height * 0.85 : size.height * 0.15

                        var decoder = OnScreen.BarcodeDecoder(cell: cell)
                        var decodeSpans: [(Double, Double)] = []
                        let sampler = OnScreen.CommitSampler()
                        if Self.decodes {
                            sampler.read = {
                                let t0 = CACurrentMediaTime()
                                let value = decoder.position(of: layer)
                                decodeSpans.append((t0, (CACurrentMediaTime() - t0) * 1000))
                                return value
                            }
                        }
                        let clock = Clock()
                        UTermScrollTrace.isEnabled = true
                        GhosttyPresentLog.reset()
                        sampler.start()
                        clock.start()
                        let (moves, dragEnd) = try await drag(feed: feed, speed: speed, direction: direction, seconds: seconds,
                                                              startY: startY, x: size.width / 2, finger: finger, ticker: ticker)
                        try await Task.sleep(for: .milliseconds(150))
                        clock.stop()
                        sampler.stop()
                        let trace = UTermScrollTrace.drain()
                        UTermScrollTrace.isEnabled = false
                        let presents = GhosttyPresentLog.readThreads()
                        let label = "\(variant) feed=\(feed.rawValue) v=\(Int(speed)) dir=\(direction > 0 ? "up" : "down") rep=\(rep)"
                        guard let result = analyze(label: label, targets: sampler.targets, moves: moves, dragEnd: dragEnd,
                                                   direction: direction, trace: trace, samples: sampler.samples,
                                                   decodeSpans: decodeSpans, presents: presents, clock: clock) else {
                            XCTFail("\(label)：没量到拖动（targets=\(sampler.targets.count) moves=\(moves.count) "
                                + "drags=\(trace.filter { $0.kind == "drag" }.count)）")
                            continue
                        }
                        for line in result.lines { print(line) }
                        summary += result.lines
                        aggregate["\(variant) \(feed.rawValue) v=\(Int(speed))", default: []].append((result, rep))
                        let origin = result.rows[result.window.lowerBound].target
                        for r in result.rows where r.index >= result.window.lowerBound - 15 && r.index <= result.window.upperBound + 15 {
                            csv += "\(variant),\(feed.rawValue),\(Int(speed)),\(direction > 0 ? "up" : "down"),\(rep),\(r.index),"
                                + "\(number((r.target - origin) * 1000)),\(number(r.interval * 1000)),\(r.moves),\(number(r.finger)),"
                                + "\(r.drags),\(number(r.sent)),\(number(r.shown, "%.0f")),\(number(r.shownPos, "%.0f")),"
                                + "\(number(r.expectedPos)),\(number(r.resid)),\(r.rowCross),\(r.tickDraws),\(number(r.tickDrawMS)),"
                                + "\(number(r.tickAppMS)),\(number(r.tickRefreshMS)),\(r.wakeups),\(number(r.wakeupMS)),"
                                + "\(r.presentsMain),\(r.presentsOff),\(number(r.busyMS)),\(number(r.decodeMS)),"
                                + "\(r.drawBeforeMove ? 1 : 0),\(result.window.contains(r.index) ? 1 : 0),\(r.flags.joined(separator: "|"))\n"
                        }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
        }
        }
        UTermScrollTrace.scrollWakeupSyncDraw = UTermScrollTrace.defaultScrollWakeupSyncDraw

        // 每个速度合起来：每类事件的数量（每 100 帧）、旁边有跨行 / 同步重画的比例。
        for key in aggregate.keys.sorted(by: { a, b in
            let pa = a.components(separatedBy: " v="), pb = b.components(separatedBy: " v=")
            return (pa[0], Double(pa.last ?? "0") ?? 0) < (pb[0], Double(pb.last ?? "0") ?? 0)
        }) {
            let runs = aggregate[key] ?? []
            var frames = 0, crossings = 0, draws = 0, presentsMain = 0, presentsOff = 0
            var byKind: [String: (n: Int, cross: Int, draw: Int)] = [:]
            var baseCross = 0, baseDraw = 0
            var steps: [Double] = []
            var lags: [Int] = []
            for (result, _) in runs {
                let rows = result.rows
                lags.append(result.lag)
                steps.append(result.expectedStep)
                func near(_ i: Int, _ key: KeyPath<FrameRow, Int>) -> Bool {
                    (max(0, i - result.lag - 1)...i).contains { rows[$0][keyPath: key] > 0 }
                }
                for i in result.window {
                    frames += 1
                    crossings += rows[i].rowCross
                    draws += rows[i].tickDraws
                    presentsMain += rows[i].presentsMain
                    presentsOff += rows[i].presentsOff
                    let c = near(i, \.rowCross), d = near(i, \.tickDraws)
                    if c { baseCross += 1 }
                    if d { baseDraw += 1 }
                    for kind in rows[i].flags {
                        var entry = byKind[kind] ?? (0, 0, 0)
                        entry.n += 1
                        if c { entry.cross += 1 }
                        if d { entry.draw += 1 }
                        byKind[kind] = entry
                    }
                }
            }
            func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }
            let kinds = Self.flagKinds.map { kind -> String in
                let e = byKind[kind] ?? (0, 0, 0)
                return "\(kind)=\(e.n)(\(pct(e.n, frames)) cross=\(pct(e.cross, e.n)) draw=\(pct(e.draw, e.n)))"
            }
            let line = String(format: "SLOWDRAG-SUM %@ runs=%d frames=%d step=%.2fpx lags=%@ crossings=%d tick-draws=%d "
                + "presents main=%d off=%d base cross=%@ draw=%@ | %@",
                key, runs.count, frames, steps.reduce(0, +) / Double(max(1, steps.count)),
                lags.map(String.init).joined(separator: "/"), crossings, draws, presentsMain, presentsOff,
                pct(baseCross, frames), pct(baseDraw, frames), kinds.joined(separator: " "))
            print(line)
            summary.append(line)
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slowdrag")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = Self.decodes ? "" : "-nodecode"
        for (name, text) in [("ios-slowdrag-\(Self.variant)\(suffix).csv", csv),
                             ("ios-slowdrag-\(Self.variant)\(suffix)-summary.txt", summary.joined(separator: "\n"))] {
            let url = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            print("SLOWDRAG wrote \(url.path)")
            let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
