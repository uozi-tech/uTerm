import SwiftUI
import UIKit
import XCTest

/// 一次量测的统一口径 —— `mount(view:) → measureScroll(steps:) → snapshot()`。
///
/// **为什么存在**：桌面那边每个探针都手写「建窗 / 扫懒行 / 3s 心跳 / 200 步往返 /
/// hitTest / 截图」这一整套，抄出来的口径各不相同（往返幅度有的钳 3 视口有的全程、
/// 单帧预算有的写死 8.33 有的按屏），于是两份报告里的同一个名字讲的不是同一件事。
/// 移动端这套地基一次收干净：探针只写十几行，读数天然可比。
///
/// 典型用法：
/// ```swift
/// func testSomeScreen() async throws {
///     defer { MobileProbeWindow.closeAll() }
///     let rig = MobileProbeRig(label: "hosts-200")
///     rig.mount(HostListView(servers: MockServerFactory.make(200)))
///     let scroll = try await rig.measureScroll()       // 时间
///     let shot = await rig.snapshot()                   // 结构 + 像素 + 成本
///     rig.report(scroll, shot)                          // 一行读数进日志
///     XCTAssertGreaterThan(scroll.scrollable, 0)        // 闸门只用结构判据
/// }
/// ```
///
/// ## 口径（与桌面 playbook §一 对齐，差异写在 README）
///
/// - 往返幅度钳在**约 3 个视口**：全程往返在大列表上一步跨几十屏，量到的是
///   「跳转」不是「滚动」。
/// - 200 步、每步 `layoutIfNeeded()` + `CATransaction.flush()` 后记一次墙钟。
///   iOS 没有 `displayIfNeeded()`，不 `flush` 只量到布局、漏掉 CA 提交那笔账。
/// - 单帧预算按**屏幕刷新率**算（`MobileProbeWindow.frameBudgetMS()`，60Hz 16.67ms /
///   120Hz 8.33ms），同时另打一份按固定 8.33ms 的比例（`ProbeBudget.strictMS`）
///   供跨机器对照。
/// - 闸门只用**结构判据与同轮相对比**，绝对毫秒只打印。
@MainActor
final class MobileProbeRig {

    // MARK: - 滚动驱动

    /// 怎么把列表滚起来。
    ///
    /// iOS 上**没有可靠的触摸合成**：`UIScrollView.panGestureRecognizer` 要收
    /// `UITouch` 序列，而 `UITouch` 没有公开构造器，XCTest 的
    /// `XCUIElement.swipeUp()` 只在 UI Test target 里有（我们是 unit test bundle，
    /// 宿主在同一进程内）。所以退而求其次：直接推 `contentOffset`，按刷新率节拍
    /// 逐步推进来近似手指。`.fingerDrag` 那档量的就是「每一拍推一小步要花多久」。
    enum ScrollDriver: String, CaseIterable {
        /// `setContentOffset(_:animated: false)`。默认。最直接，没有额外语义。
        case contentOffset
        /// `scrollRectToVisible(_:animated: false)`。走 UIKit 的可见性换算，
        /// 会被 `contentInset` / `adjustedContentInset` 影响 —— 探针要的是「滚到 y」，
        /// 所以只在验证「这条路也能驱动」时用它。
        case scrollRectToVisible
        /// 按 `CADisplayLink` 节拍逐步推进（近似手指匀速拖动）。
        /// 每拍的活儿耗时由 `DisplayLinkCounter.workMS` 记账。
        case fingerDrag

        var short: String { rawValue }
    }

    enum ProbeRigError: Error, CustomStringConvertible {
        case notMounted
        case noScrollView(histogram: String)
        case notScrollable(contentHeight: CGFloat, viewport: CGFloat)

        var description: String {
            switch self {
            case .notMounted:
                return "还没 mount：先调 rig.mount(view)"
            case .noScrollView(let histogram):
                return "被测视图里没有 UIScrollView —— 滚动读数全是假的。视图树：\(histogram)"
            case .notScrollable(let contentHeight, let viewport):
                return String(format: "可滚动余量 = 0（内容高 %.0f ≤ 视口 %.0f）："
                              + "这一档根本滚不动，所有滚动读数都是假的",
                              contentHeight, viewport)
            }
        }
    }

    // MARK: - 读数

