import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// 滚动手感基准：松手前后「画面上的位置」逐帧的轨迹，写成 CSV 给分析脚本画图、和别的终端比、改补丁 #18 时前后对照。
///
/// 默认跳过；`TEST_RUNNER_UTERM_SCROLLBENCH_DIR=<目录>` 打开（xcodebuild 把 `TEST_RUNNER_` 前缀去掉传给测试进程）。
/// - `testTerminal`：真的 Ghostty 终端 + 系统滚动那个借来的 UIScrollView，写 `ios-<变体>.csv`，
///   变体名取 `TEST_RUNNER_UTERM_SCROLLBENCH_VARIANT`（默认 `patched`，量没有补丁 #18 的代码时写 `baseline`）。
/// - `testReference`：同样大小、同样内容高度、同样起点的普通 UIScrollView（`.normal` 减速、不改落点），
///   同一根合成手指，写 `ios-reference.csv`：iOS 自己的样子。
/// - 每份 CSV 旁边的 `ios-sidecar/` 里另有 `ios-<变体>-meta.json`（设备、缩放、格高、实测帧率）与 `-summary.txt`（每轮一行）。
/// - `TEST_RUNNER_UTERM_SCROLLBENCH_RUNS`（默认 8）、`TEST_RUNNER_UTERM_SCROLLBENCH_SCENARIOS`（逗号分隔，默认全部）。
///
/// CSV 的列与场景见 `docs` 之外的那份 SPEC（表头 `platform,variant,scenario,run,t_ms,kind,…`）：
/// - `t_ms` 相对第一次抬手；`touch` 行是合成触摸发出的那一刻，`frame` 行每个显示帧一行。
/// - `frame` 行取的是这一帧主线程上所有活干完之后的状态（runloop 睡下去之前那一刻的快照，下一拍时落成上一帧的一行，
///   时间记那一帧的 `targetTimestamp`）。不在 display link 回调里当场读：UIKit 自己的减速 / 我们的对齐动画和这里的回调
///   谁先谁后不定，当场读会一帧早一帧晚，逐帧速度就成了锯齿。同理没有把 contentOffset 的 KVO 每次变动各记一行。
/// - `display_pt` = 引擎视口的位置（`uTermScrollState` 的行 × 格高 + 小数，换成点）再加上橡皮筋的平移
///   （`overscrollPixels`，画面层按它平移，回弹时用户看到的就是这个），和参照组的 contentOffset 同一个量纲。
///
/// 跑法（模拟器；先 `build-for-testing` 一次，之后改了实现再编一次即可）：
///
///     TEST_RUNNER_UTERM_SCROLLBENCH_DIR=<目录> TEST_RUNNER_UTERM_SCROLLBENCH_VARIANT=patched \
///     xcodebuild test-without-building -project uTerm.xcodeproj -scheme uTermMobile -configuration Debug \
///       -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build/DerivedData -enableCodeCoverage NO \
///       -only-testing:uTermMobileTests/GhosttyScrollBenchTests/testTerminal
///
/// 手指：`SyntheticFinger`（真的 `UITouch` + HID 事件，UIKit 自己算拖动速度、减速、回弹），每个显示帧一个 moved。
/// 偶数轮手指往上（内容偏移变大 = 往底部），奇数轮往下。
@MainActor
final class GhosttyScrollBenchTests: XCTestCase {
    private static let env = ProcessInfo.processInfo.environment
    private static var outputDirectory: String? { env["UTERM_SCROLLBENCH_DIR"].flatMap { $0.isEmpty ? nil : $0 } }
    private static var runs: Int { env["UTERM_SCROLLBENCH_RUNS"].flatMap(Int.init) ?? 8 }
    private static var scenarioFilter: Set<String>? {
        env["UTERM_SCROLLBENCH_SCENARIOS"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }
    }

    private static let windowSize = CGSize(width: 440, height: 700)
    private static let historyLines = 3000
    private static let fingerX: CGFloat = 220

