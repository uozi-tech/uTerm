import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// M16 第三轮：像素级平滑滚动（GhosttyKit 0023）在 iOS 真机上到底有没有按像素平移。
///
/// 不靠手势：和手指拖动同一个 C 入口（`ghostty_surface_mouse_scroll` + precision 位；手指拖动走
/// `scrollTouchContent` → `surface.sendMouseScroll(precision, momentum)`），每步喂几像素，每步等这个 surface
/// 交出新的一帧后截真画面（`snapshotImage()` = `drawHierarchy`，截的是渲染服务器上的 IOSurface 内容，
/// parity 探针已经核过它截得到 Ghostty 画面），用「逐行墨迹轮廓」的互相关求出画面相对上一步移了几像素。
/// 判定：按像素平移 = 绝大多数步的位移等于喂的像素；攒满一行才跳 = 大多数步位移 0，偶尔一次一整行。
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

    /// 走手指拖动的真实处理函数：伪造一个 `UIPanGestureRecognizer`，按 began → changed × n → ended 的顺序直接调
    /// GhosttyKit 的 `handleTouchScrollGesture:`（和 UIKit 投递手势时同一个 selector），里面的 `sendPointerPosition`、
    /// 惯性、吸附整行都照常跑。每个 changed 之后截一帧算位移；ended 之后再跟踪惯性 / 吸附那几帧。
    func testTouchScrollHandlerMovesByPixels() async throws {
        for inline in [true, false] {
            let rig = try await makeRig()
            let host = rig.host, sink = rig.sink, cellPx = rig.cellPx
            defer { host.close() }
            host.view.usesInlineTextSelection = inline
            let pan = FakePan()
            pan.fakeLocation = CGPoint(x: 200, y: 300)
            let selector = NSSelectorFromString("handleTouchScrollGesture:")
            XCTAssertTrue(host.view.responds(to: selector), "GhosttyKit 的拖动处理 selector 变了")
            func send(_ state: UIGestureRecognizer.State, dy: CGFloat = 0, velocity: CGFloat = 0) {
                pan.fakeState = state
                pan.fakeTranslation = CGPoint(x: 0, y: dy)
                pan.fakeVelocity = CGPoint(x: 0, y: velocity)
                pan.fakeLocation.y += dy
                _ = host.view.perform(selector, with: pan)
            }
            for (label, stepPt) in [("drag 5px", 5.0 / rig.scale), ("drag -3px", -3.0 / rig.scale)] {
                var previous = inkProfile(try await frame(host))
                send(.began)
                var shifts: [Int] = []
                var latency: [Double] = []
                for _ in 0..<20 {
                    let sentAt = CACurrentMediaTime()
                    send(.changed, dy: stepPt)
                    let image = try await frame(host)
                    if let shown = GhosttyPresentLog.read().times.first(where: { $0 >= sentAt }) { latency.append((shown - sentAt) * 1000) }
                    let profile = inkProfile(image)
                    shifts.append(shift(from: previous, to: profile, range: Int(cellPx) + 4).px)
                    previous = profile
                }
                // 抬手：没有速度 → 不起惯性，只吸附。跟踪 0.4 s 里的位移。
                send(.ended, velocity: 0)
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
                print(String(format: "SMOOTH handler inline=%@ %@ follow-ratio=%.3f input→frame p50=%.1fms max=%.1fms | ", "\(inline)", label, follow,
                             ProbeMetrics.percentile(latency, 0.5), latency.max() ?? 0)
                      + "shifts=\(shifts) pixel-steps=\(pixelSteps)/20 | after-release=\(after) net=\(after.reduce(0, +)) | scrollbar=\(sink.text)")
                XCTAssertGreaterThanOrEqual(pixelSteps, 16, "inline=\(inline) \(label)：手指拖动路径没有按像素平移（\(shifts)）")
            }
            // 甩：ended 带 1500 pt/s，惯性每帧的位移应当连续变小，而不是 0 / 整行交替。
            var previous = inkProfile(try await frame(host))
            send(.began)
            send(.changed, dy: 10 / rig.scale)
            send(.ended, velocity: 1500)
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

    /// 甩出去之后，惯性每一步都要按屏幕刷新率走（ProMotion 120 Hz）：0.5 s 里这个 surface 交的帧数、
    /// 以及截几张图看每帧位移不超过一行。修之前惯性 link 只有 60 Hz（真机日志每 16.7 ms 一步、每步约两行），
    /// 渲染 120 Hz 时同一位置连画两帧，手感就是一格一格地跳。
    func testFlingMomentumRunsAtDisplayRate() async throws {
        let rig = try await makeRig()
        let host = rig.host, cellPx = rig.cellPx
        defer { host.close() }
        let pan = FakePan()
        pan.fakeLocation = CGPoint(x: 200, y: 300)
        let selector = NSSelectorFromString("handleTouchScrollGesture:")
        func send(_ state: UIGestureRecognizer.State, dy: CGFloat = 0, velocity: CGFloat = 0) {
            pan.fakeState = state
            pan.fakeTranslation = CGPoint(x: 0, y: dy)
            pan.fakeVelocity = CGPoint(x: 0, y: velocity)
            _ = host.view.perform(selector, with: pan)
        }
        // 往回滚方向甩（离开活动区，不会撞底被清零）。
        send(.began)
        send(.changed, dy: 4)
        try await Task.sleep(for: .milliseconds(100))
        let startRow = Int(rig.sink.bar?.offset ?? 0)
        GhosttyPresentLog.reset()
        send(.ended, velocity: 1200)
        let t0 = CACurrentMediaTime()
        try await Task.sleep(for: .milliseconds(500))
        let times = GhosttyPresentLog.read().times.filter { $0 >= t0 && $0 <= t0 + 0.5 }
        let gaps = zip(times, times.dropFirst()).map { ($1 - $0) * 1000 }
        print(String(format: "SMOOTH fling presents-in-0.5s=%d gap-p50=%.1fms gap-max=%.1fms",
                     times.count, ProbeMetrics.percentile(gaps, 0.5), gaps.max() ?? 0))
        // 再截几张：惯性中段每帧位移不该超过一行。
        var previous = inkProfile(try XCTUnwrap(host.view.snapshotImage()?.cgImage))
        var shifts: [Int] = []
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(9))
            let profile = inkProfile(try XCTUnwrap(host.view.snapshotImage()?.cgImage))
            shifts.append(shift(from: previous, to: profile, range: Int(cellPx) + 4).px)
            previous = profile
        }
        print("SMOOTH fling mid shifts per ~9ms=\(shifts) cellPx=\(cellPx)")
        // 惯性滑多远、滑多久：等它停（含吸附），读视口行号的变化 × 行高；和 UIScrollView `.normal`（每毫秒 0.998、
        // 速度降到 50 pt/s 停）同一初速度的理论值比。
        let v0 = 1200.0, k = 0.998
        let theoryT = log(50 / v0) / log(k)                      // ms
        let theoryD = v0 / 1000 * (1 - pow(k, theoryT)) / -log(k)  // pt
        try await Task.sleep(for: .milliseconds(3000))
        let endRow = Int(rig.sink.bar?.offset ?? 0)
        let lastPresent = GhosttyPresentLog.read().times.last ?? t0
        let travelled = Double(startRow - endRow) * cellPx / rig.scale
        print(String(format: "SMOOTH fling v0=%.0fpt/s travelled≈%.0fpt (rows %d→%d, ±1 行) settled≈%.0fms | UIScrollView .normal theory %.0fpt %.0fms",
                     v0, travelled, startRow, endRow, (lastPresent - t0) * 1000, theoryD, theoryT))
        XCTAssertGreaterThanOrEqual(times.count, 45, "惯性没有按 120 Hz 出帧（0.5 s 只有 \(times.count) 帧）")
    }

    /// 回弹（0023 的 `ghostty_surface_set_overscroll` + UIScrollView 的橡皮筋公式）：停在底部（活动区）时继续往上推，
    /// 画面按 (1 − 1/(x·0.55/d + 1))·d 跟着走；松手后约半秒弹回原位。
    func testRubberBandAtBottomAndBounceBack() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 600))
        defer { host.close() }
        try await host.waitUntilReady()
        host.feedAndWait(TerminalSpikeCorpus.history(lines: 200, cols: host.grid.cols) + "$ ")
        try await Task.sleep(for: .milliseconds(300))
        let scale = Double(host.view.window?.screen.nativeScale ?? 3)
        let pan = FakePan()
        pan.fakeLocation = CGPoint(x: 200, y: 300)
        let selector = NSSelectorFromString("handleTouchScrollGesture:")
        func send(_ state: UIGestureRecognizer.State, dy: CGFloat = 0) {
            pan.fakeState = state
            pan.fakeTranslation = CGPoint(x: 0, y: dy)
            pan.fakeVelocity = .zero
            _ = host.view.perform(selector, with: pan)
        }
        let restImage = try await windowFrame(host)
        let rest = inkProfile(restImage)
        send(.began)
        for _ in 0..<5 { send(.changed, dy: -20) }       // 往上推 100 pt = 300 px（已在底部，全进回弹）
        let pulledImage = try await windowFrame(host)
        let pulled = inkProfile(pulledImage)
        let d = 600 * scale, x = 100 * scale
        let expected = -(1 - 1 / (x * 0.55 / d + 1)) * d
        let got = shift(from: rest, to: pulled, range: 260).px
        send(.ended)
        try await Task.sleep(for: .milliseconds(800))
        let backImage = try await windowFrame(host)
        let back = shift(from: rest, to: inkProfile(backImage), range: 260).px
        for (name, image) in [("rest", restImage), ("pulled", pulledImage), ("back", backImage)] {
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "rubber-\(name)"; attachment.lifetime = .keepAlways
            add(attachment)
        }
        print(String(format: "SMOOTH rubber-band pulled 300px → shown %dpx (UIScrollView 公式 %.0fpx) | 松手 0.8 s 后偏移 %dpx", got, expected, back))
        XCTAssertEqual(Double(got), expected, accuracy: 4, "回弹位移不符合橡皮筋公式")
        XCTAssertEqual(back, 0, "松手后没弹回原位")
    }
}

private final class ScrollSink: TerminalSurfaceScrollbarDelegate {
    var bar: TerminalScrollbar?
    var text: String { bar.map { "\($0.offset)/\($0.total)" } ?? "-" }
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) { bar = scrollbar }
}

/// 能由测试摆布状态、位移、速度的拖动手势（只给 `handleTouchScrollGesture:` 读）。
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
