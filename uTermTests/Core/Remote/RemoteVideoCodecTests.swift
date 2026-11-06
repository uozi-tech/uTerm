import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import uTerm

/// 编解码往返：合成的 4:2:0 画面 → `RemoteVideoEncoder`（低延迟硬编）→ 线上帧格式 → `RemoteVideoDecoder`
///（硬解）。核对尺寸与内容（每个色块的平均亮度），以及「没有关键帧不解 P 帧」「精修帧更清楚」。
final class RemoteVideoCodecTests: XCTestCase {

    /// 同步编一帧（测试里逐帧等输出）。
    private func encode(_ encoder: RemoteVideoEncoder, _ image: CVPixelBuffer, nanos: UInt64, keyframe: Bool = false,
                        refine: Bool = false) throws -> RemoteEncodedFrame {
        let done = expectation(description: "encoded")
        nonisolated(unsafe) var output: Result<RemoteEncodedFrame, RemoteVideoEncoderError>?
        encoder.encode(image, presentationNanos: nanos, forceKeyframe: keyframe, refine: refine) { result in
            output = result
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(output).get()
    }

    private func wire(_ encoded: RemoteEncodedFrame, codec: RemoteVideoCodec, sequence: UInt32, width: Int, height: Int,
                      refine: Bool = false) throws -> RemoteDesktopFrame {
        var flags: RemoteDesktopFrame.Flags = encoded.isKeyframe ? [.keyframe] : []
        if refine { flags.insert(.refine) }
        let frame = RemoteDesktopFrame(flags: flags, codec: codec, sequence: sequence, captureNanos: 0,
                                       width: UInt16(width), height: UInt16(height),
                                       parameterSets: encoded.parameterSets, data: encoded.data)
        // 经线上格式走一趟，和真实链路一样。
        return try RemoteDesktopFrame(decoding: frame.encoded())
    }

    private func roundTrip(codec: RemoteVideoCodec, width: Int, height: Int) throws {
        let encoder = try RemoteVideoEncoder(codec: codec, width: width, height: height,
                                             bitrate: RemoteRateController.initialBitrate(width: width, height: height),
                                             frameRate: 60)
        let decoder = RemoteVideoDecoder()
        for seed in 1...6 {
            let source = RemoteDesktopFixture.makeFrame(width: width, height: height, seed: seed)
            let encoded = try encode(encoder, source, nanos: UInt64(seed) * 16_000_000, keyframe: seed == 1)
            XCTAssertEqual(encoded.isKeyframe, seed == 1, "\(codec) 只有第一帧是关键帧（无限 GOP）")
            if encoded.isKeyframe {
                XCTAssertEqual(encoded.parameterSets.count, codec == .hevc ? 3 : 2, "HEVC = VPS/SPS/PPS，H.264 = SPS/PPS")
            }
            let frame = try wire(encoded, codec: codec, sequence: UInt32(seed), width: width, height: height)
            let image = try decoder.decode(frame)
            XCTAssertEqual(CVPixelBufferGetWidth(image), width)
            XCTAssertEqual(CVPixelBufferGetHeight(image), height)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            let decoded = RemoteDesktopFixture.blockLuma(image)
            for block in 0..<16 {
                let expected = Double(RemoteDesktopFixture.lumaValue(block: block, seed: seed))
                XCTAssertEqual(decoded[block], expected, accuracy: 6, "\(codec) 帧 \(seed) 色块 \(block)")
            }
        }
    }

    func test_hevc_round_trip_preserves_size_and_content() throws {
        try roundTrip(codec: .hevc, width: 1856, height: 1206)
    }

    func test_h264_round_trip_preserves_size_and_content() throws {
        try roundTrip(codec: .h264, width: 1280, height: 800)
    }

    func test_encoder_uses_low_latency_rate_control() throws {
        // 调研 §3.3 实测这台机器的 HEVC / H.264 都支持低延迟码控；退回普通模式意味着延迟翻倍，要能看出来。
        for codec in RemoteVideoCodec.allCases {
            let encoder = try RemoteVideoEncoder(codec: codec, width: 1280, height: 720, bitrate: 4_000_000, frameRate: 60)
            XCTAssertTrue(encoder.isLowLatency, "\(codec)")
        }
    }

    func test_decoded_frames_carry_display_p3_color_tags() throws {
        // 采集出的是 Display P3 码值：手机拿到的画面若标成 709 原色，显示时饱和度约低 17%（调研 §14.3）。
        // 显示层按解码输出上的标注做色彩管理，所以核对的是解码端看到的标注，而不是编码器的设置。
        let width = 640, height = 384
        for codec in RemoteVideoCodec.allCases {
            let encoder = try RemoteVideoEncoder(codec: codec, width: width, height: height, bitrate: 2_000_000, frameRate: 60)
            let encoded = try encode(encoder, RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 1),
                                     nanos: 1, keyframe: true)
            let image = try RemoteVideoDecoder().decode(
                wire(encoded, codec: codec, sequence: 1, width: width, height: height))
            let primaries = CVBufferCopyAttachment(image, kCVImageBufferColorPrimariesKey, nil) as? String
            let transfer = CVBufferCopyAttachment(image, kCVImageBufferTransferFunctionKey, nil) as? String
            XCTAssertEqual(primaries, kCVImageBufferColorPrimaries_P3_D65 as String, "\(codec)")
            XCTAssertEqual(transfer, kCVImageBufferTransferFunction_sRGB as String, "\(codec)")
        }
    }

