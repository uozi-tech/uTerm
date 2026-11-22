import AppKit
import GhosttyTerminal
import QuartzCore
import XCTest
@testable import uTerm

/// 滚动轨迹测量（scroll bench，Mac）：抬手前后画面上的滚动位置每一帧在哪，和同一串事件喂给普通 `NSScrollView` 的对照。
///
/// 默认跳过：要 `TEST_RUNNER_UTERM_SCROLLBENCH_DIR=<目录>` 才跑（xcodebuild 去掉前缀后测试进程读 `UTERM_SCROLLBENCH_DIR`）。
/// 测试宿主带沙盒、写不进那个目录：CSV 先写进宿主的临时目录，日志里打一行 `SCROLLBENCH-FILE <路径>`，再由调用方拷出去
/// （`TEST_RUNNER_UTERM_SCROLLBENCH_VARIANT` 给终端那份的 variant 名，默认 `baseline`）。
///
/// 事件是真的 `NSEvent`（CGEvent 造，带 phase / momentumPhase、精确位移），按 120 Hz 的节拍交给真视图的 `scrollWheel(with:)`；
/// 抬手后的惯性按 AppKit 的样子造：每毫秒衰减到 0.998，慢于 60 pt/s 时结束。位置在每个显示帧（视图的 display link）读：
/// 终端读引擎（`uTermScrollState`：首行 × 格子高 + 小数），对照读 `NSScrollView` 的可视区顶边。
/// 符号：位置变大 = 往活动区（新输出）走；`input_delta_pt` 是事件自己的 `scrollingDeltaY`（正 = 往回滚）。
@MainActor
final class GhosttyMacScrollBenchTests: XCTestCase {
    private static var outputDirectory: String? { ProcessInfo.processInfo.environment["UTERM_SCROLLBENCH_DIR"] }
    private static var variant: String { ProcessInfo.processInfo.environment["UTERM_SCROLLBENCH_VARIANT"] ?? "baseline" }
    private static var runs: Int { Int(ProcessInfo.processInfo.environment["UTERM_SCROLLBENCH_RUNS"] ?? "") ?? 8 }

    // MARK: 场景

    /// 一次合成的输入：事件和它相对抬手的时刻（秒）。
    nonisolated struct Input {
        enum Kind { case precise(phase: Int64, momentum: Int64), wheel }
        var t: Double
        var kind: Kind
        /// 位置的走向上的位移（pt，正 = 往活动区）；交给事件时取反成 `scrollingDeltaY`。
        var travel: Double
    }

    nonisolated struct Scenario {
        var id: String
        var inputs: [Input]
        /// 抬手那一刻的速度（pt/s，位置方向）：抬手前 50 ms 内的手势位移 / 0.05 s。
        var releaseVelocity: Double
    }

    // CGScrollPhase / CGMomentumScrollPhase 的取值。
    nonisolated private static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4, cancelled: Int64 = 8, mayBegin: Int64 = 128
    nonisolated private static let momentumBegin: Int64 = 1, momentumContinue: Int64 = 2, momentumEnd: Int64 = 3
    nonisolated private static let tick = 1.0 / 120

