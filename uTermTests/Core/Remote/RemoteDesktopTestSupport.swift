import CoreGraphics
import CoreVideo
import Foundation
import XCTest
@testable import uTerm

/// 远程桌面测试夹具：合成画面、合成采集源、输入记录器、像素抽样。
/// 屏幕录制与事件注入在测试进程里没有授权，所以采集与注入两端换成这些，其余全走生产代码。
enum RemoteDesktopFixture {
    /// 一张 4:2:0 视频范围的合成画面：4×4 色块网格（每块的 Y / Cb / Cr 由 `seed` 决定），
    /// `detail` 时再叠上类似文字的细线（压力场景，用于读数）。
    /// `window`（按宽高的比例）：只有这块区域按 `seed` 画，其余按 `background` 画——像真实桌面那样只有一个窗口在变。
    static func makeFrame(width: Int, height: Int, seed: Int, detail: Bool = false,
                          window: CGRect? = nil, background: Int = 0) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         attributes as CFDictionary, &buffer)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate \(status)")
        let image = buffer!
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt8.self)
        let area = window.map {
            (x0: Int($0.minX * Double(width)), x1: Int($0.maxX * Double(width)),
             y0: Int($0.minY * Double(height)), y1: Int($0.maxY * Double(height)))
        }
        func seedAt(x: Int, y: Int) -> Int {
            guard let area else { return seed }
            return x >= area.x0 && x < area.x1 && y >= area.y0 && y < area.y1 ? seed : background
        }
        for y in 0..<height {
            for x in 0..<width {
                let seed = seedAt(x: x, y: y)
                let block = (y * 4 / height) * 4 + (x * 4 / width)
                var value = Int(lumaValue(block: block, seed: seed))
                if detail, (x + seed * 3) % 9 == 0 || (y % 14 == 3 && (x / 5 + seed) % 3 != 0) {
                    value = value > 128 ? 30 : 220
                }
                luma[y * lumaStride + x] = UInt8(value)
            }
        }
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                let block = (y * 2 * 4 / height) * 4 + (x * 2 * 4 / width)
                let (cb, cr) = chromaValue(block: block, seed: seedAt(x: x * 2, y: y * 2))
                chroma[y * chromaStride + x * 2] = cb
                chroma[y * chromaStride + x * 2 + 1] = cr
            }
        }
        return image
    }

    static func lumaValue(block: Int, seed: Int) -> UInt8 {
        UInt8(32 + (block * 37 + seed * 53) % 180)
    }

    static func chromaValue(block: Int, seed: Int) -> (UInt8, UInt8) {
        (UInt8(80 + (block * 23 + seed * 7) % 96), UInt8(80 + (block * 41 + seed * 13) % 96))
    }

    /// 读亮度平面上一点，换算到 8-bit 刻度：解码器按码流位深出画面，Main10 是 x420（16 位存、高 10 位有效）。
    /// 调用方负责锁住 base address。
    static func lumaReader(_ image: CVPixelBuffer) -> (_ x: Int, _ y: Int) -> Double {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(image, 0)!
        if CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
            return { x, y in Double(base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)[x]) / 256 }
        }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        return { x, y in Double(luma[y * stride + x]) }
    }

    /// 每个色块中心区域（避开块边缘的振铃）的平均 Y，用于比对解码结果。
    static func blockLuma(_ image: CVPixelBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(image, 0), height = CVPixelBufferGetHeightOfPlane(image, 0)
        let luma = lumaReader(image)
        var result: [Double] = []
        for block in 0..<16 {
            let bx = block % 4, by = block / 4
            let x0 = bx * width / 4 + width / 16, x1 = (bx + 1) * width / 4 - width / 16
            let y0 = by * height / 4 + height / 16, y1 = (by + 1) * height / 4 - height / 16
            var sum = 0.0, count = 0
            for y in Swift.stride(from: y0, to: y1, by: 2) {
                for x in Swift.stride(from: x0, to: x1, by: 2) {
                    sum += luma(x, y)
                    count += 1
                }
            }
            result.append(sum / Double(max(1, count)))
        }
        return result
    }

    /// 两张同尺寸 4:2:0 画面的亮度 PSNR（dB）。
    static func lumaPSNR(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let width = CVPixelBufferGetWidthOfPlane(a, 0), height = CVPixelBufferGetHeightOfPlane(a, 0)
        let pa = lumaReader(a), pb = lumaReader(b)
        var squared = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let d = pa(x, y) - pb(x, y)
                squared += d * d
            }
        }
        let mse = squared / Double(width * height)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }
}

