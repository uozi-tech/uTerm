import XCTest
@testable import uTerm

/// 精修按自己的大小判断发不发得完（`RemoteDesktopStreamer.refineQuality`）与视频延迟分段（`RemoteLatencyBreakdown`）。
final class RemoteRefineLatencyTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var bytes: Int?
    }

    private func keyframeBytes(_ encoder: RemoteVideoEncoder, _ image: CVPixelBuffer) throws -> Int {
        let done = expectation(description: "encode")
        let box = Box()
        encoder.encode(image, presentationNanos: 16_000_000, forceKeyframe: true, refine: false) { result in
            if case .success(let frame) = result { box.bytes = frame.data.count }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(box.bytes)
    }

    /// 旁路精修各档按主流关键帧折算的粗估不能低估（2026-11-09 3G：一张估成 61 KB、实际约 145 KB 的精修卡了 2.9 s）。
    /// 用真编码器量：主流关键帧（6 Mbps 低延迟码控）对旁路编码器各档画质，在打字画面和满屏细节两种内容上。
    func test_sidecar_refine_estimate_does_not_undercount_real_encoder_output() throws {
        let width = 1856, height = 1206
        let images = [
            ("打字", LocalChangeRenderer(content: .typing, width: width, height: height).frame(0)),
            ("满屏细节", RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 3, detail: true)),
        ]
        for (name, image) in images {
            let stream = try RemoteVideoEncoder(codec: .hevc, width: width, height: height, bitrate: 6_000_000,
                                                frameRate: 60, tenBit: true, ltr: true)
            let keyframe = try keyframeBytes(stream, image)
            var previous = Int.max
            for quality in RemoteDesktopStreamer.stillQualities {
                // 同一个编码器换档：`setStillQuality` 要真生效。
                let still = try RemoteVideoEncoder(codec: .hevc, width: width, height: height, bitrate: 0,
                                                   frameRate: 60, tenBit: true, purpose: .still)
                still.setStillQuality(quality)
                let actual = try keyframeBytes(still, image)
                let estimate = Double(keyframe) * RemoteDesktopStreamer.refineSizeFactor(quality)
                XCTAssertGreaterThanOrEqual(estimate, Double(actual) * 0.8,
                                            "\(name) 画质 \(quality)：估 \(Int(estimate)) 实际 \(actual)，低估了")
                XCTAssertLessThanOrEqual(estimate, Double(actual) * 1.5,
                                         "\(name) 画质 \(quality)：估 \(Int(estimate)) 实际 \(actual)，高估太多会白白不精修")
                XCTAssertLessThan(actual, previous, "\(name)：画质降一档要更小")
                previous = actual
            }
        }
    }

    /// 精修画质档从高到低，粗估比例也从大到小；最高档就是旁路编码器默认画质。
    func test_refine_size_factors_shrink_with_quality() {
        let factors = RemoteDesktopStreamer.stillQualities.map(RemoteDesktopStreamer.refineSizeFactor)
        XCTAssertEqual(factors, factors.sorted(by: >))
        XCTAssertEqual(RemoteDesktopStreamer.stillQualities.first, RemoteVideoEncoder.stillQuality)
        XCTAssertGreaterThan(factors[0], 1, "最高档比主流关键帧大")
    }

    /// 延迟分段：只算确认了的主流帧，扣掉手机解码；精修 / 解坏的帧不计。
    func test_latency_breakdown_splits_a_frame_into_stages() {
        var breakdown = RemoteLatencyBreakdown()
        let ms: UInt64 = 1_000_000
        breakdown.recordCaptureDelivery(8 * ms)
        // 采集于 1000 ms，送编码于 1010 ms，编了 6 ms（1016 交给传输），1166 ms 收到确认，手机解码 4 ms。
        breakdown.recordSent(sequence: 1, captureNanos: 1_000 * ms, encodeNanos: 6 * ms, now: 1_016 * ms)
        breakdown.recordAck(sequence: 1, decodeMicros: 4_000, now: 1_166 * ms)
        breakdown.recordSent(sequence: 2, captureNanos: 1_100 * ms, encodeNanos: 6 * ms, now: 1_116 * ms)
        breakdown.forget(sequence: 2)
        breakdown.recordAck(sequence: 2, decodeMicros: 4_000, now: 1_300 * ms)
        let line = try? XCTUnwrap(breakdown.drain())
        XCTAssertTrue(line?.contains("采集交出 8/8") == true, line ?? "")
        XCTAssertTrue(line?.contains("采集→送编码 10/10") == true, line ?? "")
        XCTAssertTrue(line?.contains("编码 6/6") == true, line ?? "")
        XCTAssertTrue(line?.contains("）146/146") == true, line ?? "")
        XCTAssertTrue(line?.contains("手机解码 4/4") == true, line ?? "")
        XCTAssertTrue(line?.contains("合计 166/166（1 帧）") == true, line ?? "")
        XCTAssertNil(breakdown.drain(), "清零了")
    }
}
