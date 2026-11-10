import GhosttyTerminal
import IOSurface
import QuartzCore
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// M16 第五轮：user 说惯性「还是一抖一抖的」，第四轮量的是主线程节拍和我们发出去的步子，没量到真正上屏的画面。
///
/// 这里量「每个显示帧实际显示的位移」：
/// - Ghostty：画面在 `IOSurfaceLayer.contents` 的 IOSurface 里（不是 CAMetalLayer，没有 drawable 可挂 presented handler）。
///   在 Core Animation 提交之后（主 runloop 的 beforeWaiting，order 排在 CA 提交的 2000000 之后）读当时已提交的 IOSurface，
///   从画面本身解出滚动位置：回滚区每行开头 7 格是行号的二进制条码（█ = 1），第 0 列逐行交替，扫一列像素找到行边界，
///   再读 7 格得到行号，位置 = 行号 × 格高 − 行边界的 y。读的是画面，不是我们发了什么。
///   甩动走系统滚动那条路径（单指滚回滚区恒归 UIScrollView）：按 UIKit 会做的事驱动 GhosttyKit 借来的滚动视图
///  （`EdgeSystemFinger`：拖一步、松手，减速由 display link 每帧按三次缓出写 contentOffset 代替 UIKit）。
///   量的是「每一帧 contentOffset 走了多少，那一拍上屏的画面就走了多少」，不是 UIKit 的减速曲线本身。
///   原来这里是伪造 pan 硬调 `handleTouchScrollGesture:`，量本地包里自写的落点惯性；那套自写物理已经整套删掉。
///
/// 原来还有一半拿换引擎之前的终端视图（UIScrollView 子类）用同一套量法当参照、核「Ghostty 不比它差」；旧引擎已经从 App 里
/// 拿掉，那一半连同参照用例一起去掉了，Ghostty 自己的绝对门槛（`assertSmooth`）照旧。
///
/// 每个显示帧 = 参考 `CADisplayLink`（80–120 Hz，和减速 link 同档，不额外抬帧率）两次回调之间；这段时间里最后一次提交的画面
/// 就是下一个 vsync 显示的画面。
@MainActor
final class GhosttyOnScreenScrollTests: XCTestCase {
    override func setUp() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func tearDown() async throws {
        UTermScrollTrace.isEnabled = false
    }

    // MARK: - 提交后采样

    /// 每次 CA 提交之后调 `read` 取一次上屏位置；同时用参考 link 记每个显示帧的边界。
    @MainActor
    final class CommitSampler: NSObject {
        struct Sample { let time: Double; let value: Double }
        private(set) var samples: [Sample] = []
        private(set) var frameStarts: [Double] = []
        private(set) var targets: [Double] = []
        private(set) var failures = 0
        private(set) var observations = 0
        var read: (@MainActor () -> Double?)?
        private var observer: CFRunLoopObserver?
        private var link: CADisplayLink?

        func start() {
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, 2_000_001
            ) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.observe() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }

        @objc private func frame(_ link: CADisplayLink) {
            frameStarts.append(CACurrentMediaTime())
            targets.append(link.targetTimestamp)
            observe()
        }

