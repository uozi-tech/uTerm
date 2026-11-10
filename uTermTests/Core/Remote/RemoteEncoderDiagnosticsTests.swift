import CoreVideo
import XCTest
@testable import uTerm

/// 编码器丢帧诊断：画面变化的量法与 2 秒一行的摘要。
final class RemoteEncoderDiagnosticsTests: XCTestCase {
    func test_change_probe_tells_identical_frames_from_changed_ones() {
        let probe = RemoteFrameChangeProbe()
        let a = RemoteDesktopFixture.makeFrame(width: 640, height: 400, seed: 1)
        XCTAssertNil(probe.measure(a), "第一张没有可比的")
        XCTAssertEqual(probe.measure(a), 0, "同一张：完全相同")
        let b = RemoteDesktopFixture.makeFrame(width: 640, height: 400, seed: 2)
        XCTAssertGreaterThan(probe.measure(b) ?? 0, 0.5, "整屏色块都换了")
        // 只改左上角 10%×10%：变化面积约 1%。
        let c = RemoteDesktopFixture.makeFrame(width: 640, height: 400, seed: 2)
        CVPixelBufferLockBaseAddress(c, [])
        let stride = CVPixelBufferGetBytesPerRowOfPlane(c, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(c, 0)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<40 { for x in 0..<64 { luma[y * stride + x] = luma[y * stride + x] &+ 50 } }
        CVPixelBufferUnlockBaseAddress(c, [])
        XCTAssertEqual(probe.measure(c) ?? 0, 0.01, accuracy: 0.004)
        let small = RemoteDesktopFixture.makeFrame(width: 320, height: 200, seed: 2)
        XCTAssertNil(probe.measure(small), "尺寸变了不比")
    }

    func test_summary_separates_drop_kinds_and_change_sizes() {
        var diagnostics = RemoteEncoderDiagnostics()
        XCTAssertNil(diagnostics.drain(), "什么都没发生不写")
        for _ in 0..<3 { diagnostics.recordCapture(change: 0) }
        diagnostics.recordCapture(change: 0.2)
        diagnostics.recordDrop(keyframe: false, refresh: false, change: 0)
        diagnostics.recordDrop(keyframe: false, refresh: true, change: 0.2)
        diagnostics.recordDrop(keyframe: true, refresh: false, change: nil)
        diagnostics.recordSent(change: 0.2)
        let line = try? XCTUnwrap(diagnostics.drain())
        XCTAssertEqual(line, "编码器丢 普通 1 刷新 1 关键帧 1｜采集 4 帧，与上一张完全相同 3，变化面积 p50 0.0% / p95 20.0%"
                       + "｜被丢的帧变化 p50 20.0% / p95 20.0%｜发出的帧变化 p50 20.0% / p95 20.0%")
        XCTAssertNil(diagnostics.drain(), "摘要后清零")
    }
}