    struct Heartbeat {
        let seconds: Double
        /// 8ms `Task.sleep` 循环实际收到的拍数：主线程还愿不愿意回到 runloop。
        let sleepBeats: Int
        let idealSleepBeats: Int
        /// `CADisplayLink` 实际交付的帧数：渲染循环还在不在跑。
        let displayTicks: Int
        let idealDisplayTicks: Int
        let tickIntervalP95: Double
        /// 系统报的标称帧间隔（ms）。ProMotion 上 maxFPS=120 但 link 可能被降频。
        let nominalIntervalMS: Double
        let rateRange: String

        /// 拍数 / 理想拍数。1.0 = 渲染循环满速。
        var displayRatio: Double {
            idealDisplayTicks == 0 ? 0 : Double(displayTicks) / Double(idealDisplayTicks)
        }
        var sleepRatio: Double {
            idealSleepBeats == 0 ? 0 : Double(sleepBeats) / Double(idealSleepBeats)
        }
    }

    struct ScrollReading {
        let driver: ScrollDriver
        let steps: Int
        /// 每步「设 offset + 布局 + 提交」的主线程耗时（ms）。
        let frames: [Double]
        let p50: Double
        let p95: Double
        let max: Double
        /// 超过**本机刷新率预算**的帧占比（%）。
        let overBudgetPct: Double
        let budgetMS: Double
        /// 超过固定 8.33ms 的帧占比（%）—— 跨机器对照用。
        let overStrictPct: Double
        let viewport: CGFloat
        let amplitude: CGFloat
        let contentHeight: CGFloat
        /// 可滚动余量 = contentSize.height - viewport。**这个是 0 就一切读数作废。**
        let scrollable: CGFloat
        /// 实际走过的 offset 总里程（结构判据：驱动真的把视图推动了）。
        let travelled: CGFloat
        /// `.fingerDrag` 档才有：display link 的拍数 / 理想拍数。
        let ticks: Int
        let idealTicks: Int
    }

    struct Snapshot {
        let views: Int
        let histogram: String
        let hitP50: Double
        let hitP95: Double
        let footprintMB: Double
        let cpuSeconds: Double
        let contentHeight: CGFloat
        let scrollable: CGFloat
        /// 非背景色（众数颜色）像素占比。全空白的截图恰为 0。
        let ink: Double
        let png: Data?
        /// 这一档**实际**取到了像素（`ink > 0`）。全空白的截图 ink 恰为 0。
        let pixelsAvailable: Bool
        /// `snapshot(ocr: true)` 才有；识别器超时时为 nil（此时靠 `ink` 兜底）。
        let ocrText: String?
    }

    // MARK: - 配置

    let label: String
    let size: CGSize
    let placement: MobileProbeWindow.Placement
    let isolateHost: Bool

    private(set) var window: UIWindow?
    private(set) var hostView: UIView?
    private(set) var scrollView: UIScrollView?
    /// 挂载耗时（ms）：`layoutIfNeeded()` + `CATransaction.flush()` 那一段。
    private(set) var mountMS: Double = 0

    /// - Parameters:
    ///   - label: 打日志用的档名（例如 `"hosts-200"`）。
    ///   - size: 内容尺寸。**写死**而不是用屏幕尺寸：iPhone 与 iPad 的可视行数差三倍，
    ///     写死才能让同一份读数在两台模拟器之间可比。默认 390×700（iPhone 竖屏近似）。
    ///   - placement: 默认 `.transparentOnScreen`（计时探针档）。
    ///   - isolateHost: 把宿主窗口压到探针窗口下面（不拆），默认开。
    init(label: String,
         size: CGSize = CGSize(width: 390, height: 700),
         placement: MobileProbeWindow.Placement = .transparentOnScreen,
         isolateHost: Bool = true) {
        self.label = label
        self.size = size
        self.placement = placement
        self.isolateHost = isolateHost
    }

    // MARK: - 挂载

