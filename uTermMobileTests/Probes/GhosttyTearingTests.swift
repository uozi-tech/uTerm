import GhosttyTerminal
import IOSurface
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// M16 第七轮：user 复试第六轮（主线程不再同步重画）说「滚动的时候很模糊，且也有抖动」。查是不是渲染线程不再被主线程
/// 的同步重画限速之后，把 CA 还挂着（还在显示）的 IOSurface 拿回来重画了——一屏上下来自不同位置（撕裂）、新旧画面混在一起（糊）。
///
/// 每次 CA 提交之后、以及每个 vsync，读当时挂在画面层上的 IOSurface：
/// - 分 5 条水平条带各自解行号条码，同一帧里条带解出的滚动位置不一致 = 撕裂（画的途中被读 / 被显示）；
/// - 条码格中心的亮度介于底色和前景之间 = 混合（新旧叠在一起）或被重采样；
/// - 第 0 列行边界的过渡宽度（10%–90% 之间的像素数）= 锐度，滚动中和静止时比；
/// - 同一个 IOSurface 还挂在层上时内容变了 = 正在显示的那张被拿去重画了；
/// - 相邻两次换画面的位置往回走 = 乱序。
/// 原来同一次运行里做 A/B：第五轮（引擎 wakeup 也在主线程同步重画）和第六轮（不同步重画）各甩一遍，两种都要过。
/// 那个开关已经从本地包里拿掉，iOS 定死第五轮的行为（`UTermScrollTrace.wakeupDrawsSynchronously`），这里只留这一半；
/// 读数行的标签仍叫 `round5`，和以前的日志对得上。
@MainActor
final class GhosttyTearingTests: XCTestCase {
    typealias OnScreen = GhosttyOnScreenScrollTests

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

    /// 一次读画面的结果。
    struct Read {
        /// 各条带解出的滚动位置（mod 条码周期），解不出为 nil。
        var bands: [Double?]
        /// 条码格中心亮度落在 15%–85% 之间的格数 / 采样格数。
        var mixed = 0
        var cells = 0
        /// 第 0 列行边界最宽的过渡（px）。
        var edgeWidth = 0
        var torn: Bool {
            let values = bands.compactMap { $0 }
            guard let first = values.first else { return false }
            return values.contains { abs($0 - first) > 1.5 }
        }
    }

    struct Decoder {
        let cellWidth: Int
        let cellHeight: Int
        let period: Double
        static let bandCount = 5

        init(cell: CGSize) {
            cellWidth = Int(cell.width)
            cellHeight = Int(cell.height)
            period = Double((1 << OnScreen.barcodeBits) * Int(cell.height))
        }

        func read(_ layer: CALayer) -> (id: ObjectIdentifier, read: Read)? {
            guard let contents = layer.contents else { return nil }
            let object = contents as AnyObject
            guard CFGetTypeID(object as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
            let surface = unsafeBitCast(object, to: IOSurfaceRef.self)
            IOSurfaceLock(surface, .readOnly, nil)
            defer { IOSurfaceUnlock(surface, .readOnly, nil) }
            guard IOSurfaceGetBytesPerElement(surface) == 4 else { return nil }
            let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
            let rowBytes = IOSurfaceGetBytesPerRow(surface)
            let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
            func lum(_ x: Int, _ y: Int) -> Double {
                let p = bytes + y * rowBytes + x * 4
                return Double(Int(p[0]) + Int(p[1]) + Int(p[2])) / 765
            }
            let background = lum(width - 3, height / 2)
            let x0 = cellWidth / 2
            // 前景：第 0 列上离底色最远的亮度（█ 的颜色）。
            var foreground = background
            for y in stride(from: 0, to: height, by: 7) where abs(lum(x0, y) - background) > abs(foreground - background) {
                foreground = lum(x0, y)
            }
            guard abs(foreground - background) > 0.3 else { return nil }
            func level(_ x: Int, _ y: Int) -> Double { (lum(x, y) - background) / (foreground - background) }
            var result = Read(bands: [])
            for band in 0..<Self.bandCount {
                let start = band * height / Self.bandCount + 1
                let limit = min(height - cellHeight, start + cellHeight * 3)
                var previous = level(x0, start - 1) > 0.5
                var edge = -1
                var y = start
                while y < limit {
                    let now = level(x0, y) > 0.5
                    if now != previous { edge = y; break }
                    previous = now
                    y += 1
                }
                guard edge > 0 else { result.bands.append(nil); continue }
                // 过渡宽度：边界上下 4 px 里落在 10%–90% 之间的像素数。
                let width = (max(0, edge - 4)..<min(height, edge + 4)).filter { (0.1...0.9).contains(level(x0, $0)) }.count
                result.edgeWidth = max(result.edgeWidth, width)
                let middle = edge + cellHeight / 2
                var row = 0
                for bit in 0..<OnScreen.barcodeBits {
                    let v = level(bit * cellWidth + cellWidth / 2, middle)
                    result.cells += 1
                    if (0.15...0.85).contains(v) { result.mixed += 1 }
                    if v > 0.5 { row |= 1 << bit }
                }
                var position = Double(row * cellHeight - edge).truncatingRemainder(dividingBy: period)
                if position < 0 { position += period }
                result.bands.append(position)
            }
            return (ObjectIdentifier(object), result)
        }
    }