    /// `speed` pt/s 拖 `duration` 秒（`hold` 秒停住不动）再抬手；`momentum`：抬手后按抬手速度起惯性。
    /// `catchAfter`：惯性跑这么久后被一次触碰掐断（mayBegin），按住 0.1 s 不动后抬起（cancelled）。
    /// `startFraction`：第一步多走这么多行（0…1），让抬手落在一行里的不同位置。
    nonisolated static func gesture(id: String, speed: Double, duration: Double, hold: Double = 0, momentum: Bool,
                                    catchAfter: Double? = nil, direction: Double, startFraction: Double,
                                    cellPoints: Double) -> Scenario {
        var inputs: [Input] = []
        let steps = max(1, Int((duration / tick).rounded()))
        let start = -(hold + Double(steps) * tick)
        inputs.append(Input(t: start - tick, kind: .precise(phase: began, momentum: 0), travel: 0))
        for i in 0 ..< steps {
            var d = speed * tick * direction
            if i == 0 { d += startFraction * cellPoints * direction }
            inputs.append(Input(t: start + Double(i) * tick, kind: .precise(phase: changed, momentum: 0), travel: d))
        }
        inputs.append(Input(t: 0, kind: .precise(phase: ended, momentum: 0), travel: 0))
        let window = inputs.filter { $0.t >= -0.05 && $0.t < 0 }.reduce(0) { $0 + $1.travel }
        let releaseVelocity = hold > 0 ? 0 : window / 0.05
        if momentum {
            var t = tick
            var v = speed
            var first = true
            while v >= 60 {
                if let catchAfter, t >= catchAfter { break }
                inputs.append(Input(t: t, kind: .precise(phase: 0, momentum: first ? momentumBegin : momentumContinue),
                                    travel: v * tick * direction))
                first = false
                t += tick
                v = speed * pow(0.998, t * 1000)
            }
            inputs.append(Input(t: t, kind: .precise(phase: 0, momentum: momentumEnd), travel: 0))
            if catchAfter != nil {
                inputs.append(Input(t: t, kind: .precise(phase: mayBegin, momentum: 0), travel: 0))
                inputs.append(Input(t: t + 0.1, kind: .precise(phase: cancelled, momentum: 0), travel: 0))
            }
        }
        return Scenario(id: id, inputs: inputs, releaseVelocity: releaseVelocity)
    }

    /// 本场景第 `run` 次的输入。偶数次位置变大（往活动区），奇数次变小。
    nonisolated static func scenario(_ id: String, run: Int, cellPoints: Double) -> Scenario {
        let direction: Double = run % 2 == 0 ? 1 : -1
        // 每次换一个起点小数（黄金分割步进，8 次分得开）。
        let fraction = (Double(run) * 0.618_034).truncatingRemainder(dividingBy: 1)
        switch id {
        case "slow-release":
            return gesture(id: id, speed: 150, duration: 0.25, momentum: true, direction: direction,
                           startFraction: fraction, cellPoints: cellPoints)
        case "slow-release-nomomentum":
            // 规格外加的一条：抬手时还在走、系统没给惯性（极慢的拨动、触控板上手指先停的那几种）——抬手等 0.08 s 那条路。
            return gesture(id: id, speed: 150, duration: 0.25, momentum: false, direction: direction,
                           startFraction: fraction, cellPoints: cellPoints)
        case "hold-release":
            return gesture(id: id, speed: 400, duration: 0.2, hold: 0.15, momentum: false, direction: direction,
                           startFraction: fraction, cellPoints: cellPoints)
        case "medium-flick":
            return gesture(id: id, speed: 700, duration: 0.1, momentum: true, direction: direction,
                           startFraction: fraction, cellPoints: cellPoints)
        case "fast-flick":
            return gesture(id: id, speed: 2500, duration: 0.08, momentum: true, direction: direction,
                           startFraction: fraction, cellPoints: cellPoints)
        case "catch":
            return gesture(id: id, speed: 1500, duration: 0.1, momentum: true, catchAfter: 0.25, direction: direction,
                           startFraction: fraction, cellPoints: cellPoints)
        case "wheel-notch":
            // 5 格老式滚轮，80 ms 一格；最后一格算「抬手」。
            let inputs = (0 ..< 5).map { i in Input(t: Double(i - 4) * 0.08, kind: .wheel, travel: direction) }
            return Scenario(id: id, inputs: inputs, releaseVelocity: direction / 0.08)
        default:
            fatalError("unknown scenario \(id)")
        }
    }

    nonisolated static let startRow = 2000
    nonisolated static let scenarioIDs = ["slow-release", "slow-release-nomomentum", "hold-release", "medium-flick", "fast-flick", "catch", "wheel-notch"]

    // MARK: 事件

    /// 按整数 pt 发精确位移（CGEvent 的位移字段是整数），余数带到下一个事件，总位移不丢。
    @MainActor
    final class EventMaker {
        private var carry: Double = 0

        func reset() { carry = 0 }

