import GhosttyTerminal
import IOSurface
import ObjectiveC
import os
import QuartzCore
import SwiftData
import SwiftTerm
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// M16 第八轮：按「真正上玻璃」给滚动打分用的被测端。
///
/// 前七轮量的是 CA 提交时的画面，量不到提交之后 render server 合成、换上屏的那一段。这里只负责「做动作 + 记 App 侧的账」，
/// 上玻璃的时刻由外面的 `xctrace`（Animation Hitches 模板，系统级）录：每个 vsync、每次换屏（swap）、每帧的生命周期。
/// 两边用同一个时钟（mach absolute time：这里的 `CACurrentMediaTime()`，trace 里 `time-info` 表给出起点），
/// 由 `scratchpad/ios-measure/r8/glass_score.py` 对起来打分。
///
/// 一次只跑一个被测对象（环境变量 `UTERM_GLASS_SUBJECT`），每个对象同一套动作：
/// 6k / 12k / 20k px/s 各甩一次，无输出、有 Claude 式输出（每 100 ms 一帧）各一遍，方向交替。
/// - `ghostty-sync`：整个工作区界面里的 Ghostty 标签，默认行为（引擎 wakeup 也在主线程同步重画，第五轮）；
/// - `ghostty-free`：同上，「渲染不同步」打开（第六轮）；
/// - `swiftterm`：整个工作区界面里的 SwiftTerm 标签（UIScrollView 子类，自己在 `draw(_:)` 里画字）；
/// - `uiscrollview`：一个普通 UIScrollView（400 行 UILabel），内容由合成器平移——「满分」基准。
/// Ghostty 的惯性是它自己的（伪造 pan 调 `handleTouchScrollGesture:`，之后全是 display link 驱动的真实代码）。
/// 后两个没有手指起不了 UIKit 的减速（伪造 pan 调 `handlePan:` 试过不行），改由 display link 每拍按**同一条**
/// 三次缓出曲线设 contentOffset（按物理像素取整）：和 UIScrollView 自己减速是同一个机制（主线程 display link 回调里改
/// bounds，本轮 runloop 末尾 CA 提交），而且四个对象走的是同一条位移曲线，可以直接叠着比。
///
/// 输出（stdout，由脚本解析）：
/// - `GLASS-META …`：屏幕倍率、格高等；
/// - `GLASS-READY`：准备好了，等外面开始录（`.dynamicTracing` 的 signpost 被打开 = Instruments 在录）；
/// - `GLASS-FLING {…}`、`GLASS-T …`（每拍：目标 vsync 时刻、这一拍想显示的位置）、`GLASS-C …`（每次 CA 提交：时刻、画面里的位置）；
/// - `GLASS-DONE`。
@MainActor
final class ScrollGlassTraceTests: XCTestCase {
    typealias OnScreen = GhosttyOnScreenScrollTests

    nonisolated static let subsystem = "com.uozi.uTerm.glass"
    nonisolated static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    nonisolated static let tracingProbe = OSSignposter(logHandle: OSLog(subsystem: subsystem, category: .dynamicTracing))

    override func setUp() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func tearDown() async throws {
        UTermScrollTrace.isEnabled = false
        UTermScrollTrace.legacyWakeupSyncDraw = false
        restoreDraw?()
        restoreDraw = nil
    }

    // MARK: - App 侧的账

    /// 每次 CA 提交之后读一次「画面里的滚动位置」，变了就记一笔（时刻、位置）。不带自己的 display link，不影响刷新率。
    @MainActor
    final class CommitLog {
        private(set) var commits: [(time: Double, position: Double)] = []
        var read: (@MainActor () -> Double?)?
        private var observer: CFRunLoopObserver?
        private var last: Double?

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

        func reset() { commits.removeAll() }

        private func observe() {
            guard let value = read?() else { return }
            if let last, abs(last - value) < 0.01 { return }
            last = value
            let now = CACurrentMediaTime()
            commits.append((now, value))
            // 核对两边时钟用：trace 的 os-signpost 表里能看到这条，消息里是这边的时刻。
            let text = String(format: "%.6f %.1f", now, value)
            ScrollGlassTraceTests.signposter.emitEvent("commit", "\(text, privacy: .public)")
        }
    }