    override func setUp() async throws {
        guard Self.outputDirectory != nil else {
            throw XCTSkip("滚动基准默认跳过：TEST_RUNNER_UTERM_SCROLLBENCH_DIR=<目录> 打开")
        }
        UIApplication.shared.isIdleTimerDisabled = true
        let deadline = CACurrentMediaTime() + 10
        while CACurrentMediaTime() < deadline,
              !UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: 场景

    /// 手指脚本的一段。`frames` 按显示帧数算（60 / 120 Hz 下时长一样）。
    enum Step {
        /// 手指不在屏上，什么都不发（开头的空帧、松手后的等待）。`seconds` 从这一段开始算。
        case idle(seconds: Double)
        /// 按下（占一帧）。
        case down
        /// 每帧一个 moved，`speed` pt/s（正 = 手指往上，内容偏移变大）。
        case move(speed: Double, seconds: Double)
        /// 每帧一个位置不变的 moved（手指按住不动，UIKit 的拖动速度跟着落到 0）。
        case hold(seconds: Double)
        /// 按着不发任何事件（接住滑行时手指静静按着）。
        case still(seconds: Double)
        /// 抬手（不占帧：和上一段最后一帧同一拍发出，「动着松手」就是这样）。
        case lift
    }

    struct Scenario {
        let id: String
        /// 起点离一端只有几行（`edge-bounce`），否则在回滚中间。
        let nearEnd: Bool
        /// 方向 +1 / -1 下的脚本。
        let script: (_ direction: Double) -> [Step]
    }

    static let scenarios: [Scenario] = [
        Scenario(id: "slow-release", nearEnd: false) { d in [.down, .move(speed: 150 * d, seconds: 0.25), .lift] },
        Scenario(id: "hold-release", nearEnd: false) { d in
            [.down, .move(speed: 400 * d, seconds: 0.2), .hold(seconds: 0.15), .lift]
        },
        Scenario(id: "medium-flick", nearEnd: false) { d in [.down, .move(speed: 700 * d, seconds: 0.12), .lift] },
        Scenario(id: "fast-flick", nearEnd: false) { d in [.down, .move(speed: 2500 * d, seconds: 0.1), .lift] },
        Scenario(id: "catch", nearEnd: false) { d in
            [.down, .move(speed: 1500 * d, seconds: 0.1), .lift, .idle(seconds: 0.25), .down, .still(seconds: 0.1 - 1.0 / 60), .lift]
        },
        Scenario(id: "edge-bounce", nearEnd: true) { d in [.down, .move(speed: 900 * d, seconds: 0.12), .lift] },
    ]

    /// 这一轮的起点：回滚中间（行号也错开一点）或离一端 3 行多，行内的小数按黄金分割错开。
    struct Start {
        let row: UInt
        /// 行内位置，0..<1 行。
        let fraction: Double
    }

    static func start(for scenario: Scenario, run: Int, maxRow: Int) -> Start {
        let fraction = (0.13 + Double(run) * 0.618_034).truncatingRemainder(dividingBy: 1)
        let direction = run % 2 == 0 ? 1 : -1
        guard scenario.nearEnd else { return Start(row: UInt(1200 + run * 37), fraction: fraction) }
        // 往底部甩的从底下数 3 + f 行起，往顶部甩的从顶上数 3 + f 行起。
        if direction > 0 { return Start(row: UInt(maxRow - 4), fraction: 1 - fraction) }
        return Start(row: 3, fraction: fraction)
    }

    // MARK: 被测对象

    /// 一次采样读到的：内容偏移（点）、画面位置（点）、还在不在动。
    struct Sample { let offset: Double; let display: Double; let moving: Bool }

    /// 被测的一方：终端或者普通的 UIScrollView。
    struct Subject {
        let scrollView: UIScrollView
        let read: @MainActor () -> Sample
        let cellPoints: Double
        /// 停到这一轮的起点。
        let park: @MainActor (Start) async throws -> Void
    }

    // MARK: 记录

    struct Row {
        let time: Double
        let kind: String
        let finger: Double?
        let offset: Double
        let display: Double
    }

    /// 每帧一行：runloop 每次睡下去之前存一份快照，下一个显示帧到来时把它落成上一帧的一行。
    @MainActor
    final class FrameRecorder {
        private let read: @MainActor () -> Sample
        private var observer: CFRunLoopObserver?
        private var pending: Sample?
        private var frameTime: Double?
        private(set) var rows: [Row] = []
        private(set) var intervals: [Double] = []
        private var lastTimestamp: Double?

        init(read: @escaping @MainActor () -> Sample) {
            self.read = read
        }

        func start() {
            pending = read()
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              true, CFIndex.max) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.snapshot() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        func stop() {
            if let observer { CFRunLoopObserverInvalidate(observer) }
            observer = nil
        }

        private func snapshot() { pending = read() }

        /// 显示帧到了：上一帧的快照落成一行。返回上一帧的快照（判断停没停用）。
        @discardableResult
        func tick(_ link: CADisplayLink) -> Sample? {
            if let last = lastTimestamp { intervals.append(link.timestamp - last) }
            lastTimestamp = link.timestamp
            var emitted: Sample?
            if let frameTime, let pending {
                rows.append(Row(time: frameTime, kind: "frame", finger: nil, offset: pending.offset, display: pending.display))
                emitted = pending
            }
            frameTime = link.targetTimestamp
            return emitted
        }

        func touch(finger: CGFloat) {
            let now = read()
            rows.append(Row(time: CACurrentMediaTime(), kind: "touch", finger: Double(finger), offset: now.offset, display: now.display))
        }
    }

    /// 夹在滚动视图的代理前面，记下松手那一刻拖动手势的速度和 UIKit 给的速度，原样转给原来的代理。
    @MainActor
    final class ReleaseTap: NSObject, UIScrollViewDelegate {
        weak var inner: (any UIScrollViewDelegate)?
        /// 拖动手势在松手时的速度（pt/s，正 = 内容偏移变大）。
        var panVelocity: Double?
        /// `willEndDragging` 的速度换成 pt/s。
        var uikitVelocity: Double?

        init(_ scrollView: UIScrollView) {
            inner = scrollView.delegate
            super.init()
            scrollView.delegate = self
        }

        func reset() { panVelocity = nil; uikitVelocity = nil }

        func scrollViewDidScroll(_ s: UIScrollView) { inner?.scrollViewDidScroll?(s) }
        func scrollViewWillBeginDragging(_ s: UIScrollView) { inner?.scrollViewWillBeginDragging?(s) }
        func scrollViewWillEndDragging(_ s: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            // 只记第一次松手（接住滑行那一下不拖动，不会到这里）。
            if panVelocity == nil {
                panVelocity = -Double(s.panGestureRecognizer.velocity(in: s).y)
                uikitVelocity = Double(velocity.y) * 1000
            }
            inner?.scrollViewWillEndDragging?(s, withVelocity: velocity, targetContentOffset: targetContentOffset)
        }
        func scrollViewDidEndDragging(_ s: UIScrollView, willDecelerate decelerate: Bool) {
            inner?.scrollViewDidEndDragging?(s, willDecelerate: decelerate)
        }
        func scrollViewWillBeginDecelerating(_ s: UIScrollView) { inner?.scrollViewWillBeginDecelerating?(s) }
        func scrollViewDidEndDecelerating(_ s: UIScrollView) { inner?.scrollViewDidEndDecelerating?(s) }
        func scrollViewDidEndScrollingAnimation(_ s: UIScrollView) { inner?.scrollViewDidEndScrollingAnimation?(s) }
    }

    /// 一轮的结果。
    struct RunTrace {
        let scenario: String
        let run: Int
        let liftTime: Double
        let rows: [Row]
        let panVelocity: Double?
        let uikitVelocity: Double?
        let targetSpeed: Double
        let startOffset: Double
        let restedAfter: Double?
    }

    /// 按脚本驱动手指，逐帧记录，直到停住 600 ms（最多抬手后 5 s）。
    static func perform(_ scenario: Scenario, run: Int, subject: Subject, finger: SyntheticFinger,
                        tap: ReleaseTap) async throws -> (RunTrace, [Double]) {
        let direction: Double = run % 2 == 0 ? 1 : -1
        let script = scenario.script(direction)
        // 抬手前不够 300 ms 的，前面补空帧。
        var preLift = 0.0
        for step in script {
            if case .lift = step { break }
            switch step {
            case .down: preLift += 1.0 / 60
            case let .move(_, s), let .hold(s), let .still(s), let .idle(s): preLift += s
            case .lift: break
            }
        }
        let steps = [Step.idle(seconds: max(0.1, 0.34 - preLift))] + script
        let startY: CGFloat = direction > 0 ? 520 : 180
        let targetSpeed = script.compactMap { step -> Double? in
            if case let .move(speed, _) = step { return speed }
            return nil
        }.first ?? 0

        tap.reset()
        let recorder = FrameRecorder(read: subject.read)
        let startOffset = Double(subject.scrollView.contentOffset.y)
        recorder.start()
        defer { recorder.stop() }

        var index = 0
        var phaseStart: Double?
        var phaseFrames = 0
        var fingerY = startY
        var fingerDown = false
        var liftTime: Double?
        var lastTarget = 0.0
        var lastDisplay: Double?
        var lastMotion = 0.0
        var restedAt: Double?
        var failure: Error?

        let ticker = FrameTicker()
        await ticker.run { link in
            let previous = recorder.tick(link)
            let now = CACurrentMediaTime()
            let dt = lastTarget == 0 ? link.duration : link.targetTimestamp - lastTarget
            lastTarget = link.targetTimestamp
            let fps = 1 / max(link.duration, 1.0 / 240)
            do {
                // 每拍从当前段往下走：占帧的段做完这一拍就停，不占帧的（抬手）接着做。
                var consumed = false
                while index < steps.count, !consumed {
                    if phaseStart == nil { phaseStart = now; phaseFrames = 0 }
                    let elapsed = now - (phaseStart ?? now)
                    func frames(_ seconds: Double) -> Int { max(1, Int((seconds * fps).rounded())) }
                    switch steps[index] {
                    case let .idle(seconds), let .still(seconds):
                        if elapsed + 0.5 / fps >= seconds { index += 1; phaseStart = nil; continue }
                        consumed = true
                    case .down:
                        fingerY = startY
                        try finger.down(at: CGPoint(x: fingerX, y: fingerY))
                        fingerDown = true
                        recorder.touch(finger: fingerY)
                        index += 1; phaseStart = nil
                        consumed = true
                    case let .move(speed, seconds):
                        fingerY -= CGFloat(speed * dt)
                        try finger.move(to: CGPoint(x: fingerX, y: fingerY))
                        recorder.touch(finger: fingerY)
                        phaseFrames += 1
                        if phaseFrames >= frames(seconds) { index += 1; phaseStart = nil }
                        consumed = true
                    case let .hold(seconds):
                        try finger.hold()
                        recorder.touch(finger: fingerY)
                        phaseFrames += 1
                        if phaseFrames >= frames(seconds) { index += 1; phaseStart = nil }
                        consumed = true
                    case .lift:
                        try finger.up()
                        fingerDown = false
                        recorder.touch(finger: fingerY)
                        if liftTime == nil { liftTime = CACurrentMediaTime() }
                        index += 1; phaseStart = nil
                    }
                }
            } catch {
                failure = error
                return false
            }
            guard let liftTime else { return true }
            // 脚本走完以后等它停：位置不再变、也不在减速 / 回弹 / 对齐，满 600 ms。
            if let previous {
                if let lastDisplay, abs(previous.display - lastDisplay) > 0.001 { lastMotion = now }
                if previous.moving { lastMotion = now }
                lastDisplay = previous.display
            }
            if index < steps.count || fingerDown { lastMotion = now; return true }
            if lastMotion == 0 { lastMotion = now }
            if restedAt == nil, now - lastMotion >= 0.6 { restedAt = lastMotion }
            if restedAt != nil { return false }
            return now - liftTime < 5
        }
        if let failure { throw failure }
        let lift = try XCTUnwrap(liftTime, "\(scenario.id) 第 \(run) 轮没有抬手")
        // 抬手前只留 300 ms；按时间排好（帧行是下一拍才落下的，记的是上一帧的时刻）。
        let rows = recorder.rows.filter { $0.time - lift >= -0.3 }.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        let trace = RunTrace(scenario: scenario.id, run: run, liftTime: lift, rows: rows, panVelocity: tap.panVelocity,
                             uikitVelocity: tap.uikitVelocity, targetSpeed: targetSpeed, startOffset: startOffset,
                             restedAfter: restedAt.map { $0 - lift })
        return (trace, recorder.intervals)
    }

    // MARK: 终端

    /// 和别的系统滚动探针同一个宿主（11 pt 字号），回滚 3000 行。
    private func terminalRig() async throws -> (GhosttyProbeHost, UIScrollView, Double, Int) {
        let host = try GhosttyProbeHost(size: Self.windowSize)
        // 合成的触摸会被它当成有人碰了真机。
        host.window.removeGestureRecognizer(host.touchWatch)
        try await host.waitUntilReady()
        host.feedAndWait(GhosttyOnScreenScrollTests.barcodeHistory(lines: Self.historyLines, cols: host.grid.cols))
        try await Task.sleep(for: .milliseconds(400))
        let scrollView = try XCTUnwrap(host.view.uTermSystemScrollView)
        XCTAssertTrue(host.view.uTermSystemPanWouldBegin, "单指拖动不归系统滚动：基准量的不是那条路径")
        let cell = try XCTUnwrap(host.view.uTermCellPixels)
        let scale = Double(host.window.screen.scale)
        // 最底下那一行：滚到底读引擎的行号。
        _ = host.view.surface?.scrollToRow(UInt(Self.historyLines * 2))
        try await Task.sleep(for: .milliseconds(300))
        let maxRow = host.view.uTermScrollState.row
        XCTAssertGreaterThan(maxRow, 2000, "回滚不够长")
        return (host, scrollView, Double(cell.height) / scale, maxRow)
    }

    private static func park(_ host: GhosttyProbeHost, _ start: Start, cellPoints: Double) async throws {
        _ = host.view.surface?.scrollToRow(start.row)
        try await Task.sleep(for: .milliseconds(300))
        if start.fraction > 0, let scrollView = host.view.uTermSystemScrollView {
            scrollView.contentOffset.y += CGFloat(start.fraction * cellPoints)
            try await Task.sleep(for: .milliseconds(80))
        }
    }

    func testTerminal() async throws {
        let variant = Self.env["UTERM_SCROLLBENCH_VARIANT"].flatMap { $0.isEmpty ? nil : $0 } ?? "patched"
        let (host, scrollView, cellPoints, maxRow) = try await terminalRig()
        defer { host.close() }
        let scale = Double(host.window.screen.scale)
        let finger = try SyntheticFinger(window: host.window)
        let tap = ReleaseTap(scrollView)
        defer { scrollView.delegate = tap.inner }
        let view = host.view
        let subject = Subject(scrollView: scrollView, read: {
            let state = view.uTermScrollState
            let cellPx = cellPoints * scale
            let display = (Double(state.row) * cellPx + state.fraction - state.overscrollPixels) / scale
            let moving = state.isGliding || state.isBouncing || scrollView.isDragging || scrollView.isDecelerating
            return Sample(offset: Double(scrollView.contentOffset.y), display: display, moving: moving)
        }, cellPoints: cellPoints, park: { start in try await Self.park(host, start, cellPoints: cellPoints) })
        try await bench(variant: variant, subject: subject, finger: finger, tap: tap, maxRow: maxRow, scale: scale,
                        extra: ["grid_cols": "\(host.grid.cols)", "grid_rows": "\(host.grid.rows)",
                                "cell_px": String(format: "%.0f", cellPoints * scale)])
    }

    // MARK: 参照：普通的 UIScrollView

    func testReference() async throws {
        let (host, terminalScroll, cellPoints, maxRow) = try await terminalRig()
        defer { host.close() }
        let scale = Double(host.window.screen.scale)
        // 起点先在终端上停一遍读出来，参照组用一样的内容偏移。
        var starts: [String: CGFloat] = [:]
        for scenario in Self.scenarios where Self.scenarioFilter?.contains(scenario.id) ?? true {
            for run in 0 ..< Self.runs {
                try await Self.park(host, Self.start(for: scenario, run: run, maxRow: maxRow), cellPoints: cellPoints)
                starts["\(scenario.id)#\(run)"] = terminalScroll.contentOffset.y
            }
        }
        let frame = terminalScroll.convert(terminalScroll.bounds, to: host.window)
        let contentSize = terminalScroll.contentSize
        host.view.isHidden = true

        let scrollView = UIScrollView(frame: CGRect(origin: frame.origin, size: terminalScroll.bounds.size))
        scrollView.contentSize = contentSize
        scrollView.decelerationRate = .normal
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .darkGray
        host.window.addSubview(scrollView)
        defer { scrollView.removeFromSuperview() }
        let plain = PlainDelegate()
        scrollView.delegate = plain
        let tap = ReleaseTap(scrollView)
        let finger = try SyntheticFinger(window: host.window)
        let subject = Subject(scrollView: scrollView, read: {
            let y = Double(scrollView.contentOffset.y)
            return Sample(offset: y, display: y,
                          moving: scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking)
        }, cellPoints: cellPoints, park: { _ in })
        try await bench(variant: "reference", subject: subject, finger: finger, tap: tap, maxRow: maxRow, scale: scale,
                        extra: ["content_height_pt": String(format: "%.3f", contentSize.height),
                                "bounds_height_pt": String(format: "%.3f", scrollView.bounds.height)]) { id, run in
            if let y = starts["\(id)#\(run)"] {
                scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// 参照组的代理什么都不做（UIKit 的默认行为）。
    final class PlainDelegate: NSObject, UIScrollViewDelegate {}

    // MARK: 跑全部场景、写文件

    private func bench(variant: String, subject: Subject, finger: SyntheticFinger, tap: ReleaseTap, maxRow: Int,
                       scale: Double, extra: [String: String],
                       prepare: ((String, Int) async throws -> Void)? = nil) async throws {
        var csv = "platform,variant,scenario,run,t_ms,kind,finger_pt,input_delta_pt,offset_pt,display_pt,cell_pt,release_v_ptps,uikit_v_ptps\n"
        var intervals: [Double] = []
        var summary: [String] = []
        var problems: [String] = []
        func number(_ value: Double?, _ format: String = "%.3f") -> String {
            guard let value, value.isFinite else { return "nan" }
            return String(format: format, value)
        }
        for scenario in Self.scenarios where Self.scenarioFilter?.contains(scenario.id) ?? true {
            for run in 0 ..< Self.runs {
                let start = Self.start(for: scenario, run: run, maxRow: maxRow)
                if let prepare {
                    try await prepare(scenario.id, run)
                } else {
                    try await subject.park(start)
                }
                let (trace, ticks) = try await Self.perform(scenario, run: run, subject: subject, finger: finger, tap: tap)
                intervals += ticks
                let cell = number(subject.cellPoints, "%.4f")
                let release = number(trace.panVelocity, "%.1f")
                let uikit = number(trace.uikitVelocity, "%.1f")
                for row in trace.rows {
                    csv += "ios,\(variant),\(scenario.id),\(run),\(number((row.time - trace.liftTime) * 1000)),\(row.kind),"
                        + "\(number(row.finger)),nan,\(number(row.offset)),\(number(row.display)),\(cell),\(release),\(uikit)\n"
                }
                let frames = trace.rows.filter { $0.kind == "frame" }
                let before = frames.filter { $0.time < trace.liftTime }.count
                let last = frames.last.map { ($0.time - trace.liftTime) * 1000 } ?? .nan
                let line = String(format: "BENCH %@ %@#%d target=%.0f release=%@ uikit=%@ start=%.3f frames=%d(before %d) "
                    + "last=%.0fms rest=%@ final=%.3f", variant, scenario.id, run, trace.targetSpeed, release, uikit,
                    trace.startOffset, frames.count, before, last,
                    trace.restedAfter.map { String(format: "%.0fms", $0 * 1000) } ?? "-", frames.last?.display ?? .nan)
                print(line)
                summary.append(line)
                if before < 8 { problems.append("\(scenario.id)#\(run)：抬手前只有 \(before) 帧") }
                if trace.restedAfter == nil { problems.append("\(scenario.id)#\(run)：5 s 内没停") }
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        let sorted = intervals.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        var meta: [String: Any] = [
            "variant": variant,
            "device": Self.env["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name,
            "model": Self.env["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model,
            "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "screen_scale": scale,
            "native_scale": Double(UIScreen.main.nativeScale),
            "maximum_fps": UIScreen.main.maximumFramesPerSecond,
            "measured_frame_interval_ms": median * 1000,
            "measured_fps": median > 0 ? 1 / median : 0,
            "cell_pt": subject.cellPoints,
            "window_pt": [Double(Self.windowSize.width), Double(Self.windowSize.height)],
            "scroll_bounds_pt": [Double(subject.scrollView.bounds.width), Double(subject.scrollView.bounds.height)],
            "content_height_pt": Double(subject.scrollView.contentSize.height),
            "history_lines": Self.historyLines,
            "max_row": maxRow,
            "runs": Self.runs,
            "engine": TerminalEngineVersion.current,
        ]
        for (key, value) in extra { meta[key] = value }
        let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])

        let name = "ios-\(variant)"
        let files: [(String, Data)] = [("\(name).csv", Data(csv.utf8)), ("ios-sidecar/\(name)-meta.json", metaData),
                                       ("ios-sidecar/\(name)-summary.txt", Data(summary.joined(separator: "\n").utf8))]
        // 模拟器里的测试宿主多半能直接写 Mac 上的目录；写不进去就写进自己的 tmp，再由 `simctl get_app_container` 拷出来。
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scrollbench")
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        for (file, data) in files {
            let local = fallback.appendingPathComponent(file)
            try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: local)
            if let dir = Self.outputDirectory {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url)
                    print("BENCH wrote \(url.path)")
                } catch {
                    print("BENCH 写不进 \(url.path)（\(error.localizedDescription)），在 \(fallback.path)")
                }
            }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: file.hasSuffix(".json") ? "public.json" : "public.plain-text")
            attachment.name = (file as NSString).lastPathComponent
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        print("BENCH meta \(String(decoding: metaData, as: UTF8.self))")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "；"))
    }
}