/// 合成画面怎么变（弱网矩阵用）。真实使用里多数时候只有一小块在变；满屏每帧都变是压力上限。
nonisolated enum SyntheticContent: String, CaseIterable, Sendable {
    /// 每帧满屏变化（滚动整页、播视频），30 fps。
    case fullScreen = "full"
    /// 终端里打字：静止桌面上一块深色文字区，一个字一个字出现，光标跟着走；每秒 10 个字。
    case typing
    /// 一个窗格（约四成屏幕）里的文字匀速往上滚，其余不动；30 fps。
    case scroll
    /// 屏幕一角约 4% 的区域整块变化（进度动画、小窗视频），30 fps。
    case smallArea = "area"

    /// 出帧节奏：打字是每秒 10 个字，其余按 30 fps。
    var fps: Int { self == .typing ? 10 : 30 }
}

/// 局部变化的画面：一张静止底图，每帧复制一份、只改一小块。
///
/// 每帧现场生成（Debug 下改一小块只要几毫秒）；滚动窗格事先画好一条比窗格高出一个循环周期的亮度条，
/// 每帧按偏移整行拷贝，循环处严丝合缝（周期是行高的整数倍）。
final class LocalChangeRenderer: @unchecked Sendable {
    let content: SyntheticContent
    let width: Int
    let height: Int
    private let base: CVPixelBuffer

    // 打字
    private let cellWidth: Int
    private let cellHeight: Int
    private let textColumns = 60
    private let textLines = 8
    private let textOrigin: (x: Int, y: Int)

    // 滚动
    private let pane: (x: Int, y: Int, w: Int, h: Int)
    private let rowHeight: Int
    private let scrollStep: Int
    private let scrollPeriodRows = 12
    private var strip: [UInt8] = []

    // 小区域
    private let area: (x: Int, y: Int, w: Int, h: Int)