    /// 四个对象共用的位移曲线：和本地包里的惯性一样——总位移取整到整行，时长 3·total/v，三次缓出。
    struct Glide {
        let total: Double
        let duration: Double

        init(velocityPx: Double, cellPx: Double) {
            let projected = velocityPx / 1000 / -log(0.998)
            var total = (projected / cellPx).rounded() * cellPx
            if total * velocityPx <= 0 { total += velocityPx > 0 ? cellPx : -cellPx }
            self.total = total
            duration = min(max(3 * total / velocityPx, 0.12), 3.0)
        }

        func position(at elapsed: Double) -> Double {
            let u = min(1, max(0, elapsed / duration))
            return u >= 1 ? total : total * (1 - pow(1 - u, 3))
        }
    }

    /// 真手甩之前手指是在拖的，屏幕已经跑在 120 Hz；从静止的屏直接起惯性，头几帧显示还在从 10 Hz 往上爬
    ///（实测头三帧挤在同一次换屏里），量到的是屏幕提速而不是滚动。所以每次甩之前先按同样的速度「拖」这么久。
    static let dragLead = 0.2

    /// 每个显示帧调一次闭包（给 Ghostty 的拖动阶段用），跑够时长后返回。
    @MainActor
    final class FrameTicker: NSObject {
        private var link: CADisplayLink?
        private var body: (@MainActor (Double) -> Void)?
        private var until = 0.0
        private var done: CheckedContinuation<Void, Never>?

        func run(seconds: Double, _ body: @escaping @MainActor (Double) -> Void) async {
            self.body = body
            until = CACurrentMediaTime() + seconds
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                done = continuation
                let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        }

        @objc private func frame(_ link: CADisplayLink) {
            body?(link.targetTimestamp - link.timestamp)
            if link.targetTimestamp >= until {
                link.invalidate()
                self.link = nil
                done?.resume()
                done = nil
            }
        }
    }

    /// display link 每拍推一个位置（给 SwiftTerm、UIScrollView 用）：先按初速匀速「拖」`dragLead` 秒，再按曲线滑行。
    /// 只有滑行阶段记进 ticks（打分只看惯性）。
    @MainActor
    final class LinkDriver: NSObject {
        private(set) var ticks: [(target: Double, position: Double)] = []
        private var link: CADisplayLink?
        private var glide: Glide?
        private var velocity = 0.0
        private var start = 0.0
        private var glideStart = 0.0
        private var origin = 0.0
        private var apply: (@MainActor (Double) -> Void)?

        func run(_ glide: Glide, velocity: Double, from origin: Double, apply: @escaping @MainActor (Double) -> Void) {
            self.glide = glide
            self.velocity = velocity
            self.origin = origin
            self.apply = apply
            start = 0
            glideStart = 0
            ticks.removeAll()
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func frame(_ link: CADisplayLink) {
            guard let glide else { return }
            if start == 0 { start = link.timestamp }
            if glideStart == 0, link.timestamp - start < ScrollGlassTraceTests.dragLead {
                apply?((origin + velocity * (link.targetTimestamp - start)).rounded())
                return
            }
            if glideStart == 0 {
                glideStart = link.timestamp
                origin = (origin + velocity * (link.timestamp - start)).rounded()
            }
            let elapsed = link.targetTimestamp - glideStart
            let position = origin + glide.position(at: elapsed).rounded()
            ticks.append((link.targetTimestamp, position))
            apply?(position)
            if elapsed >= glide.duration {
                link.invalidate()
                self.link = nil
            }
        }
    }

    private func emit(subject: String, index: Int, velocity: Double, output: Bool,
                      ticks: [(target: Double, position: Double)], commits: [(time: Double, position: Double)]) {
        print("GLASS-FLING {\"subject\":\"\(subject)\",\"fling\":\(index),\"v\":\(Int(velocity)),\"output\":\(output),\"ticks\":\(ticks.count),\"commits\":\(commits.count)}")
        func chunks(_ tag: String, _ rows: [String]) {
            for start in stride(from: 0, to: rows.count, by: 40) {
                print("\(tag) \(subject) \(index) " + rows[start..<min(rows.count, start + 40)].joined(separator: ";"))
            }
        }
        chunks("GLASS-T", ticks.map { String(format: "%.6f,%.1f", $0.target, $0.position) })
        chunks("GLASS-C", commits.map { String(format: "%.6f,%.1f", $0.time, $0.position) })
    }

