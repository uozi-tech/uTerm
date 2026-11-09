import GhosttyTerminal
import QuartzCore
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// M16 第六轮：user 真机日志里剩下的抖是偶发掉帧（个别拍提交晚于 vsync、惯性 link 跳拍），而 user 甩得比测试快得多
///（初速 5k–24k px/s，每拍 40–200 px、跨 1–4 行）。这里按 user 的甩速复现，并把每一拍主线程的时间拆开：
/// - 我们的惯性回调（`glide-cb`）、其中发给 Ghostty 的滚动（`glide-send`，含等 renderer_state 锁）；
/// - GhosttyKit 协调器的 tick（`tick-app` = ghostty_app_tick、`tick-refresh`、`tick-draw` = 主线程同步整帧重画并等 GPU）；
/// - 主队列上的 wakeup tick（`wakeup-tick`）；
/// - Core Animation 提交（CA 的 2000000 号 observer 前后）；
/// - 主线程这一拍的总忙时（runloop 醒来到睡下）；其余的算「其他」（SwiftUI、输出、UIKit）。
/// 按这一拍惯性跨了几行分桶，给 p50 / p95 / max。上屏是否赶上 vsync 用 `GhosttyOnScreenScrollTests` 的条码解码。
@MainActor
final class GhosttyFrameBudgetTests: XCTestCase {
    typealias OnScreen = GhosttyOnScreenScrollTests

    override func setUp() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func tearDown() async throws {
        UTermScrollTrace.isEnabled = false
        UTermScrollTrace.legacyWakeupSyncDraw = false
    }

    private final class Pan: UIPanGestureRecognizer {
        var fakeState: UIGestureRecognizer.State = .possible
        var fakeTranslation: CGPoint = .zero
        var fakeVelocity: CGPoint = .zero
        override var state: UIGestureRecognizer.State {
            get { fakeState }
            set { fakeState = newValue }
        }
        override var numberOfTouches: Int { 1 }
        override func translation(in view: UIView?) -> CGPoint { fakeTranslation }
        override func setTranslation(_ translation: CGPoint, in view: UIView?) { fakeTranslation = translation }
        override func velocity(in view: UIView?) -> CGPoint { fakeVelocity }
        override func location(in view: UIView?) -> CGPoint { CGPoint(x: 200, y: 300) }
    }

    /// 主线程忙时（runloop 每次醒来到睡下）和 CA 提交耗时。
    @MainActor
    final class MainLoopClock {
        private(set) var busy: [(start: Double, end: Double)] = []
        private(set) var commits: [(start: Double, end: Double)] = []
        private var observers: [CFRunLoopObserver] = []
        private var wokeAt: Double = 0
        private var commitStart: Double = 0

        func start() {
            func add(_ activity: CFRunLoopActivity, _ order: CFIndex, _ body: @escaping @MainActor () -> Void) {
                let observer = CFRunLoopObserverCreateWithHandler(nil, activity.rawValue, true, order) { _, _ in
                    MainActor.assumeIsolated { body() }
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                observers.append(observer!)
            }
            wokeAt = CACurrentMediaTime()
            add(.afterWaiting, CFIndex.min) { [unowned self] in wokeAt = CACurrentMediaTime() }
            add(.beforeWaiting, 1_999_999) { [unowned self] in commitStart = CACurrentMediaTime() }
            add(.beforeWaiting, 2_000_000 + 2) { [unowned self] in
                if commitStart > 0 { commits.append((commitStart, CACurrentMediaTime())) }
                commitStart = 0
            }
            add(.beforeWaiting, CFIndex.max) { [unowned self] in
                busy.append((wokeAt, CACurrentMediaTime()))
            }
        }

        func stop() {
            for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observers.removeAll()
        }
    }

    struct Frame {
        var target: Double
        var rows = 0
        var sent = 0.0
        var busy = 0.0
        var glideCB = 0.0
        var glideSend = 0.0
        var tickApp = 0.0
        var tickRefresh = 0.0
        var tickDraw = 0.0
        var tickDraws = 0
        var wakeup = 0.0
        var commit = 0.0
        var decode = 0.0
        var late = false
        var skippedBefore = false
        var other: Double { max(0, busy - glideCB - tickApp - tickRefresh - tickDraw - wakeup - commit - decode) }
    }

    private func pct(_ values: [Double], _ p: Double) -> Double { ProbeMetrics.percentile(values, p) }