    struct Tally {
        var frames = 0
        var torn = 0
        var mixedFrames = 0
        var mixedCells = 0
        var cells = 0
        var maxEdge = 0
        var mutated = 0
        var reversals = 0
        var commitsPerVsyncMax = 0
        var multiCommitVsyncs = 0
        var line: String {
            String(format: "frames=%d torn=%d mixed-frames=%d mixed-cells=%d/%d edge-width-max=%dpx mutated-while-shown=%d reversals=%d vsyncs-with-2+-new-frames=%d (max %d)",
                   frames, torn, mixedFrames, mixedCells, cells, maxEdge, mutated, reversals, multiCommitVsyncs, commitsPerVsyncMax)
        }
    }

    /// 读画面：CA 提交之后（新画面）和每个 vsync（同一张还挂着时有没有被改）各读一次。
    @MainActor
    final class Watcher: NSObject {
        let layer: CALayer
        let decoder: Decoder
        var tally = Tally()
        private var observer: CFRunLoopObserver?
        private var link: CADisplayLink?
        private var currentID: ObjectIdentifier?
        private var currentPosition: Double?
        private var lastNewPosition: Double?
        private var direction: Double = 0
        private var newThisVsync = 0

        init(layer: CALayer, decoder: Decoder) {
            self.layer = layer
            self.decoder = decoder
        }

        func start(direction: Double) {
            self.direction = direction
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, 2_000_001
            ) { [weak self] _, _ in MainActor.assumeIsolated { self?.observe(atVsync: false) } }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
            let link = CADisplayLink(target: self, selector: #selector(vsync))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        }

        @objc private func vsync() {
            tally.commitsPerVsyncMax = max(tally.commitsPerVsyncMax, newThisVsync)
            if newThisVsync >= 2 { tally.multiCommitVsyncs += 1 }
            newThisVsync = 0
            observe(atVsync: true)
        }

        private func observe(atVsync: Bool) {
            guard let (id, read) = decoder.read(layer) else { return }
            let position = read.bands.compactMap { $0 }.first
            if id != currentID {
                // 换了新画面。
                currentID = id
                currentPosition = position
                newThisVsync += 1
                tally.frames += 1
                if read.torn { tally.torn += 1 }
                if read.mixed > 0 { tally.mixedFrames += 1 }
                tally.mixedCells += read.mixed
                tally.cells += read.cells
                tally.maxEdge = max(tally.maxEdge, read.edgeWidth)
                if let position, let last = lastNewPosition {
                    var step = position - last
                    let period = decoder.period
                    if step > period / 2 { step -= period } else if step < -period / 2 { step += period }
                    if direction != 0, step * direction < -1.5 { tally.reversals += 1 }
                }
                lastNewPosition = position ?? lastNewPosition
            } else if let position, let shown = currentPosition, abs(position - shown) > 1.5 {
                // 同一张 IOSurface 还挂着，内容却变了：正在显示的那张被拿去重画。
                tally.mutated += 1
                currentPosition = position
                if read.torn { tally.torn += 1 }
            }
        }
    }

