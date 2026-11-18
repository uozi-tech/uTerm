import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest
@testable import uTermMobile

/// `RemoteDesktopUpscaler` 在手机的 GPU 上：颜色不变、尺寸对、一帧花多久。判定规则在 Mac 侧的
/// `RemoteDesktopUpscalerTests`；这里只核对「换了一套 GPU 结果还对」，并量真机上窗口模式那个尺寸的耗时
///（1902×1338 → 2852×2006，10-bit 4:2:0，和解码出来的一样）。
final class RemoteDesktopUpscalerDeviceTests: XCTestCase {
    private let transfer: VTPixelTransferSession = {
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        return session!
    }()

    private func buffer(_ width: Int, _ height: Int, _ format: OSType) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        return out!
    }

    private func convert(_ source: CVPixelBuffer, to format: OSType) -> CVPixelBuffer {
        let out = buffer(CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source), format)
        XCTAssertEqual(VTPixelTransferSessionTransferImage(transfer, from: source, to: out), noErr)
        return out
    }

    /// 四列纯色，每列下半截叠一像素宽的黑白竖条。
    private func card(width: Int, height: Int) -> CVPixelBuffer {
        let card = buffer(width, height, kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(card, [])
        let base = CVPixelBufferGetBaseAddress(card)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(card)
        let colors: [(UInt8, UInt8, UInt8)] = [(40, 60, 220), (30, 180, 60), (220, 120, 30), (128, 128, 128)]
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                let c = colors[x * 4 / width]
                if y > height / 2, x % 4 < 2 { p[0] = 20; p[1] = 20; p[2] = 20 } else { p[0] = c.0; p[1] = c.1; p[2] = c.2 }
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(card, [])
        return card
    }

    private func pixel(_ image: CVPixelBuffer, x: Double, y: Double) -> [Int] {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let px = Int(x * Double(CVPixelBufferGetWidth(image))), py = Int(y * Double(CVPixelBufferGetHeight(image)))
        let p = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            + py * CVPixelBufferGetBytesPerRow(image) + px * 4
        return [Int(p[0]), Int(p[1]), Int(p[2])]
    }

    func testColorsSizeAndFormatSurviveOnThisGPU() {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] {
            let source = convert(card(width: 640, height: 400), to: format)
            let upscaler = RemoteDesktopUpscaler()
            upscaler.setDisplayPixels(width: 960, height: 600)
            let output = upscaler.process(source)
            XCTAssertFalse(output === source, "应该放大了（格式 \(format)）")
            XCTAssertEqual(CVPixelBufferGetWidth(output), 960)
            XCTAssertEqual(CVPixelBufferGetHeight(output), 600)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), format)
            let before = convert(source, to: kCVPixelFormatType_32BGRA), after = convert(output, to: kCVPixelFormatType_32BGRA)
            for x in [0.125, 0.375, 0.625, 0.875] {
                let a = pixel(before, x: x, y: 0.25), b = pixel(after, x: x, y: 0.25)
                XCTAssertLessThanOrEqual(zip(a, b).map { abs($0 - $1) }.max() ?? 0, 3,
                                         "纯色块放大后颜色不能变（格式 \(format)，x \(x)）：\(a) → \(b)")
            }
        }
    }

    /// 窗口模式的真实尺寸一帧花多久（同一张反复放大，GPU 没有别的事）。
    func testTimePerFrameAtWindowModeSize() {
        let source = convert(card(width: 1902, height: 1338), to: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let upscaler = RemoteDesktopUpscaler()
        upscaler.setDisplayPixels(width: 2853, height: 2007)
        // 每次都当成隔了一秒才来的帧：连着来的会被当成「画面在动」原样放行。
        _ = upscaler.process(source, now: 0)
        var samples: [Double] = []
        for index in 1...40 {
            let start = DispatchTime.now().uptimeNanoseconds
            let output = upscaler.process(source, now: UInt64(index) * 1_000_000_000)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            XCTAssertEqual(CVPixelBufferGetWidth(output), 2852)
        }
        samples.sort()
        let line = String(format: "UPSCALE_TIMING 1902x1338→2852x2006 10-bit：p50 %.2f ms，p90 %.2f ms，最大 %.2f ms",
                          samples[samples.count / 2], samples[samples.count * 9 / 10], samples.last ?? 0)
        print(line)
        XCTContext.runActivity(named: line) { _ in }
        XCTAssertLessThan(samples[samples.count / 2], 12, "单帧反复放大都要十几毫秒的话，每秒 30 帧的小动画也赶不上")
    }

    /// 连续出帧时（每秒 60 帧、张张不同、画面真的在屏幕上显示着）放大和送显示各花多久。
    /// 单帧反复量只有 3 ms，但 2026-11-18 真机滚动时收帧被拖到一帧一两百毫秒：这条量的是更接近实际的情形。
    @MainActor
    func testSustainedPresentationAtSixtyFramesPerSecond() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.isHidden = false
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resize
        layer.frame = window.bounds
        window.layer.addSublayer(layer)
        defer { window.isHidden = true }

        // 八张不同的画面轮着来（竖条错开几个像素，像在滚动）。
        let sources: [CVPixelBuffer] = (0..<8).map { index in
            let bgra = card(width: 1902, height: 1338)
            CVPixelBufferLockBaseAddress(bgra, [])
            let base = CVPixelBufferGetBaseAddress(bgra)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(bgra)
            for y in Swift.stride(from: index * 40, to: 1338, by: 320) {
                memset(base + y * stride, 255, stride * 24)
            }
            CVPixelBufferUnlockBaseAddress(bgra, [])
            return convert(bgra, to: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        }
        let renderer = RemoteDesktopRenderer(layer.sampleBufferRenderer)
        // 按 Duo 内屏横握时画布的像素数算（窗口模式的真实情形），不看这台设备此刻的屏幕方向。
        let pixels = (2853, 2007)

        /// 按 `fps` 连着送 `count` 帧。`force`：不看帧来得多密，张张放大（量 GPU 正忙时放大一帧要多久）。
        func run(fps: Double, count: Int, upscale: Bool, force: Bool = false) async
            -> (process: [Double], enqueue: [Double], scaled: Int, settled: Bool) {
            let upscaler = RemoteDesktopUpscaler()
            if upscale { upscaler.setDisplayPixels(width: pixels.0, height: pixels.1) }
            var process: [Double] = [], enqueue: [Double] = [], scaled = 0
            let queue = DispatchQueue(label: "test.present", qos: .userInteractive)
            let interval = 1000 / fps
            for frame in 0..<count {
                let source = sources[frame % sources.count]
                let (p, e, s): (Double, Double, Bool) = await withCheckedContinuation { continuation in
                    queue.async {
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        // `force`：每帧都假装隔了很久才来。
                        let image = force ? upscaler.process(source, now: UInt64(frame + 1) * 1_000_000_000) : upscaler.process(source)
                        let t1 = DispatchTime.now().uptimeNanoseconds
                        renderer.enqueue(image)
                        let t2 = DispatchTime.now().uptimeNanoseconds
                        continuation.resume(returning: (Double(t1 - t0) / 1e6, Double(t2 - t1) / 1e6, image !== source))
                    }
                }
                process.append(p); enqueue.append(e); if s { scaled += 1 }
                try? await Task.sleep(for: .microseconds(Int(max(0, interval - p - e) * 1000)))
            }
            let settled: Bool = await withCheckedContinuation { continuation in
                queue.async {
                    let sharp = upscaler.settle(sources[(count - 1) % sources.count])
                    if let sharp { renderer.enqueue(sharp) }
                    continuation.resume(returning: sharp != nil)
                }
            }
            return (process.sorted(), enqueue.sorted(), scaled, settled)
        }
        func summary(_ values: [Double]) -> String {
            String(format: "p50 %.2f / p90 %.2f / 最大 %.2f ms", values[values.count / 2], values[values.count * 9 / 10], values.last ?? 0)
        }
        let plain = await run(fps: 60, count: 240, upscale: false)
        let forced = await run(fps: 60, count: 240, upscale: true, force: true)
        let scroll = await run(fps: 60, count: 240, upscale: true)
        let spinner = await run(fps: 30, count: 120, upscale: true)
        let lines = [
            "UPSCALE_LIVE 画面 1902×1338，按 \(pixels.0)×\(pixels.1) 显示，图层铺满这台设备的屏幕",
            "UPSCALE_LIVE 60 帧不放大：送显示 \(summary(plain.enqueue))",
            "UPSCALE_LIVE 60 帧张张硬放大：放大 \(summary(forced.process))，送显示 \(summary(forced.enqueue))",
            "UPSCALE_LIVE 60 帧按规则（滚动）：这一步 \(summary(scroll.process))，放大了 \(scroll.scaled)/240 帧，停下后补放大 \(scroll.settled)",
            "UPSCALE_LIVE 30 帧按规则（小动画）：放大 \(summary(spinner.process))，放大了 \(spinner.scaled)/120 帧，停下后补放大 \(spinner.settled)",
        ]
        XCTAssertLessThanOrEqual(scroll.scaled, 2, "每秒 60 帧时只有开头那一两张放大")
        XCTAssertTrue(scroll.settled, "滚动停下后最后一张要补放大")
        XCTAssertLessThan(scroll.process[scroll.process.count * 9 / 10], 2, "滚动时送显示之前这一步几乎不花时间")
        XCTAssertGreaterThan(spinner.scaled, 100, "每秒 30 帧的小动画张张放大")
        lines.forEach { print($0) }
        XCTContext.runActivity(named: lines.joined(separator: "｜")) { _ in }
    }
}