    /// 建窗 + 挂 SwiftUI + 首次布局 + CA 提交，返回挂载耗时（ms）。
    ///
    /// **跨档比挂载没有意义**：每次运行的第一个 fixture 会吃掉 SwiftUI 首次渲染的
    /// 一次性开销（README 基线里 200 行反而比 2000 行贵就是这个）。只在同一档
    /// 做前→后对照。
    @discardableResult
    func mount<V: View>(_ view: V) -> Double {
        let root = AnyView(view.frame(width: size.width, height: size.height))
        let (window, host) = MobileProbeWindow.make(size: size,
                                                    placement: placement,
                                                    isolateHost: isolateHost,
                                                    rootView: root)
        self.window = window
        self.hostView = host.view

        let start = CFAbsoluteTimeGetCurrent()
        host.view.layoutIfNeeded()
        // iOS 没有 `displayIfNeeded()`；`CATransaction.flush()` 是把这一轮的图层
        // 提交真的推出去的等价手法，不 flush 的话「挂载」只量到布局、漏掉 CA 那笔账。
        CATransaction.flush()
        mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000

        self.scrollView = host.view.firstScrollView()
        return mountMS
    }

    /// 逼一次布局 + CA 提交。每一步测量前后都要走它，否则量到的只是「设了个属性」。
    func layout() {
        hostView?.layoutIfNeeded()
        CATransaction.flush()
    }

    // MARK: - 前置判据（滚不动就当场判红，不要拿假读数写报告）

    func requireHost() throws -> UIView {
        guard let hostView else { throw ProbeRigError.notMounted }
        return hostView
    }

    func requireScrollView() throws -> UIScrollView {
        let host = try requireHost()
        guard let scrollView else { throw ProbeRigError.noScrollView(histogram: host.classHistogram()) }
        return scrollView
    }

    /// 可滚动余量。**为 0 就抛** —— 这是本套夹具的反向自证点：
    /// 一个滚不动的档，它的单帧 p50 / 拍数 / hitTest 全都是「静止画面」的读数，
    /// 看着漂亮但什么都没测到。宁可判红。
    @discardableResult
    func requireScrollable() throws -> CGFloat {
        let scroll = try requireScrollView()
        layout()
        let viewport = scroll.bounds.height
        let content = scroll.contentSize.height
        let slack = content - viewport
        guard slack > 0.5 else {
            throw ProbeRigError.notScrollable(contentHeight: content, viewport: viewport)
        }
        return slack
    }

    // MARK: - 滚动驱动

    /// 把列表滚到 y（钳在 `[0, maxOffset]`）。
    func scrollTo(_ y: CGFloat, driver: ScrollDriver = .contentOffset) {
        guard let scroll = scrollView else { return }
        let maxOffset = Swift.max(0, scroll.contentSize.height - scroll.bounds.height)
        let target = Swift.min(maxOffset, Swift.max(0, y))
        switch driver {
        case .contentOffset, .fingerDrag:
            scroll.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        case .scrollRectToVisible:
            scroll.scrollRectToVisible(CGRect(x: 0, y: target,
                                              width: scroll.bounds.width,
                                              height: scroll.bounds.height),
                                       animated: false)
        }
    }

    /// 从头到尾扫一遍整篇文档，返回扫完之后的 `contentSize.height`。
    ///
    /// `LazyVStack` 的文档高 = 建过的行的实测高 + 没建过的行的**估高**。估高取决于这一轮
    /// 碰巧建过哪些行：iOS 27 上同一份 200 条消息、只往返扫过前三屏时，两次读数能差 14%
    /// （148k 对 173k，而真实高度是 28 万上下）。要拿文档高当「两边挂的是不是同一批内容」
    /// 的判据，就得先把估高换成实测高 —— 扫完之后同一份内容的读数只差 0.2%。
    ///
    /// 只给**规模有限**的 fixture 用：每步都逼一次布局，一千条量级要好几秒。
    @discardableResult
    func settleContentHeight() -> CGFloat {
        guard let scroll = scrollView else { return 0 }
        let stride = Swift.max(1, scroll.bounds.height * 0.8)
        var y: CGFloat = 0
        var steps = 0
        // 上界每步重读：扫的过程中估高在被实测高替换，文档会一路变长。
        while y < scroll.contentSize.height - scroll.bounds.height, steps < 5_000 {
            scrollTo(y)
            layout()
            y += stride
            steps += 1
        }
        scrollTo(scroll.contentSize.height)
        layout()
        return scroll.contentSize.height
    }