        private func observe() {
            observations += 1
            guard let read else { return }
            if let value = read() {
                samples.append(Sample(time: CACurrentMediaTime(), value: value))
            } else {
                failures += 1
            }
        }
    }

    // MARK: - Ghostty：从 IOSurface 解出滚动位置

    nonisolated static let barcodeBits = 7

    /// 回滚区：每行开头 7 格是行号 k 的二进制（第 j 格 = 第 j 位，█ = 1），第 0 列因此逐行交替。
    /// 条码后面接一段像 Claude 跑过的带色 diff + 中文说明（让渲染的活儿接近真实回滚区），右边留几列空白当底色采样点。
    static func barcodeHistory(lines: Int, cols: Int) -> String {
        let colors = ["32", "31", "36", "33", "90"]
        let room = max(0, (cols - barcodeBits - 8) / 2)   // 中文占两列，按字数的一半放，保证不折行
        return (0..<lines).map { k in
            let code = (0..<barcodeBits).map { (k >> $0) & 1 == 1 ? "█" : " " }.joined()
            let text = "\(k % 2 == 0 ? "+" : "⎿") let v\(k % 10) = f(\(k)) // 说明 App/File\(k % 100).swift 处理滚动收尾"
            return code + "  \u{1B}[\(colors[k % colors.count])m\(String(text.prefix(room)))\u{1B}[0m\r\n"
        }.joined()
    }

    struct BarcodeDecoder {
        let cellWidth: Int
        let cellHeight: Int
        private(set) var last: Double?
        private(set) var pixelFormat: OSType = 0
        private(set) var diagnostic: String?

        init(cell: CGSize) {
            cellWidth = Int(cell.width)
            cellHeight = Int(cell.height)
        }

        /// 已提交画面的顶边在回滚内容里的像素位置（连续展开，不回绕）。
        mutating func position(of layer: CALayer) -> Double? {
            guard let contents = layer.contents else { return nil }
            let object = contents as AnyObject
            guard CFGetTypeID(object as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
            let surface = unsafeBitCast(object, to: IOSurfaceRef.self)
            IOSurfaceLock(surface, .readOnly, nil)
            defer { IOSurfaceUnlock(surface, .readOnly, nil) }
            pixelFormat = IOSurfaceGetPixelFormat(surface)
            let base = IOSurfaceGetBaseAddress(surface)
            let rowBytes = IOSurfaceGetBytesPerRow(surface)
            let width = IOSurfaceGetWidth(surface)
            let height = IOSurfaceGetHeight(surface)
            let element = IOSurfaceGetBytesPerElement(surface)
            let lum: (Int, Int) -> Double
            switch element {
            case 4:
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                lum = { x, y in
                    let p = bytes + y * rowBytes + x * 4
                    return Double(Int(p[0]) + Int(p[1]) + Int(p[2])) / 765
                }
            case 8:
                lum = { x, y in
                    let p = (base + y * rowBytes + x * 8).assumingMemoryBound(to: UInt16.self)
                    return Double(Float(Float16(bitPattern: p[0])) + Float(Float16(bitPattern: p[1]))
                        + Float(Float16(bitPattern: p[2]))) / 3
                }
            default:
                return nil
            }
            guard width > cellWidth * Self.bitsWidth, height > cellHeight * 3 else { return nil }
            let background = lum(width - 3, height / 2)
            let ink: (Int, Int) -> Bool = { x, y in abs(lum(x, y) - background) > 0.3 }
            let x0 = cellWidth / 2
            var previous = ink(x0, 0)
            var edge = -1
            for y in 1..<min(height, cellHeight * 3) {
                let now = ink(x0, y)
                if now != previous { edge = y; break }
                previous = now
            }
            if diagnostic == nil {
                let column = stride(from: 0, to: min(height, cellHeight * 3), by: 3).map { String(format: "%.2f", lum(x0, $0)) }
                let row = stride(from: 0, to: min(width, cellWidth * 10), by: 4).map { String(format: "%.2f", lum($0, cellHeight + cellHeight / 2)) }
                diagnostic = "size=\(width)x\(height) cell=\(cellWidth)x\(cellHeight) bg=\(background) edge=\(edge) col0=\(column.joined(separator: ",")) row1=\(row.joined(separator: ","))"
            }
            guard edge > 0, edge + cellHeight / 2 < height else { return nil }
            let middle = edge + cellHeight / 2
            var row = 0
            for bit in 0..<GhosttyOnScreenScrollTests.barcodeBits where ink(bit * cellWidth + cellWidth / 2, middle) {
                row |= 1 << bit
            }
            let period = Double((1 << GhosttyOnScreenScrollTests.barcodeBits) * cellHeight)
            let raw = Double(row * cellHeight - edge)
            guard let last else {
                self.last = raw
                return raw
            }
            let turns = ((last - raw) / period).rounded()
            let value = raw + turns * period
            self.last = value
            return value
        }

        private static var bitsWidth: Int { GhosttyOnScreenScrollTests.barcodeBits + 1 }
    }

    static func surfaceLayer(in root: CALayer) -> CALayer? {
        if NSStringFromClass(type(of: root)).contains("IOSurface") { return root }
        for sub in root.sublayers ?? [] {
            if let found = surfaceLayer(in: sub) { return found }
        }
        return nil
    }

    // MARK: - 分析

    struct Report {
        let label: String
        /// 每个显示帧实际显示的位移（px，已按运动方向取正）。
        let shown: [Double]
        /// 同一帧里我们发出去的位移（没传 `sentEvents` 时为 nil）。
        let sent: [Double]?
        let lag: Int
        let mismatches: Int
        /// 速度 ≥ 2 px/帧时出现的 0 位移帧（这一拍没换画面）。
        let repeats: Int
        /// 二阶差分 |Δ[i+1] − 2Δ[i] + Δ[i−1]| 的最大值，不含开头 2 帧（手指拖动交给减速的那一下单列）。
        let maxJerk: Double
        /// 相邻两帧位移比的最大值（两帧都 ≥ 4 px 时才算，取整噪声不算进来），同样不含开头 2 帧。
        let maxRatio: Double
        /// 开头 3 帧的位移（只打印）。
        let handoff: [Double]
        /// 换了画面的提交离它该显示的 vsync 还剩多少 ms：最小值，和不到 1 ms 的个数。
        let minMargin: Double
        let tightMargins: Int
        let decoded: Int
        let failures: Int
        let travelled: Double

        var line: String {
            let head = shown.prefix(40).map { String(format: "%.0f", $0) }.joined(separator: ",")
            let tail = shown.suffix(60).map { String(format: "%.0f", $0) }.joined(separator: ",")
            let sentTail = (sent ?? []).suffix(60).map { String(format: "%.0f", $0) }.joined(separator: ",")
            return String(format: "ONSCREEN %@ frames=%d travelled=%.0fpx repeats=%d max-jerk=%.0fpx max-ratio=%.2f handoff=%@ lag=%d mismatch=%d commit-margin-min=%.2fms margins<1ms=%d decoded=%d failed=%d | shown-head=%@ | shown-tail=%@ | sent-tail=%@",
                          label, shown.count, travelled, repeats, maxJerk, maxRatio,
                          handoff.map { String(format: "%.0f", $0) }.joined(separator: "/"), lag, mismatches,
                          minMargin, tightMargins, decoded, failures, head, tail, sentTail)
        }
    }

    /// 按 vsync 分桶：一次提交在第一个比它晚的 targetTimestamp 上屏（参考 link 每拍记的 target），每拍取最后一次提交，
    /// 算每拍位移；只看运动区间（第一次动到最后一次动）。
    static func analyze(_ label: String, sampler: CommitSampler, sentEvents: [(time: Double, value: Double)]?) -> Report {
        let targets = sampler.targets
        func slot(_ time: Double) -> Int? {
            guard let last = targets.last, time < last else { return nil }
            var lo = 0, hi = targets.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if targets[mid] > time { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
        var position = [Double?](repeating: nil, count: targets.count)
        var previousValue: Double?
        var margins: [Double] = []
        for sample in sampler.samples {
            guard let index = slot(sample.time) else { continue }
            position[index] = sample.value
            if let previousValue, abs(previousValue - sample.value) > 0.5 { margins.append((targets[index] - sample.time) * 1000) }
            previousValue = sample.value
        }
        var carried: Double?
        let filled: [Double] = position.map { value in
            if let value { carried = value }
            return carried ?? .nan
        }
        var delta = [Double](repeating: 0, count: targets.count)
        for index in 1..<max(1, filled.count) where !filled[index].isNaN && !filled[index - 1].isNaN {
            delta[index] = filled[index] - filled[index - 1]
        }
        var sent = [Double](repeating: 0, count: targets.count)
        for event in sentEvents ?? [] { if let index = slot(event.time) { sent[index] += event.value } }

        let moving = delta.indices.filter { abs(delta[$0]) > 0.5 }
        guard let firstMove = moving.first, let lastMove = moving.last else {
            return Report(label: label, shown: [], sent: nil, lag: 0, mismatches: 0, repeats: 0, maxJerk: 0, maxRatio: 0,
                          handoff: [], minMargin: 0, tightMargins: 0, decoded: sampler.samples.count,
                          failures: sampler.failures, travelled: 0)
        }
        let window = Array(firstMove...lastMove)
        let total = window.reduce(0) { $0 + delta[$1] }
        let sign: Double = total < 0 ? -1 : 1
        let shown = window.map { delta[$0] * sign }

        // 平滑速度：前后各 2 帧的平均位移。速度 ≥ 2 px/帧时，整像素取整不会造成 0 位移帧，出现 0 就是重复帧。
        func speed(_ i: Int) -> Double {
            let range = max(0, i - 2)...min(shown.count - 1, i + 2)
            return range.reduce(0) { $0 + shown[$1] } / Double(range.count)
        }
        var repeats = 0, maxJerk = 0.0, maxRatio = 1.0
        for i in shown.indices {
            let fast = speed(i) >= 2
            if fast, shown[i] < 0.5 { repeats += 1 }
            guard i >= 2 else { continue }
            if fast, i < shown.count - 1 {
                maxJerk = max(maxJerk, abs(shown[i + 1] - 2 * shown[i] + shown[i - 1]))
            }
            if shown[i] >= 4, shown[i - 1] >= 4 {
                maxRatio = max(maxRatio, shown[i] / shown[i - 1], shown[i - 1] / shown[i])
            }
        }

        var lag = 0, mismatches = 0
        var sentWindow: [Double]?
        if sentEvents != nil {
            let sentTotal = sent.reduce(0, +)
            let sentSign: Double = sentTotal < 0 ? -1 : 1
            var best = Int.max
            for candidate in 0...3 {
                let count = window.filter { index in
                    let source = index - candidate
                    let expected = source >= 0 ? sent[source] * sentSign : 0
                    return abs(delta[index] * sign - expected) > 0.5
                }.count
                if count < best { best = count; lag = candidate }
            }
            mismatches = best
            sentWindow = window.map { $0 - lag >= 0 ? sent[$0 - lag] * sentSign : 0 }
        }
        return Report(label: label, shown: shown, sent: sentWindow, lag: lag, mismatches: mismatches, repeats: repeats,
                      maxJerk: maxJerk, maxRatio: maxRatio, handoff: Array(shown.prefix(3)),
                      minMargin: margins.min() ?? 0, tightMargins: margins.filter { $0 < 1 }.count,
                      decoded: sampler.samples.count, failures: sampler.failures, travelled: abs(total))
    }

    // MARK: - Ghostty 甩动

    private func ghosttyFling(output: Bool, velocity: CGFloat) async throws -> Report {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 600))
        defer { host.close() }
        try await host.waitUntilReady()
        let cols = host.grid.cols
        host.feedAndWait(Self.barcodeHistory(lines: 400, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols))
        return try await measureGhosttyFling(label: "ghostty", view: host.view, output: output, velocity: velocity) { text in
            host.bridge.feed(Data(text.utf8))
        } frame: { TerminalSpikeCorpus.claudeFrame($0, cols: cols) }
    }

    /// 同一套量法，挂在整个工作区界面里（标签条、键盘条、SwiftUI 外壳都在），输出走假 SSH 后端、经控制器进 Ghostty——
    /// 和 user 手机上的路径只差真手指。
    private func ghosttyFlingInWorkspace(output: Bool, velocity: CGFloat) async throws -> Report {
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
        let rig = MobileProbeRig(label: "ghostty-onscreen")
        rig.mount(WorkspaceScreen()
            .environment(store).environment(relay).environment(sessions)
            .environment(\.mAccent, M.accent).modelContainer(container))
        tab.controller.start(profile: server, container: container, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(connected)
        let bridge = tab.controller.terminal
        // surface 建好、网格到位、画面开始吃字节之后再喂：就绪之前喂的只进影子，要等一次回放才上屏。
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.view.surface != nil && bridge.grid != nil && bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface
        }
        XCTAssertTrue(ready, "Ghostty surface 没建起来")
        let transport = try XCTUnwrap(handles.latest)
        let cols = bridge.grid?.cols ?? 80
        await transport.write(Data((Self.barcodeHistory(lines: 400, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols)).utf8))
        _ = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { (bridge.view.uTermCellPixels != nil) }
        try await Task.sleep(for: .milliseconds(500))
        defer { tab.controller.close() }
        return try await measureGhosttyFling(label: "ghostty-workspace", view: bridge.view, output: output, velocity: velocity) { text in
            await transport.write(Data(text.utf8))
        } frame: { TerminalSpikeCorpus.claudeFrame($0, cols: cols) }
    }

    private func measureGhosttyFling(label: String, view: MGhosttyTerminalView, output: Bool, velocity: CGFloat = 1000,
                                     feed: @escaping @MainActor (String) async -> Void,
                                     frame: @escaping @MainActor (Int) -> String) async throws -> Report {
        try await Task.sleep(for: .milliseconds(300))
        let cell = try XCTUnwrap(view.uTermCellPixels)
        for _ in 0..<60 { view.sendMouseScroll(x: 0, y: Double(cell.height), mods: TerminalScrollModifiers(precision: true)) }
        try await Task.sleep(for: .milliseconds(300))
        let layer = try XCTUnwrap(Self.surfaceLayer(in: view.layer), "找不到 IOSurfaceLayer")
        let finger = try EdgeSystemFinger(view: view)
        XCTAssertTrue(view.uTermSystemPanWouldBegin, "有回滚的普通屏：单指拖动应当归系统滚动")
        // 按下就松手、带速度：量的是松手后的减速，时长按「初速度 = 抬手速度」定（见 EdgeSystemFinger.flingSeconds）。
        // 不先拖一步：拖动那一步和减速第一帧之间隔着减速 link 起步的那一拍（测试里的假减速才有，UIKit 没有），
        // 混进来就是一拍不动再接一大步，量到的是夹具不是滚动。
        func fling(_ velocity: CGFloat) {
            finger.begin()
            finger.end(velocity: velocity, seconds: EdgeSystemFinger.flingSeconds)
        }
        // 预热（第一次起 link、编管线不算），等它完全落定。
        fling(-300)
        try await Task.sleep(for: .milliseconds(2200))

        var decoder = BarcodeDecoder(cell: cell)
        let sampler = CommitSampler()
        sampler.read = { decoder.position(of: layer) }
        UTermScrollTrace.isEnabled = true
        GhosttyPresentLog.reset()
        sampler.start()
        let feeder = output ? Task { @MainActor in
            var n = 1
            while !Task.isCancelled {
                await feed(frame(n))
                n += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        } : nil
        try await Task.sleep(for: .milliseconds(100))
        fling(velocity)
        try await Task.sleep(for: .milliseconds(2600))
        feeder?.cancel()
        sampler.stop()
        let trace = UTermScrollTrace.drain()
        UTermScrollTrace.isEnabled = false
        // 减速每一步按它算位置用的 targetTimestamp 归拍（回调偶尔晚到，按回调时刻归会错拍，上屏其实是准的）。
        let frames = finger.decelerator.frames
        func target(for time: Double) -> Double? { frames.last { $0.time <= time }?.target }
        var sent: [(time: Double, value: Double)] = []
        for event in trace {
            switch event.kind {
            case "momentum": sent.append((time: (target(for: event.time) ?? event.time + 0.0001) - 0.0001, value: event.value))
            case "drag": sent.append((time: event.time, value: event.value))
            default: break
            }
        }
        let report = Self.analyze("\(label) v=\(Int(velocity)) output=\(output)", sampler: sampler, sentEvents: sent)
        // 减速 link 算位置用的 targetTimestamp 和参考 link 的是不是同一个 vsync（不是的话就是两条 link 相位不齐）。
        let offGrid = frames.filter { f in !sampler.targets.contains { abs($0 - f.target) < 0.001 } }.count
        // 起步诊断：减速头几帧的回调时刻 / target、参考 link 的 vsync，都相对第一帧的回调时刻（ms）。
        if let origin = frames.first?.time {
            let rel = { (t: Double) in String(format: "%.2f", (t - origin) * 1000) }
            let first = frames.prefix(4).map { "decel-target=\(rel($0.target))@\(rel($0.time))" }
            let vsyncs = sampler.targets.filter { abs($0 - origin) < 0.03 }.map(rel)
            print("ONSCREEN-START \(label) v=\(Int(velocity)) output=\(output) \(first.joined(separator: " ")) ref-targets=\(vsyncs.joined(separator: ","))")
        }
        print("ONSCREEN-PHASE \(label) v=\(Int(velocity)) output=\(output) decel-frames=\(frames.count) decel-target-not-a-ref-vsync=\(offGrid)")
        print(report.line)
        print("ONSCREEN-DIAG \(decoder.diagnostic ?? "-")")

        // 时序：减速每一步发出去之后，Ghostty 多久把画面交给 CA、交的那一刻在显示帧里的相位。
        let presents = GhosttyPresentLog.read()
        let glide = trace.filter { $0.kind == "momentum" }.map(\.time)
        let latency = glide.compactMap { t in presents.times.first { $0 >= t }.map { ($0 - t) * 1000 } }
        let starts = sampler.frameStarts
        let phases: [Double] = presents.times.compactMap { t in
            guard let index = starts.lastIndex(where: { $0 <= t }), index + 1 < starts.count else { return nil }
            return (t - starts[index]) / (starts[index + 1] - starts[index])
        }
        print(String(format: "ONSCREEN-TIMING %@ output=%@ presents=%d offMain=%d decel-steps=%d step→present p50=%.1fms p95=%.1fms max=%.1fms present-phase p50=%.2f p95=%.2f max=%.2f pixel-format=%@ frames=%d frame-interval-p50=%.2fms",
                     label, "\(output)", presents.times.count, presents.offMain, glide.count,
                     ProbeMetrics.percentile(latency, 0.5), ProbeMetrics.percentile(latency, 0.95), latency.max() ?? 0,
                     ProbeMetrics.percentile(phases, 0.5), ProbeMetrics.percentile(phases, 0.95), phases.max() ?? 0,
                     fourCC(decoder.pixelFormat), starts.count,
                     ProbeMetrics.percentile(zip(starts, starts.dropFirst()).map { ($1 - $0) * 1000 }, 0.5)))
        XCTAssertTrue(view.uTermScrollState.isAtRest, "\(report.label)：甩完之后没停在整行上 \(view.uTermScrollState)")
        return report
    }

    private func fourCC(_ code: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
    }

    // MARK: - 用例

    /// 每拍上屏位移的回归门槛（单独窗口 / 整个工作区界面，有无输出，初速 1000 / 4000 pt/s 都要过）：
    /// - 重复帧 0（速度 ≥ 2 px/帧时没有一拍不换画面）；
    /// - 和这一拍发出去的位移逐拍对得上（错位 ≤ 1 拍）；
    /// - 二阶差分 ≤ 4 px、相邻两拍位移比 ≤ 1.35（整像素取整的噪声是 1–2 px、比值 1.25 左右）。
    ///
    /// 原来还有一条「交接那一拍只有拖动那一步」（开头那一拍的位移 = 18 px）：那是本地包里「拖动 → 惯性交接对齐上屏」的
    /// 回归门槛，那段代码随自写物理删了；系统路径上手指最后一步和减速第一步谁落在哪一拍是 UIKit 的事，测试里的假减速
    /// 复现不了，所以这一条去掉，甩动也不再先拖一步（见 measureGhosttyFling）。
    private func assertSmooth(_ report: Report, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(report.shown.count, 30, "\(report.label)：上屏位置没解出来（decoded=\(report.decoded) failed=\(report.failures)）",
                             file: file, line: line)
        XCTAssertEqual(report.repeats, 0, "\(report.label)：重复帧", file: file, line: line)
        XCTAssertLessThanOrEqual(report.mismatches, 1, "\(report.label)：上屏和发出的位移对不上", file: file, line: line)
        XCTAssertLessThanOrEqual(report.maxJerk, 4, "\(report.label)：每拍位移忽大忽小（二阶差分）", file: file, line: line)
        XCTAssertLessThanOrEqual(report.maxRatio, 1.35, "\(report.label)：相邻两拍位移比", file: file, line: line)
    }

    func testGhosttyFlingOnScreen() async throws {
        for velocity in [1000, 4000] as [CGFloat] {
            for output in [false, true] {
                let report = try await ghosttyFling(output: output, velocity: velocity)
                assertSmooth(report)
            }
        }
    }

    /// 原来核「拖动交给惯性的那一帧不能一帧走两步」：在 display link 回调前 0.3–6 ms 的各个相位上松手，交接那一帧上屏的
    /// 位移必须只是拖动那一步。它测的是本地包里自写惯性的交接逻辑（起点对到 vsync、等拖动那一步画上画面层再补发第一步，
    /// 靠 `glide-first` 打点判定），那段代码已经随自写滚动物理删掉。系统路径上这一拍由 UIKit 自己交接（手指最后一个事件和
    /// 减速第一帧都在它手里），测试没法伪造触摸来驱动它；剩下的自写惯性（抓鼠标 / 备用屏）不滚视口，没有「上屏位移」可量。
    /// 系统路径上屏位置的连续性由 `testGhosttyFlingOnScreen` 和 `GhosttySystemScrollJitterTests` 核。
    func testGhosttyFlingHandoffOnScreen() throws {
        throw XCTSkip("自写惯性的「拖动 → 惯性交接对齐上屏」已随自写滚动物理删除；系统滚动的交接在 UIKit 里，测试驱动不了。"
            + "上屏位置的连续性见 testGhosttyFlingOnScreen 与 GhosttySystemScrollJitterTests")
    }

    func testGhosttyFlingOnScreenInWorkspace() async throws {
        for velocity in [1000, 4000] as [CGFloat] {
            for output in [false, true] {
                let report = try await ghosttyFlingInWorkspace(output: output, velocity: velocity)
                assertSmooth(report)
            }
        }
    }
}