    init(content: SyntheticContent, width: Int, height: Int) {
        self.content = content
        self.width = width
        self.height = height
        cellWidth = max(4, width / 160) / 2 * 2
        cellHeight = cellWidth * 2
        textOrigin = (width / 10 / 2 * 2, height / 4 / 2 * 2)
        pane = (width * 12 / 100 / 2 * 2, height * 12 / 100 / 2 * 2, width * 55 / 100 / 2 * 2, height * 70 / 100 / 2 * 2)
        rowHeight = max(10, height / 60 / 5 * 5)
        scrollStep = rowHeight / 5
        area = (width * 72 / 100 / 2 * 2, height * 8 / 100 / 2 * 2, width * 20 / 100 / 2 * 2, height * 20 / 100 / 2 * 2)
        base = RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 1000, detail: true)
        switch content {
        case .typing:
            fill(base, x: textOrigin.x - cellWidth, y: textOrigin.y - cellHeight / 2,
                 w: (textColumns + 2) * cellWidth, h: textLines * cellHeight * 3 / 2 + cellHeight, luma: 28)
        case .scroll:
            buildStrip()
        default:
            break
        }
    }

    /// 第 `index` 帧（从 0 起）。
    func frame(_ index: Int) -> CVPixelBuffer {
        let image = copy(base)
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        switch content {
        case .fullScreen:
            preconditionFailure("满屏变化走 SyntheticFrameSource.prepareCycle")
        case .typing:
            let typed = index % (textColumns * textLines) + 1
            for i in 0..<typed { drawGlyph(i, luma: luma, stride: stride) }
            // 光标：下一个字的位置一个实心块。
            let (cx, cy) = cellOrigin(typed)
            for y in cy..<(cy + cellHeight) { for x in cx..<(cx + cellWidth) { luma[y * stride + x] = 170 } }
        case .scroll:
            let offset = (index % (scrollPeriodRows * rowHeight / scrollStep)) * scrollStep
            strip.withUnsafeBufferPointer { source in
                for row in 0..<pane.h {
                    let from = source.baseAddress! + (row + offset) * pane.w
                    (luma + (pane.y + row) * stride + pane.x).update(from: from, count: pane.w)
                }
            }
        case .smallArea:
            for y in 0..<area.h {
                for x in 0..<area.w {
                    let cell = ((x + index * 5) / 6) &* 31 ^ ((y + index * 3) / 6) &* 17
                    luma[(area.y + y) * stride + area.x + x] = UInt8(40 + (cell &+ index * 7) % 170)
                }
            }
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
            let chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<(area.h / 2) {
                for x in 0..<(area.w / 2) {
                    let at = (area.y / 2 + y) * chromaStride + (area.x / 2 + x) * 2
                    chroma[at] = UInt8(90 + (index * 7 + x / 4) % 60)
                    chroma[at + 1] = UInt8(90 + (index * 11 + y / 4) % 60)
                }
            }
        }
        return image
    }

    private func cellOrigin(_ i: Int) -> (Int, Int) {
        let i = i % (textColumns * textLines)
        return (textOrigin.x + (i % textColumns) * cellWidth, textOrigin.y + (i / textColumns) * cellHeight * 3 / 2)
    }

    /// 第 `i` 个字：3×5 点阵，笔画由 `i` 决定；每 7 个左右有一个空格。
    private func drawGlyph(_ i: Int, luma: UnsafeMutablePointer<UInt8>, stride: Int) {
        let bits = Self.glyphBits(i)
        guard bits != 0 else { return }
        let (ox, oy) = cellOrigin(i)
        for gy in 1..<(cellHeight - 1) {
            for gx in 1..<(cellWidth - 1) where bits >> ((gy * 5 / cellHeight) * 3 + gx * 3 / cellWidth) & 1 == 1 {
                luma[(oy + gy) * stride + ox + gx] = 215
            }
        }
    }

    private static func glyphBits(_ i: Int) -> Int {
        let hash = (UInt64(i) &+ 1) &* 0x9E37_79B9_7F4A_7C15
        if hash >> 59 % 7 == 0 { return 0 }
        return Int(truncatingIfNeeded: hash >> 20) & 0x7FFF | 0x2
    }

    /// 滚动窗格的亮度条：窗格高 + 一个周期，第 r 行文字的内容只看 r 对周期取模，循环无缝。
    private func buildStrip() {
        let period = scrollPeriodRows * rowHeight
        let total = pane.h + period
        let glyphWidth = max(4, rowHeight * 2 / 5)
        strip = [UInt8](repeating: 28, count: pane.w * total)
        for y in 0..<total {
            let textRow = (y / rowHeight) % scrollPeriodRows
            let inRow = y % rowHeight
            guard inRow >= 2, inRow < rowHeight - 2 else { continue }
            let length = 20 + (textRow * 37) % 50
            for x in 0..<pane.w {
                let column = x / glyphWidth
                guard column < length else { break }
                let bits = Self.glyphBits(textRow * 97 + column)
                let gx = (x % glyphWidth) * 3 / glyphWidth, gy = (inRow - 2) * 5 / (rowHeight - 4)
                if bits >> (gy * 3 + gx) & 1 == 1 { strip[y * pane.w + x] = 205 }
            }
        }
    }

    private func fill(_ image: CVPixelBuffer, x: Int, y: Int, w: Int, h: Int, luma value: UInt8) {
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        for row in max(0, y)..<min(height, y + h) {
            (luma + row * stride + max(0, x)).update(repeating: value, count: min(width, x + w) - max(0, x))
        }
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt8.self)
        for row in max(0, y / 2)..<min(height / 2, (y + h) / 2) {
            (chroma + row * chromaStride + max(0, x) / 2 * 2).update(repeating: 128, count: (min(width, x + w) - max(0, x)) / 2 * 2)
        }
    }

    private func copy(_ source: CVPixelBuffer) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         attributes as CFDictionary, &buffer)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate \(status)")
        let image = buffer!
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(image, [])
        defer {
            CVPixelBufferUnlockBaseAddress(image, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        for plane in 0..<2 {
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            let from = CVPixelBufferGetBaseAddressOfPlane(source, plane)!
            let to = CVPixelBufferGetBaseAddressOfPlane(image, plane)!
            let fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let toStride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
            let bytes = min(fromStride, toStride)
            for row in 0..<rows { (to + row * toStride).copyMemory(from: from + row * fromStride, byteCount: bytes) }
        }
        return image
    }
}