    /// 以小于一屏的间距扫过 `[0, amplitude]`，把懒建的行全部实例化。
    ///
    /// 不扫的话第一遍往返会把「首次建行」的账算进滚动成本，规模越大越夸张。
    func sweepLazyRows(amplitude: CGFloat, driver: ScrollDriver = .contentOffset) async throws {
        guard let scroll = scrollView else { return }
        let viewport = scroll.bounds.height
        var visited: CGFloat = 0
        while visited < amplitude {
            scrollTo(visited, driver: driver)
            layout()
            try await Task.sleep(for: .milliseconds(8))
            visited += viewport * 0.8
        }
        scrollTo(0, driver: driver)
        layout()
        try await Task.sleep(for: .milliseconds(120))
    }

    /// 通过 `ScrollViewReader` 驱动（视图得先用 `ProbeScrollReaderBox` 包一层）。
    ///
    /// 单列出来而不是并进 `ScrollDriver`：它是按 **id** 寻址的，`measureScroll`
    /// 是按 **y** 寻址的，两套坐标混在一个入口里只会让读数含义模糊。
    /// 它的价值是回答一个具体问题——「`.transparentOnScreen` 档下 SwiftUI 自己的
    /// 滚动 API 还灵不灵」，答案见 `ProbeRigSelfTests.testScrollDriversAllMove`。
    func scrollViaReader(_ anchor: ProbeScrollAnchor, to id: Int, anchorPoint: UnitPoint = .top) {
        anchor.scrollTo?(id, anchorPoint)
        layout()
    }

    // MARK: - 尺一：心跳

    /// N 秒双心跳。
    ///
    /// - `Task.sleep(8ms)` 拍数 —— 主线程还愿不愿意回到 runloop（理想 `seconds/0.008`）。
    /// - `CADisplayLink` 拍数 —— 渲染循环实际交付了几帧（理想 `maxFPS × seconds`）。
    ///
    /// 报告里写「拍数/理想」这个**比值**，别写绝对拍数：模拟器的
    /// `maximumFramesPerSecond` 跟着宿主 Mac 的显示器走，跨机器比绝对拍数会得出反的结论。
    ///
    /// - Parameter wave: 心跳期间是否同时做往返滚动（默认开）。关掉就是纯静止心跳。
    func heartbeat(seconds: Double = 3,
                   wave: Bool = true,
                   amplitude: CGFloat? = nil,
                   period: Int = 80) async throws -> Heartbeat {
        let amp: CGFloat
        if let amplitude {
            amp = amplitude
        } else if let scroll = scrollView {
            let maxOffset = Swift.max(0, scroll.contentSize.height - scroll.bounds.height)
            amp = Swift.min(maxOffset, scroll.bounds.height * 3)
        } else {
            amp = 0
        }

        let maxFPS = MobileProbeWindow.maximumFramesPerSecond()
        let counter = DisplayLinkCounter()
        counter.start()
        let start = Date()
        var beats = 0
        while Date().timeIntervalSince(start) < seconds {
            try await Task.sleep(for: .milliseconds(8))
            if wave, amp > 0 {
                let phase = 0.5 * (1 - cos(Double(beats % period) / Double(period) * 2 * .pi))
                scrollTo(amp * phase)
            }
            beats += 1
        }
        counter.stop()
        return Heartbeat(seconds: seconds,
                         sleepBeats: beats,
                         idealSleepBeats: Int(seconds / 0.008),
                         displayTicks: counter.ticks,
                         idealDisplayTicks: Int(Double(maxFPS) * seconds),
                         tickIntervalP95: ProbeMetrics.percentile(counter.intervals, 0.95),
                         nominalIntervalMS: counter.nominalIntervalMS,
                         rateRange: String(format: "[%.0f,%.0f]p%.0f",
                                           counter.rateRange.minimum,
                                           counter.rateRange.maximum,
                                           counter.rateRange.preferred ?? 0))
    }

    // MARK: - 尺二：单帧