    /// 等外面的 xctrace 真正开始录。顺序是：这边准备好打印 GLASS-READY → 脚本立刻启动 xctrace → 这边固定等 20 秒
    /// 再做动作（xctrace 从启动到开始录实测 4–5 秒；脚本会核对它确实在 15 秒内开始录了）。
    /// 试过的别的办法都不行：先开录再启动测试，xcodebuild 一起测试会话 xctrace 的连接就断；开录后用 devicectl 往手机
    /// 发通知，也常把 xctrace 的连接弄断；`.dynamicTracing` 的 signpost 开关在这个模板下探不到。
    private func waitForTracing(subject: String) async throws {
        print("GLASS-READY subject=\(subject)")
        try await Task.sleep(for: .seconds(20))
        print("GLASS-TRACING subject=\(subject) media=\(String(format: "%.6f", CACurrentMediaTime()))")
    }

    private static let plan: [(velocity: Double, output: Bool)] = [
        (6000, false), (-6000, false), (12000, false), (-12000, false), (20000, false), (-20000, false),
        (6000, true), (-6000, true), (12000, true), (-12000, true), (20000, true), (-20000, true),
    ]

    // MARK: - Ghostty（整个工作区界面）

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

    /// 这次是在哪块屏上跑的（折叠屏两块屏尺寸不同，分开打分）。
    private static func screenLine(_ scene: UIWindowScene) -> String {
        let screen = scene.screen
        return "screenPt=\(Int(screen.bounds.width))x\(Int(screen.bounds.height)) screenPx=\(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height)) scale=\(screen.nativeScale) maxFPS=\(screen.maximumFramesPerSecond) orientation=\(scene.effectiveGeometry.interfaceOrientation.rawValue)"
    }

    /// 单独一扇真的可见的全屏窗口（和 UIScrollView 基准同一种窗口）。
    /// 没放进整个工作区界面：探针里的工作区窗口默认是透明的（alpha 0，合成器不画，玻璃上什么都没换）；
    /// 强制成可见后 Ghostty 标签又不出帧了（没查原因），所以这一轮三个对象都用单独窗口。
    private func runGhostty(subject: String, freeRenderer: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = try GhosttyProbeHost(size: scene.screen.bounds.size)
        defer { host.close() }
        try await host.waitUntilReady()
        UTermScrollTrace.legacyWakeupSyncDraw = !freeRenderer
        UTermScrollTrace.emitsSignposts = true
        let cols = host.grid.cols
        host.feedAndWait(OnScreen.barcodeHistory(lines: 1500, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols))
        try await Task.sleep(for: .milliseconds(500))
        let view = host.view
        let cell = try XCTUnwrap(view.uTermCellPixels)
        let scale = Double(scene.screen.nativeScale)
        // 滚到回滚区中间。
        for _ in 0..<600 { view.sendMouseScroll(x: 0, y: Double(cell.height), mods: TerminalScrollModifiers(precision: true)) }
        try await Task.sleep(for: .milliseconds(500))
        print("GLASS-META subject=\(subject) \(Self.screenLine(scene)) cellPx=\(Int(cell.height)) viewPt=\(Int(view.bounds.width))x\(Int(view.bounds.height))")

        let pan = Pan()
        let selector = NSSelectorFromString("handleTouchScrollGesture:")
        let ticker = FrameTicker()
        func fling(_ velocityPx: Double) async {
            let v = CGFloat(velocityPx / scale)
            pan.fakeState = .began; pan.fakeTranslation = .zero; _ = view.perform(selector, with: pan)
            // 手指先拖 dragLead 秒：每个显示帧一个 .changed，位移 = 速度 × 这一帧的时长。
            await ticker.run(seconds: Self.dragLead) { dt in
                pan.fakeState = .changed; pan.fakeTranslation = CGPoint(x: 0, y: v * dt)
                _ = view.perform(selector, with: pan)
            }
            pan.fakeState = .ended; pan.fakeTranslation = .zero; pan.fakeVelocity = CGPoint(x: 0, y: v)
            _ = view.perform(selector, with: pan)
        }
        // 预热。
        await fling(3000); try await Task.sleep(for: .milliseconds(1900))
        await fling(-3000); try await Task.sleep(for: .milliseconds(1900))

        var decoder = OnScreen.BarcodeDecoder(cell: cell)
        // 画面层每次现找：surface 重建（尺寸、可见性变化）会换一个层，拿着旧的就再也读不到新画面。
        var layer: CALayer { OnScreen.surfaceLayer(in: view.layer) ?? view.layer }
        let log = CommitLog()
        // 顺手核一件事（补丁 0024 靠它）：挂在层上的 IOSurface，render server 会不会给它加 use count。
        // 每次 CA 提交后看：现在挂着的那张 in-use 吗；上一张（刚被换下来的）还 in-use 吗。
        var inUse = (current: 0, currentTotal: 0, previous: 0, previousTotal: 0)
        var lastSurface: IOSurfaceRef?
        log.read = {
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
                let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
                if let last = lastSurface, last !== surface {
                    inUse.previousTotal += 1
                    if IOSurfaceIsInUse(last) { inUse.previous += 1 }
                    inUse.currentTotal += 1
                    if IOSurfaceIsInUse(surface) { inUse.current += 1 }
                }
                lastSurface = surface
            }
            return decoder.position(of: layer)
        }
        log.start()
        defer { log.stop() }
        try await waitForTracing(subject: subject)

