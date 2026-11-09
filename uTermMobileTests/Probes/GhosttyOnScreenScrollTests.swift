import GhosttyTerminal
import IOSurface
import ObjectiveC
import QuartzCore
import SwiftData
import SwiftTerm
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
/// - SwiftTerm（UIScrollView）：文字画在滚动视图自己的 layer 上，`bounds` 变了但没重画时文字不动，所以上屏位置 = 最近一次
///   `draw(_:)` 时的 `contentOffset`。甩动走 UIScrollView 自己的 `handlePan:` 和减速（真 pan 识别器对象，换掉 state /
///   translation / velocity 三个读数），和手指甩出去走同一套 UIKit 代码。
///
/// 每个显示帧 = 参考 `CADisplayLink`（80–120 Hz，和惯性 link 同档，不额外抬帧率）两次回调之间；这段时间里最后一次提交的画面
/// 就是下一个 vsync 显示的画面。
@MainActor
final class GhosttyOnScreenScrollTests: XCTestCase {
    override func setUp() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func tearDown() async throws {
        UTermScrollTrace.isEnabled = false
        restoreDraw?()
        restoreDraw = nil
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
        /// 同一帧里我们发出去的位移（SwiftTerm 没有）。
        let sent: [Double]?
        let lag: Int
        let mismatches: Int
        /// 速度 ≥ 2 px/帧时出现的 0 位移帧（这一拍没换画面）。
        let repeats: Int
        /// 二阶差分 |Δ[i+1] − 2Δ[i] + Δ[i−1]| 的最大值，不含开头 2 帧（手指拖动交给惯性的那一下单列）。
        let maxJerk: Double
        /// 相邻两帧位移比的最大值（两帧都 ≥ 4 px 时才算，取整噪声不算进来），同样不含开头 2 帧。
        let maxRatio: Double
        /// 开头 3 帧的位移（看拖动 → 惯性交接有没有一下跳）。
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
        let rig = MobileProbeRig(label: "ghostty-onscreen")
        rig.mount(WorkspaceScreen()
            .environment(store).environment(relay).environment(sessions)
            .environment(\.mAccent, M.accent).modelContainer(container))
        tab.controller.start(profile: server, container: container, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(connected)
        let bridge = try XCTUnwrap(tab.controller.ghostty, "试用开关打开后标签应当走 Ghostty")
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { bridge.view.surface != nil && bridge.grid != nil }
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
        let pan = Pan()
        let selector = NSSelectorFromString("handleTouchScrollGesture:")
        func fling(_ velocity: CGFloat) {
            pan.fakeState = .began; pan.fakeTranslation = .zero; _ = view.perform(selector, with: pan)
            pan.fakeState = .changed; pan.fakeTranslation = CGPoint(x: 0, y: 6); _ = view.perform(selector, with: pan)
            pan.fakeState = .ended; pan.fakeTranslation = .zero; pan.fakeVelocity = CGPoint(x: 0, y: velocity)
            _ = view.perform(selector, with: pan)
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
        let sent = trace.filter { $0.kind == "momentum" || $0.kind == "drag" }.map { (time: $0.time, value: $0.value) }
        let report = Self.analyze("\(label) v=\(Int(velocity)) output=\(output)", sampler: sampler, sentEvents: sent)
        // 惯性 link 算位置用的 targetTimestamp 和参考 link 的是不是同一个 vsync（不是的话就是两条 link 相位不齐）。
        let glideTargets = trace.filter { $0.kind == "glide-target" }.map(\.value)
        let offGrid = glideTargets.filter { t in !sampler.targets.contains { abs($0 - t) < 0.001 } }.count
        let packageCommits = trace.filter { $0.kind == "commit" }.count
        // 交接诊断：拖动那一步、惯性第一帧的 timestamp / target、参考 link 的 vsync，都相对拖动时刻（ms）。
        if let drag = trace.last(where: { $0.kind == "drag" }) {
            let rel = { (t: Double) in String(format: "%.2f", (t - drag.time) * 1000) }
            let first = trace.filter { $0.kind.hasPrefix("glide-first") || $0.kind == "glide-target" }.prefix(5)
                .map { "\($0.kind)=\(rel($0.value))@\(rel($0.time))" }
            let vsyncs = sampler.targets.filter { abs($0 - drag.time) < 0.03 }.map(rel)
            print("ONSCREEN-HANDOFF \(label) v=\(Int(velocity)) output=\(output) \(first.joined(separator: " ")) ref-targets=\(vsyncs.joined(separator: ","))")
        }
        print("ONSCREEN-PHASE \(label) v=\(Int(velocity)) output=\(output) glide-frames=\(glideTargets.count) glide-target-not-a-ref-vsync=\(offGrid) package-commit-events=\(packageCommits)")
        print(report.line)
        print("ONSCREEN-DIAG \(decoder.diagnostic ?? "-")")

        // 时序：每一步惯性发出去之后，Ghostty 多久把画面交给 CA、交的那一刻在显示帧里的相位。
        let presents = GhosttyPresentLog.read()
        let glide = trace.filter { $0.kind == "momentum" }.map(\.time)
        let latency = glide.compactMap { t in presents.times.first { $0 >= t }.map { ($0 - t) * 1000 } }
        let starts = sampler.frameStarts
        let phases: [Double] = presents.times.compactMap { t in
            guard let index = starts.lastIndex(where: { $0 <= t }), index + 1 < starts.count else { return nil }
            return (t - starts[index]) / (starts[index + 1] - starts[index])
        }
        print(String(format: "ONSCREEN-TIMING %@ output=%@ presents=%d offMain=%d glide-steps=%d step→present p50=%.1fms p95=%.1fms max=%.1fms present-phase p50=%.2f p95=%.2f max=%.2f pixel-format=%@ frames=%d frame-interval-p50=%.2fms",
                     label, "\(output)", presents.times.count, presents.offMain, glide.count,
                     ProbeMetrics.percentile(latency, 0.5), ProbeMetrics.percentile(latency, 0.95), latency.max() ?? 0,
                     ProbeMetrics.percentile(phases, 0.5), ProbeMetrics.percentile(phases, 0.95), phases.max() ?? 0,
                     fourCC(decoder.pixelFormat), starts.count,
                     ProbeMetrics.percentile(zip(starts, starts.dropFirst()).map { ($1 - $0) * 1000 }, 0.5)))
        return report
    }

    private func fourCC(_ code: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
    }

    // MARK: - SwiftTerm（UIScrollView）参照

    private var restoreDraw: (() -> Void)?
    nonisolated(unsafe) private static var drawOffsets: [(time: Double, offset: Double)] = []
    nonisolated(unsafe) private static var drawTarget: ObjectIdentifier?

    private func hookSwiftTermDraw(scale: Double) {
        let method = class_getInstanceMethod(SwiftTerm.TerminalView.self, #selector(UIView.draw(_:)))!
        typealias Draw = @convention(c) (AnyObject, Selector, CGRect) -> Void
        let original = method_getImplementation(method)
        let call = unsafeBitCast(original, to: Draw.self)
        let hooked: @convention(block) (AnyObject, CGRect) -> Void = { view, rect in
            if ObjectIdentifier(view) == Self.drawTarget, let scroll = view as? UIScrollView {
                Self.drawOffsets.append((CACurrentMediaTime(), Double(scroll.contentOffset.y) * scale))
            }
            call(view, #selector(UIView.draw(_:)), rect)
        }
        method_setImplementation(method, imp_implementationWithBlock(hooked))
        restoreDraw = { method_setImplementation(method, original) }
    }

    /// 驱动方式：
    /// - `.uikitAnimation`：`setContentOffset(_:animated: true)`，UIScrollView 自己逐帧推（和它减速走同一个逐帧驱动），
    ///   测「UIKit 自己滚的时候每拍上屏是什么样」；
    /// - `.decelerate`：参考 link 每拍按 UIScrollView `.normal` 的减速（每毫秒 0.998）算位置、按物理像素取整后设
    ///   contentOffset，和 UIScrollView 减速的曲线、取整方式一样。
    /// 用伪造 pan 调 UIScrollView 的 `handlePan:` 起不了减速（试过：拖动生效、松手不减速，第二次还让测试进程退出），没用。
    enum SwiftTermDrive: String { case uikitAnimation, decelerate }

    /// 代码设 contentOffset 时 UIKit 的 isTracking / isDecelerating 恒为假，SwiftTerm 会当成没人在滚、来了输出就把视图拽回底部
    ///（补丁 #17 的逻辑），量的就不是「手指甩出去的惯性」了。把这个实例换成运行时子类，这两个读数由测试给：先 tracking
    /// 把视图停在回滚区（SwiftTerm 记成用户在看历史），再 decelerating 走完减速——和真甩动时 SwiftTerm 看到的一样。
    nonisolated(unsafe) private static var fakeTracking = false
    nonisolated(unsafe) private static var fakeDecelerating = false

    private static func overrideScrollState(_ view: UIScrollView) -> AnyClass {
        let base: AnyClass = object_getClass(view)!
        let name = "UTermProbeScrollState_\(NSStringFromClass(base))"
        if let existing = NSClassFromString(name) {
            object_setClass(view, existing)
            return base
        }
        let cls: AnyClass = objc_allocateClassPair(base, name, 0)!
        let tracking: @convention(block) (AnyObject) -> Bool = { _ in Self.fakeTracking }
        let decelerating: @convention(block) (AnyObject) -> Bool = { _ in Self.fakeDecelerating }
        for (selector, block) in [(#selector(getter: UIScrollView.isTracking), tracking as Any),
                                  (#selector(getter: UIScrollView.isDecelerating), decelerating as Any)] {
            let method = class_getInstanceMethod(base, selector)!
            class_addMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        objc_registerClassPair(cls)
        object_setClass(view, cls)
        return base
    }

    private func swiftTermScroll(output: Bool, drive: SwiftTermDrive, velocity: Double = 1000) async throws -> Report {
        let host = try SwiftTermProbeHost(size: CGSize(width: 440, height: 600))
        defer { host.close() }
        let view = host.view
        let scale = Double(host.window.screen.nativeScale)
        view.feed(text: TerminalSpikeCorpus.history(lines: 400, cols: host.grid.cols)
                  + TerminalSpikeCorpus.claudeFrame(0, cols: host.grid.cols))
        host.container.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let cellHeight = view.bounds.height / CGFloat(max(1, host.grid.rows))
        let bottom = max(0, view.contentSize.height - view.bounds.height)
        let start = max(0, bottom - 60 * cellHeight)
        let base = Self.overrideScrollState(view)
        defer { object_setClass(view, base); Self.fakeTracking = false; Self.fakeDecelerating = false }
        Self.fakeTracking = true
        view.setContentOffset(CGPoint(x: 0, y: start), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        Self.fakeTracking = false
        Self.fakeDecelerating = true

        hookSwiftTermDraw(scale: scale)
        Self.drawTarget = ObjectIdentifier(view)
        Self.drawOffsets.removeAll()
        let sampler = CommitSampler()
        // 上屏位置 = 最近一次 draw 时的 contentOffset（文字画在滚动视图自己的 layer 上，bounds 动了但没重画时文字不动）。
        sampler.read = { Self.drawOffsets.last.map { $0.offset } }
        sampler.start()
        let cols = host.grid.cols
        let feeder = output ? Task { @MainActor in
            var n = 1
            while !Task.isCancelled {
                view.feed(text: TerminalSpikeCorpus.claudeFrame(n, cols: cols))
                n += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        } : nil
        try await Task.sleep(for: .milliseconds(100))
        // 往回滚区方向走 UIScrollView 公式算出来的距离（初速 1000 pt/s ≈ 500 pt）。
        let distance = velocity / 1000 / -log(0.998)
        let counter = DisplayLinkCounter()
        switch drive {
        case .uikitAnimation:
            view.setContentOffset(CGPoint(x: 0, y: max(0, start - distance)), animated: true)
        case .decelerate:
            var v = velocity / 1000            // pt/ms
            var y = Double(start)
            var last = CACurrentMediaTime()
            counter.onTick = {
                let now = CACurrentMediaTime()
                let dt = (now - last) * 1000
                last = now
                v *= pow(0.998, dt)
                y -= v * dt
                guard v > 0.02 else { counter.onTick = nil; return }
                view.contentOffset = CGPoint(x: 0, y: (max(0, y) * scale).rounded() / scale)
            }
            counter.start(preferred: CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120))
        }
        try await Task.sleep(for: .milliseconds(drive == .decelerate ? 3000 : 1500))
        counter.stop()
        feeder?.cancel()
        sampler.stop()
        Self.drawTarget = nil
        let report = Self.analyze("swiftterm-\(drive.rawValue) output=\(output)", sampler: sampler, sentEvents: nil)
        print(report.line)
        print("ONSCREEN-TIMING swiftterm-\(drive.rawValue) output=\(output) draws=\(Self.drawOffsets.count) frames=\(sampler.targets.count)")
        restoreDraw?()
        restoreDraw = nil
        return report
    }

    // MARK: - 拖动 → 惯性交接

    /// 在「下一次 display link 回调前 `lead` ms」这个相位上做一次拖动 + 松手（真手指的触摸事件也是在帧开头、回调前后到）。
    private func flingAtPhase(view: MGhosttyTerminalView, sampler: CommitSampler, lead: Double, velocity: CGFloat) async {
        let pan = Pan()
        let selector = NSSelectorFromString("handleTouchScrollGesture:")
        // 回调大约在它的 timestamp（= 上一拍记下的 target）前 0.9 ms 来；量出来的，见 ONSCREEN-HANDOFF 诊断行。
        let nextCallback = (sampler.targets.last ?? CACurrentMediaTime()) - 0.0009
        var fire = nextCallback - lead / 1000
        while fire < CACurrentMediaTime() + 0.002 { fire += 1.0 / 120 }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + (fire - CACurrentMediaTime() - 0.0015)) {
                while CACurrentMediaTime() < fire {}
                pan.fakeState = .began; pan.fakeTranslation = .zero; _ = view.perform(selector, with: pan)
                pan.fakeState = .changed; pan.fakeTranslation = CGPoint(x: 0, y: velocity > 0 ? 6 : -6)
                _ = view.perform(selector, with: pan)
                pan.fakeState = .ended; pan.fakeTranslation = .zero; pan.fakeVelocity = CGPoint(x: 0, y: velocity)
                _ = view.perform(selector, with: pan)
                done.resume()
            }
        }
    }

    // MARK: - 用例

    /// 同一轮里 Ghostty 的读数，留给 SwiftTerm 参照用例比（XCTest 按名字排序跑，Ghostty 的先跑）。
    nonisolated(unsafe) private static var ghosttyReadings: [Report] = []

    /// 每拍上屏位移的回归门槛（单独窗口 / 整个工作区界面，有无输出，初速 1000 / 4000 pt/s 都要过）：
    /// - 重复帧 0（速度 ≥ 2 px/帧时没有一拍不换画面）；
    /// - 和这一拍发出去的位移逐拍对得上（错位 ≤ 1 拍）；
    /// - 二阶差分 ≤ 4 px、相邻两拍位移比 ≤ 1.35（整像素取整的噪声是 1–2 px、比值 1.25 左右）；
    /// - 交接那一拍只有拖动那一步（不是拖动 + 惯性第一步叠在一起）。
    private func assertSmooth(_ report: Report, drag: Double = 18, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(report.shown.count, 30, "\(report.label)：上屏位置没解出来（decoded=\(report.decoded) failed=\(report.failures)）",
                             file: file, line: line)
        XCTAssertEqual(report.repeats, 0, "\(report.label)：重复帧", file: file, line: line)
        XCTAssertLessThanOrEqual(report.mismatches, 1, "\(report.label)：上屏和发出的位移对不上", file: file, line: line)
        XCTAssertLessThanOrEqual(report.maxJerk, 4, "\(report.label)：每拍位移忽大忽小（二阶差分）", file: file, line: line)
        XCTAssertLessThanOrEqual(report.maxRatio, 1.35, "\(report.label)：相邻两拍位移比", file: file, line: line)
        XCTAssertEqual(report.handoff.first ?? 0, drag, accuracy: 1.5, "\(report.label)：交接那一拍一下走了两步", file: file, line: line)
    }

    func testGhosttyFlingOnScreen() async throws {
        for velocity in [1000, 4000] as [CGFloat] {
            for output in [false, true] {
                let report = try await ghosttyFling(output: output, velocity: velocity)
                Self.ghosttyReadings.append(report)
                assertSmooth(report)
            }
        }
    }

    /// 拖动交给惯性的那一帧不能「一帧走两步」：在回调前 0.3–6 ms 各个相位上松手，交接那一帧上屏的位移必须只是拖动那一步。
    func testGhosttyFlingHandoffOnScreen() async throws {
        var problems: [String] = []
        for output in [false, true] {
            let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 600))
            defer { host.close() }
            try await host.waitUntilReady()
            let cols = host.grid.cols
            host.feedAndWait(Self.barcodeHistory(lines: 400, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols))
            try await Task.sleep(for: .milliseconds(300))
            let cell = try XCTUnwrap(host.view.uTermCellPixels)
            for _ in 0..<120 { host.view.sendMouseScroll(x: 0, y: Double(cell.height), mods: TerminalScrollModifiers(precision: true)) }
            try await Task.sleep(for: .milliseconds(300))
            let layer = try XCTUnwrap(Self.surfaceLayer(in: host.view.layer))
            var decoder = BarcodeDecoder(cell: cell)
            let feeder = output ? Task { @MainActor in
                var n = 1
                while !Task.isCancelled {
                    host.bridge.feed(Data(TerminalSpikeCorpus.claudeFrame(n, cols: cols).utf8))
                    n += 1
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } : nil
            defer { feeder?.cancel() }
            var lines: [String] = []
            for (index, lead) in [0.3, 0.8, 1.5, 3.0, 6.0, 0.3, 0.8, 1.5].enumerated() {
                let velocity: CGFloat = index % 2 == 0 ? 1000 : -1000
                let sampler = CommitSampler()
                sampler.read = { decoder.position(of: layer) }
                UTermScrollTrace.isEnabled = true
                sampler.start()
                try await Task.sleep(for: .milliseconds(80))
                await flingAtPhase(view: host.view, sampler: sampler, lead: lead, velocity: velocity)
                try await Task.sleep(for: .milliseconds(1800))
                sampler.stop()
                let trace = UTermScrollTrace.drain()
                UTermScrollTrace.isEnabled = false
                let drag = abs(trace.filter { $0.kind == "drag" }.reduce(0) { $0 + $1.value })
                // 0 = 拖动已画上、照常起步；1 = 拖动还没画上、这一帧先不走；2 = 拖动赶在 vsync 前画上了、惯性第一步当场补上。
                let skipped = trace.filter { $0.kind == "glide-first" }.map(\.value).max() ?? -1
                let report = Self.analyze("handoff", sampler: sampler, sentEvents: nil)
                let first = report.handoff.first ?? 0
                let merged = abs(first - drag) > 1.5
                lines.append(String(format: "lead=%.1fms drag=%.0f shown=%@ start=%.0f repeats=%d%@", lead, drag,
                                    report.handoff.map { String(format: "%.0f", $0) }.joined(separator: "/"), skipped,
                                    report.repeats, merged ? " MERGED" : ""))
                if merged { problems.append("output=\(output) lead=\(lead)ms 交接帧 \(Int(first)) px ≠ 拖动 \(Int(drag)) px") }
                if report.repeats > 0 { problems.append("output=\(output) lead=\(lead)ms 重复帧 \(report.repeats)") }
            }
            print("ONSCREEN-HANDOFF-PHASES output=\(output) " + lines.joined(separator: " | "))
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "；"))
    }

    func testGhosttyFlingOnScreenInWorkspace() async throws {
        for velocity in [1000, 4000] as [CGFloat] {
            for output in [false, true] {
                let report = try await ghosttyFlingInWorkspace(output: output, velocity: velocity)
                Self.ghosttyReadings.append(report)
                assertSmooth(report)
            }
        }
    }

    /// SwiftTerm（UIScrollView）同一套量法当参照；同一轮跑过 Ghostty 的话，核 Ghostty 不比它差：
    /// 重复帧不多于它、二阶差分不超过它 + 1 px、相邻位移比不超过它 + 0.05（都按 1000 pt/s 那几条比）。
    func testSwiftTermScrollOnScreen() async throws {
        var reference: [Report] = []
        for drive in [SwiftTermDrive.decelerate, .uikitAnimation] {
            for output in [false, true] {
                let report = try await swiftTermScroll(output: output, drive: drive)
                XCTAssertGreaterThan(report.shown.count, 30, "\(report.label)：没滚起来")
                if drive == .decelerate { reference.append(report) }
            }
        }
        let ghostty = Self.ghosttyReadings.filter { $0.label.contains("v=1000") }
        guard !ghostty.isEmpty else { return }
        let floorRepeats = reference.map(\.repeats).max() ?? 0
        let floorJerk = reference.map(\.maxJerk).max() ?? 0
        let floorRatio = reference.map(\.maxRatio).max() ?? 1
        print(String(format: "ONSCREEN-COMPARE swiftterm-decelerate repeats≤%d jerk≤%.0f ratio≤%.2f | ghostty %@", floorRepeats, floorJerk, floorRatio,
                     ghostty.map { String(format: "%@ repeats=%d jerk=%.0f ratio=%.2f", $0.label, $0.repeats, $0.maxJerk, $0.maxRatio) }
                        .joined(separator: "; ")))
        for report in ghostty {
            XCTAssertLessThanOrEqual(report.repeats, floorRepeats, "\(report.label) 重复帧比 SwiftTerm 多")
            XCTAssertLessThanOrEqual(report.maxJerk, floorJerk + 1, "\(report.label) 二阶差分比 SwiftTerm 大")
            XCTAssertLessThanOrEqual(report.maxRatio, floorRatio + 0.05, "\(report.label) 相邻位移比比 SwiftTerm 大")
        }
    }
}
