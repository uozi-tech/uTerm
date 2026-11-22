import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// 上游 2026-11-22 在手机上报：「自然滚动有点回归，感觉速度向量不连续」。
///
/// 量的是松手前后 contentOffset 逐帧的速度：手指拖动那几帧的速度、UIKit 减速头几帧的速度、对齐动画头一帧的位移，
/// 有没有反向（速度变号）、有没有从静止一下跳到很快。手势是 `SyntheticFinger` 合成的真触摸，拖动、`willEndDragging`
/// 给的速度、减速、回弹全是 UIKit 自己的（别的系统滚动探针用的是三次缓出的假减速，量不到这一段）。
/// 读数打印成 `VELO …` 行，定下的门槛见各条用例。
@MainActor
final class GhosttySystemScrollVelocityTests: XCTestCase {
    override func setUp() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
        let deadline = CACurrentMediaTime() + 10
        while CACurrentMediaTime() < deadline,
              !UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: 夹具

    /// contentOffset 每次变动都记一笔（KVO：拖动、减速、对齐动画每帧各写一次）。
    @MainActor
    final class OffsetLog {
        struct Sample { let time: Double; let y: CGFloat; let tag: String }
        private(set) var samples: [Sample] = []
        var tag = "idle"
        private var observation: NSKeyValueObservation?