    /// 200 步往返，量单帧主线程耗时。
    ///
    /// 幅度钳在**约 3 个视口**（`amplitudeViewports`），与桌面口径一致。
    /// 滚不动（`scrollable == 0`）直接抛 —— 见 `requireScrollable()`。
    func measureScroll(steps: Int = 200,
                       driver: ScrollDriver = .contentOffset,
                       amplitudeViewports: CGFloat = 3,
                       period: Int = 80,
                       sweepFirst: Bool = true) async throws -> ScrollReading {
        let scroll = try requireScrollView()
        let slack = try requireScrollable()
        let viewport = scroll.bounds.height
        let amplitude = Swift.min(slack, viewport * amplitudeViewports)

        if sweepFirst { try await sweepLazyRows(amplitude: amplitude, driver: driver) }

        let budget = MobileProbeWindow.frameBudgetMS()
        var frames: [Double] = []
        var travelled: CGFloat = 0
        var previous = scroll.contentOffset.y
        var ticks = 0
        var idealTicks = 0

        func phase(_ step: Int) -> CGFloat {
            CGFloat(0.5 * (1 - cos(Double(step % period) / Double(period) * 2 * .pi)))
        }

        switch driver {
        case .contentOffset, .scrollRectToVisible:
            for step in 0..<steps {
                let start = CFAbsoluteTimeGetCurrent()
                scrollTo(amplitude * phase(step), driver: driver)
                layout()
                frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                travelled += abs(scroll.contentOffset.y - previous)
                previous = scroll.contentOffset.y
                try await Task.sleep(for: .milliseconds(8))
            }

        case .fingerDrag:
            // 「模拟手指」：不睡固定 8ms，而是挂在 `CADisplayLink` 上，每一拍推一小步。
            // 一拍推进的距离 = 整段往返 / steps，节拍由系统给（60 或 120Hz），
            // 于是「每拍耗时」量到的就是真实刷新节奏下主线程的账。
            let counter = DisplayLinkCounter()
            var step = 0
            counter.onTick = { [weak self] in
                guard let self else { return }
                self.scrollTo(amplitude * phase(step))
                self.layout()
                step += 1
            }
            counter.start()
            let deadline = Date().addingTimeInterval(Double(steps) / 30.0 + 2)
            while counter.ticks < steps && Date() < deadline {
                try await Task.sleep(for: .milliseconds(4))
                travelled += abs(scroll.contentOffset.y - previous)
                previous = scroll.contentOffset.y
            }
            counter.stop()
            counter.onTick = nil
            frames = counter.workMS
            ticks = counter.ticks
            idealTicks = steps
        }

        return ScrollReading(
            driver: driver,
            steps: driver == .fingerDrag ? frames.count : steps,
            frames: frames,
            p50: ProbeMetrics.percentile(frames, 0.5),
            p95: ProbeMetrics.percentile(frames, 0.95),
            max: frames.max() ?? 0,
            overBudgetPct: percentOver(frames, budget),
            budgetMS: budget,
            overStrictPct: percentOver(frames, ProbeBudget.strictMS),
            viewport: viewport,
            amplitude: amplitude,
            contentHeight: scroll.contentSize.height,
            scrollable: slack,
            travelled: travelled,
            ticks: ticks,
            idealTicks: idealTicks)
    }