/// 合成采集源：按需（`emit`）或按定时器出帧，模拟 ScreenCaptureKit「有变化才出帧」的行为。
final class SyntheticFrameSource: RemoteDesktopFrameSource, @unchecked Sendable {
    let width: Int
    let height: Int
    let detail: Bool
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "test.synthetic.capture", qos: .userInteractive)
    private var onFrame: (@Sendable (CVPixelBuffer, UInt64) -> Void)?
    private var timer: DispatchSourceTimer?
    private var seed = 0
    private(set) var started = false
    private(set) var stopped = false
    /// 已经交出去的帧的 seed（按顺序）。
    private(set) var emitted: [Int] = []
    /// 设了它，精修时来源换给一张这个 seed 的画面（模拟「运动帧快缩、精修用 Lanczos 重缩」）。
    var refinedSeed: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _refinedSeed }
        set { lock.lock(); _refinedSeed = newValue; lock.unlock() }
    }
    private var _refinedSeed: Int?
    /// 精修时来源被问了几次。
    private(set) var refinedRequests = 0
    /// 定时器出过几帧（`run` / `play`；每帧都是新画面）。
    private var ticks = 0
    var produced: Int { lock.lock(); defer { lock.unlock() }; return ticks }
    private var local: LocalChangeRenderer?

    init(width: Int, height: Int, detail: Bool = false) {
        self.width = width
        self.height = height
        self.detail = detail
    }

    func start(onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
               onStop: @escaping @Sendable (Error?) -> Void) async throws {
        install(onFrame)
        // 与 ScreenCaptureKit 一样：开始采集后立刻交出第一张完整画面。
        emit()
    }

    private func install(_ handler: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void) {
        lock.lock(); defer { lock.unlock() }
        onFrame = handler
        started = true
    }

    private var onGeometry: (@Sendable (RemoteDesktopFrameGeometry) -> Void)?

    func observeGeometry(_ handler: @escaping @Sendable (RemoteDesktopFrameGeometry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        onGeometry = handler
    }

    /// 主控端报来的「看得见的那一块」（按顺序；nil = 回到整块）。
    private var regionRequests: [RemoteDesktopRegion?] = []
    var requestedRegions: [RemoteDesktopRegion?] { lock.lock(); defer { lock.unlock() }; return regionRequests }
    /// 设了它，之后 `emit` 出的帧都标成只画了这一块（模拟来源按区域取画面）。
    var emittedRegion: RemoteDesktopRegion? {
        get { lock.lock(); defer { lock.unlock() }; return _emittedRegion }
        set { lock.lock(); _emittedRegion = newValue; lock.unlock() }
    }
    private var _emittedRegion: RemoteDesktopRegion?

    func setRegion(_ visible: RemoteDesktopRegion?) {
        lock.lock(); regionRequests.append(visible); lock.unlock()
    }

    /// 有没有人订了几何（只看一个窗口的流才订）。
    var observesGeometry: Bool { lock.lock(); defer { lock.unlock() }; return onGeometry != nil }

    /// 模拟按窗口采集时系统报来的新范围（窗口挪了、改了大小、菜单伸出窗口）。
    func report(_ geometry: RemoteDesktopFrameGeometry) {
        lock.lock(); let handler = onGeometry; lock.unlock()
        queue.sync { handler?(geometry) }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        onFrame = nil
        timer?.cancel()
        timer = nil
    }

    var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return started && !stopped }

    func refinedImage(of frame: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock()
        refinedRequests += 1
        let seed = _refinedSeed
        lock.unlock()
        return seed.map { RemoteDesktopFixture.makeFrame(width: width, height: height, seed: $0, detail: detail) }
    }

    /// 出一帧（新画面）。
    @discardableResult
    func emit() -> Int {
        lock.lock()
        seed += 1
        let current = seed
        let handler = onFrame
        let region = _emittedRegion
        emitted.append(current)
        lock.unlock()
        let image = RemoteDesktopFixture.makeFrame(width: width, height: height, seed: current, detail: detail)
        RemoteFrameRegionTag.set(region, on: image)
        handler?(image, DispatchTime.now().uptimeNanoseconds)
        return current
    }

    /// 预先生成的一组画面（Debug 下逐像素生成一张 1856×1206 要上百毫秒，现场生成会让采集源自己成为瓶颈）。
    private var cycle: [CVPixelBuffer] = []
    private var cycleIndex = 0

    /// `window`：只让这块区域变（其余保持最后一次 `emit` 的画面），见 `RemoteDesktopFixture.makeFrame`。
    func prepareCycle(count: Int, window: CGRect? = nil) {
        lock.lock(); let background = seed; lock.unlock()
        let frames = (0..<count).map {
            RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 1000 + $0, detail: detail,
                                           window: window, background: background)
        }
        lock.lock(); cycle = frames; lock.unlock()
    }

    /// 按帧率连续出帧（画面每帧都变，等同滚动 / 播放视频的压力场景）。用 `prepareCycle` 备好的画面轮流出。
    func run(fps: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let handler = self.onFrame
            let frames = self.cycle
            let local = self.local
            let tick = self.ticks
            self.ticks += 1
            self.cycleIndex = frames.isEmpty ? 0 : (self.cycleIndex + 1) % frames.count
            let index = self.cycleIndex
            self.lock.unlock()
            if let local {
                handler?(local.frame(tick), DispatchTime.now().uptimeNanoseconds)
                return
            }
            guard !frames.isEmpty else {
                self.emit()
                return
            }
            handler?(frames[index], DispatchTime.now().uptimeNanoseconds)
        }
        lock.lock()
        self.timer?.cancel()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    /// 按 `content` 的方式与节奏连续出帧。满屏变化同 `prepareCycle(count: 12)` + `run(fps: 30)`。
    func play(_ content: SyntheticContent) {
        if content == .fullScreen {
            prepareCycle(count: 12)
        } else {
            let renderer = LocalChangeRenderer(content: content, width: width, height: height)
            lock.lock(); local = renderer; lock.unlock()
        }
        run(fps: content.fps)
    }
}

