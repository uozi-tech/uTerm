import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// M16 第十轮：user 说系统滚动版「丝滑很多，但是顶部底部中间会有反复横跳」。
///
/// 量「看得见的位置」会不会往回走：每次 CA 提交之后，从 Ghostty 画面层的 IOSurface 里解出引擎画到了哪一行（行首条码，
/// 同 `GhosttyOnScreenScrollTests`），再减去画面层的平移（回弹），就是这一帧屏幕顶边对着的内容位置。手势单向的时候它只该
/// 单向走；往回走 ≥ 2 px 就记一次「横跳」，按所处阶段归类（中段 / 跨进回弹那一下 / 回弹里 / 弹回）。
/// 手势按 UIKit 会做的事驱动滚动视图（display link 每帧改 contentOffset = 手指拖动；setContentOffset(animated:) 代替减速和弹回）。
/// 不是 UIKit 真减速，量的是「我们这一侧把位置交给引擎、把越界交给画面层」这一段会不会来回。
@MainActor
final class GhosttySystemScrollJitterTests: XCTestCase {
    override func setUp() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
        let deadline = CACurrentMediaTime() + 10
        while CACurrentMediaTime() < deadline,
              !UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    override func tearDown() async throws {
        UTermScrollTrace.isEnabled = false
    }

    struct Sample {
        let time: Double
        let engine: Double
        let translation: Double
        let offset: Double
        let phase: String
        /// 同一个单向手势里的样本组（拖到边、跨进回弹、回弹里算一组），往回走只在组内比。
        let group: Int
        var visible: Double { engine - translation }
    }

    /// 每次 CA 提交之后记一笔（画面层换没换都记：回弹只动平移，不换画面）。
    @MainActor
    final class Recorder {
        var samples: [Sample] = []
        var phase = "idle"
        var group = 0
        var read: (@MainActor () -> (engine: Double, translation: Double, offset: Double)?)?
        private var observer: CFRunLoopObserver?

        func start() {
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, 2_000_001
            ) { [weak self] _, _ in MainActor.assumeIsolated { self?.observe() } }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        func stop() {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }

        private func observe() {
            guard let value = read?() else { return }
            if let last = samples.last, abs(last.engine - value.engine) < 0.01, abs(last.translation - value.translation) < 0.01,
               abs(last.offset - value.offset) < 0.01 { return }
            samples.append(Sample(time: CACurrentMediaTime(), engine: value.engine, translation: value.translation,
                                  offset: value.offset, phase: phase, group: group))
        }
    }

    /// 每帧调一次 `step(dt)`，直到它返回 false。
    @MainActor
    final class Ticker: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private var step: (@MainActor (Double) -> Bool)?
        private var done: CheckedContinuation<Void, Never>?

        func run(_ step: @escaping @MainActor (Double) -> Bool) async {
            self.step = step
            last = 0
            await withCheckedContinuation { continuation in
                done = continuation
                let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        }

        @objc private func frame(_ link: CADisplayLink) {
            let dt = last == 0 ? link.duration : link.targetTimestamp - last
            last = link.targetTimestamp
            if step?(dt) != true {
                link.invalidate()
                self.link = nil
                done?.resume()
                done = nil
            }
        }
    }

    /// 往回走超过 1 物理像素的次数与最大幅度，按阶段分。`direction`：+1 = 位置该变大（往活动区），-1 = 该变小（往回滚顶）。
    private func reversals(_ samples: [Sample], direction: Double) -> [String: (count: Int, max: Double)] {
        var out: [String: (count: Int, max: Double)] = [:]
        for (a, b) in zip(samples, samples.dropFirst()) where a.group == b.group && a.phase != "idle" && b.phase != "idle" {
            let back = (a.visible - b.visible) * direction
            if back > 1 {
                let entry = out[b.phase] ?? (0, 0)
                out[b.phase] = (entry.count + 1, max(entry.max, back))
            }
        }
        return out
    }