    private func bucketLine(_ frames: [Frame], label: String) -> String {
        func stat(_ key: KeyPath<Frame, Double>) -> String {
            let v = frames.map { $0[keyPath: key] }
            return String(format: "%.2f/%.2f/%.2f", pct(v, 0.5), pct(v, 0.95), v.max() ?? 0)
        }
        let draws = frames.map(\.tickDraws).reduce(0, +)
        return "\(label) frames=\(frames.count) late=\(frames.filter(\.late).count) link-skip=\(frames.filter(\.skippedBefore).count) "
            + "busy=\(stat(\.busy)) glide-cb=\(stat(\.glideCB)) glide-send=\(stat(\.glideSend)) tick-draw=\(stat(\.tickDraw)) (\(draws) 次) "
            + "tick-app=\(stat(\.tickApp)) tick-refresh=\(stat(\.tickRefresh)) wakeup=\(stat(\.wakeup)) ca-commit=\(stat(\.commit)) "
            + "other=\(stat(\.other)) [p50/p95/max ms]"
    }

    /// 一次甩动的逐拍账。`velocityPx` 是物理像素 / 秒（user 日志口径）。
    private func measure(label: String, view: MGhosttyTerminalView, velocityPx: Double, output: Bool,
                         feed: @escaping @MainActor (String) async -> Void,
                         frame: @escaping @MainActor (Int) -> String) async throws -> [Frame] {
        // 量的是第六轮的做法（wakeup 不在主线程同步重画）；工作区里建 bridge 时会按设置切到第五轮，这里显式切回来。
        UTermScrollTrace.legacyWakeupSyncDraw = false
        let cell = try XCTUnwrap(view.uTermCellPixels)
        let cellPx = Double(cell.height)
        let scale = Double(view.window?.screen.nativeScale ?? 3)
        let layer = try XCTUnwrap(OnScreen.surfaceLayer(in: view.layer))
        let pan = Pan()
        let selector = NSSelectorFromString("handleTouchScrollGesture:")
        func fling(_ velocityPt: CGFloat) {
            pan.fakeState = .began; pan.fakeTranslation = .zero; _ = view.perform(selector, with: pan)
            pan.fakeState = .changed; pan.fakeTranslation = CGPoint(x: 0, y: velocityPt > 0 ? 6 : -6); _ = view.perform(selector, with: pan)
            pan.fakeState = .ended; pan.fakeTranslation = .zero; pan.fakeVelocity = CGPoint(x: 0, y: velocityPt)
            _ = view.perform(selector, with: pan)
        }

        var decoder = OnScreen.BarcodeDecoder(cell: cell)
        var decodeSpans: [(Double, Double)] = []
        let sampler = OnScreen.CommitSampler()
        sampler.read = {
            let t0 = CACurrentMediaTime()
            let value = decoder.position(of: layer)
            decodeSpans.append((t0, (CACurrentMediaTime() - t0) * 1000))
            return value
        }
        let clock = MainLoopClock()
        let feeder = output ? Task { @MainActor in
            var n = 1
            while !Task.isCancelled {
                await feed(frame(n))
                n += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        } : nil
        let threads0 = ThreadCPU.snapshot()
        let mainID = ThreadCPU.currentThreadID()
        UTermScrollTrace.isEnabled = true
        GhosttyPresentLog.reset()
        sampler.start()
        clock.start()
        try await Task.sleep(for: .milliseconds(150))
        fling(CGFloat(velocityPx / scale))
        try await Task.sleep(for: .milliseconds(1900))
        clock.stop()
        sampler.stop()
        feeder?.cancel()
        let trace = UTermScrollTrace.drain()
        UTermScrollTrace.isEnabled = false
        let cpu = ThreadCPU.delta(from: threads0, to: ThreadCPU.snapshot(), mainID: mainID)
        let presents = GhosttyPresentLog.read().times

        // 逐拍：每个惯性回调一拍，key = 它的 target。
        let targets = trace.filter { $0.kind == "glide-target" }
        guard !targets.isEmpty else { XCTFail("\(label)：惯性没起来"); return [] }
        var frames: [Frame] = []
        var cumulative = trace.filter { $0.kind == "drag" }.reduce(0) { $0 + $1.value }
        let moves = trace.filter { $0.kind == "momentum" }
        var previousTarget = targets[0].value - 1.0 / 120
        for (index, event) in targets.enumerated() {
            var f = Frame(target: event.value)
            let windowStart = previousTarget, windowEnd = event.value
            f.skippedBefore = index > 0 && windowEnd - windowStart > 0.0105
            // 这一拍发出的位移（惯性回调在 target 前约 1 拍内）。
            let nextCallback = index + 1 < targets.count ? targets[index + 1].time : .infinity
            let sent = moves.filter { $0.time >= event.time && $0.time < nextCallback }.reduce(0) { $0 + $1.value }
            let before = (cumulative / cellPx).rounded(.down)
            cumulative += sent
            f.rows = Int(abs((cumulative / cellPx).rounded(.down) - before))
            f.sent = abs(sent)
            // 主线程这一拍（上一个 target 到这个 target）的账。
            func overlap(_ a: Double, _ b: Double) -> Double { max(0, min(b, windowEnd) - max(a, windowStart)) * 1000 }
            f.busy = clock.busy.reduce(0) { $0 + overlap($1.start, $1.end) }
            f.commit = clock.commits.reduce(0) { $0 + overlap($1.start, $1.end) }
            func spans(_ kind: String) -> [UTermScrollTrace.Event] {
                trace.filter { $0.kind == kind && $0.time >= windowStart && $0.time < windowEnd }
            }
            f.glideCB = spans("glide-cb").reduce(0) { $0 + $1.value }
            f.glideSend = spans("glide-send").reduce(0) { $0 + $1.value }
            f.tickApp = spans("tick-app").reduce(0) { $0 + $1.value }
            f.tickRefresh = spans("tick-refresh").reduce(0) { $0 + $1.value }
            f.tickDraw = spans("tick-draw").reduce(0) { $0 + $1.value }
            f.tickDraws = spans("tick-draw").count
            f.wakeup = spans("wakeup-tick").reduce(0) { $0 + $1.value }
            f.decode = decodeSpans.filter { $0.0 >= windowStart && $0.0 < windowEnd }.reduce(0) { $0 + $1.1 }
            // 上屏晚了：这一步发出后第一次换画面的提交不在它的 target 之前。
            if sent != 0 {
                let base = sampler.samples.last { $0.time <= event.time }?.value
                let change = sampler.samples.first { $0.time > event.time && $0.value != base }
                f.late = (change?.time ?? .infinity) >= event.value
            }
            frames.append(f)
            previousTarget = event.value
        }
        let moving = frames.filter { $0.sent > 0 }
        print("BUDGET \(label) v=\(Int(velocityPx))px/s output=\(output) frames=\(moving.count) "
              + "travelled=\(Int(moving.reduce(0) { $0 + $1.sent }))px late=\(moving.filter(\.late).count) "
              + "link-skip=\(frames.filter(\.skippedBefore).count) presents=\(presents.count) "
              + String(format: "cpu main=%.0fms renderer=%.0fms io=%.0fms total=%.0fms", cpu.mainMS, cpu.ms(matching: "renderer"),
                       cpu.ms(matching: "io"), cpu.totalMS))
        for rows in 0...4 {
            let bucket = moving.filter { rows < 4 ? $0.rows == rows : $0.rows >= 4 }
            if !bucket.isEmpty { print("BUDGET \(label) v=\(Int(velocityPx)) output=\(output) " + bucketLine(bucket, label: "rows=\(rows < 4 ? "\(rows)" : "4+")")) }
        }
        // 晚了 / 跳拍的那几拍逐拍列出来。
        let bad = frames.enumerated().filter { $0.element.late || $0.element.skippedBefore }.prefix(12)
        if !bad.isEmpty {
            print("BUDGET-BAD \(label) v=\(Int(velocityPx)) output=\(output) " + bad.map { index, f in
                String(format: "#%d rows=%d sent=%.0f busy=%.1f cb=%.1f send=%.1f draw=%.1f(%d) app=%.1f wake=%.1f commit=%.1f other=%.1f%@%@",
                       index, f.rows, f.sent, f.busy, f.glideCB, f.glideSend, f.tickDraw, f.tickDraws, f.tickApp, f.wakeup,
                       f.commit, f.other, f.late ? " LATE" : "", f.skippedBefore ? " SKIP" : "")
            }.joined(separator: " | "))
        }
        return moving
    }

    private static let velocities: [Double] = [6000, 12000, 20000]

    /// 打印分桶，并核回归门槛：
    /// - 甩动期间主线程不再同步整帧重画（tick-draw 0 次；修前每个跨行的拍一次，2.1 ms、最长 5.5 ms）；
    /// - 跨行的拍主线程忙时 p95 < 2 ms（修前约 3.1 ms）；
    /// - 赶不上 vsync 的拍、惯性 link 跳拍各不超过 2 拍（每组约 1,000 拍）。
    private func summarize(_ all: [String: [Frame]]) {
        for (key, frames) in all.sorted(by: { $0.key < $1.key }) {
            for rows in 0...4 {
                let bucket = frames.filter { rows < 4 ? $0.rows == rows : $0.rows >= 4 }
                if !bucket.isEmpty { print("BUDGET-ALL \(key) " + bucketLine(bucket, label: "rows=\(rows < 4 ? "\(rows)" : "4+")")) }
            }
            let crossing = frames.filter { $0.rows > 0 }
            XCTAssertEqual(frames.map(\.tickDraws).reduce(0, +), 0, "\(key)：甩动期间主线程还在同步重画")
            XCTAssertLessThan(pct(crossing.map(\.busy), 0.95), 2.0, "\(key)：跨行的拍主线程忙时 p95")
            // 每组约 1,000 拍；手机刚解锁、系统忙时偶尔有一两拍被系统占走（主线程「其他」一下 10 ms 以上），
            // 门槛留 2 拍。修前不是这个量级：主线程同步重画每跨一行一次。
            XCTAssertLessThanOrEqual(frames.filter(\.late).count, 2, "\(key)：没赶上 vsync 的拍")
            XCTAssertLessThanOrEqual(frames.filter(\.skippedBefore).count, 2, "\(key)：惯性 link 跳拍")
        }
    }

    /// 单独窗口（和 user 手机同尺寸 440×956 pt），无 / 有 Claude 输出，6k / 12k / 20k px/s 各甩两次。
    func testFrameBudgetAtUserFlingSpeeds() async throws {
        var all: [String: [Frame]] = [:]
        for output in [false, true] {
            let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 956))
            defer { host.close() }
            try await host.waitUntilReady()
            let cols = host.grid.cols
            host.feedAndWait(OnScreen.barcodeHistory(lines: 1500, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols))
            try await Task.sleep(for: .milliseconds(300))
            let cell = try XCTUnwrap(host.view.uTermCellPixels)
            for _ in 0..<80 { host.view.sendMouseScroll(x: 0, y: Double(cell.height), mods: TerminalScrollModifiers(precision: true)) }
            try await Task.sleep(for: .milliseconds(300))
            // 预热：起 link、编管线。
            _ = try await measure(label: "warmup", view: host.view, velocityPx: 3000, output: false, feed: { _ in }, frame: { _ in "" })
            for velocity in Self.velocities {
                for round in 0..<2 {
                    // 来回甩，留在回滚区中间（20k px/s 一次走约 10,000 px ≈ 256 行）。
                    let signed = round == 0 ? velocity : -velocity
                    let frames = try await measure(label: "isolated", view: host.view, velocityPx: signed, output: output) { text in
                        host.bridge.feed(Data(text.utf8))
                    } frame: { TerminalSpikeCorpus.claudeFrame($0, cols: cols) }
                    all["isolated output=\(output)", default: []] += frames
                }
            }
        }
        summarize(all)
    }