        init(_ scrollView: UIScrollView) {
            observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, change in
                let y = change.newValue?.y ?? 0
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let last = self.samples.last, abs(last.y - y) < 0.0001 { return }
                    self.samples.append(Sample(time: CACurrentMediaTime(), y: y, tag: self.tag))
                }
            }
        }

        func clear() { samples.removeAll() }
        func stop() { observation?.invalidate(); observation = nil }
    }

    /// 一次手势的读数。速度单位 pt/s，正 = contentOffset 变大（内容往上走，往活动区）。
    struct Reading: CustomStringConvertible {
        let label: String
        /// 拖动最后几帧的速度（按样本时间差算）。
        let dragVelocities: [Double]
        /// 松手之后（减速 / 对齐）头几帧的速度。
        let afterVelocities: [Double]
        /// 松手之后第一帧的位移（pt）。
        let firstStepAfter: Double
        /// 松手之后速度和拖动方向相反的帧数，以及反向走的总距离（pt）。
        let reversedFrames: Int
        let reversedDistance: Double
        /// 松手之后头一帧速度 ÷ 拖动最后一帧的速度。
        var handoffRatio: Double {
            guard let last = dragVelocities.last, last != 0, let first = afterVelocities.first else { return .nan }
            return first / last
        }

        var description: String {
            func list(_ v: [Double]) -> String { v.map { String(format: "%.0f", $0) }.joined(separator: ",") }
            return String(format: "%@ drag=[%@] after=[%@] first-step=%.2fpt handoff=%.2f reversed=%d帧/%.2fpt",
                          label, list(dragVelocities), list(afterVelocities), firstStepAfter, handoffRatio,
                          reversedFrames, reversedDistance)
        }
    }

    /// 从 log 里按 tag 切出拖动段与松手后的段，算速度。`direction`：拖动的方向（+1 / -1）。
    static func reading(_ label: String, _ samples: [OffsetLog.Sample], direction: Double, afterTag: String = "after",
                        keep: Int = 8) -> Reading {
        func velocities(_ s: [OffsetLog.Sample]) -> [Double] {
            zip(s, s.dropFirst()).map { a, b in
                let dt = max(0.001, b.time - a.time)
                return Double(b.y - a.y) / dt
            }
        }
        let drag = samples.filter { $0.tag == "drag" }
        let after = samples.filter { $0.tag == afterTag }
        let joined = (drag.last.map { [$0] } ?? []) + after
        let afterV = velocities(joined)
        let steps = zip(joined, joined.dropFirst()).map { Double($1.y - $0.y) }
        let reversed = steps.filter { $0 * direction < -0.01 }
        return Reading(label: label, dragVelocities: Array(velocities(drag).suffix(3)), afterVelocities: Array(afterV.prefix(keep)),
                       firstStepAfter: steps.first ?? 0, reversedFrames: reversed.count,
                       reversedDistance: abs(reversed.reduce(0, +)))
    }

    /// 合成一次拖动：从 `start` 按 `speed` pt/s（正 = 手指往上，contentOffset 变大）拖 `frames` 帧，
    /// `holdFrames` > 0 时最后停住那么多帧再抬（松手速度 ≈ 0），否则在动着的那一帧抬手。
    static func drag(_ finger: SyntheticFinger, log: OffsetLog, from start: CGPoint, speed: Double, frames: Int,
                     holdFrames: Int = 0) async throws {
        log.tag = "drag"
        try finger.down(at: start)
        var y = start.y
        var n = 0
        var last = 0.0
        var failure: Error?
        let ticker = FrameTicker()
        await ticker.run { link in
            let dt = last == 0 ? link.duration : link.targetTimestamp - last
            last = link.targetTimestamp
            n += 1
            do {
                if n <= frames {
                    y -= CGFloat(speed * dt)
                    try finger.move(to: CGPoint(x: start.x, y: y))
                    if n == frames, holdFrames == 0 {
                        log.tag = "after"
                        try finger.up()
                        return false
                    }
                    return true
                }
                if n <= frames + holdFrames {
                    try finger.hold()
                    if n == frames + holdFrames {
                        log.tag = "after"
                        try finger.up()
                        return false
                    }
                    return true
                }
                return false
            } catch {
                failure = error
                return false
            }
        }
        if let failure { throw failure }
    }

    /// 一个只记 / 改落点的代理。
    @MainActor
    final class PlainDelegate: NSObject, UIScrollViewDelegate {
        var rewrite: ((_ current: CGFloat, _ proposed: CGFloat, _ velocity: CGFloat) -> CGFloat)?
        var lastVelocity: CGFloat = 0
        var lastPan: CGFloat = 0
        var lastProposed: CGFloat = 0
        var willDecelerate: Bool?

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            lastVelocity = velocity.y
            lastPan = -scrollView.panGestureRecognizer.velocity(in: scrollView).y
            lastProposed = targetContentOffset.pointee.y
            if let rewrite {
                targetContentOffset.pointee.y = rewrite(scrollView.contentOffset.y, targetContentOffset.pointee.y, velocity.y)
            }
        }

        func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
            willDecelerate = decelerate
        }
    }

    /// 夹在 GhosttyKit 的滚动代理前面，记下 UIKit 松手时给的速度、提议的落点、改写后的落点、要不要减速，原样转给它。
    @MainActor
    final class DelegateTap: NSObject, UIScrollViewDelegate {
        struct Release { let offset: CGFloat; let velocity: CGFloat; let pan: CGFloat; let proposed: CGFloat; let target: CGFloat; var decelerate: Bool? }
        weak var inner: (any UIScrollViewDelegate)?
        private(set) var releases: [Release] = []

        init(_ scrollView: UIScrollView) {
            inner = scrollView.delegate
            super.init()
            scrollView.delegate = self
        }

        func scrollViewDidScroll(_ s: UIScrollView) { inner?.scrollViewDidScroll?(s) }
        func scrollViewWillBeginDragging(_ s: UIScrollView) { inner?.scrollViewWillBeginDragging?(s) }
        func scrollViewWillEndDragging(_ s: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            let proposed = targetContentOffset.pointee.y
            inner?.scrollViewWillEndDragging?(s, withVelocity: velocity, targetContentOffset: targetContentOffset)
            releases.append(Release(offset: s.contentOffset.y, velocity: velocity.y * 1000, pan: -s.panGestureRecognizer.velocity(in: s).y, proposed: proposed,
                                    target: targetContentOffset.pointee.y, decelerate: nil))
        }
        func scrollViewDidEndDragging(_ s: UIScrollView, willDecelerate decelerate: Bool) {
            if !releases.isEmpty { releases[releases.count - 1].decelerate = decelerate }
            inner?.scrollViewDidEndDragging?(s, willDecelerate: decelerate)
        }
        func scrollViewDidEndDecelerating(_ s: UIScrollView) { inner?.scrollViewDidEndDecelerating?(s) }
        func scrollViewDidEndScrollingAnimation(_ s: UIScrollView) { inner?.scrollViewDidEndScrollingAnimation?(s) }

        var lastLine: String {
            guard let r = releases.last else { return "release=-" }
            return String(format: "release: offset=%.2f v=%.0fpt/s pan=%.0fpt/s proposed=%+.2fpt target=%+.2fpt decelerate=%@",
                          r.offset, r.velocity, r.pan, r.proposed - r.offset, r.target - r.offset, r.decelerate.map { "\($0)" } ?? "-")
        }
    }

    // MARK: UIKit 自己：慢的松手、改写 targetContentOffset 之后的减速

    /// 普通 UIScrollView、合成的真触摸：UIKit 把多慢的松手当成停住；落点不改 / 往前往后挪 / 挪到起点 / 挪到起点身后，
    /// 松手那一刻速度怎么变；停住再抬、落点挪开时它自己怎么动过去。只量 UIKit、不碰终端，核的是补丁 #18 依据的前提：
    /// UIKit 换了行为，这一条先红。读数在维护者的内部测量记录里（不在公开仓库）。
    func testUIKitReleasePremises() async throws {
        let window = try makeSpikeWindow(size: CGSize(width: 400, height: 700))
        defer { window.isHidden = true }
        let scrollView = UIScrollView(frame: window.bounds)
        scrollView.contentSize = CGSize(width: 400, height: 200_000)
        scrollView.decelerationRate = .normal
        let delegate = PlainDelegate()
        scrollView.delegate = delegate
        window.addSubview(scrollView)
        defer { scrollView.removeFromSuperview() }
        let finger = try SyntheticFinger(window: window)
        let log = OffsetLog(scrollView)
        defer { log.stop() }

        // 1. 慢的松手：UIKit 给的速度是 0（不减速），手指自己的速度（拖动手势的）不是。
        for speed in [100.0, 150.0, 200.0] {
            scrollView.setContentOffset(CGPoint(x: 0, y: 100_000), animated: false)
            try await Task.sleep(for: .milliseconds(150))
            delegate.rewrite = nil
            delegate.willDecelerate = nil
            log.clear()
            try await Self.drag(finger, log: log, from: CGPoint(x: 200, y: 500), speed: speed, frames: 20)
            try await Task.sleep(for: .milliseconds(600))
            print(String(format: "VELO UIKit 慢松手 v=%.0f uikit-velocity=%.0f pan=%.0f decelerate=%@", speed, delegate.lastVelocity * 1000,
                         delegate.lastPan, String(describing: delegate.willDecelerate)))
            XCTAssertEqual(delegate.lastVelocity, 0, "\(Int(speed)) pt/s 的松手 UIKit 不再当成停住了：补丁 #18 的慢松手分支要重看")
            XCTAssertEqual(delegate.lastPan, CGFloat(speed), accuracy: CGFloat(speed) * 0.25, "拖动手势的速度读不到手指的速度")
            XCTAssertEqual(delegate.willDecelerate, false)
        }

        // 2. 甩：改写落点。
        let cases: [(String, ((CGFloat, CGFloat) -> CGFloat)?)] = [
            ("不改", nil),
            ("往回 25pt（仍在前方）", { _, proposed in proposed - 25 }),
            ("往前 25pt", { _, proposed in proposed + 25 }),
            ("落点 = 起点", { current, _ in current }),
            ("落点在起点身后 10pt", { current, _ in current - 10 }),
        ]
        for speed in [300.0, 1200.0] {
            for (name, rewrite) in cases {
                scrollView.setContentOffset(CGPoint(x: 0, y: 100_000), animated: false)
                try await Task.sleep(for: .milliseconds(150))
                if let rewrite {
                    delegate.rewrite = { current, proposed, _ in rewrite(current, proposed) }
                } else {
                    delegate.rewrite = nil
                }
                log.clear()
                try await Self.drag(finger, log: log, from: CGPoint(x: 200, y: 500), speed: speed, frames: 12)
                try await Task.sleep(for: .milliseconds(1500))
                let r = Self.reading("UIKit v=\(Int(speed)) \(name)", log.samples, direction: 1)
                print("VELO \(r) uikit-velocity=\(String(format: "%.0f", delegate.lastVelocity * 1000)) "
                    + "decelerate=\(String(describing: delegate.willDecelerate))")
                switch name {
                case "落点 = 起点":
                    XCTAssertEqual(delegate.willDecelerate, false, "落点挪到起点：UIKit 应当当场停住")
                case "落点在起点身后 10pt":
                    XCTAssertGreaterThan(r.reversedFrames, 0, "落点在身后：UIKit 应当一帧拽回去（这是补丁 #18 要躲开的）")
                default:
                    XCTAssertEqual(r.reversedFrames, 0, r.description)
                    // 落点往前往后挪几十点，减速头一帧的速度仍接着松手的速度（不改时也只有 0.9 上下）。
                    XCTAssertGreaterThan(r.handoffRatio, 0.75, r.description)
                    XCTAssertLessThan(r.handoffRatio, 1.25, r.description)
                }
            }
        }

        // 3. 停住再抬（速度 0），落点挪开 20 pt：UIKit 自己动过去，头一帧就接近全程最快。补丁 #18 不让它这么动。
        scrollView.setContentOffset(CGPoint(x: 0, y: 100_000), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        delegate.rewrite = { current, _, _ in current + 20 }
        log.clear()
        try await Self.drag(finger, log: log, from: CGPoint(x: 200, y: 500), speed: 600, frames: 10, holdFrames: 12)
        try await Task.sleep(for: .milliseconds(1000))
        let after = log.samples.filter { $0.tag == "after" }
        let steps = zip(after, after.dropFirst()).map { Double($1.y - $0.y) }
        print("VELO UIKit 停住后抬、落点 +20pt：逐帧位移 " + steps.prefix(12).map { String(format: "%.2f", $0) }.joined(separator: ","))
        XCTAssertEqual(delegate.lastVelocity, 0)
        if let peak = steps.max(), steps.count >= 2 {
            XCTAssertGreaterThanOrEqual(steps[0], peak * 0.7, "UIKit 从静止动到改写的落点，头一帧应当就接近最快的一帧")
        }
    }

    // MARK: 终端：真触摸下的松手

    private func terminalRig() async throws -> (GhosttyProbeHost, UIScrollView, CGFloat) {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 600))
        // 合成的触摸会被它当成有人碰了真机。
        host.window.removeGestureRecognizer(host.touchWatch)
        try await host.waitUntilReady()
        host.feedAndWait(GhosttyOnScreenScrollTests.barcodeHistory(lines: 600, cols: host.grid.cols))
        try await Task.sleep(for: .milliseconds(400))
        let scrollView = try XCTUnwrap(host.view.uTermSystemScrollView)
        XCTAssertTrue(host.view.uTermSystemPanWouldBegin)
        let cell = try XCTUnwrap(host.view.uTermCellPixels)
        let scale = host.window.screen.scale
        return (host, scrollView, cell.height / scale)
    }

    private func park(_ host: GhosttyProbeHost, row: UInt, plus points: CGFloat = 0) async throws {
        _ = host.view.surface?.scrollToRow(row)
        try await Task.sleep(for: .milliseconds(300))
        if points != 0, let scrollView = host.view.uTermSystemScrollView {
            scrollView.contentOffset.y += points
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 拖着松手：慢的（UIKit 当成停住）、快的（UIKit 减速），往两个方向、松手落在行内不同的位置。
    /// - 松手之后内容一帧都不往拖动的反方向走（原来慢松手一半的时候往回弹到最近的一行）；
    /// - 慢松手：松手后头一帧的速度接着手指的速度（0.4–1.6 倍；原来手指一离开内容就停、再由 UIKit 从静止往最近的一行动，常常还是反方向）；
    /// - 停下来时在整行上。
    func testReleaseKeepsDirectionAndSpeed() async throws {
        let (host, scrollView, cellPt) = try await terminalRig()
        defer { host.close() }
        let finger = try SyntheticFinger(window: host.window)
        let log = OffsetLog(scrollView)
        let tap = DelegateTap(scrollView)
        defer { log.stop(); scrollView.delegate = tap.inner }
        var problems: [String] = []
        var slow: [String] = []
        for speed in [-900.0, -200.0, -120.0, -60.0, 60.0, 120.0, 200.0, 900.0] {
            for frames in [8, 11, 15] {
                try await park(host, row: 300)
                log.clear()
                try await Self.drag(finger, log: log, from: CGPoint(x: 220, y: 300), speed: speed, frames: frames)
                try await Task.sleep(for: .milliseconds(700))
                // 甩出去的要等 UIKit 减速完（900 pt/s 约 2–3 s）。
                let deadline = CACurrentMediaTime() + 4
                while CACurrentMediaTime() < deadline, host.view.uTermScrollState.isGliding {
                    try await Task.sleep(for: .milliseconds(100))
                }
                let r = Self.reading("终端松手 v=\(Int(speed)) \(frames)帧", log.samples, direction: speed > 0 ? 1 : -1)
                let state = host.view.uTermScrollState
                print("VELO \(r) rest=\(state.isAtRest) cell=\(String(format: "%.2f", cellPt))pt \(tap.lastLine)")
                if r.reversedFrames > 0 {
                    problems.append("\(r.label)：往回走 \(r.reversedFrames) 帧 / \(String(format: "%.2f", r.reversedDistance)) pt")
                }
                if !state.isAtRest { problems.append("\(r.label)：没停在整行上 \(state)") }
                // 慢松手：UIKit 速度 0、手指在动。到行的距离够按手指的速度起步（3 × 距离 ÷ 速度 ≥ 0.1 s）时，头一帧速度要接得上。
                guard let release = tap.releases.last, release.velocity == 0, release.pan.magnitude >= 20,
                      let lifted = log.samples.last(where: { $0.tag == "drag" }), let landed = log.samples.last else { continue }
                let distance = Double(landed.y - lifted.y).magnitude
                let first = r.afterVelocities.first ?? 0
                let ratio = first / Double(release.pan)
                let line = String(format: "%@ 手指 %.0f pt/s → 头一帧 %.0f pt/s（%.2f 倍），走 %.2f pt 到行", r.label, release.pan, first, ratio, distance)
                slow.append(line)
                if distance > 0.5, 3 * distance / Double(release.pan.magnitude) >= 0.1, !(0.4...1.6).contains(ratio) {
                    problems.append("\(r.label)：慢松手头一帧速度 \(Int(first)) pt/s，手指 \(Int(release.pan)) pt/s")
                }
            }
        }
        print("VELO 慢松手：" + slow.joined(separator: "；"))
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "；"))
    }

    /// 对齐从静止起步：停在半行上、对齐接手时（拖着停住松手、减速途中按一下停住 0.12 s 后），头 20% 的时间里走的路程。
    /// 原来是 0.25 s 的三次缓出：头一帧就是平均速度的近 3 倍，头 20% 走掉一半（理论 0.49）；现在是从 0 加速的三次曲线（理论 0.10）。
    func testAlignmentStartsFromRest() async throws {
        let (host, scrollView, cellPt) = try await terminalRig()
        defer { host.close() }
        let log = OffsetLog(scrollView)
        defer { log.stop() }
        var problems: [String] = []
        let cases: [(String, CGFloat)] = [("拖着停住松手", 0.45), ("拖着停住松手", 0.6), ("减速中按下", 0.42), ("减速中按下", 0.55)]
        for (label, fraction) in cases {
            try await park(host, row: 300, plus: cellPt * fraction)
            let start = scrollView.contentOffset.y
            log.clear()
            log.tag = "after"
            if label == "拖着停住松手" {
                // UIKit 拖着停住松手：速度 0、提议的落点是原处、不减速。
                scrollView.delegate?.scrollViewWillBeginDragging?(scrollView)
                var target = scrollView.contentOffset
                scrollView.delegate?.scrollViewWillEndDragging?(scrollView, withVelocity: .zero, targetContentOffset: &target)
                scrollView.delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: false)
            } else {
                host.view.uTermTouchDownDuringMomentum()
            }
            try await Task.sleep(for: .milliseconds(700))
            let samples = log.samples
            let total = Double((samples.last?.y ?? start) - start)
            guard let first = samples.first, samples.count >= 4, total.magnitude > 1 else {
                problems.append("\(label) \(fraction)：没对齐（\(samples.count) 帧，走了 \(total) pt）")
                continue
            }
            // 时长从第一帧之前那一拍算起（第一帧写的已经是第一个 vsync 的位置）；对齐的整段时长 0.25 s。
            // 不按帧数算：UIKit 把 contentOffset 取整到 1/3 pt，尾巴上连着几帧不变，KVO 只记变了的那几帧。
            let frame = 1 / Double(max(1, UIScreen.main.maximumFramesPerSecond))
            let early = samples.filter { $0.time - first.time + frame <= 0.25 * 0.2 + 0.002 }
            let earlyFraction = Double((early.last?.y ?? start) - start) / total
            let steps = zip([start] + samples.map(\.y), samples.map(\.y)).map { Double($1 - $0) }
            print(String(format: "VELO 对齐 %@ 起点 +%.2f 行：%d 帧走 %.2f pt，头 20%% 时间走了 %.2f，逐帧 %@", label, fraction, samples.count,
                         total, earlyFraction, steps.map { String(format: "%.2f", $0) }.joined(separator: ",")))
            if earlyFraction > 0.25 { problems.append("\(label) \(fraction)：头 20% 的时间走了 \(String(format: "%.2f", earlyFraction))") }
            if steps.contains(where: { $0 * total < -0.01 }) { problems.append("\(label) \(fraction)：对齐途中往回走") }
            if !host.view.uTermScrollState.isAtRest { problems.append("\(label) \(fraction)：没停在整行上") }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "；"))
    }
}