    /// 两个 Ghostty 标签：一个像「装新包前就开着、重启后恢复出来的」那样先建好、滚到中间、再退到后台
    /// （setSurfaceVisible(false)，界面上透明且不接触摸，和工作区里非活动标签一样），另一个新开在前台。
    /// 前台拖、甩、到顶到底回弹的全过程：前台看得见的位置单向走、每帧不往回跳超过 1 px；后台那个的位置、手势、滚动视图一下都不动。
    func testBackgroundTabStaysOutOfTheWay() async throws {
        let size = CGSize(width: 440, height: 600)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = .dark
        window.isHidden = false
        defer { window.isHidden = true }

        func mount() -> GhosttyTerminalBridge {
            let bridge = GhosttyTerminalBridge(controller: GhosttyProbeHost.controller, frame: CGRect(origin: .zero, size: size))
            bridge.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(bridge.view)
            return bridge
        }
        func ready(_ bridge: GhosttyTerminalBridge) async throws {
            let deadline = CACurrentMediaTime() + 5
            // 等到画面开始吃字节（surface 建好、网格到位）：就绪之前喂的只进影子，要等一次回放才上屏。
            while CACurrentMediaTime() < deadline,
                  bridge.view.surface == nil || bridge.grid == nil || !bridge.isSurfaceReady || !bridge.outputPump.isFeedingSurface {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        // 「恢复出来的」那个：先建、喂内容、滚到中间、退到后台。
        let restored = mount()
        try await ready(restored)
        restored.feed(Data(GhosttyOnScreenScrollTests.barcodeHistory(lines: 500, cols: restored.grid?.cols ?? 60).utf8))
        restored.session.waitForPendingOutput()
        try await Task.sleep(for: .milliseconds(300))
        _ = restored.view.surface?.scrollToRow(180)
        try await Task.sleep(for: .milliseconds(300))
        restored.view.setSurfaceVisible(false)
        restored.view.alpha = 0
        restored.view.isUserInteractionEnabled = false
        let restoredScroll = try XCTUnwrap(restored.view.uTermSystemScrollView)
        XCTAssertFalse(restoredScroll.panGestureRecognizer.isEnabled, "后台标签的系统滚动手势应当停用")
        let restoredBefore = (restored.view.uTermScrollState, restoredScroll.contentOffset)

        // 新开的在前台。
        let fresh = mount()
        try await ready(fresh)
        fresh.feed(Data(GhosttyOnScreenScrollTests.barcodeHistory(lines: 600, cols: fresh.grid?.cols ?? 60).utf8))
        fresh.session.waitForPendingOutput()
        try await Task.sleep(for: .milliseconds(400))
        let view = fresh.view
        let scrollView = try XCTUnwrap(view.uTermSystemScrollView)
        XCTAssertTrue(view.uTermSystemPanWouldBegin)
        XCTAssertFalse(restored.view === view || restoredScroll === scrollView, "两个标签不该共用视图或滚动视图")
        let scale = Double(window.screen.nativeScale)
        let cell = try XCTUnwrap(view.uTermCellPixels)
        var decoder = GhosttyOnScreenScrollTests.BarcodeDecoder(cell: cell)
        let recorder = Recorder()
        recorder.read = {
            guard let layer = GhosttyOnScreenScrollTests.surfaceLayer(in: view.layer),
                  let engine = decoder.position(of: layer) else { return nil }
            return (engine, Double(view.layer.sublayerTransform.m42) * scale, Double(scrollView.contentOffset.y) * scale)
        }
        recorder.start()
        defer { recorder.stop() }
        let ticker = Ticker()
        let decel = EdgeDecelerator()

        /// 往一个方向拖（pt/s，正 = 内容往下 = 往回滚顶），拖过边 0.2 s 后松手，带速度时走减速，最后弹回。
        func gesture(_ label: String, speed: Double, release: Double) async {
            view.scrollViewWillBeginDragging(scrollView)
            recorder.group += 1
            recorder.phase = "\(label)-drag"
            var elapsed = 0.0
            var inBand = 0.0
            await ticker.run { dt in
                let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
                let o = scrollView.contentOffset.y
                let out = o < 0 || o > maxOffset
                scrollView.contentOffset.y = o - CGFloat(speed * dt) * (out ? 0.5 : 1)
                elapsed += dt
                if out { inBand += dt }
                return inBand < 0.2 && elapsed < 3
            }
            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            var target = CGPoint(x: 0, y: min(max(0, scrollView.contentOffset.y - CGFloat(release) / 1000 * 0.998 / 0.002), maxOffset))
            view.scrollViewWillEndDragging(scrollView, withVelocity: CGPoint(x: 0, y: -release / 1000), targetContentOffset: &target)
            view.scrollViewDidEndDragging(scrollView, willDecelerate: true)
            recorder.group += 1
            recorder.phase = "\(label)-release"
            decel.run(scrollView, to: target.y) { view.scrollViewDidEndDecelerating(scrollView) }
            try? await Task.sleep(for: .milliseconds(700))
            recorder.phase = "idle"
        }
        await gesture("up-slow", speed: 900, release: 0)
        await gesture("down-fast", speed: -6000, release: 0)
        await gesture("up-fast", speed: 6000, release: 0)
        // 中段甩：不拖到边，松手带速度。
        _ = view.surface?.scrollToRow(300)
        try await Task.sleep(for: .milliseconds(400))
        view.scrollViewWillBeginDragging(scrollView)
        recorder.group += 1
        recorder.phase = "fling-mid-drag"
        var elapsed = 0.0
        await ticker.run { dt in scrollView.contentOffset.y -= CGFloat(2000 * dt); elapsed += dt; return elapsed < 0.15 }
        var target = CGPoint(x: 0, y: scrollView.contentOffset.y - 2000 / 1000 * 0.998 / 0.002)
        view.scrollViewWillEndDragging(scrollView, withVelocity: CGPoint(x: 0, y: -2), targetContentOffset: &target)
        view.scrollViewDidEndDragging(scrollView, willDecelerate: true)
        recorder.phase = "fling-mid-glide"
        decel.run(scrollView, to: target.y) { view.scrollViewDidEndDecelerating(scrollView) }
        try await Task.sleep(for: .milliseconds(700))
        recorder.phase = "idle"

        // 方向：拖的那一段按速度符号；松手那一段是弹回或减速，按样本首尾判断（单向）。
        var bad: [String] = []
        for group in Set(recorder.samples.map(\.group)).sorted() {
            let samples = recorder.samples.filter { $0.group == group && $0.phase != "idle" }
            guard let first = samples.first, let last = samples.last, abs(last.visible - first.visible) > 2 else { continue }
            let direction: Double = last.visible > first.visible ? 1 : -1
            let r = reversals(samples, direction: direction)
            if !r.isEmpty { bad.append("\(first.phase)…: " + r.map { "\($0.key)=\($0.value.count)次/最大\(String(format: "%.0f", $0.value.max))px" }.joined(separator: " ")) }
        }
        let restoredAfter = (restored.view.uTermScrollState, restoredScroll.contentOffset)
        print("JITTER 多标签 前台样本 \(recorder.samples.count) 个；往回走：\(bad.isEmpty ? "无" : bad.joined(separator: "；"))")
        print("JITTER 多标签 后台标签 镜像 \(restoredBefore.0.row)+\(restoredBefore.0.fractionPixels) → \(restoredAfter.0.row)+\(restoredAfter.0.fractionPixels)，contentOffset \(restoredBefore.1.y) → \(restoredAfter.1.y)")
        XCTAssertTrue(bad.isEmpty, "前台标签看得见的位置往回走了：\(bad)")
        XCTAssertEqual(restoredBefore.0, restoredAfter.0, "后台标签的位置被动了")
        XCTAssertEqual(restoredBefore.1, restoredAfter.1, "后台标签的滚动视图被动了")
        restored.view.removeFromSuperview()
        fresh.view.removeFromSuperview()
    }

    func testVisiblePositionNeverJumpsBack() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 600))
        host.window.overrideUserInterfaceStyle = .dark
        defer { host.close() }
        try await host.waitUntilReady()
        host.feedAndWait(GhosttyOnScreenScrollTests.barcodeHistory(lines: 600, cols: host.grid.cols))
        try await Task.sleep(for: .milliseconds(400))
        let view = host.view
        let scale = Double(view.window?.screen.nativeScale ?? 3)
        let cell = try XCTUnwrap(view.uTermCellPixels)
        let scrollView = try XCTUnwrap(view.uTermSystemScrollView)
        XCTAssertTrue(view.uTermSystemPanWouldBegin)
        var decoder = GhosttyOnScreenScrollTests.BarcodeDecoder(cell: cell)
        let recorder = Recorder()
        recorder.read = {
            guard let layer = GhosttyOnScreenScrollTests.surfaceLayer(in: view.layer),
                  let engine = decoder.position(of: layer) else { return nil }
            return (engine, Double(view.layer.sublayerTransform.m42) * scale, Double(scrollView.contentOffset.y) * scale)
        }
        recorder.start()
        defer { recorder.stop() }
        let ticker = Ticker()
        let decel = EdgeDecelerator()
        UTermScrollTrace.isEnabled = true

