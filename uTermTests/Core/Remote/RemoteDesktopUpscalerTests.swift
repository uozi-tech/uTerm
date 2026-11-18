import CoreImage
import CoreVideo
import VideoToolbox
import XCTest
@testable import uTerm

/// 画面比屏幕上要显示的像素少时先放大再显示（`RemoteDesktopUpscaler`）。
final class RemoteDesktopUpscalerTests: XCTestCase {
    // MARK: - 放不放、放多大

    func test_window_at_two_pixels_per_point_is_scaled_to_a_three_pixel_screen() throws {
        let size = try XCTUnwrap(RemoteDesktopUpscaler.outputSize(image: (1902, 1338), display: (2853, 2007)))
        XCTAssertEqual(size.width, 2852, "取偶数")
        XCTAssertEqual(size.height, 2006)
    }

    func test_picture_already_dense_enough_is_left_alone() {
        XCTAssertNil(RemoteDesktopUpscaler.outputSize(image: (2853, 2007), display: (2853, 2007)), "看整个屏幕：视频就是按屏幕像素送来的")
        XCTAssertNil(RemoteDesktopUpscaler.outputSize(image: (2600, 1800), display: (2853, 2007)), "只差一成：双线性看不出糊")
        XCTAssertNil(RemoteDesktopUpscaler.outputSize(image: (3840, 2160), display: (1280, 720)), "要缩小的不归这里管")
        XCTAssertNil(RemoteDesktopUpscaler.outputSize(image: (0, 0), display: (100, 100)))
    }

    func test_scale_is_capped() throws {
        let doubled = try XCTUnwrap(RemoteDesktopUpscaler.outputSize(image: (800, 600), display: (4000, 3000)))
        XCTAssertEqual(doubled.width, 1600, "最多放大 2 倍，剩下的交给显示层")
        XCTAssertEqual(doubled.height, 1200)
        let big = try XCTUnwrap(RemoteDesktopUpscaler.outputSize(image: (2560, 1600), display: (5120, 3200)))
        XCTAssertLessThanOrEqual(big.width * big.height, RemoteDesktopUpscaler.maximumPixels, "输出不超过像素上限")
        XCTAssertGreaterThan(big.width, 2560)
    }

    // MARK: - 放大出来的画面

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

    /// 左半是四块纯色，右半是两像素宽的黑白竖条（最容易被放大抹糊的东西）。
    private func testCard(width: Int, height: Int) -> CVPixelBuffer {
        let card = buffer(width, height, kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(card, [])
        let base = CVPixelBufferGetBaseAddress(card)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(card)
        let colors: [(UInt8, UInt8, UInt8)] = [(40, 60, 220), (30, 180, 60), (220, 120, 30), (128, 128, 128)]   // BGR
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                if x < width / 2 {
                    let c = colors[(y * 2 / height) * 2 + (x * 4 / width)]
                    p[0] = c.0; p[1] = c.1; p[2] = c.2
                } else {
                    let v: UInt8 = x % 4 < 2 ? 20 : 235
                    p[0] = v; p[1] = v; p[2] = v
                }
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(card, [])
        return card
    }

    private func pixel(_ image: CVPixelBuffer, x: Double, y: Double) -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let px = Int(x * Double(CVPixelBufferGetWidth(image))), py = Int(y * Double(CVPixelBufferGetHeight(image)))
        let p = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            + py * CVPixelBufferGetBytesPerRow(image) + px * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    /// 右半（竖条那块）水平相邻像素差的平方和：越大边缘越利。
    private func edgeEnergy(_ image: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        var sum = 0.0
        for y in Swift.stride(from: height / 4, to: height * 3 / 4, by: 7) {
            for x in (width * 5 / 8)..<(width * 7 / 8) {
                let d = Double(base[y * stride + (x + 1) * 4 + 1]) - Double(base[y * stride + x * 4 + 1])
                sum += d * d
            }
        }
        return sum
    }

    private func upscaled(_ format: OSType, file: StaticString = #filePath, line: UInt = #line)
        -> (source: CVPixelBuffer, output: CVPixelBuffer) {
        let source = convert(testCard(width: 640, height: 400), to: format)
        let upscaler = RemoteDesktopUpscaler()
        upscaler.setDisplayPixels(width: 960, height: 600)
        return (source, upscaler.process(source))
    }

    func test_without_a_display_size_or_when_dense_enough_the_same_buffer_comes_back() {
        let source = convert(testCard(width: 640, height: 400), to: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let upscaler = RemoteDesktopUpscaler()
        XCTAssertTrue(upscaler.process(source) === source, "画布还没报显示多大")
        upscaler.setDisplayPixels(width: 680, height: 425)
        XCTAssertTrue(upscaler.process(source) === source, "差不到 1.15 倍")
    }

    func test_output_is_display_sized_and_keeps_format_and_color_tags() {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] {
            let (source, output) = upscaled(format)
            XCTAssertFalse(output === source)
            XCTAssertEqual(CVPixelBufferGetWidth(output), 960)
            XCTAssertEqual(CVPixelBufferGetHeight(output), 600)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), format, "位深和取样不变，显示层照原来的路走")
            let key = kCVImageBufferYCbCrMatrixKey
            let before = CVBufferCopyAttachment(source, key, nil) as? String
            XCTAssertNotNil(before, "前提：源图带着矩阵标记")
            XCTAssertEqual(CVBufferCopyAttachment(output, key, nil) as? String, before)
        }
    }

