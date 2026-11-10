import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// M16 第三轮：像素级平滑滚动（GhosttyKit 0023）在 iOS 真机上到底有没有按像素平移。
///
/// 不靠手势：和手指拖动同一个 C 入口（`ghostty_surface_mouse_scroll` + precision 位；系统滚动的 `scrollViewDidScroll`
/// 和自写的拖动最后都是 `surface.sendMouseScroll(precision, momentum)`），每步喂几像素，每步等这个 surface
/// 交出新的一帧后截真画面（`snapshotImage()` = `drawHierarchy`，截的是渲染服务器上的 IOSurface 内容，
/// parity 探针已经核过它截得到 Ghostty 画面），用「逐行墨迹轮廓」的互相关求出画面相对上一步移了几像素。
/// 判定：按像素平移 = 绝大多数步的位移等于喂的像素；攒满一行才跳 = 大多数步位移 0，偶尔一次一整行。
///
/// 后三条原来是伪造 pan 硬调 `handleTouchScrollGesture:`，在有回滚的普通屏上量本地包里自写的拖动 / 惯性 / 橡皮筋回弹。
/// 那套自写滚动物理已经整套删掉（单指滚回滚区恒归系统 UIScrollView），三条各自改成：
/// - `testTouchScrollHandlerMovesByPixels`：同一条判据（手指走几像素、画面走几像素）改在系统路径上核（`EdgeSystemFinger`）；
/// - `testFlingMomentumRunsAtDisplayRate`：同一条判据（惯性 link 按屏幕刷新率走）改核留下来的那条自写惯性（备用屏）；
/// - `testRubberBandAtBottomAndBounceBack`：橡皮筋公式现在是 UIKit 的，改核我们这一侧——越界多少、画面层就平移多少，松手弹回 0。
@MainActor
final class GhosttySmoothScrollPixelTests: XCTestCase {
    override func setUp() async throws {
        // 别让手机在测试中途自动锁屏（锁屏后 Ghostty 不画，截到的是空白，读数全错）。
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// 每一像素行的墨迹量（与底色的差之和），取画面中间一条竖带。
    private func inkProfile(_ image: CGImage) -> [Double] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bg = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
        return (0..<height).map { y in
            var sum = 0
            for x in stride(from: width / 10, to: width * 9 / 10, by: 2) {
                let i = (y * width + x) * 4
                sum += abs(Int(pixels[i]) - bg.0) + abs(Int(pixels[i + 1]) - bg.1) + abs(Int(pixels[i + 2]) - bg.2)
            }
            return Double(sum)
        }
    }

    /// `b` 相对 `a` 往下移了几像素（负 = 往上），在 ±range 里找差最小的位移。
    private func shift(from a: [Double], to b: [Double], range: Int) -> (px: Int, residual: Double) {
        var best = (px: 0, residual: Double.infinity)
        let n = a.count
        for s in -range...range {
            var sum = 0.0, count = 0
            for y in max(0, s) + range..<min(n, n + s) - range {
                let d = a[y - s] - b[y]
                sum += d * d; count += 1
            }
            let r = count > 0 ? sum / Double(count) : .infinity
            if r < best.residual { best = (s, r) }
        }
        return best
    }

    private struct Rig {
        let host: GhosttyProbeHost
        let sink: ScrollSink
        let cellPx: Double
        let scale: Double
    }