    /// 整个工作区界面（SwiftUI 外壳、标签条、键盘条，输出走假 SSH 后端经控制器进 Ghostty）。
    func testFrameBudgetInWorkspace() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DefaultsKey.debugGhosttyTrial)
        defaults.set(true, forKey: DefaultsKey.debugGhosttyTrial)
        defer {
            if let previous { defaults.set(previous, forKey: DefaultsKey.debugGhosttyTrial) }
            else { defaults.removeObject(forKey: DefaultsKey.debugGhosttyTrial) }
        }
        defer { MobileProbeWindow.closeAll() }
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
        let rig = MobileProbeRig(label: "ghostty-budget")
        rig.mount(WorkspaceScreen()
            .environment(store).environment(relay).environment(sessions)
            .environment(\.mAccent, M.accent).modelContainer(container))
        tab.controller.start(profile: server, container: container, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(connected)
        let bridge = try XCTUnwrap(tab.controller.ghostty)
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { bridge.view.surface != nil && bridge.grid != nil }
        XCTAssertTrue(ready)
        defer { tab.controller.close() }
        let transport = try XCTUnwrap(handles.latest)
        let cols = bridge.grid?.cols ?? 80
        await transport.write(Data((OnScreen.barcodeHistory(lines: 1500, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols)).utf8))
        _ = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { bridge.view.uTermCellPixels != nil }
        try await Task.sleep(for: .milliseconds(800))
        let cell = try XCTUnwrap(bridge.view.uTermCellPixels)
        for _ in 0..<80 { bridge.view.sendMouseScroll(x: 0, y: Double(cell.height), mods: TerminalScrollModifiers(precision: true)) }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await measure(label: "warmup", view: bridge.view, velocityPx: 3000, output: false, feed: { _ in }, frame: { _ in "" })
        var all: [String: [Frame]] = [:]
        for output in [false, true] {
            for velocity in Self.velocities {
                for round in 0..<2 {
                    let signed = round == 0 ? velocity : -velocity
                    let frames = try await measure(label: "workspace", view: bridge.view, velocityPx: signed, output: output) { text in
                        await transport.write(Data(text.utf8))
                    } frame: { TerminalSpikeCorpus.claudeFrame($0, cols: cols) }
                    all["workspace output=\(output)", default: []] += frames
                }
            }
        }
        summarize(all)
    }
}
