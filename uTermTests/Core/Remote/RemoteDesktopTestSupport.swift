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
    static func makeFrame(width: Int, height: Int, seed: Int, detail: Bool = false) -> CVPixelBuffer {
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
        for y in 0..<height {
            for x in 0..<width {
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
                let (cb, cr) = chromaValue(block: block, seed: seed)
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

    /// 每个色块中心区域（避开块边缘的振铃）的平均 Y，用于比对解码结果。
    static func blockLuma(_ image: CVPixelBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(image, 0), height = CVPixelBufferGetHeightOfPlane(image, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        var result: [Double] = []
        for block in 0..<16 {
            let bx = block % 4, by = block / 4
            let x0 = bx * width / 4 + width / 16, x1 = (bx + 1) * width / 4 - width / 16
            let y0 = by * height / 4 + height / 16, y1 = (by + 1) * height / 4 - height / 16
            var sum = 0, count = 0
            for y in Swift.stride(from: y0, to: y1, by: 2) {
                for x in Swift.stride(from: x0, to: x1, by: 2) {
                    sum += Int(luma[y * stride + x])
                    count += 1
                }
            }
            result.append(Double(sum) / Double(max(1, count)))
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
        let sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        var squared = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let d = Double(pa[y * sa + x]) - Double(pb[y * sb + x])
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

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        onFrame = nil
        timer?.cancel()
        timer = nil
    }

    var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return started && !stopped }

    /// 出一帧（新画面）。
    @discardableResult
    func emit() -> Int {
        lock.lock()
        seed += 1
        let current = seed
        let handler = onFrame
        emitted.append(current)
        lock.unlock()
        let image = RemoteDesktopFixture.makeFrame(width: width, height: height, seed: current, detail: detail)
        handler?(image, DispatchTime.now().uptimeNanoseconds)
        return current
    }

    /// 预先生成的一组画面（Debug 下逐像素生成一张 1856×1206 要上百毫秒，现场生成会让采集源自己成为瓶颈）。
    private var cycle: [CVPixelBuffer] = []
    private var cycleIndex = 0

    func prepareCycle(count: Int) {
        let frames = (0..<count).map {
            RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 1000 + $0, detail: detail)
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
            self.cycleIndex = frames.isEmpty ? 0 : (self.cycleIndex + 1) % frames.count
            let index = self.cycleIndex
            self.lock.unlock()
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
}

/// 记录注入的输入（替代 CGEvent）。
final class RecordingInputSink: RemoteDesktopInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [RemoteDesktopInput] = []
    private var pastes: [RemoteDesktopPaste] = []

    func inject(_ input: RemoteDesktopInput) {
        lock.lock(); inputs.append(input); lock.unlock()
    }

    func paste(_ content: RemoteDesktopPaste) {
        lock.lock(); pastes.append(content); lock.unlock()
    }

    var all: [RemoteDesktopInput] { lock.lock(); defer { lock.unlock() }; return inputs }
    var allPastes: [RemoteDesktopPaste] { lock.lock(); defer { lock.unlock() }; return pastes }
}

/// 一个可变的「Mac 环境」：开关与授权可在用例里随时改。
@MainActor
final class FakeDesktopMac {
    var enabled = true
    var screenAuthorized = true
    var canControl = true
    let display = RemoteDesktopDisplay(id: 7, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                       pixelWidth: 3024, pixelHeight: 1964)
    let injector = RecordingInputSink()
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
            display: { [weak self] _ in self?.display },
            makeSource: { [weak self] _, width, height in
                let source = SyntheticFrameSource(width: width, height: height, detail: self?.detail ?? false)
                self?.sources.append(source)
                return source
            },
            makeInjector: { [weak self] _ in self?.injector ?? RecordingInputSink() },
            cursorLocation: { cursorBox.value })
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