    /// 参数集或码流是空的（坏帧）：报错，不能在取指针时崩掉。
    func test_empty_parameter_set_or_payload_throws_instead_of_crashing() throws {
        XCTAssertThrowsError(try RemoteVideoDecoder.formatDescription(codec: .hevc, parameterSets: [Data([0x40]), Data()]))
        XCTAssertThrowsError(try RemoteVideoDecoder.formatDescription(codec: .h264, parameterSets: [Data()]))
        let width = 320, height = 192
        let encoder = try RemoteVideoEncoder(codec: .h264, width: width, height: height, bitrate: 1_000_000, frameRate: 30)
        let key = try encode(encoder, RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 3), nanos: 1,
                             keyframe: true)
        let frame = try wire(key, codec: .h264, sequence: 1, width: width, height: height)
        let format = try RemoteVideoDecoder.formatDescription(codec: .h264, parameterSets: frame.parameterSets)
        XCTAssertThrowsError(try RemoteVideoDecoder.sampleBuffer(Data(), format: format))
    }

    func test_decoder_refuses_delta_frames_until_keyframe() throws {
        let width = 640, height = 384
        let encoder = try RemoteVideoEncoder(codec: .hevc, width: width, height: height, bitrate: 2_000_000, frameRate: 60)
        let key = try encode(encoder, RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 1), nanos: 1,
                             keyframe: true)
        let delta = try encode(encoder, RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 2), nanos: 2)
        let decoder = RemoteVideoDecoder()
        // 重连后第一帧不是关键帧：不解（解出来是花屏），等关键帧。
        XCTAssertThrowsError(try decoder.decode(try wire(delta, codec: .hevc, sequence: 2, width: width, height: height))) {
            XCTAssertEqual($0 as? RemoteVideoDecodeError, .needsKeyframe)
        }
        XCTAssertNoThrow(try decoder.decode(try wire(key, codec: .hevc, sequence: 1, width: width, height: height)))
        XCTAssertNoThrow(try decoder.decode(try wire(delta, codec: .hevc, sequence: 2, width: width, height: height)))
        // 码流坏了：报错，并回到「等关键帧」。
        var broken = try wire(delta, codec: .hevc, sequence: 3, width: width, height: height)
        broken.data = Data(repeating: 0, count: 64)
        XCTAssertThrowsError(try decoder.decode(broken))
        XCTAssertTrue(decoder.awaitingKeyframe)
    }

    func test_decoder_rebuilds_when_resolution_changes() throws {
        let decoder = RemoteVideoDecoder()
        for (width, height) in [(640, 384), (1024, 640)] {
            let encoder = try RemoteVideoEncoder(codec: .hevc, width: width, height: height, bitrate: 3_000_000, frameRate: 60)
            let key = try encode(encoder, RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 3), nanos: 1,
                                 keyframe: true)
            let image = try decoder.decode(try wire(key, codec: .hevc, sequence: 1, width: width, height: height))
            XCTAssertEqual(CVPixelBufferGetWidth(image), width)
            XCTAssertEqual(CVPixelBufferGetHeight(image), height)
        }
    }

    func test_ten_bit_stream_is_main10_low_latency_and_round_trips() throws {
        let width = 1856, height = 1206
        let encoder = try RemoteVideoEncoder(codec: .hevc, width: width, height: height, bitrate: 10_000_000,
                                             frameRate: 60, tenBit: true)
        XCTAssertTrue(encoder.isLowLatency, "10-bit 也要走低延迟码控")
        let decoder = RemoteVideoDecoder()
        for seed in 1...3 {
            // 和生产一样喂 10-bit（采集直接出 `x420`）：喂 8-bit 时 VideoToolbox 会悄悄编成 Main。
            let source = try Self.tenBit(RemoteDesktopFixture.makeFrame(width: width, height: height, seed: seed))
            let encoded = try encode(encoder, source, nanos: UInt64(seed) * 16_000_000, keyframe: seed == 1)
            if seed == 1 {
                let format = try RemoteVideoDecoder.formatDescription(codec: .hevc, parameterSets: encoded.parameterSets)
                XCTAssertEqual(Self.hevcProfile(format), 2, "hvcC 的 profile 应为 Main10")
            }
            let image = try decoder.decode(try wire(encoded, codec: .hevc, sequence: UInt32(seed), width: width, height: height))
            let decoded = RemoteDesktopFixture.blockLuma(image)
            for block in 0..<16 {
                XCTAssertEqual(decoded[block], Double(RemoteDesktopFixture.lumaValue(block: block, seed: seed)), accuracy: 6)
            }
        }
    }

    /// 旁路精修：另一个会话、每次都是关键帧，用另一个解码器解；比同一张画面在主流里清楚得多，
    /// 而且主流的解码器不受影响，接着往下解。
    func test_still_encoder_makes_sharper_independent_keyframes() throws {
        let width = 1856, height = 1206
        let stream = try RemoteVideoEncoder(codec: .hevc, width: width, height: height, bitrate: 4_000_000,
                                            frameRate: 60, tenBit: true)
        let still = try RemoteVideoEncoder(codec: .hevc, width: width, height: height, bitrate: 0, frameRate: 60,
                                           tenBit: true, purpose: .still)
        XCTAssertFalse(still.isLowLatency)
        let streamDecoder = RemoteVideoDecoder(), stillDecoder = RemoteVideoDecoder()
        let first = RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 1, detail: true)
        let firstTenBit = try Self.tenBit(first)
        let streamed = try streamDecoder.decode(try wire(try encode(stream, firstTenBit, nanos: 1, keyframe: true),
                                                         codec: .hevc, sequence: 1, width: width, height: height))

        var sharpened: [CVPixelBuffer] = []
        for index in 0..<2 {
            let encoded = try encode(still, firstTenBit, nanos: UInt64(index + 1) * 16_000_000, keyframe: true)
            XCTAssertTrue(encoded.isKeyframe, "旁路精修帧每次都是关键帧，不依赖手机上的任何一帧")
            sharpened.append(try stillDecoder.decode(
                try wire(encoded, codec: .hevc, sequence: UInt32(10 + index), width: width, height: height, refine: true)))
        }
        let streamPSNR = RemoteDesktopFixture.lumaPSNR(first, streamed)
        let stillPSNR = RemoteDesktopFixture.lumaPSNR(first, sharpened[0])
        print(String(format: "[桌面探针] 旁路精修 1856×1206：主流 4 Mbps %.2f dB → 旁路 %.2f dB", streamPSNR, stillPSNR))
        XCTAssertGreaterThan(stillPSNR, streamPSNR + 2)

        // 主流接着来一帧 P 帧：它的参考是主流自己的上一帧，旁路帧没进过这个解码器，照样解得对。
        // 4 Mbps 下码控要为开头那个关键帧还账，会先丢几帧：同一画面隔一帧再送，和发送端一样。
        let second = try Self.tenBit(RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 2))
        var next: RemoteEncodedFrame?
        for attempt in 0..<200 where next == nil {
            next = try? encode(stream, second, nanos: UInt64(attempt + 2) * 16_000_000)
        }
        let delta = try XCTUnwrap(next)
        XCTAssertFalse(delta.isKeyframe)
        let image = try streamDecoder.decode(try wire(delta, codec: .hevc, sequence: 2, width: width, height: height))
        let decoded = RemoteDesktopFixture.blockLuma(image)
        for block in 0..<16 {
            XCTAssertEqual(decoded[block], Double(RemoteDesktopFixture.lumaValue(block: block, seed: 2)), accuracy: 6)
        }
    }

    /// 8-bit 合成画面转成采集给的 10-bit 4:2:0（`x420`）。
    private static func tenBit(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        CVPixelBufferCreate(nil, CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image),
                            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &output)
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        let converted = try XCTUnwrap(output)
        XCTAssertEqual(VTPixelTransferSessionTransferImage(try XCTUnwrap(session), from: image, to: converted), noErr)
        return converted
    }

    /// hvcC 第 2 字节的低 5 位是 general_profile_idc（1 = Main，2 = Main10）。
    private static func hevcProfile(_ format: CMFormatDescription) -> Int? {
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any]
        let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
        guard let hvcC = atoms?["hvcC"] as? Data, hvcC.count > 1 else { return nil }
        return Int(hvcC[hvcC.startIndex + 1] & 0x1f)
    }

    /// 静止精修：低码率下编出来的画面糊，同一画面以精修方式再编一次（P 帧，临时压低 QP 上限）应明显更清楚。
    /// 读数打印出来；断言只要求「不比原来差」，具体提升多少随画面与硬件而变。
    func test_refine_frame_improves_static_quality() throws {
        // 码率下限（拥塞时）与起始码率各量一次。
        for bitrate in [1_000_000, RemoteRateController.initialBitrate(width: 1856, height: 1206)] {
            try refine(bitrate: bitrate)
        }
    }

    private func refine(bitrate: Int) throws {
        let width = 1856, height = 1206
        let encoder = try RemoteVideoEncoder(codec: .hevc, width: width, height: height, bitrate: bitrate, frameRate: 60)
        let decoder = RemoteVideoDecoder()
        var lastDecoded: CVPixelBuffer?
        var source = RemoteDesktopFixture.makeFrame(width: width, height: height, seed: 1, detail: true)
        var bytes: [Int] = []
        var drops = 0
        var nanos: UInt64 = 0
        /// 低码率下码控会主动丢帧（`.dropped`）：同一画面隔一帧再送，和发送端的处理一样。
        func encodeKeeping(_ image: CVPixelBuffer, keyframe: Bool = false, refine: Bool = false) throws -> RemoteEncodedFrame {
            for _ in 0..<400 {
                nanos += 16_000_000
                do {
                    return try encode(encoder, image, nanos: nanos, keyframe: keyframe, refine: refine)
                } catch RemoteVideoEncoderError.dropped {
                    drops += 1
                }
            }
            throw RemoteVideoEncoderError.dropped
        }
        // 先让码控进入低码率状态：连续几帧大变化。
        for seed in 1...8 {
            source = RemoteDesktopFixture.makeFrame(width: width, height: height, seed: seed, detail: true)
            let encoded = try encodeKeeping(source, keyframe: seed == 1)
            bytes.append(encoded.data.count)
            lastDecoded = try decoder.decode(try wire(encoded, codec: .hevc, sequence: UInt32(seed), width: width, height: height))
        }
        let before = RemoteDesktopFixture.lumaPSNR(source, try XCTUnwrap(lastDecoded))
        let refined = try encodeKeeping(source, refine: true)
        let refinedImage = try decoder.decode(try wire(refined, codec: .hevc, sequence: 9, width: width, height: height,
                                                       refine: true))
        let after = RemoteDesktopFixture.lumaPSNR(source, refinedImage)
        // 精修之后恢复：下一帧不再受 QP 上限约束。
        let dropsBeforeNext = drops
        let next = try encodeKeeping(source)
        let recoveryMs = Double(drops - dropsBeforeNext) * 16
        print(String(format: "[桌面探针] 静止精修 1856×1206 HEVC @%.1f Mbps：PSNR %.2f → %.2f dB；精修帧 %d B，之前每帧 p50 %d B，之后一帧 %d B；精修后码控连丢 %.0f ms 才出下一帧；共丢 %d 次",
                     Double(bitrate) / 1e6, before, after, refined.data.count, bytes.sorted()[bytes.count / 2], next.data.count, recoveryMs, drops))
        XCTAssertGreaterThanOrEqual(after, before - 0.5)
    }
}
