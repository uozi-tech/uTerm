import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// M16 第四轮：回弹在持续输出时卡、惯性收尾卡。真机逐帧记录，无输出 / 有 Claude 式输出（每 100 ms 一个 DEC 2026 同步帧，
/// 同 M8）各跑一遍。
///
/// 每帧记：显示节拍间隔（120 Hz 参考 link，超过 1.5 拍算 hitch）、本地包滚动补丁每一步发出的值
///（`UTermScrollTrace`：减速 / 拖动的像素、越界平移量、视口首行行号）、这个 surface 的出帧间隔、主线程与渲染线程 CPU。
///
/// 手势走系统滚动那条路径（单指滚回滚区恒归 UIScrollView）：按 UIKit 会做的事驱动 GhosttyKit 借来的滚动视图
///（`EdgeSystemFinger`：拖动 = 改 contentOffset，松手后的减速 / 回弹由 display link 每帧写 contentOffset 代替）。
/// 原来这两条是伪造 pan 硬调 `handleTouchScrollGesture:`，量本地包里自写的橡皮筋回弹和落点惯性；那套自写物理已经整套删掉，
/// 同一条用户可见的行为（越界松手弹回 0、甩出去停在整行上、期间不卡）改在系统路径上核，断言原样。
/// 量不到 UIKit 自己的减速曲线，量的是我们这一侧每帧把 contentOffset 换成引擎位移 / 画面层平移的那一段。
@MainActor
final class GhosttyScrollFeelTests: XCTestCase {
    override func setUp() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func tearDown() async throws {
        UTermScrollTrace.isEnabled = false
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
                        gesture: @escaping @MainActor (EdgeSystemFinger) async throws -> Void) async throws -> Run {
        let finger = try EdgeSystemFinger(view: host.view)
        XCTAssertTrue(host.view.uTermSystemPanWouldBegin, "有回滚的普通屏：单指拖动应当归系统滚动")
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
        try await gesture(finger)
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
            let run = try await record("rubber output=\(output)", host: host, output: output, seconds: 1.6) { finger in
                finger.begin()
                for _ in 0..<30 {
                    // 已经在底上，每步都在界外：UIKit 拖过界时位移打折（橡皮筋），这里按手指 4 pt 走一半算。
                    finger.move(-2)
                    try await Task.sleep(for: .milliseconds(8))
                }
                finger.end(velocity: 0)
            }
            let over = run.trace.filter { $0.kind == "overscroll" }
            let releaseAt = over.firstIndex { $0.time > (over.first?.time ?? 0) + 0.24 } ?? over.count
            // 回弹 = 松手之后到平移量第一次回到 0 为止。之后停稳了，来一帧输出也会记一笔 0（按引擎对位置时顺手把平移归零），
            // 那些不是回弹的步子。
            let released = Array(over[min(releaseAt, over.count)...])
            let bounce = released.firstIndex { abs($0.value) < 0.5 }.map { Array(released[...$0]) } ?? released
            let bounceGaps = gaps(bounce.map(\.time))
            print("FEEL \(run.label) " + summary(run, kinds: ["overscroll"]))
            print(String(format: "FEEL %@ overscroll steps=%d peak=%.0fpx end=%.1fpx bounce-steps=%d bounce-step-gap-max=%.1fms bounce-gaps>12.5=%d values=%@",
                         run.label, over.count, over.map { abs($0.value) }.max() ?? 0, over.last?.value ?? 0, bounce.count,
                         bounceGaps.max() ?? 0, bounceGaps.filter { $0 > 12.5 }.count,
                         over.suffix(40).map { String(format: "%.0f", $0.value) }.joined(separator: ",")))
            worst[run.label] = run.ticks.filter { $0 > 12.5 }.count + bounceGaps.filter { $0 > 12.5 }.count
            XCTAssertGreaterThan(over.map { abs($0.value) }.max() ?? 0, 100, "\(run.label)：推过底 60 pt，画面层应当跟着平移")
            XCTAssertEqual(over.last?.value ?? 0, 0, accuracy: 0.5, "\(run.label)：松手后没弹回 0")
            XCTAssertTrue(host.view.uTermScrollState.isAtRest, "\(run.label)：弹回之后没停稳 \(host.view.uTermScrollState)")
        }
        print("FEEL rubber worst \(worst)")
        for (label, bad) in worst { XCTAssertLessThanOrEqual(bad, 3, "\(label)：回弹期间卡顿 \(bad) 次") }
    }

    // MARK: 场景 2：甩出去，到减速停下（含落到整行）

    func testFlingSettleWhileOutput() async throws {
        var problems: [String] = []
        for output in [false, true] {
            let host = try await hostAtBottom()
            defer { host.close() }
            let cellPx = Double(try XCTUnwrap(host.view.uTermCellPixels).height)
            for _ in 0..<60 { host.view.sendMouseScroll(x: 0, y: cellPx, mods: TerminalScrollModifiers(precision: true)) }
            try await Task.sleep(for: .milliseconds(300))
            // 预热一次（第一次起 display link、编管线的开销不算进读数）。
            // 预热那一下的减速要等它完全落定（约 1.5 s），不然下一段从半行开始，落点核对会错。
            _ = try await record("warmup", host: host, output: false, seconds: 2.2) { finger in
                finger.begin()
                finger.end(velocity: -300, seconds: EdgeSystemFinger.flingSeconds)
            }
            let run = try await record("fling output=\(output)", host: host, output: output, seconds: 2.8) { finger in
                finger.begin()
                finger.move(6)
                try await Task.sleep(for: .milliseconds(8))
                finger.end(velocity: 1000, seconds: EdgeSystemFinger.flingSeconds)
            }
            // 松手之后每一步发给引擎的像素（减速、以及停下后对齐整行的那几步，都记成 momentum）。
            let steps = run.trace.filter { $0.kind == "momentum" }
            // 速度曲线不连续：按每 4 步（约 33 ms）的位移和看，减速阶段后一窗比前一窗多走 30% 且多 2 px 以上 = 先慢下来又突然快一截
            //（「先停一下再挪一下」）。按窗看是为了不把整像素取整造成的 1 / 0 交替、以及记录时刻的抖动算成跳变。
            let window = 4
            let sums = stride(from: 0, to: max(0, steps.count - window + 1), by: window).map { start in
                steps[start..<min(steps.count, start + window)].reduce(0) { $0 + abs($1.value) }
            }
            var jumps = 0
            for (a, b) in zip(sums, sums.dropFirst()).dropFirst(1) where b > a * 1.3 && b - a > 2 { jumps += 1 }
            let total = run.trace.filter { ["momentum", "drag"].contains($0.kind) }.reduce(0) { $0 + $1.value }
            let landed = abs(total.truncatingRemainder(dividingBy: cellPx))
            let state = host.view.uTermScrollState
            print("FEEL \(run.label) " + summary(run, kinds: ["momentum"]))
            print(String(format: "FEEL %@ steps=%d travelled=%.0fpx (%.2f rows) speed-jumps=%d rest=%@ tail-4step-sums(px)=%@ tail-steps(px)=%@",
                         run.label, steps.count, total, total / cellPx, jumps, "\(state.row)+\(state.fractionPixels)px",
                         sums.suffix(16).map { String(format: "%.1f", $0) }.joined(separator: ","),
                         steps.suffix(24).map { String(format: "%.1f", $0.value) }.joined(separator: ",")))
            if steps.count < 20 { problems.append("\(run.label) 松手后只走了 \(steps.count) 步（减速没起来）") }
            if jumps > 0 { problems.append("\(run.label) 速度曲线跳变 \(jumps) 次") }
            if run.ticks.filter({ $0 > 12.5 }).count > 3 { problems.append("\(run.label) 显示卡顿 \(run.ticks.filter { $0 > 12.5 }.count) 次") }
            if min(landed, cellPx - landed) > 1 { problems.append("\(run.label) 没停在整行上（零头 \(landed) px）") }
            if !state.isAtRest { problems.append("\(run.label) 停下之后不在整行上 / 还在动（\(state)）") }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "；"))
    }
}