/// 内存里的 Mac 剪贴板（替代 `NSPasteboard.general`，测试不碰真实剪贴板）。
final class FakeClipboard: RemoteDesktopClipboardSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var content: String?

    var changeCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// 读文字要卡多久（模拟接力来的内容：系统去别的设备取，取不到要等超时）。
    var readDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _readDelay }
        set { lock.lock(); _readDelay = newValue; lock.unlock() }
    }
    private var _readDelay: TimeInterval = 0
    /// 读过几次文字。
    private(set) var reads = 0

    func text() -> String? {
        let delay = readDelay
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return content
    }

    /// 模拟 Mac 上的一次拷贝；nil = 拷贝了不是文字的东西（图片、文件）。
    func copy(_ text: String?) {
        lock.lock(); count += 1; content = text; lock.unlock()
    }
}

/// 记录注入的输入（替代 CGEvent）。粘贴像生产一样先写剪贴板（给了 `clipboard` 时）。
final class RecordingInputSink: RemoteDesktopInputSink, @unchecked Sendable {
    private let clipboard: FakeClipboard?
    private let lock = NSLock()
    private var inputs: [RemoteDesktopInput] = []
    private var pastes: [RemoteDesktopPaste] = []
    private var releases = 0

    func inject(_ input: RemoteDesktopInput) {
        lock.lock(); inputs.append(input); lock.unlock()
    }

    init(clipboard: FakeClipboard? = nil) {
        self.clipboard = clipboard
    }

    func paste(_ content: RemoteDesktopPaste) {
        switch content {
        case .text(let text): clipboard?.copy(text)
        case .png, .jpeg: clipboard?.copy(nil)
        }
        lock.lock(); pastes.append(content); lock.unlock()
    }

    func releaseButtons() {
        lock.lock(); releases += 1; lock.unlock()
    }

    private var boundsUpdates: [CGRect] = []

    func updateBounds(_ bounds: CGRect) {
        lock.lock(); boundsUpdates.append(bounds); lock.unlock()
    }

    /// 只看一个窗口时发送端报来的范围（按顺序）。
    var allBounds: [CGRect] { lock.lock(); defer { lock.unlock() }; return boundsUpdates }

