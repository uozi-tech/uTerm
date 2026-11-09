import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// M16 第四轮：回弹在持续输出时卡、惯性收尾卡。真机逐帧记录，无输出 / 有 Claude 式输出（每 100 ms 一个 DEC 2026 同步帧，
/// 同 M8）各跑一遍。
///
/// 每帧记：显示节拍间隔（120 Hz 参考 link，超过 1.5 拍算 hitch）、本地包滚动补丁每一步发出的值
///（`UTermScrollTrace`：惯性 / 吸附 / 拖动的像素、回弹量、视口首行行号）、这个 surface 的出帧间隔、主线程与渲染线程 CPU。
/// 手势用伪造的 `UIPanGestureRecognizer` 直接调 GhosttyKit 的 `handleTouchScrollGesture:`，按 120 Hz 的真实时间节奏喂。
@MainActor
final class GhosttyScrollFeelTests: XCTestCase {
    override func setUp() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func tearDown() async throws {
        UTermScrollTrace.isEnabled = false
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

    private struct Run {
        let label: String
        let ticks: [Double]          // 参考 link 每拍间隔（ms）
        let presents: [Double]       // 本 surface 交帧时刻
        let trace: [UTermScrollTrace.Event]
        let cpu: ThreadCPU.Delta
        let seconds: Double
    }

    private func hostAtBottom() async throws -> GhosttyProbeHost {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 600))
        try await host.waitUntilReady()
        host.feedAndWait(TerminalSpikeCorpus.history(lines: 400, cols: host.grid.cols)
                         + TerminalSpikeCorpus.claudeFrame(0, cols: host.grid.cols))
        try await Task.sleep(for: .milliseconds(300))
        return host
    }

    /// 跑一段手势，同时（可选）每 100 ms 来一个 Claude 帧。
    private func record(_ label: String, host: GhosttyProbeHost, output: Bool, seconds: Double,
                        gesture: @escaping @MainActor (Pan, Selector) async throws -> Void) async throws -> Run {
        let pan = Pan()
        let selector = NSSelectorFromString("handleTouchScrollGesture:")
        let counter = DisplayLinkCounter()
        UTermScrollTrace.isEnabled = true
        GhosttyPresentLog.reset()
        let mainID = ThreadCPU.currentThreadID()
        let cpu0 = ThreadCPU.snapshot()
        counter.start(preferred: CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120))
        let t0 = CACurrentMediaTime()
        let cols = host.grid.cols
        let feeder = output ? Task { @MainActor in
            var n = 1
            while !Task.isCancelled {
                host.bridge.feed(Data(TerminalSpikeCorpus.claudeFrame(n, cols: cols).utf8))
                n += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        } : nil
        try await gesture(pan, selector)
        while CACurrentMediaTime() - t0 < seconds { try await Task.sleep(for: .milliseconds(20)) }
        feeder?.cancel()
        counter.stop()
        let cpu = ThreadCPU.delta(from: cpu0, to: ThreadCPU.snapshot(), mainID: mainID)
        let presents = GhosttyPresentLog.read().times
        let trace = UTermScrollTrace.drain()
        UTermScrollTrace.isEnabled = false
        return Run(label: label, ticks: counter.intervals, presents: presents, trace: trace, cpu: cpu,
                   seconds: CACurrentMediaTime() - t0)
    }

    private func gaps(_ times: [Double]) -> [Double] { zip(times, times.dropFirst()).map { ($1 - $0) * 1000 } }

    private func summary(_ run: Run, kinds: Set<String>) -> String {
        let hitches = run.ticks.filter { $0 > 12.5 }.count
        let presentGaps = gaps(run.presents)
        let motion = run.trace.filter { kinds.contains($0.kind) }
        let motionGaps = gaps(motion.map(\.time))
        let rows = Set(run.trace.filter { $0.kind == "row" }.map(\.value)).count
        return String(format: "ticks=%d hitch(>12.5ms)=%d max-tick=%.1fms | presents=%d gap-max=%.1fms gaps>12.5=%d | motion-steps=%d step-gap-max=%.1fms step-gaps>12.5=%d rows-seen=%d | cpu main=%.0fms renderer=%.0fms total=%.0fms",
                      run.ticks.count, hitches, run.ticks.max() ?? 0, run.presents.count, presentGaps.max() ?? 0,
                      presentGaps.filter { $0 > 12.5 }.count, motion.count, motionGaps.max() ?? 0,
                      motionGaps.filter { $0 > 12.5 }.count, rows, run.cpu.mainMS, run.cpu.ms(matching: "renderer"),
                      run.cpu.totalMS)
    }

    // MARK: 场景 1：停在底部往上推、松手回弹

    func testRubberBandWhileOutput() async throws {
        var worst: [String: Int] = [:]
        for output in [false, true] {
            let host = try await hostAtBottom()
            defer { host.close() }
            let run = try await record("rubber output=\(output)", host: host, output: output, seconds: 1.6) { pan, sel in
                pan.fakeState = .began; _ = host.view.perform(sel, with: pan)
                for _ in 0..<30 {
                    pan.fakeState = .changed; pan.fakeTranslation = CGPoint(x: 0, y: -4)
                    _ = host.view.perform(sel, with: pan)
                    try await Task.sleep(for: .milliseconds(8))
                }
                pan.fakeState = .ended; pan.fakeTranslation = .zero; pan.fakeVelocity = .zero
                _ = host.view.perform(sel, with: pan)
            }
            let over = run.trace.filter { $0.kind == "overscroll" }
            let releaseAt = over.firstIndex { $0.time > (over.first?.time ?? 0) + 0.24 } ?? over.count
            let bounce = Array(over[min(releaseAt, over.count)...])
            let bounceGaps = gaps(bounce.map(\.time))
            print("FEEL \(run.label) " + summary(run, kinds: ["overscroll"]))
            print(String(format: "FEEL %@ overscroll steps=%d peak=%.0fpx end=%.1fpx bounce-step-gap-max=%.1fms bounce-gaps>12.5=%d values=%@",
                         run.label, over.count, over.map { abs($0.value) }.max() ?? 0, over.last?.value ?? 0,
                         bounceGaps.max() ?? 0, bounceGaps.filter { $0 > 12.5 }.count,
                         over.suffix(40).map { String(format: "%.0f", $0.value) }.joined(separator: ",")))
            worst[run.label] = run.ticks.filter { $0 > 12.5 }.count + bounceGaps.filter { $0 > 12.5 }.count
            XCTAssertEqual(over.last?.value ?? 0, 0, accuracy: 0.5, "\(run.label)：松手后没弹回 0")
        }
        print("FEEL rubber worst \(worst)")
        for (label, bad) in worst { XCTAssertLessThanOrEqual(bad, 3, "\(label)：回弹期间卡顿 \(bad) 次") }
    }

    // MARK: 场景 2：甩出去，到惯性停下（含落到整行）

    func testFlingSettleWhileOutput() async throws {
        var problems: [String] = []
        for output in [false, true] {
            let host = try await hostAtBottom()
            defer { host.close() }
            let scale = Double(host.view.window?.screen.nativeScale ?? 3)
            let cellPx = (Double(host.view.bounds.height) * scale / Double(host.grid.rows)).rounded(.down)
            for _ in 0..<60 { host.view.sendMouseScroll(x: 0, y: cellPx, mods: TerminalScrollModifiers(precision: true)) }
            try await Task.sleep(for: .milliseconds(300))
            // 预热一次（第一次起 display link、编管线的开销不算进读数），再滚回原处。
            // 预热那一下的滑行要等它完全落定（三次缓出约 1.6 s），不然下一段从半行开始，落点核对会错。
            _ = try await record("warmup", host: host, output: false, seconds: 2.2) { pan, sel in
                pan.fakeState = .began; _ = host.view.perform(sel, with: pan)
                pan.fakeState = .ended; pan.fakeVelocity = CGPoint(x: 0, y: -300); _ = host.view.perform(sel, with: pan)
            }
            let run = try await record("fling output=\(output)", host: host, output: output, seconds: 2.8) { pan, sel in
                pan.fakeState = .began; _ = host.view.perform(sel, with: pan)
                pan.fakeState = .changed; pan.fakeTranslation = CGPoint(x: 0, y: 6); _ = host.view.perform(sel, with: pan)
                try await Task.sleep(for: .milliseconds(8))
                pan.fakeState = .ended; pan.fakeTranslation = .zero; pan.fakeVelocity = CGPoint(x: 0, y: 1000)
                _ = host.view.perform(sel, with: pan)
            }
            let steps = run.trace.filter { ["momentum", "snap"].contains($0.kind) }
            // 每步速度（px/ms）：位移 ÷ 距上一步的时间。
            var speeds: [Double] = []
            for (a, b) in zip(steps, steps.dropFirst()) where b.time > a.time {
                speeds.append(abs(b.value) / ((b.time - a.time) * 1000))
            }
            // 速度曲线不连续：按每 4 步（约 33 ms）的位移和看，减速阶段后一窗比前一窗多走 30% 且多 2 px 以上 = 先慢下来又突然快一截
            //（「先停一下再挪一下」）。按窗看是为了不把整像素取整造成的 1 / 0 交替、以及记录时刻的抖动算成跳变。
            let window = 4
            let sums = stride(from: 0, to: max(0, steps.count - window + 1), by: window).map { start in
                steps[start..<min(steps.count, start + window)].reduce(0) { $0 + abs($1.value) }
            }
            var jumps = 0
            for (a, b) in zip(sums, sums.dropFirst()).dropFirst(1) where b > a * 1.3 && b - a > 2 { jumps += 1 }
            let snaps = steps.filter { $0.kind == "snap" }
            let total = run.trace.filter { ["momentum", "snap", "drag"].contains($0.kind) }.reduce(0) { $0 + $1.value }
            let landed = abs(total.truncatingRemainder(dividingBy: cellPx))
            print("FEEL \(run.label) " + summary(run, kinds: ["momentum", "snap"]))
            print(String(format: "FEEL %@ steps=%d (momentum %d + snap %d) travelled=%.0fpx (%.2f rows) speed-jumps=%d tail-4step-sums(px)=%@ tail-steps(px)=%@",
                         run.label, steps.count, steps.count - snaps.count, snaps.count, total, total / cellPx, jumps,
                         sums.suffix(16).map { String(format: "%.1f", $0) }.joined(separator: ","),
                         steps.suffix(24).map { String(format: "%.1f", $0.value) }.joined(separator: ",")))
            if jumps > 0 { problems.append("\(run.label) 速度曲线跳变 \(jumps) 次") }
            if run.ticks.filter({ $0 > 12.5 }).count > 3 { problems.append("\(run.label) 显示卡顿 \(run.ticks.filter { $0 > 12.5 }.count) 次") }
            if min(landed, cellPx - landed) > 1 { problems.append("\(run.label) 没停在整行上（零头 \(landed) px）") }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "；"))
    }
}