    private func percentOver(_ values: [Double], _ budget: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.filter { $0 > budget }.count) / Double(values.count) * 100
    }

    // MARK: - 尺三：结构 + 像素 + 成本

    /// 结构（`UIView` 数 / 类名直方图）、`hitTest` 耗时、footprint / CPU、像素判据。
    ///
    /// - Parameters:
    ///   - ocr: 开 `VisionTextProbe`。**默认关** —— 模拟器上 Vision 走宿主 Mac 的
    ///     CPU，首次请求常要好几秒，而「空壳」这种硬故障墨迹就能挡住。要认字再开。
    ///   - hitSamples: 每个位置打多少次 `hitTest`（首中尾三处，共 3×samples 次）。
    ///
    /// 截图取的是**进来时那一屏**：hitTest 会把列表扫到首中尾三处，截图前会先滚回来。
    /// 所以 `rig.scrollTo(y); await rig.snapshot()` 截到的确实是 `y` 那一屏。
    func snapshot(ocr: Bool = false, hitSamples: Int = 100) async -> Snapshot {
        guard let host = hostView else {
            return Snapshot(views: 0, histogram: "<not mounted>", hitP50: 0, hitP95: 0,
                            footprintMB: ProbeMetrics.footprintMB(),
                            cpuSeconds: ProbeMetrics.threadCPUSeconds(),
                            contentHeight: 0, scrollable: 0, ink: 0, png: nil,
                            pixelsAvailable: false, ocrText: nil)
        }

        // 量之前先把当前滚动位置记下来 —— 下面的 hitTest 要扫首中尾三处，
        // 扫完停在 98% 那一处。不还原的话「滚到第 300 行再 snapshot」截出来的是
        // 第 1929 行（实测踩过），像素/OCR 判据当场对不上号。
        let offsetBefore = scrollView?.contentOffset.y ?? 0

        // hitTest：首中尾三处各打 hitSamples 次。它不随规模涨才说明命中路径没被行数拖累。
        var hits: [Double] = []
        let amplitude: CGFloat = {
            guard let scroll = scrollView else { return 0 }
            return Swift.max(0, scroll.contentSize.height - scroll.bounds.height)
        }()
        for fraction in [0.02, 0.5, 0.98] {
            scrollTo(amplitude * CGFloat(fraction))
            layout()
            try? await Task.sleep(for: .milliseconds(120))
            for i in 0..<hitSamples {
                let point = CGPoint(x: CGFloat(40 + (i % 8) * 40), y: CGFloat(40 + (i % 15) * 40))
                let start = CFAbsoluteTimeGetCurrent()
                _ = host.hitTest(point, with: nil)
                hits.append((CFAbsoluteTimeGetCurrent() - start) * 1_000_000)
            }
        }

        // 像素：`drawHierarchy(afterScreenUpdates:)` 而非 `layer.render(in:)`。
        // 后者不走 SwiftUI 的绘制路径，纯 Text 会被画成一片白，墨迹判据直接假红。
        //
        // **三档都真截**，不按摆法预判 —— 「哪档取得到像素」是靠
        // `ProbeRigSelfTests.testPlacementABIsRecorded` 量出来的事实，不是这里写死的假设。
        // 实测结论：`.offScreen` 也截得到，三档 ink 一位不差（README「三档 A/B」）。
        // `pixelsAvailable` 因此是**读数**（`ink > 0`）而不是配置：一张全空白的图
        // 众数占满全幅，`inkFraction` 恰好是 0。
        // 还原到进 snapshot 之前的那一屏，再截图。
        scrollTo(offsetBefore)
        layout()
        try? await Task.sleep(for: .milliseconds(120))
        let png = capturePNG()
        let ink = png.map { VisionTextProbe.inkFraction(png: $0) } ?? 0
        let pixelsAvailable = ink > 0

        var text: String?
        if ocr, let png { text = await VisionTextProbe.text(png) }

        return Snapshot(views: host.recursiveViewCount(),
                        histogram: host.classHistogram(),
                        hitP50: ProbeMetrics.percentile(hits, 0.5),
                        hitP95: ProbeMetrics.percentile(hits, 0.95),
                        footprintMB: ProbeMetrics.footprintMB(),
                        cpuSeconds: ProbeMetrics.threadCPUSeconds(),
                        contentHeight: scrollView?.contentSize.height ?? 0,
                        scrollable: amplitude,
                        ink: ink,
                        png: png,
                        pixelsAvailable: pixelsAvailable,
                        ocrText: text)
    }

    /// 当前屏上这一帧的 PNG。
    ///
    /// `drawHierarchy(in:afterScreenUpdates: true)` 而非 `layer.render(in:)`：
    /// 后者不走 SwiftUI 的绘制路径，纯 `Text` 会被画成一片白（README 坑⑥）。
    func capturePNG() -> Data? {
        guard let host = hostView else { return nil }
        layout()
        let renderer = UIGraphicsImageRenderer(bounds: host.bounds)
        return renderer.pngData { _ in
            host.drawHierarchy(in: host.bounds, afterScreenUpdates: true)
        }
    }

    // MARK: - 收尾

    /// 拆窗，并留一小段让图层后备存储真的散掉（下一档的 footprint 才干净）。
    func close() async {
        if let window { MobileProbeWindow.close(window) }
        window = nil
        hostView = nil
        scrollView = nil
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - 报告

    /// 一行读数进日志。**绝对毫秒只打印，闸门只用结构判据。**
    func report(_ scroll: ScrollReading? = nil,
                _ snapshot: Snapshot? = nil,
                _ heartbeat: Heartbeat? = nil) {
        var parts: [String] = [String(format: "[%@] placement=%@ mount=%.2fms",
                                      label, placement.short, mountMS)]
        if let heartbeat {
            parts.append(String(format: "sleep=%d/%d(%.2f) ticks=%d/%d(%.2f) tick-p95=%.2fms "
                                + "nominal=%.2fms rate=%@",
                                heartbeat.sleepBeats, heartbeat.idealSleepBeats, heartbeat.sleepRatio,
                                heartbeat.displayTicks, heartbeat.idealDisplayTicks,
                                heartbeat.displayRatio, heartbeat.tickIntervalP95,
                                heartbeat.nominalIntervalMS, heartbeat.rateRange))
        }
        if let scroll {
            parts.append(String(format: "driver=%@ steps=%d p50=%.3fms p95=%.3fms max=%.3fms "
                                + "over-%.2f=%.1f%% over-8.33=%.1f%% amp=%.0f content=%.0f "
                                + "scrollable=%.0f travelled=%.0f",
                                scroll.driver.short, scroll.steps, scroll.p50, scroll.p95, scroll.max,
                                scroll.budgetMS, scroll.overBudgetPct, scroll.overStrictPct,
                                scroll.amplitude, scroll.contentHeight, scroll.scrollable,
                                scroll.travelled))
            if scroll.driver == .fingerDrag {
                parts.append(String(format: "drag-ticks=%d/%d", scroll.ticks, scroll.idealTicks))
            }
        }
        if let snapshot {
            parts.append(String(format: "views=%d hit-p50=%.1fus hit-p95=%.1fus ink=%.4f%@ "
                                + "cpu=%.2fs footprint=%.1fMB",
                                snapshot.views, snapshot.hitP50, snapshot.hitP95, snapshot.ink,
                                snapshot.pixelsAvailable ? "" : "(n/a)",
                                snapshot.cpuSeconds, snapshot.footprintMB))
        }
        print(parts.joined(separator: " "))
        if let snapshot { print("[\(label)-views] \(snapshot.histogram)") }
        if let window { print("[\(label)-window] \(MobileProbeWindow.describe(window))") }
    }
}