        func event(_ input: Input) throws -> (NSEvent, Double) {
            switch input.kind {
            case .wheel:
                let lines = Int32(-input.travel)
                let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                               wheel1: lines, wheel2: 0, wheel3: 0))
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
                let e = try XCTUnwrap(NSEvent(cgEvent: cg))
                return (e, Double(e.scrollingDeltaY))
            case let .precise(phase, momentum):
                // 不带位移的事件（began / ended / 惯性结束）照真设备的样子发 0，余数留给下一个带位移的。
                var points = 0.0
                if input.travel != 0 {
                    let wanted = -input.travel + carry
                    points = wanted.rounded()
                    carry = wanted - points
                }
                let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                               wheel1: Int32(points), wheel2: 0, wheel3: 0))
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points))
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                let e = try XCTUnwrap(NSEvent(cgEvent: cg))
                return (e, Double(e.scrollingDeltaY))
            }
        }
    }

    private let maker = EventMaker()

    // MARK: 采样

    nonisolated struct Row {
        var t: Double
        var kind: String
        var inputDelta: Double?
        var display: Double
    }

    /// 一次回放：按计划时刻交事件（0.5 ms 的定时器），每个显示帧（视图的 display link）记一次位置。
    @MainActor
    final class Player: NSObject {
        let maker: EventMaker
        let deliver: (NSEvent) -> Void
        let position: () -> Double
        let atRest: () -> Bool
        var pending: [Input]
        let lastInput: Double
        var origin: Double = 0
        var rows: [Row] = []
        var liftActual: Double?
        var restSince: Double?
        var done = false
        var failure: Error?

        init(scenario: Scenario, maker: EventMaker, deliver: @escaping (NSEvent) -> Void,
             position: @escaping () -> Double, atRest: @escaping () -> Bool) {
            self.maker = maker
            self.deliver = deliver
            self.position = position
            self.atRest = atRest
            pending = scenario.inputs.sorted { $0.t < $1.t }
            lastInput = scenario.inputs.map(\.t).max() ?? 0
        }

        @objc func frame(_: CADisplayLink) {
            let now = CACurrentMediaTime() - origin
            guard now >= -0.3, !done else { return }
            rows.append(Row(t: now, kind: "frame", inputDelta: nil, display: position()))
        }

        func tick() {
            let now = CACurrentMediaTime() - origin
            while let next = pending.first, next.t <= now {
                pending.removeFirst()
                do {
                    let (e, delta) = try maker.event(next)
                    deliver(e)
                    if next.t == 0, liftActual == nil { liftActual = now }
                    rows.append(Row(t: now, kind: "touch", inputDelta: delta, display: position()))
                } catch { failure = error }
            }
            guard pending.isEmpty, now > lastInput else { return }
            if atRest() {
                if restSince == nil { restSince = now }
            } else {
                restSince = nil
            }
            if let restSince, now - restSince >= 0.6 { done = true }
            if now > max(3.5, lastInput + 1) { done = true }
        }
    }

    /// 回放一个场景：`deliver` 把事件交给视图，`position` 读此刻的位置（pt），`atRest` 判定停稳。
    /// 抬手前 300 ms 开始采，停稳后再采 600 ms（最长到抬手后 3.5 s）。
    private func play(_ scenario: Scenario, view: NSView, deliver: @escaping (NSEvent) -> Void,
                      position: @escaping () -> Double, atRest: @escaping () -> Bool) async throws -> [Row] {
        maker.reset()
        let player = Player(scenario: scenario, maker: maker, deliver: deliver, position: position, atRest: atRest)
        let firstInput = scenario.inputs.map(\.t).min() ?? 0
        let lead = max(0.3, -firstInput + 0.05)
        player.origin = CACurrentMediaTime() + lead // 抬手的时刻（按计划）
        let link = view.displayLink(target: player, selector: #selector(Player.frame(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let timer = Timer(timeInterval: 0.0005, repeats: true) { [weak player] _ in
            MainActor.assumeIsolated { player?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        while !player.done, player.failure == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if let failure = player.failure { throw failure }
        // 按真正交出抬手事件的时刻对齐（计划时刻和实际差不到 1 ms，换个口径更准）。
        let shift = player.liftActual ?? 0
        return player.rows.map { var r = $0; r.t -= shift; return r }.sorted { $0.t < $1.t }
    }

    // MARK: 输出

    nonisolated static let header = "platform,variant,scenario,run,t_ms,kind,finger_pt,input_delta_pt,offset_pt,display_pt,cell_pt,release_v_ptps,uikit_v_ptps"

    private func csvLines(_ rows: [Row], variant: String, scenario: Scenario, run: Int, cellPoints: Double) -> [String] {
        func f(_ v: Double?, _ digits: Int = 3) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "nan" }
        return rows.map { r in
            ["mac", variant, scenario.id, String(run), f(r.t * 1000), r.kind, "nan", f(r.inputDelta), "nan",
             f(r.display, 4), f(cellPoints, 4), f(scenario.releaseVelocity, 1), "nan"].joined(separator: ",")
        }
    }

    private func write(_ lines: [String], name: String) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scrollbench")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try ([Self.header] + lines).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        print("SCROLLBENCH-FILE \(url.path)")
        // 沙盒放行时直接写到目标目录（一般不放行，调用方从上面那个路径拷）。
        if let out = Self.outputDirectory {
            try? ([Self.header] + lines).joined(separator: "\n").appending("\n")
                .write(toFile: (out as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: 用例

    /// 终端（真 Ghostty surface，默认配置 `.settlesOnRow`）。
    func testTerminalTrace() async throws {
        try XCTSkipUnless(Self.outputDirectory != nil, "测量用例：TEST_RUNNER_UTERM_SCROLLBENCH_DIR=<目录> 才跑")
        let rig = await GhosttySurfaceRig(size: NSSize(width: 800, height: 500))
        defer { rig.close() }
        var text = ""
        for n in 1 ... 4000 { text += "line \(n)\r\n" }
        await rig.feed(text)
        let view = rig.view
        let cellPixels = try XCTUnwrap(view.uTermCellPixels).height
        let scale = try XCTUnwrap(view.window).backingScaleFactor
        let cellPoints = Double(cellPixels / scale)
        func position() -> Double {
            let s = view.uTermScrollState
            return (Double(s.row) * Double(cellPixels) + s.fraction) / Double(scale)
        }
        // 每次都从回滚中段的同一行（第 2000 行，整行上）起步，和对照的起点一致，停下的位置才能逐次比。
        func moveToStart() async throws {
            for _ in 0 ..< 8 {
                _ = await rig.waitUntil(3) { view.uTermScrollState.isAtRest }
                let rows = Self.startRow - view.uTermScrollState.row
                if rows == 0, view.uTermScrollState.isAtRest { return }
                for e in [Input(t: 0, kind: .precise(phase: Self.began, momentum: 0), travel: 0),
                          Input(t: 0, kind: .precise(phase: Self.changed, momentum: 0), travel: Double(rows) * cellPoints),
                          Input(t: 0, kind: .precise(phase: Self.ended, momentum: 0), travel: 0)] {
                    view.scrollWheel(with: try maker.event(e).0)
                }
                _ = await rig.waitUntil(3) { view.uTermScrollState.isAtRest }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(view.uTermScrollState.row, Self.startRow, "没回到起点：\(view.uTermScrollState)")
        }
        try await moveToStart()
        try await Task.sleep(for: .milliseconds(300))

        let meta: [String: Any] = [
            "variant": Self.variant,
            "display_max_fps": view.window?.screen?.maximumFramesPerSecond ?? 0,
            "backing_scale": scale,
            "cell_px": cellPixels,
            "cell_pt": cellPoints,
            "event_rate_hz": 120,
            "momentum": "v(t)=v_lift*0.998^ms, ends below 60 pt/s",
            "settler_snap_duration_s": 0.18,
        ]
        print("SCROLLBENCH-META \(String(data: try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]), encoding: .utf8) ?? "")")

        var lines: [String] = []
        for id in Self.scenarioIDs {
            for run in 0 ..< Self.runs {
                rig.keepRendering()
                try await moveToStart()
                try await Task.sleep(for: .milliseconds(200))
                let s = Self.scenario(id, run: run, cellPoints: cellPoints)
                let rows = try await play(s, view: view, deliver: { view.scrollWheel(with: $0) }, position: position,
                                          atRest: { view.uTermScrollState.isAtRest })
                XCTAssertGreaterThanOrEqual(rows.filter { $0.kind == "frame" && $0.t < 0 }.count, 8, "\(id) #\(run)：抬手前的帧不够")
                lines += csvLines(rows, variant: Self.variant, scenario: s, run: run, cellPoints: cellPoints)
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        try write(lines, name: "mac-\(Self.variant).csv")
    }

    /// 对照：普通 `NSScrollView`（不吸附），文档视图很高，喂同一串事件。`cell_pt` 用终端的格子高（量终端那一份时报出的值）。
    func testReferenceTrace() async throws {
        try XCTSkipUnless(Self.outputDirectory != nil, "测量用例：TEST_RUNNER_UTERM_SCROLLBENCH_DIR=<目录> 才跑")
        // 格子高：开一个终端量一次（和 testTerminalTrace 同一套配置）。
        let rig = await GhosttySurfaceRig(size: NSSize(width: 800, height: 500))
        let cellPixels = try XCTUnwrap(rig.view.uTermCellPixels).height
        let scale = try XCTUnwrap(rig.view.window).backingScaleFactor
        // 测完才关：关掉最后一个终端会话时测试宿主会退出（实测中途关掉，十几秒后进程以 0 退出）。
        defer { rig.close() }
        let cellPoints = Double(cellPixels / scale)

        // 合成事件直接交给 `NSScrollView.scrollWheel` 时它不认惯性（实测：responsive scrolling 那条路连拖动都不动，
        // 老路径拖动照走、惯性事件一个都不吃，抬手即停）。所以精确位移在这里按 AppKit 跟手的样子 1:1 挪可视区
        // （不吸附、不取整），老式滚轮照旧交给 NSScrollView 自己。
        final class Flipped: NSView {
            override var isFlipped: Bool { true }
            override class var isCompatibleWithResponsiveScrolling: Bool { false }
        }
        final class PlainScrollView: NSScrollView {
            override class var isCompatibleWithResponsiveScrolling: Bool { false }
            override func scrollWheel(with event: NSEvent) {
                guard event.hasPreciseScrollingDeltas, let document = documentView else { return super.scrollWheel(with: event) }
                let clip = contentView
                let maxY = document.frame.height - clip.bounds.height
                let y = min(max(0, clip.bounds.origin.y - event.scrollingDeltaY), maxY)
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                reflectScrolledClipView(clip)
            }
        }
        let rect = NSRect(x: 0, y: 0, width: 800, height: 500)
        let scrollView = PlainScrollView(frame: rect)
        scrollView.hasVerticalScroller = true
        // Ghostty 的老式滚轮一格滚 3 行（`mouse-scroll-multiplier` 的 discrete 默认 3）。
        scrollView.verticalLineScroll = 3 * cellPoints
        let document = Flipped(frame: NSRect(x: 0, y: 0, width: 800, height: 4000 * cellPoints))
        scrollView.documentView = document
        let window = ProbeWindow.make(contentRect: rect, contentView: scrollView, placement: .transparentOnScreen,
                                      keepsDrawing: true)
        defer { window.orderOut(nil) }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: Double(Self.startRow) * cellPoints))
        scrollView.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(300))
        func position() -> Double { Double(clip.bounds.origin.y) }
        var lastSeen = position()
        var stillSince = CACurrentMediaTime()
        func atRest() -> Bool {
            let p = position()
            let now = CACurrentMediaTime()
            if abs(p - lastSeen) > 0.001 { lastSeen = p; stillSince = now }
            return now - stillSince > 0.1
        }

        var lines: [String] = []
        for id in Self.scenarioIDs {
            for run in 0 ..< Self.runs {
                let s = Self.scenario(id, run: run, cellPoints: cellPoints)
                let rows = try await play(s, view: scrollView, deliver: { scrollView.scrollWheel(with: $0) },
                                          position: position, atRest: atRest)
                lines += csvLines(rows, variant: "reference", scenario: s, run: run, cellPoints: cellPoints)
                try await Task.sleep(for: .milliseconds(250))
                // 回到中段（上一次走远了也不碰到两头）。
                clip.scroll(to: NSPoint(x: 0, y: Double(Self.startRow) * cellPoints))
                scrollView.reflectScrolledClipView(clip)
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try write(lines, name: "mac-reference.csv")
    }
}