        // 1. 从中段慢拖、快拖往回滚顶走（内容往下，位置变小），一路拖过顶进回弹，再松手弹回。
        _ = view.surface?.scrollToRow(40)
        try await Task.sleep(for: .milliseconds(300))
        for speed in [600.0, 2400.0] {           // pt/s
            _ = view.surface?.scrollToRow(40)
            try await Task.sleep(for: .milliseconds(300))
            view.scrollViewWillBeginDragging(scrollView)
            recorder.group += 1
            recorder.phase = "drag-mid@\(Int(speed))"
            var crossed = false
            var inBand = 0.0
            await ticker.run { dt in
                let before = scrollView.contentOffset.y
                // UIKit 拖过界时位移打折（橡皮筋）；这里照 UIScrollView 的公式简化成越界部分走一半。
                let step = speed * dt
                scrollView.contentOffset.y = before > 0 ? before - step : before - step * 0.5
                if scrollView.contentOffset.y <= 0 {
                    if !crossed { crossed = true; recorder.phase = "cross-top@\(Int(speed))" } else { recorder.phase = "band-top@\(Int(speed))" }
                    inBand += dt
                }
                return inBand < 0.25
            }
            var target = CGPoint.zero
            view.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
            view.scrollViewDidEndDragging(scrollView, willDecelerate: true)
            recorder.group += 1
            recorder.phase = "bounce-top@\(Int(speed))"
            decel.run(scrollView, to: target.y) { view.scrollViewDidEndDecelerating(scrollView) }
            try await Task.sleep(for: .milliseconds(700))
            recorder.phase = "idle"
        }
        let topSamples = recorder.samples
        let upward = reversals(topSamples.filter { !$0.phase.hasPrefix("bounce") }, direction: -1)
        let bounceTop = reversals(topSamples.filter { $0.phase.hasPrefix("bounce") }, direction: 1)