    func test_flat_colors_come_out_unchanged() {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] {
            let (source, output) = upscaled(format)
            let before = convert(source, to: kCVPixelFormatType_32BGRA), after = convert(output, to: kCVPixelFormatType_32BGRA)
            for (x, y) in [(0.06, 0.25), (0.18, 0.25), (0.31, 0.25), (0.43, 0.25), (0.06, 0.75), (0.31, 0.75)] {
                let a = pixel(before, x: x, y: y), b = pixel(after, x: x, y: y)
                XCTAssertLessThanOrEqual(max(abs(a.b - b.b), abs(a.g - b.g), abs(a.r - b.r)), 3,
                                         "纯色块放大后颜色不能变（格式 \(format)，位置 \(x),\(y)）：\(a) → \(b)")
            }
        }
    }

    func test_edges_stay_sharper_than_plain_bilinear_scaling() {
        let (source, output) = upscaled(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let bilinear = buffer(960, 600, kCVPixelFormatType_32BGRA)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let linear = CIImage(cvPixelBuffer: convert(source, to: kCVPixelFormatType_32BGRA)).samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: 1.5, y: 1.5))
        context.render(linear, to: bilinear, bounds: CGRect(x: 0, y: 0, width: 960, height: 600), colorSpace: nil)
        let sharp = edgeEnergy(convert(output, to: kCVPixelFormatType_32BGRA)), soft = edgeEnergy(bilinear)
        // 这种满幅的密条上双三次比双线性多留约 17% 的边缘能量（真实文字页面上是 47% 对 68–74%，见放大器的注释）。
        XCTAssertGreaterThan(sharp, soft * 1.1, "密竖条放大后要比双线性利（\(sharp) 对 \(soft)）")
    }

    // MARK: - 画面在动时不放大

    private let ms: UInt64 = 1_000_000

    /// 按间隔（毫秒）依次送帧，返回每一帧放不放大。
    private func admits(_ upscaler: RemoteDesktopUpscaler, gaps: [UInt64], from start: UInt64 = 0) -> [Bool] {
        var now = start
        return gaps.map { gap in
            now += gap * ms
            return upscaler.admit(now: now)
        }
    }

    func test_slow_trickle_of_frames_is_scaled_every_time() {
        let upscaler = RemoteDesktopUpscaler()
        XCTAssertEqual(admits(upscaler, gaps: [0, 33, 33, 500, 33, 40]), Array(repeating: true, count: 6),
                       "转圈的小动画、光标闪、打字：每秒三十帧以下，张张放大")
    }

    func test_fast_frames_are_passed_through_and_scaling_resumes_only_after_a_calm_run() {
        let upscaler = RemoteDesktopUpscaler()
        XCTAssertEqual(admits(upscaler, gaps: [0, 33, 16, 17, 16]), [true, true, false, false, false], "滚动：不放大")
        let calm = admits(upscaler, gaps: Array(repeating: 33, count: RemoteDesktopUpscaler.calmFramesToResume), from: 82 * ms)
        XCTAssertEqual(calm.dropLast(), ArraySlice(repeating: false, count: calm.count - 1), "刚慢下来还不放大：帧率在分界上下晃时不能一帧利一帧糊")
        XCTAssertEqual(calm.last, true, "连着慢够了才重新放大")
    }

    func test_one_fast_frame_in_the_calm_run_starts_the_count_over() {
        let upscaler = RemoteDesktopUpscaler()
        _ = admits(upscaler, gaps: [0, 16])
        let count = RemoteDesktopUpscaler.calmFramesToResume
        var gaps = Array(repeating: UInt64(33), count: count - 1)
        gaps.append(16)
        gaps.append(contentsOf: Array(repeating: 33, count: count - 1))
        XCTAssertFalse(admits(upscaler, gaps: gaps, from: 16 * ms).contains(true))
    }

    func test_device_too_slow_for_the_frame_rate_passes_frames_through() {
        let upscaler = RemoteDesktopUpscaler()
        for _ in 0..<40 { upscaler.record(costMillis: 30) }
        XCTAssertEqual(admits(upscaler, gaps: [0, 33, 33, 200]), [true, false, false, true],
                       "放大一帧要 30 ms：每秒三十帧赶不上就不放，隔得够久的照放")
    }

    func test_last_frame_of_a_scroll_is_scaled_once_the_picture_stops() {
        let source = convert(testCard(width: 640, height: 400), to: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let upscaler = RemoteDesktopUpscaler()
        upscaler.setDisplayPixels(width: 960, height: 600)
        XCTAssertFalse(upscaler.process(source, now: 0) === source, "第一帧放大")
        XCTAssertNil(upscaler.settle(source), "最后显示的已经是放大的：停下来不用补")
        XCTAssertTrue(upscaler.process(source, now: 16 * ms) === source, "滚动中：原样")
        XCTAssertTrue(upscaler.process(source, now: 32 * ms) === source)
        let settled = try? XCTUnwrap(upscaler.settle(source))
        XCTAssertEqual(settled.map(CVPixelBufferGetWidth), 960, "停下来：把最后那张补放大")
        XCTAssertNil(upscaler.settle(source), "只补一次")
        XCTAssertFalse(upscaler.process(source, now: 500 * ms) === source, "停过之后来得慢的帧直接放大，不用再数")
    }

    func test_settle_has_nothing_to_do_when_the_picture_needs_no_scaling() {
        let source = convert(testCard(width: 640, height: 400), to: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let upscaler = RemoteDesktopUpscaler()
        upscaler.setDisplayPixels(width: 640, height: 400)
        _ = upscaler.process(source, now: 0)
        _ = upscaler.process(source, now: 16 * ms)
        XCTAssertNil(upscaler.settle(source), "看整个屏幕：本来就不放大")
    }

    // MARK: - 送显示不排队

    private func frame(_ sequence: UInt32) -> RemoteDesktopFrame {
        RemoteDesktopFrame(flags: [], codec: .hevc, sequence: sequence, captureNanos: 0, width: 16, height: 16,
                           parameterSets: [], data: Data())
    }

    func test_presenter_returns_at_once_and_shows_only_the_latest_when_showing_is_slow() {
        let image = testCard(width: 16, height: 16)
        let shown = Shown()
        let firstStarted = expectation(description: "第一张开始显示"), release = DispatchSemaphore(value: 0)
        let allDone = expectation(description: "最后一张显示完")
        let presenter = RemoteDesktopPresenter(present: { _, frame in
            shown.append(frame.sequence)
            if frame.sequence == 1 {
                firstStarted.fulfill()
                release.wait()      // 第一张显示得很慢
            }
            if frame.sequence == 4 { allDone.fulfill() }
        })
        let start = Date()
        presenter.submit(image, frame(1))
        wait(for: [firstStarted], timeout: 2)
        presenter.submit(image, frame(2))
        presenter.submit(image, frame(3))
        presenter.submit(image, frame(4))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "交出去立刻返回，不等显示")
        release.signal()
        wait(for: [allDone], timeout: 2)
        XCTAssertEqual(shown.values, [1, 4], "显示慢的时候中间的不显示，只显示最新的一张")
        XCTAssertEqual(presenter.skipped, 2)
    }

    func test_presenter_shows_every_frame_in_order_when_it_keeps_up() {
        let image = testCard(width: 16, height: 16)
        let shown = Shown()
        let presenter = RemoteDesktopPresenter(present: { _, frame in shown.append(frame.sequence) })
        for sequence in 1...20 as ClosedRange<UInt32> {
            let done = expectation(description: "显示 \(sequence)")
            shown.onAppend = { done.fulfill() }
            presenter.submit(image, frame(sequence))
            wait(for: [done], timeout: 2)
        }
        XCTAssertEqual(shown.values, Array(1...20))
        XCTAssertEqual(presenter.skipped, 0)
    }

    func test_presenter_calls_settle_once_with_the_last_frame_after_frames_stop() {
        let image = testCard(width: 16, height: 16)
        let settled = Shown()
        let done = expectation(description: "停稳")
        let presenter = RemoteDesktopPresenter(settleDelay: 0.05, present: { _, _ in }, settle: { _, frame in
            settled.append(frame.sequence)
            done.fulfill()
        })
        for sequence in 1...5 as ClosedRange<UInt32> {
            presenter.submit(image, frame(sequence))
            Thread.sleep(forTimeInterval: 0.01)
        }
        wait(for: [done], timeout: 2)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(settled.values, [5], "帧还在来的时候不调；停下来只拿最后一张调一次")
    }
}

private final class Shown: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [UInt32] = []
    var onAppend: (() -> Void)?

    func append(_ value: UInt32) {
        lock.lock()
        list.append(value)
        let notify = onAppend
        lock.unlock()
        notify?()
    }

    var values: [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
}