    var releaseCount: Int { lock.lock(); defer { lock.unlock() }; return releases }
    var all: [RemoteDesktopInput] { lock.lock(); defer { lock.unlock() }; return inputs }
    var allPastes: [RemoteDesktopPaste] { lock.lock(); defer { lock.unlock() }; return pastes }
}

/// 合成的系统声音：每 10 ms 出一块（与 SCK 的节拍相近），可切成静音。
final class SyntheticAudioSource: RemoteAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "test.audio.source")
    private var timer: DispatchSourceTimer?
    private var onSamples: (@Sendable ([Float], UInt64) -> Void)?
    private var frame = 0
    private var silent = false
    private(set) var started = false
    private(set) var stopped = false

    func setSilent(_ value: Bool) { lock.lock(); silent = value; lock.unlock() }

    func start(onSamples: @escaping @Sendable ([Float], UInt64) -> Void,
               onStop: @escaping @Sendable (Error?) -> Void) async throws {
        begin(onSamples)
    }

    private func begin(_ onSamples: @escaping @Sendable ([Float], UInt64) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.lock()
        self.onSamples = onSamples
        started = true
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    private func tick() {
        lock.lock()
        let handler = onSamples
        let quiet = silent
        let start = frame
        frame += 480
        lock.unlock()
        var samples = [Float](repeating: 0, count: 960)
        if !quiet {
            for index in 0..<480 {
                let value = Float(sin(Double(start + index) * 2 * .pi * 440 / 48_000)) * 0.5
                samples[2 * index] = value
                samples[2 * index + 1] = value
            }
        }
        handler?(samples, DispatchTime.now().uptimeNanoseconds &- 10_000_000)
    }

    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        onSamples = nil
        stopped = true
        lock.unlock()
    }
}

/// 手机端的假扬声器：不出声，只记下有没有在放、把取样的回调留给用例自己拉。
@MainActor
final class SilentAudioOutput: RemoteAudioOutput {
    var onInterrupted: ((String) -> Void)?
    private(set) var isPlaying = false
    /// 用例按帧数拉一段交错采样。
    private(set) var pull: (@Sendable (Int) -> [Float])?

    /// 设了就模拟手机上的声音打不开（通话中 `AVAudioSession.setActive` 抛错）。
    var startError: Error?

    func start(pull: @escaping @Sendable (UnsafeMutableBufferPointer<Float>, Int) -> Void) throws {
        if let startError { throw startError }
        isPlaying = true
        self.pull = { frames in
            var samples = [Float](repeating: 0, count: frames * Int(RemoteAudioPolicy.channels))
            samples.withUnsafeMutableBufferPointer { pull($0, frames) }
            return samples
        }
    }

    func stop() {
        isPlaying = false
        pull = nil
    }
}