        // 2. 回到底部附近，往活动区拖过底进回弹，再弹回。
        recorder.samples.removeAll()
        for speed in [600.0, 2400.0] {
            _ = view.surface?.performBindingAction("scroll_to_bottom")
            try await Task.sleep(for: .milliseconds(200))
            _ = view.surface?.scrollToRow(UInt(max(0, 600 - host.grid.rows - 30)))
            try await Task.sleep(for: .milliseconds(400))
            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            view.scrollViewWillBeginDragging(scrollView)
            recorder.group += 1
            recorder.phase = "drag-mid-down@\(Int(speed))"
            var crossed = false
            var inBand = 0.0
            await ticker.run { dt in
                let before = scrollView.contentOffset.y
                let step = speed * dt
                scrollView.contentOffset.y = before < maxOffset ? before + step : before + step * 0.5
                if scrollView.contentOffset.y >= maxOffset {
                    if !crossed { crossed = true; recorder.phase = "cross-bottom@\(Int(speed))" } else { recorder.phase = "band-bottom@\(Int(speed))" }
                    inBand += dt
                }
                return inBand < 0.25
            }
            var target = CGPoint(x: 0, y: maxOffset)
            view.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
            view.scrollViewDidEndDragging(scrollView, willDecelerate: true)
            recorder.group += 1
            recorder.phase = "bounce-bottom@\(Int(speed))"
            decel.run(scrollView, to: target.y) { view.scrollViewDidEndDecelerating(scrollView) }
            try await Task.sleep(for: .milliseconds(700))
            recorder.phase = "idle"
        }
        let bottomSamples = recorder.samples
        let downward = reversals(bottomSamples.filter { !$0.phase.hasPrefix("bounce") }, direction: 1)
        let bounceBottom = reversals(bottomSamples.filter { $0.phase.hasPrefix("bounce") }, direction: -1)