        for (index, step) in Self.plan.enumerated() {
            let feeder = step.output ? Task { @MainActor in
                var n = 1
                while !Task.isCancelled {
                    host.bridge.feed(Data(TerminalSpikeCorpus.claudeFrame(n, cols: cols).utf8))
                    n += 1
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } : nil
            try await Task.sleep(for: .milliseconds(250))
            log.reset()
            UTermScrollTrace.isEnabled = true
            await fling(step.velocity)
            try await Task.sleep(for: .milliseconds(1800))
            let trace = UTermScrollTrace.drain()
            UTermScrollTrace.isEnabled = false
            feeder?.cancel()
            // 每拍想显示的位置：手指往下（发出的像素为正）= 往回滚区走 = 条码位置变小。
            // 原点 = 这次惯性结束时画面里的位置 + 整次惯性发出的像素（惯性停在整行上，画面和发出的是对得上的），
            // 这样拖动阶段发了多少、画没画完都不影响。
            let glideTotal = trace.filter { $0.kind == "momentum" }.reduce(0) { $0 + $1.value }
            let origin = try XCTUnwrap(decoder.position(of: layer)) + glideTotal
            var sent = 0.0
            var ticks: [(target: Double, position: Double)] = []
            var target: Double?
            for event in trace {
                switch event.kind {
                case "glide-target":
                    target = event.value
                    ticks.append((event.value, origin - sent))
                case "momentum":
                    sent += event.value
                    if let target, !ticks.isEmpty, ticks[ticks.count - 1].target == target {
                        ticks[ticks.count - 1].position = origin - sent
                    }
                default: break
                }
            }
            emit(subject: subject, index: index, velocity: step.velocity, output: step.output, ticks: ticks, commits: log.commits)
        }
        print("GLASS-INUSE subject=\(subject) 刚挂上的那张 in-use=\(inUse.current)/\(inUse.currentTotal) 刚换下的那张 in-use=\(inUse.previous)/\(inUse.previousTotal)")
        print("GLASS-DONE subject=\(subject)")
        try await Task.sleep(for: .milliseconds(500))
    }

    // MARK: - SwiftTerm（整个工作区界面）

    private var restoreDraw: (() -> Void)?
    nonisolated(unsafe) private static var drawnOffset: Double?
    nonisolated(unsafe) private static var drawTarget: ObjectIdentifier?
    nonisolated(unsafe) private static var fakeTracking = false

    /// 代码设 contentOffset 时 UIKit 的 isTracking 恒为假，SwiftTerm 来了输出就把视图拽回底部；这个实例的 isTracking 由测试给。
    private static func overrideTracking(_ view: UIScrollView) -> AnyClass {
        let base: AnyClass = object_getClass(view)!
        let name = "UTermGlassTracking_\(NSStringFromClass(base))"
        if let existing = NSClassFromString(name) {
            object_setClass(view, existing)
            return base
        }
        let cls: AnyClass = objc_allocateClassPair(base, name, 0)!
        let tracking: @convention(block) (AnyObject) -> Bool = { _ in Self.fakeTracking }
        let selector = #selector(getter: UIScrollView.isTracking)
        class_addMethod(cls, selector, imp_implementationWithBlock(tracking),
                        method_getTypeEncoding(class_getInstanceMethod(base, selector)!))
        objc_registerClassPair(cls)
        object_setClass(view, cls)
        return base
    }