    /// 整屏宽 440×600，400 行各不相同的回滚，先往回滚里推 40 行离开活动区。
    private func makeRig() async throws -> Rig {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 600))
        try await host.waitUntilReady()
        let sink = ScrollSink()
        host.view.delegate = sink
        host.feedAndWait(TerminalSpikeCorpus.history(lines: 400, cols: host.grid.cols) + "$ ")
        try await Task.sleep(for: .milliseconds(300))
        let scale = Double(host.view.window?.screen.nativeScale ?? 3)
        let cellPx = (Double(host.view.bounds.height) * scale / Double(host.grid.rows)).rounded(.down)
        for _ in 0..<40 { host.view.sendMouseScroll(x: 0, y: cellPx, mods: TerminalScrollModifiers(precision: true)) }
        try await Task.sleep(for: .milliseconds(400))
        print("SMOOTH start scrollbar=\(sink.text) rows=\(host.grid.rows) cellPx≈\(cellPx) scale=\(scale) inlineSelection=\(host.view.usesInlineTextSelection)")
        return Rig(host: host, sink: sink, cellPx: cellPx, scale: scale)
    }

    /// 等这个 surface 交出新的一帧，再截真画面。
    private func frame(_ host: GhosttyProbeHost) async throws -> CGImage {
        let before = GhosttyPresentLog.read().times.count
        let t0 = CACurrentMediaTime()
        while GhosttyPresentLog.read().times.count == before, CACurrentMediaTime() - t0 < 0.25 {
            try await Task.sleep(for: .milliseconds(4))
        }
        try await Task.sleep(for: .milliseconds(20))
        return try XCTUnwrap(host.view.snapshotImage()?.cgImage)
    }

    /// 整扇窗口的合成结果（回弹靠平移图层，视图自己的 drawHierarchy 不一定带上 sublayerTransform，截窗口才是屏幕上那一帧）。
    private func windowFrame(_ host: GhosttyProbeHost) async throws -> CGImage {
        try await Task.sleep(for: .milliseconds(30))
        // 按屏幕的 nativeScale 出图：回弹量按物理像素算，Duo 内屏是 2.807 px/pt（UIScreen.scale 是 3），
        // 默认格式按 3 出图会把位移多量 7%。
        let format = UIGraphicsImageRendererFormat()
        format.scale = host.window.screen.nativeScale
        let renderer = UIGraphicsImageRenderer(bounds: host.window.bounds, format: format)
        let image = renderer.image { _ in host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: false) }
        return try XCTUnwrap(image.cgImage)
    }

    /// 直接调 C 入口（`sendMouseScroll` + precision）：引擎那一层是不是按像素画。
    func testPrecisionScrollMovesByPixels() async throws {
        let rig = try await makeRig()
        let host = rig.host, sink = rig.sink, cellPx = rig.cellPx
        defer { host.close() }
        func frame() async throws -> CGImage { try await self.frame(host) }

        for (label, mods) in [("precision", TerminalScrollModifiers(precision: true)),
                              ("precision+momentum", TerminalScrollModifiers(precision: true, momentum: .changed))] {
            for step in [5.0, -5.0, 3.0] {
                var previous = inkProfile(try await frame())
                var shifts: [Int] = []
                var offsets: [String] = []
                var presentsWithoutMove = 0
                for _ in 0..<24 {
                    let presents = GhosttyPresentLog.read().times.count
                    host.view.sendMouseScroll(x: 0, y: step, mods: mods)
                    let image = try await frame()
                    if GhosttyPresentLog.read().times.count == presents { presentsWithoutMove += 1 }
                    let profile = inkProfile(image)
                    shifts.append(shift(from: previous, to: profile, range: Int(cellPx) + 4).px)
                    offsets.append(sink.text)
                    previous = profile
                }
                let pixelSteps = shifts.filter { abs(abs($0) - abs(Int(step))) <= 1 }.count
                let zero = shifts.filter { $0 == 0 }.count
                let rowJumps = shifts.filter { abs(abs($0) - Int(cellPx)) <= 2 }.count
                print("SMOOTH \(label) step=\(step)px shifts=\(shifts) | pixel-steps=\(pixelSteps) zero=\(zero) row-jumps=\(rowJumps) no-new-frame=\(presentsWithoutMove) | scrollbar \(offsets.first ?? "") → \(offsets.last ?? "")")
                let attachment = XCTAttachment(image: UIImage(cgImage: try await frame()))
                attachment.name = "smooth-\(label)-\(step)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertGreaterThanOrEqual(pixelSteps, 18, "\(label) 每步 \(step)px：画面没有按像素平移（位移 \(shifts)）")
            }
        }
    }

    /// 手指拖动（系统滚动那条路径）：UIScrollView 的 contentOffset 每走几像素，画面就平移几像素。
    /// 按 UIKit 会做的事驱动 GhosttyKit 借来的滚动视图（`EdgeSystemFinger`：began → 每步改 contentOffset → 松手），
    /// 每一步之后截一帧算位移；松手之后再跟踪对齐整行 / 减速那几帧。用例名里的 handler 是沿用下来的
    ///（原来硬调 `handleTouchScrollGesture:`）。
    func testTouchScrollHandlerMovesByPixels() async throws {
        for inline in [true, false] {
            let rig = try await makeRig()
            let host = rig.host, sink = rig.sink, cellPx = rig.cellPx
            defer { host.close() }
            host.view.usesInlineTextSelection = inline
            let finger = try EdgeSystemFinger(view: host.view)
            XCTAssertTrue(host.view.uTermSystemPanWouldBegin, "inline=\(inline)：有回滚的普通屏，单指拖动应当归系统滚动")
            for (label, stepPt) in [("drag 5px", 5.0 / rig.scale), ("drag -3px", -3.0 / rig.scale)] {
                var previous = inkProfile(try await frame(host))
                finger.begin()
                var shifts: [Int] = []
                var latency: [Double] = []
                for _ in 0..<20 {
                    let sentAt = CACurrentMediaTime()
                    finger.move(CGFloat(stepPt))
                    let image = try await frame(host)
                    if let shown = GhosttyPresentLog.read().times.first(where: { $0 >= sentAt }) { latency.append((shown - sentAt) * 1000) }
                    let profile = inkProfile(image)
                    shifts.append(shift(from: previous, to: profile, range: Int(cellPx) + 4).px)
                    previous = profile
                }
                // 抬手：没有速度 → 不减速，只对齐整行。跟踪 0.4 s 里的位移。
                finger.end(velocity: 0)
                var after: [Int] = []
                let t0 = CACurrentMediaTime()
                while CACurrentMediaTime() - t0 < 0.4 {
                    let profile = inkProfile(try await frame(host))
                    after.append(shift(from: previous, to: profile, range: Int(cellPx) + 4).px)
                    previous = profile
                }
                let want = Int((stepPt * rig.scale).rounded())
                let pixelSteps = shifts.filter { abs($0 - want) <= 1 }.count
                let follow = Double(shifts.reduce(0, +)) / (stepPt * rig.scale * 20)
                let state = host.view.uTermScrollState
                print(String(format: "SMOOTH handler inline=%@ %@ follow-ratio=%.3f input→frame p50=%.1fms max=%.1fms | ", "\(inline)", label, follow,
                             ProbeMetrics.percentile(latency, 0.5), latency.max() ?? 0)
                      + "shifts=\(shifts) pixel-steps=\(pixelSteps)/20 | after-release=\(after) net=\(after.reduce(0, +)) rest=\(state.row)+\(state.fractionPixels)px | scrollbar=\(sink.text)")
                // 「按像素走」的判据：没有哪一步跳了整行（按行滚的实现是一串 0 夹着整行），而且总量跟得上手指。
                // 不再要求「20 步里 16 步正好是 want」：系统路径上 UIKit 把 contentOffset 取整到 1/3 pt，Duo 内屏的倍率是 2.807，
                // 一步 3 px 的手指位移落到屏上是 2 / 3 / 4 px 交替；截图偶尔比换帧早一拍，记成 0 和 2×want 一对（真机实测如此）。
                let largest = shifts.map(abs).max() ?? 0
                XCTAssertLessThanOrEqual(largest, 2 * abs(want) + 2, "inline=\(inline) \(label)：有一步跳得太多，不是按像素平移（\(shifts)）")
                XCTAssertLessThan(largest, Int(cellPx) - 2, "inline=\(inline) \(label)：有一步跳了整行（\(shifts)）")
                XCTAssertEqual(follow, 1, accuracy: 0.15, "inline=\(inline) \(label)：屏上的总位移没跟上手指（\(shifts)）")
                XCTAssertGreaterThanOrEqual(shifts.filter { $0 != 0 }.count, 10, "inline=\(inline) \(label)：大多数步子没动（\(shifts)）")
            }
            // 甩：松手带 1500 pt/s，减速每帧的位移应当连续变小，而不是 0 / 整行交替。
            var previous = inkProfile(try await frame(host))
            finger.begin()
            finger.move(10 / rig.scale)
            finger.end(velocity: 1500, seconds: EdgeSystemFinger.flingSeconds)
            var fling: [Int] = []
            let t0 = CACurrentMediaTime()
            while CACurrentMediaTime() - t0 < 1.2 {
                let profile = inkProfile(try await frame(host))
                fling.append(shift(from: previous, to: profile, range: Int(cellPx) + 4).px)
                previous = profile
            }
            let rowSized = fling.filter { abs(abs($0) - Int(cellPx)) <= 2 }.count
            let small = fling.filter { $0 != 0 && abs($0) < Int(cellPx) - 2 }.count
            print("SMOOTH handler inline=\(inline) fling shifts=\(fling) | sub-row=\(small) row-sized=\(rowSized) | scrollbar=\(sink.text)")
        }
    }

    /// 自写的惯性每一步都要按屏幕刷新率走（ProMotion 120 Hz）：0.5 s 里惯性 link 回调了几次。
    /// 修之前这个 link 没设帧率、只有 60 Hz（真机日志每 16.7 ms 一步、每步约两行），渲染 120 Hz 时同一位置连画两帧，
    /// 手感就是一格一格地跳。
    ///
    /// 这条 link 现在只给不归系统滚动的那几种拖动用（备用屏、没有回滚、程序抓鼠标、双指）；有回滚的普通屏松手后的减速是
    /// UIKit 自己的 display link，测试驱动不了也不归我们管。所以改在备用屏上量：less / vim 没抓鼠标时，位移由引擎换成
    /// 方向键发给程序，松手后按速度衰减（UIScrollView `.normal`，每毫秒 0.998，慢到 50 pt/s 停）。顺带核它滑多远。
    func testFlingMomentumRunsAtDisplayRate() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 600))
        defer { host.close() }
        try await host.waitUntilReady()
        host.feedAndWait("\u{1B}[?1049h\u{1B}[2J\u{1B}[Halt screen\r\nline 2\r\n")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(host.view.uTermSystemPanWouldBegin, "备用屏没有回滚：拖动归自写路径")
        let scale = Double(host.view.window?.screen.nativeScale ?? 3)
        let cellPt = Double(try XCTUnwrap(host.view.uTermCellPixels).height) / scale
        let pan = FakePan()
        pan.fakeLocation = CGPoint(x: 200, y: 300)
        let selector = NSSelectorFromString("handleTouchScrollGesture:")
        XCTAssertTrue(host.view.responds(to: selector), "GhosttyKit 的拖动处理 selector 变了")
        func send(_ state: UIGestureRecognizer.State, dy: CGFloat = 0, velocity: CGFloat = 0) {
            pan.fakeState = state
            pan.fakeTranslation = CGPoint(x: 0, y: dy)
            pan.fakeVelocity = CGPoint(x: 0, y: velocity)
            _ = host.view.perform(selector, with: pan)
        }
        func arrows() -> Int {
            let input = (host.bridge.inputLog ?? []).map { String(decoding: $0, as: UTF8.self) }.joined()
            return input.components(separatedBy: "\u{1B}[A").count - 1
        }
        send(.began)
        send(.changed, dy: 4)
        try await Task.sleep(for: .milliseconds(100))
        host.bridge.inputLog = []
        UTermScrollTrace.isEnabled = true
        defer { UTermScrollTrace.isEnabled = false }
        let v0 = 1200.0
        send(.ended, velocity: CGFloat(v0))
        let t0 = CACurrentMediaTime()
        XCTAssertTrue(host.view.uTermScrollState.isGliding, "\(v0) pt/s 松手应当起惯性")
        try await Task.sleep(for: .milliseconds(500))
        let steps = UTermScrollTrace.drain().filter { $0.kind == "momentum" && $0.time >= t0 && $0.time <= t0 + 0.5 }
        let gaps = zip(steps, steps.dropFirst()).map { ($1.time - $0.time) * 1000 }
        print(String(format: "SMOOTH fling momentum-steps-in-0.5s=%d gap-p50=%.1fms gap-max=%.1fms",
                     steps.count, ProbeMetrics.percentile(gaps, 0.5), gaps.max() ?? 0))
        // 滑多远、滑多久：等它停，数程序收到的上箭头 × 行高；和 UIScrollView `.normal`（每毫秒 0.998、速度降到 50 pt/s 停）
        // 同一初速度的理论值比。
        let k = 0.998
        let theoryT = log(50 / v0) / log(k)                      // ms
        let theoryD = v0 / 1000 * (1 - pow(k, theoryT)) / -log(k)  // pt
        var stoppedAt: Double?
        while CACurrentMediaTime() - t0 < 4 {
            try await Task.sleep(for: .milliseconds(20))
            if !host.view.uTermScrollState.isGliding { stoppedAt = CACurrentMediaTime() - t0; break }
        }
        try await Task.sleep(for: .milliseconds(200))
        let travelled = Double(arrows()) * cellPt
        print(String(format: "SMOOTH fling v0=%.0fpt/s travelled≈%.0fpt (%d 个上箭头 × %.2fpt) stopped≈%.0fms | UIScrollView .normal theory %.0fpt %.0fms",
                     v0, travelled, arrows(), cellPt, (stoppedAt ?? -1) * 1000, theoryD, theoryT))
        XCTAssertNotNil(stoppedAt, "惯性一直没停")
        // 距离：衰减按每帧的标称时长算，主线程卡掉的拍不补，机器忙时会短一些，下限放宽。
        XCTAssertGreaterThan(travelled, theoryD * 0.5, "备用屏松手后的惯性滑得太近（没起来或者停早了）")
        XCTAssertLessThan(travelled, theoryD * 1.3, "备用屏松手后的惯性滑得太远")
        XCTAssertGreaterThanOrEqual(steps.count, 45, "惯性没有按 120 Hz 走（0.5 s 只有 \(steps.count) 步）")
    }

    /// 回弹（系统滚动那条路径）：停在底部（活动区）时继续往上推，UIScrollView 的 contentOffset 越过底多少，画面就整体
    /// 平移多少（平移的是宿主图层，不让渲染器为它出帧）；松手后回到原位。橡皮筋公式本身现在是 UIKit 的，测试里直接给越界量。
    func testRubberBandAtBottomAndBounceBack() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 600))
        defer { host.close() }
        try await host.waitUntilReady()
        host.feedAndWait(TerminalSpikeCorpus.history(lines: 200, cols: host.grid.cols) + "$ ")
        try await Task.sleep(for: .milliseconds(300))
        let scale = Double(host.view.window?.screen.nativeScale ?? 3)
        let finger = try EdgeSystemFinger(view: host.view)
        XCTAssertTrue(host.view.uTermSystemPanWouldBegin, "有回滚的普通屏：单指拖动应当归系统滚动")
        let restImage = try await windowFrame(host)
        let rest = inkProfile(restImage)
        finger.begin()
        for _ in 0..<5 { finger.move(-12) }              // 已在底部：contentOffset 越过底 60 pt
        let pulledImage = try await windowFrame(host)
        let pulled = inkProfile(pulledImage)
        let expected = -60 * scale
        let got = shift(from: rest, to: pulled, range: 260).px
        XCTAssertEqual(host.view.uTermScrollState.overscrollPixels, expected, accuracy: 1.5, "越界量没记对")
        finger.end(velocity: 0)
        try await Task.sleep(for: .milliseconds(800))
        let backImage = try await windowFrame(host)
        let back = shift(from: rest, to: inkProfile(backImage), range: 260).px
        for (name, image) in [("rest", restImage), ("pulled", pulledImage), ("back", backImage)] {
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "rubber-\(name)"; attachment.lifetime = .keepAlways
            add(attachment)
        }
        print(String(format: "SMOOTH rubber-band 越过底 %.0fpx → 画面平移 %dpx | 松手 0.8 s 后偏移 %dpx", -expected, got, back))
        XCTAssertEqual(Double(got), expected, accuracy: 4, "越界多少，画面就该平移多少")
        XCTAssertEqual(back, 0, "松手后没弹回原位")
        XCTAssertTrue(host.view.uTermScrollState.isAtRest, "弹回之后没停稳 \(host.view.uTermScrollState)")
    }
}

private final class ScrollSink: TerminalSurfaceScrollbarDelegate {
    var bar: TerminalScrollbar?
    var text: String { bar.map { "\($0.offset)/\($0.total)" } ?? "-" }
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) { bar = scrollbar }
}

/// 能由测试摆布状态、位移、速度的拖动手势（只给 `handleTouchScrollGesture:` 读；备用屏那条自写拖动用）。
private final class FakePan: UIPanGestureRecognizer {
    var fakeState: UIGestureRecognizer.State = .possible
    var fakeTranslation: CGPoint = .zero
    var fakeVelocity: CGPoint = .zero
    var fakeLocation: CGPoint = .zero

    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set { fakeState = newValue }
    }
    override var numberOfTouches: Int { 1 }
    override func translation(in view: UIView?) -> CGPoint { fakeTranslation }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) { fakeTranslation = translation }
    override func velocity(in view: UIView?) -> CGPoint { fakeVelocity }
    override func location(in view: UIView?) -> CGPoint { fakeLocation }
}