/// 一个可变的「Mac 环境」：开关与授权可在用例里随时改。
@MainActor
final class FakeDesktopMac {
    var audioEnabled = true
    private(set) var audioSources: [SyntheticAudioSource] = []
    var latestAudioSource: SyntheticAudioSource? { audioSources.last }
    var enabled = true
    var screenAuthorized = true
    var canControl = true
    var unlockEnabled = true
    let screen = FakeScreenController()
    let display = RemoteDesktopDisplay(id: 7, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                       pixelWidth: 3024, pixelHeight: 1964)
    /// 第二块显示器（外接 1080p，放在主显示器右边）。只在 `hasSecondDisplay` 时报给主控端。
    let secondDisplay = RemoteDesktopDisplay(id: 9, bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                             pixelWidth: 1920, pixelHeight: 1080)
    var hasSecondDisplay = false
    /// 设了就模拟无显示器的 Mac：叫醒主显示器（7）时系统把它换成这块新号的屏，之后只报这块。
    var displayAfterWake: RemoteDesktopDisplay?
    private var mainReplaced = false
    /// 光标此刻的样子（nil = 不报形状）。
    var cursorShape: RemoteDesktopCursorImage?
    /// 取了几次图（指纹没变就不该取）。
    private(set) var cursorImageReads = 0
    /// 每次开流用的是哪块显示器。
    private(set) var openedDisplays: [UInt32] = []
    /// 能单独看的窗口：号 → 位置（全局坐标，点）。按 2 倍屏算像素。
    var windows: [(id: UInt32, app: String, title: String, bounds: CGRect)] = []
    /// 每次开流采的是哪个窗口（nil = 整块显示器）。
    private(set) var openedWindows: [UInt32?] = []
    /// 被提到最前的窗口（按顺序）。
    private(set) var raisedWindows: [UInt32] = []
    /// 被调过大小的窗口和要的尺寸、被还原的窗口和位置（按顺序）。
    private(set) var fittedWindows: [(id: UInt32, size: CGSize)] = []
    private(set) var restoredWindows: [(id: UInt32, frame: CGRect)] = []
    /// App 的最小窗口尺寸：要的比它小时只能调到它。
    var minimumWindowSize = CGSize(width: 400, height: 350)
    /// 开流前整理过几次显示器（无显示器换 2 倍模式那一步）。
    private(set) var preparedDisplays = 0
    /// 每次整理显示器时看的设备要的像素。
    private(set) var preparedViewerPixels: [(width: Int, height: Int)] = []
    private(set) var preparedPointScales: [Double?] = []
    /// 有没有人在看桌面的通知（true = 有人开始看，false = 没人看了）。
    private(set) var displayUse: [Bool] = []
    /// 设备连上来时预建显示器用的尺寸（见 `RemoteHostServer.prewarmDesktop`）。
    private(set) var prewarmedViewerPixels: [(width: Int, height: Int)] = []
    let clipboard = FakeClipboard()
    lazy var injector = RecordingInputSink(clipboard: clipboard)
    var detail = false
    private(set) var sources: [SyntheticFrameSource] = []
    var cursor = CGPoint(x: 756, y: 491)

    var latestSource: SyntheticFrameSource? { sources.last }

    func environment() -> RemoteDesktopEnvironment {
        let cursorBox = CursorBox(self.cursor)
        self.cursorBox = cursorBox
        return RemoteDesktopEnvironment(
            isEnabled: { [weak self] in self?.enabled ?? false },
            screenCaptureAuthorized: { [weak self] in self?.screenAuthorized ?? false },
            canPostEvents: { [weak self] in self?.canControl ?? false },
            display: { [weak self] requested in
                guard let self else { return nil }
                if self.mainReplaced, let replacement = self.displayAfterWake {
                    return requested == nil || requested == replacement.id ? replacement : nil
                }
                return requested == self.secondDisplay.id && self.hasSecondDisplay ? self.secondDisplay : self.display
            },
            prepareDisplays: { [weak self] viewer, scale in
                self?.preparedDisplays += 1
                self?.preparedViewerPixels.append(viewer)
                self?.preparedPointScales.append(scale)
            },
            prewarmDisplays: { [weak self] viewer, _ in self?.prewarmedViewerPixels.append(viewer) },
            displaysInUse: { [weak self] inUse in self?.displayUse.append(inUse) },
            listDisplays: { [weak self] in
                guard let self, self.hasSecondDisplay else { return [] }
                return [self.display, self.secondDisplay].map {
                    RemoteDesktopDisplaySummary(id: $0.id, name: $0.id == 7 ? "内建显示器" : "外接显示器",
                                                width: $0.bounds.width, height: $0.bounds.height, isMain: $0.id == 7)
                }
            },
            listWindows: { [weak self] in
                (self?.windows ?? []).map {
                    RemoteDesktopWindowSummary(id: $0.id, app: $0.app, title: $0.title,
                                               width: $0.bounds.width, height: $0.bounds.height)
                }
            },
            window: { [weak self] id in
                guard let self, let window = self.windows.first(where: { $0.id == id }) else { return nil }
                let display = RemoteDesktopDisplay(id: self.display.id, bounds: window.bounds,
                                                   pixelWidth: Int(window.bounds.width * 2),
                                                   pixelHeight: Int(window.bounds.height * 2), windowID: id)
                return (display, window.title.isEmpty ? window.app : window.title)
            },
            raiseWindow: { [weak self] id in self?.raisedWindows.append(id) },
            fitWindow: { [weak self] id, size in
                guard let self, let index = self.windows.firstIndex(where: { $0.id == id }) else { return nil }
                self.fittedWindows.append((id, size))
                let original = self.windows[index].bounds
                let fitted = CGSize(width: max(size.width, self.minimumWindowSize.width),
                                    height: max(size.height, self.minimumWindowSize.height))
                guard fitted != original.size else { return nil }
                self.windows[index].bounds = CGRect(origin: original.origin, size: fitted)
                return original
            },
            restoreWindow: { [weak self] id, frame in
                guard let self else { return }
                self.restoredWindows.append((id, frame))
                if let index = self.windows.firstIndex(where: { $0.id == id }) { self.windows[index].bounds = frame }
            },
            makeSource: { [weak self] display, width, height, _ in
                self?.openedDisplays.append(display.id)
                self?.openedWindows.append(display.windowID)
                let source = SyntheticFrameSource(width: width, height: height, detail: self?.detail ?? false)
                self?.sources.append(source)
                return source
            },
            makeInjector: { [weak self] _ in self?.injector ?? RecordingInputSink() },
            cursorLocation: { cursorBox.value },
            cursorSignature: { [weak self] in self?.cursorShape.map { $0.png.hashValue ^ Int($0.hotX * 100) } },
            cursorImage: { [weak self] in
                self?.cursorImageReads += 1
                return self?.cursorShape
            },
            clipboard: clipboard,
            makeScreenController: { [weak self] in self?.screen ?? FakeScreenController() },
            isUnlockEnabled: { [weak self] in self?.unlockEnabled ?? false },
            wakeDisplay: { [weak self] id in
                guard let self, id == self.display.id, self.displayAfterWake != nil else { return }
                self.mainReplaced = true
            },
            isAudioEnabled: { [weak self] in self?.audioEnabled ?? false },
            makeAudioSource: { [weak self] _ in
                let source = SyntheticAudioSource()
                self?.audioSources.append(source)
                return source
            })
    }