    private func runSwiftTerm(subject: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = try SwiftTermProbeHost(size: scene.screen.bounds.size)
        defer { host.close() }
        let view = host.view
        let cols = host.grid.cols
        view.feed(text: TerminalSpikeCorpus.history(lines: 1500, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols))
        host.container.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(view.contentSize.height, view.bounds.height * 10, "回滚区没填起来")
        let scale = Double(scene.screen.nativeScale)
        let cellPx = (Double(view.bounds.height) / Double(max(1, view.getTerminal().rows)) * scale).rounded()
        print("GLASS-META subject=\(subject) \(Self.screenLine(scene)) cellPx=\(Int(cellPx)) viewPt=\(Int(view.bounds.width))x\(Int(view.bounds.height)) contentPt=\(Int(view.contentSize.height))")

        let base = Self.overrideTracking(view)
        defer { object_setClass(view, base); Self.fakeTracking = false }
        Self.fakeTracking = true
        let method = class_getInstanceMethod(SwiftTerm.TerminalView.self, #selector(UIView.draw(_:)))!
        typealias Draw = @convention(c) (AnyObject, Selector, CGRect) -> Void
        let original = method_getImplementation(method)
        let call = unsafeBitCast(original, to: Draw.self)
        let hooked: @convention(block) (AnyObject, CGRect) -> Void = { object, rect in
            if ObjectIdentifier(object) == Self.drawTarget, let scroll = object as? UIScrollView {
                Self.drawnOffset = Double(scroll.contentOffset.y) * scale
            }
            call(object, #selector(UIView.draw(_:)), rect)
        }
        method_setImplementation(method, imp_implementationWithBlock(hooked))
        restoreDraw = { method_setImplementation(method, original) }
        Self.drawTarget = ObjectIdentifier(view)

        let middle = (view.contentSize.height - view.bounds.height) / 2
        view.setContentOffset(CGPoint(x: 0, y: (middle * scale).rounded() / scale), animated: false)
        try await Task.sleep(for: .milliseconds(400))
        let driver = LinkDriver()
        func fling(_ velocityPx: Double) {
            // 手指往下（速度为正）= 往回滚区走 = contentOffset 变小。
            let glide = Glide(velocityPx: -velocityPx, cellPx: cellPx)
            driver.run(glide, velocity: -velocityPx, from: Double(view.contentOffset.y) * scale) { position in
                view.contentOffset = CGPoint(x: 0, y: position / scale)
            }
        }
        fling(3000); try await Task.sleep(for: .milliseconds(2100))
        fling(-3000); try await Task.sleep(for: .milliseconds(2100))

        let log = CommitLog()
        // 字画在滚动视图自己的 layer 上：bounds 动了但没重画时字不动，所以画面里的位置 = 最近一次 draw 时的 contentOffset。
        log.read = { Self.drawnOffset }
        log.start()
        defer { log.stop() }
        try await waitForTracing(subject: subject)

        for (index, step) in Self.plan.enumerated() {
            let feeder = step.output ? Task { @MainActor in
                var n = 1
                while !Task.isCancelled {
                    view.feed(text: TerminalSpikeCorpus.claudeFrame(n, cols: cols))
                    n += 1
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } : nil
            try await Task.sleep(for: .milliseconds(250))
            log.reset()
            fling(step.velocity)
            try await Task.sleep(for: .milliseconds(2000))
            feeder?.cancel()
            emit(subject: subject, index: index, velocity: step.velocity, output: step.output, ticks: driver.ticks, commits: log.commits)
        }
        print("GLASS-DONE subject=\(subject)")
        try await Task.sleep(for: .milliseconds(500))
    }

    // MARK: - 普通 UIScrollView（合成器平移内容）

    private func runScrollView(subject: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try makeSpikeWindow(size: scene.screen.bounds.size)
        defer { window.isHidden = true }
        let scale = Double(scene.screen.nativeScale)
        let scroll = UIScrollView(frame: window.bounds)
        scroll.backgroundColor = .black
        scroll.contentInsetAdjustmentBehavior = .never
        let rowHeight: CGFloat = 13
        let rows = 1200
        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let colors: [UIColor] = [.systemGreen, .systemRed, .systemTeal, .systemYellow, .lightGray]
        for row in 0..<rows {
            let label = UILabel(frame: CGRect(x: 8, y: CGFloat(row) * rowHeight, width: window.bounds.width - 16, height: rowHeight))
            label.font = font
            label.textColor = colors[row % colors.count]
            label.text = "\(row % 2 == 0 ? "+" : "⎿") let v\(row % 10) = f(\(row)) // 说明 App/File\(row % 100).swift 处理滚动收尾"
            scroll.addSubview(label)
        }
        scroll.contentSize = CGSize(width: window.bounds.width, height: CGFloat(rows) * rowHeight)
        window.addSubview(scroll)
        // 「输出」：滚动视图外面一行每 100 ms 改一次字，占一点主线程和合成。
        let status = UILabel(frame: CGRect(x: 8, y: window.bounds.height - 60, width: window.bounds.width - 16, height: 20))
        status.font = font
        status.textColor = .white
        status.backgroundColor = .darkGray
        window.addSubview(status)
        let cellPx = Double(rowHeight) * scale
        print("GLASS-META subject=\(subject) \(Self.screenLine(scene)) cellPx=\(Int(cellPx)) viewPt=\(Int(scroll.bounds.width))x\(Int(scroll.bounds.height)) contentPt=\(Int(scroll.contentSize.height))")
        let middle = (scroll.contentSize.height - scroll.bounds.height) / 2
        scroll.contentOffset = CGPoint(x: 0, y: (middle * scale).rounded() / scale)
        try await Task.sleep(for: .milliseconds(400))
        let driver = LinkDriver()
        func fling(_ velocityPx: Double) {
            let glide = Glide(velocityPx: -velocityPx, cellPx: cellPx)
            driver.run(glide, velocity: -velocityPx, from: Double(scroll.contentOffset.y) * scale) { position in
                scroll.contentOffset = CGPoint(x: 0, y: position / scale)
            }
        }
        fling(3000); try await Task.sleep(for: .milliseconds(2100))
        fling(-3000); try await Task.sleep(for: .milliseconds(2100))

        let log = CommitLog()
        log.read = { Double(scroll.contentOffset.y) * scale }
        log.start()
        defer { log.stop() }
        try await waitForTracing(subject: subject)

        for (index, step) in Self.plan.enumerated() {
            let feeder = step.output ? Task { @MainActor in
                var n = 1
                while !Task.isCancelled {
                    status.text = "✻ Thinking… (\(n / 10)s · ↓ \(n * 7) tokens)"
                    n += 1
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } : nil
            try await Task.sleep(for: .milliseconds(250))
            log.reset()
            fling(step.velocity)
            try await Task.sleep(for: .milliseconds(2000))
            feeder?.cancel()
            emit(subject: subject, index: index, velocity: step.velocity, output: step.output, ticks: driver.ticks, commits: log.commits)
        }
        print("GLASS-DONE subject=\(subject)")
        try await Task.sleep(for: .milliseconds(500))
    }

    // MARK: - 入口

    /// 只在外面的录制脚本带着 `UTERM_GLASS_SUBJECT` 跑时才做事；平时跑全量测试直接跳过。
    func testRecordForGlassScore() async throws {
        guard let subject = ProcessInfo.processInfo.environment["UTERM_GLASS_SUBJECT"], !subject.isEmpty else {
            throw XCTSkip("没设 UTERM_GLASS_SUBJECT：这条只配合 scratchpad/ios-measure/r8/glass-record.sh 录 xctrace 用")
        }
        switch subject {
        case "ghostty-sync": try await runGhostty(subject: subject, freeRenderer: false)
        case "ghostty-free": try await runGhostty(subject: subject, freeRenderer: true)
        case "swiftterm": try await runSwiftTerm(subject: subject)
        case "uiscrollview": try await runScrollView(subject: subject)
        default: XCTFail("不认识的被测对象：\(subject)")
        }
    }
}