    private func run(velocityPx: Double, output: Bool, host: GhosttyProbeHost,
                     decoder: Decoder, layer: CALayer, cols: Int) async throws -> Tally {
        let scale = Double(host.view.window?.screen.nativeScale ?? 3)
        let pan = Pan()
        let selector = NSSelectorFromString("handleTouchScrollGesture:")
        let watcher = Watcher(layer: layer, decoder: decoder)
        let feeder = output ? Task { @MainActor in
            var n = 1
            while !Task.isCancelled {
                host.bridge.feed(Data(TerminalSpikeCorpus.claudeFrame(n, cols: cols).utf8))
                n += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        } : nil
        // 条码行号随视口往回滚区走而变小：手指往下（速度为正）时位置减小。
        watcher.start(direction: velocityPx > 0 ? -1 : 1)
        try await Task.sleep(for: .milliseconds(120))
        let v = CGFloat(velocityPx / scale)
        pan.fakeState = .began; pan.fakeTranslation = .zero; _ = host.view.perform(selector, with: pan)
        pan.fakeState = .changed; pan.fakeTranslation = CGPoint(x: 0, y: v > 0 ? 6 : -6); _ = host.view.perform(selector, with: pan)
        pan.fakeState = .ended; pan.fakeTranslation = .zero; pan.fakeVelocity = CGPoint(x: 0, y: v)
        _ = host.view.perform(selector, with: pan)
        try await Task.sleep(for: .milliseconds(1800))
        watcher.stop()
        feeder?.cancel()
        try await Task.sleep(for: .milliseconds(150))
        return watcher.tally
    }

    func testTearingAndBlurWhileFlinging() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 956))
        defer { host.close() }
        try await host.waitUntilReady()
        let cols = host.grid.cols
        host.feedAndWait(OnScreen.barcodeHistory(lines: 1500, cols: cols) + TerminalSpikeCorpus.claudeFrame(0, cols: cols))
        try await Task.sleep(for: .milliseconds(300))
        let cell = try XCTUnwrap(host.view.uTermCellPixels)
        for _ in 0..<80 { host.view.sendMouseScroll(x: 0, y: Double(cell.height), mods: TerminalScrollModifiers(precision: true)) }
        try await Task.sleep(for: .milliseconds(400))
        let layer = try XCTUnwrap(OnScreen.surfaceLayer(in: host.view.layer))
        let decoder = Decoder(cell: cell)
        let still = try XCTUnwrap(decoder.read(layer)?.read)
        print("TEAR static bands=\(still.bands.map { $0.map { String(Int($0)) } ?? "-" }) mixed=\(still.mixed)/\(still.cells) edge-width=\(still.edgeWidth)px torn=\(still.torn)")

        var all: [String: Tally] = [:]
        for output in [false, true] {
            for velocity in [6000.0, 12000, 20000] {
                for sign in [1.0, -1.0] {
                    let tally = try await run(velocityPx: velocity * sign, output: output,
                                              host: host, decoder: decoder, layer: layer, cols: cols)
                    let label = "round5 v=\(Int(velocity * sign)) output=\(output)"
                    print("TEAR \(label) \(tally.line)")
                    all[label] = tally
                }
            }
        }
        // 回归门槛：不撕裂、不混合、不乱序，滚动中锐度和静止时一样。
        // 「正在显示的 IOSurface 被重画」偶尔出现（每 12 次甩动 1–2 次）：交换链 3 张、GPU 画完就放回，
        // 不等 CA 换下，是 Zig 侧的问题（见报告），这里只打印不设门槛。
        for (label, tally) in all.sorted(by: { $0.key < $1.key }) {
            XCTAssertGreaterThan(tally.frames, 60, "\(label)：没读到画面")
            XCTAssertEqual(tally.torn, 0, "\(label)：撕裂")
            XCTAssertEqual(tally.mixedFrames, 0, "\(label)：新旧混合 / 重采样")
            XCTAssertEqual(tally.reversals, 0, "\(label)：画面往回走")
            XCTAssertLessThanOrEqual(tally.maxEdge, still.edgeWidth + 1, "\(label)：滚动中边缘变糊")
        }
        let mutated = all.values.map(\.mutated).reduce(0, +)
        print("TEAR mutated-while-shown total=\(mutated) over \(all.count) flings")
    }
}