    private var cursorBox: CursorBox?

    func moveCursor(to point: CGPoint) {
        cursorBox?.value = point
    }

    final class CursorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var point: CGPoint
        init(_ point: CGPoint) { self.point = point }
        var value: CGPoint {
            get { lock.lock(); defer { lock.unlock() }; return point }
            set { lock.lock(); point = newValue; lock.unlock() }
        }
    }
}

/// 记录型「屏幕控制」假件：锁屏状态、解锁结果可编排，帘幕与锁屏调用都记下来，供远程解锁用例断言。
@MainActor
final class FakeScreenController: RemoteScreenController {
    var locked = true
    /// 下一次 `unlock` 是否成功。
    var unlockSucceeds = true
    /// 下一次 `unlock` 报「有程序占着键盘」（优先于 `unlockSucceeds`）。
    var inputBlocked = false
    /// 收到的密码（断言用完清零，默认不校验内容）。
    private(set) var lastPassword: String?
    private(set) var unlockCalls = 0
    private(set) var curtainHistory: [Bool] = []
    private(set) var lockScreenCalls = 0
    private(set) var wakeCalls = 0
    var onLocalCurtainRelease: (() -> Void)?

    var isLocked: Bool { locked }
    private(set) var isCurtained = false

    func wake() { wakeCalls += 1 }

    /// 每次 `unlock` 打密码时帘幕是否挂着（应是关的：帘幕开着时按键进不了锁屏密码框）。
    private(set) var curtainedDuringUnlock: [Bool] = []
    /// 每次按回车提交时帘幕是否挂着（应已挂上：锁屏一消失物理屏就是黑的）。
    private(set) var curtainedAtSubmit: [Bool] = []

    func unlock(password: String, beforeSubmit: @escaping @MainActor () -> Void) async -> RemoteUnlockAttempt {
        unlockCalls += 1
        lastPassword = password
        curtainedDuringUnlock.append(isCurtained)
        if inputBlocked { return .inputBlocked }
        beforeSubmit()
        curtainedAtSubmit.append(isCurtained)
        if unlockSucceeds { locked = false }
        return unlockSucceeds ? .unlocked : .stillLocked
    }

    func lockScreen() {
        lockScreenCalls += 1
        locked = true
    }

    func setCurtain(_ on: Bool) {
        isCurtained = on
        curtainHistory.append(on)
    }

    /// 触发「本机解除帘幕」出口（模拟坐在 Mac 前的人连按 Esc）。
    func fireLocalRelease() { onLocalCurtainRelease?() }
}