// MARK: - ScrollViewReader 驱动

/// `ScrollViewReader` 的 proxy 逃逸口。
///
/// SwiftUI 的 `ScrollViewProxy` 只在 `ScrollViewReader` 的闭包里拿得到，探针在外面。
/// 用 `ProbeScrollReaderBox` 包一层，proxy 就落进这个盒子，
/// 之后 `rig.scrollViaReader(anchor, to: 900)` 就能驱动。
/// **刻意不标 `@MainActor`**：绑定点在 SwiftUI 的 `onAppear` 里，那是个非隔离闭包，
/// 从里面写一个 `@MainActor` 属性在 Swift 6 语言模式下判成数据竞争。
/// 实际读写全在主线程（`onAppear` 与探针都在主线程），所以 `@unchecked Sendable`
/// 是「绕开判定」而不是「真的跨线程共享」。
final class ProbeScrollAnchor: @unchecked Sendable {
    /// `(id, anchor)` → 滚过去。未绑定时为 nil。
    var scrollTo: ((Int, UnitPoint) -> Void)?
    var isBound: Bool { scrollTo != nil }
}

/// 把内容包进 `ScrollViewReader` 并把 proxy 交给 `anchor`。
///
/// 用法（`ForEach` 的 id 必须是 `Int`，与 `scrollViaReader(to:)` 的形参对上）：
/// ```swift
/// ProbeScrollReaderBox(anchor: anchor) {
///     ScrollView { LazyVStack { ForEach(0..<rows, id: \.self) { Text("\($0)").id($0) } } }
/// }
/// ```
struct ProbeScrollReaderBox<Content: View>: View {
    let anchor: ProbeScrollAnchor
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            content().onAppear {
                anchor.scrollTo = { id, point in
                    // 不加 `withAnimation`：探针要的是「立刻到位」，动画会把
                    // 读数摊到之后好几帧上，单帧成本就失真了。
                    proxy.scrollTo(id, anchor: point)
                }
            }
        }
    }
}

// MARK: - 附件

extension XCTestCase {
    /// 把 PNG 挂进 xcresult（失败时能直接看到当时屏上是什么），并落一份到临时目录。
    /// 返回落盘路径，方便直接 `open`。
    @discardableResult
    func attachProbePNG(_ png: Data?, name: String) -> String? {
        guard let png else { return nil }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        try? png.write(to: url)
        return url.path
    }
}