        // 3. 中段长距离滑行（UIKit 的 setContentOffset 动画，节奏接近减速）。
        recorder.samples.removeAll()
        _ = view.surface?.scrollToRow(300)
        try await Task.sleep(for: .milliseconds(400))
        recorder.group += 1
        recorder.phase = "glide-mid"
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y - CGFloat(cell.height) * 40 / CGFloat(scale)), animated: true)
        try await Task.sleep(for: .milliseconds(900))
        recorder.phase = "idle"
        let glide = reversals(recorder.samples, direction: -1)

        // 4. 停在半行上松手（起对齐动画），动画还没走完手指就又往回滚顶方向拖起来。修之前对齐动画和手指同时写 contentOffset。
        recorder.samples.removeAll()
        _ = view.surface?.scrollToRow(300)
        try await Task.sleep(for: .milliseconds(400))
        var catchSamples: [Sample] = []
        for attempt in 0..<4 {
            view.scrollViewWillBeginDragging(scrollView)
            // 往活动区拖半行多一点再松手：落点离下一行更近，对齐动画往活动区走，接着手指往反方向拖。
            scrollView.contentOffset.y += CGFloat(cell.height) * 0.7 / CGFloat(scale)
            view.scrollViewDidEndDragging(scrollView, willDecelerate: false)
            try await Task.sleep(for: .milliseconds(30 + attempt * 25))
            view.scrollViewWillBeginDragging(scrollView)
            recorder.group += 1
            recorder.phase = "catch-align#\(attempt)"
            var elapsed = 0.0
            await ticker.run { dt in
                scrollView.contentOffset.y -= 300 * dt
                elapsed += dt
                return elapsed < 0.35
            }
            recorder.phase = "idle"
            var target = scrollView.contentOffset
            view.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
            view.scrollViewDidEndDragging(scrollView, willDecelerate: false)
            try await Task.sleep(for: .milliseconds(500))
            catchSamples += recorder.samples
            recorder.samples.removeAll()
        }
        let caught = reversals(catchSamples, direction: -1)
        print("JITTER 对齐动画中接着拖 头 24 帧：" + catchSamples.prefix(24).map {
            String(format: "%@ e=%.0f t=%.0f v=%.0f o=%.1f", $0.phase, $0.engine, $0.translation, $0.visible, $0.offset)
        }.joined(separator: " | "))
        let writes = UTermScrollTrace.drain().filter { $0.kind == "sv-write" }.map { Int($0.value) }

        func line(_ r: [String: (count: Int, max: Double)]) -> String {
            r.isEmpty ? "无" : r.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.count)次/最大\(String(format: "%.0f", $0.value.max))px" }.joined(separator: " ")
        }
        print("JITTER scale=\(scale) cellPx=\(Int(cell.height)) samples top=\(topSamples.count) bottom=\(bottomSamples.count)")
        print("JITTER 往顶拖（含跨进回弹）往回走：\(line(upward))")
        print("JITTER 顶部弹回 往回走：\(line(bounceTop))")
        print("JITTER 往底拖（含跨进回弹）往回走：\(line(downward))")
        print("JITTER 底部弹回 往回走：\(line(bounceBottom))")
        print("JITTER 中段滑行 往回走：\(line(glide))")
        print("JITTER 对齐动画中接着拖 往回走：\(line(caught))")
        print("JITTER 我们主动写的次数（原因码→次数）：\(Dictionary(grouping: writes, by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key })")
        // 跨进回弹那几帧：逐帧打出来看（引擎位置、平移、看得见的位置、滚动视图位置）。
        for samples in [topSamples, bottomSamples] {
            if let index = samples.firstIndex(where: { $0.phase.hasPrefix("cross") && $0.phase.hasSuffix("2400") }) {
                let window = samples[max(0, index - 4)..<min(samples.count, index + 8)]
                print("JITTER 跨边那几帧：" + window.map { String(format: "%@ e=%.0f t=%.0f v=%.0f o=%.0f", $0.phase, $0.engine, $0.translation, $0.visible, $0.offset) }.joined(separator: " | "))
            }
        }
        for (label, r) in [("往顶拖", upward), ("顶部弹回", bounceTop), ("往底拖", downward), ("底部弹回", bounceBottom), ("中段滑行", glide),
                           ("对齐动画中接着拖", caught)] {
            XCTAssertTrue(r.isEmpty, "\(label)：看得见的位置往回走了 \(line(r))")
        }
    }
}
