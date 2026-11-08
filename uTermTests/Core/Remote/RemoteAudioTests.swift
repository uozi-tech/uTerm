import CoreMedia
import XCTest
@testable import uTerm

/// 远程桌面声音（调研 §17）：线上格式、编解码往返、冗余与码率策略、抖动缓冲。
final class RemoteAudioTests: XCTestCase {

    // MARK: - 线上格式

    func test_audio_frame_round_trips_with_and_without_redundancy() throws {
        let plain = RemoteDesktopAudioFrame(stream: 3, sequence: 42, captureNanos: 123_456_789, data: Data([1, 2, 3]))
        XCTAssertEqual(try RemoteDesktopAudioFrame(decoding: plain.encoded()), plain)
        XCTAssertFalse(plain.flags.contains(.redundancy))

        let red = RemoteDesktopAudioFrame(stream: 3, sequence: 43, captureNanos: 1, data: Data([9]),
                                          redundant: [Data([8, 8]), Data([7])])
        let decoded = try RemoteDesktopAudioFrame(decoding: red.encoded())
        XCTAssertEqual(decoded, red)
        XCTAssertEqual(decoded.redundant, [Data([8, 8]), Data([7])])

        let silence = RemoteDesktopAudioFrame(flags: .silence, stream: 1, sequence: 5, captureNanos: 9, data: Data())
        XCTAssertTrue(try RemoteDesktopAudioFrame(decoding: silence.encoded()).isSilence)
    }

    func test_audio_frame_rejects_empty_non_silent_and_truncated() {
        let empty = RemoteDesktopAudioFrame(stream: 1, sequence: 1, captureNanos: 0, data: Data())
        XCTAssertThrowsError(try RemoteDesktopAudioFrame(decoding: empty.encoded()))
        let frame = RemoteDesktopAudioFrame(stream: 1, sequence: 1, captureNanos: 0, data: Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try RemoteDesktopAudioFrame(decoding: frame.encoded().dropLast(2)))
    }

    func test_audio_format_json_round_trips() throws {
        let format = RemoteDesktopAudioFormat(stream: 2, codec: .opus, magicCookie: Data([1, 2]))
        XCTAssertEqual(try RemoteJSON.decode(RemoteDesktopAudioFormat.self, from: RemoteJSON.encode(format)), format)
        let off = RemoteDesktopAudioFormat(stream: 2, codec: nil, message: "Mac 上没有打开")
        XCTAssertEqual(try RemoteJSON.decode(RemoteDesktopAudioFormat.self, from: RemoteJSON.encode(off)), off)
    }

    // MARK: - 策略

    func test_redundancy_and_bitrate_policy() {
        XCTAssertEqual(RemoteAudioPolicy.redundancy(lossRate: 0), 0)
        XCTAssertEqual(RemoteAudioPolicy.redundancy(lossRate: 0.01), 1)
        XCTAssertEqual(RemoteAudioPolicy.redundancy(lossRate: 0.08), 2)
        XCTAssertEqual(RemoteAudioPolicy.bitrate(pacingRate: nil), RemoteAudioPolicy.normalBitrate)
        XCTAssertEqual(RemoteAudioPolicy.bitrate(pacingRate: 10_000_000 / 8), RemoteAudioPolicy.normalBitrate)
        XCTAssertEqual(RemoteAudioPolicy.bitrate(pacingRate: 1_000_000 / 8), RemoteAudioPolicy.lowBitrate)
    }

    // MARK: - 编解码

    private func sine(seconds: Double, frequency: Double = 440, amplitude: Float = 0.5) -> [Float] {
        let frames = Int(48_000 * seconds)
        var samples = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            let value = Float(sin(Double(index) * 2 * .pi * frequency / 48_000)) * amplitude
            samples[2 * index] = value
            samples[2 * index + 1] = value
        }
        return samples
    }

    /// 解出来的声音与原声逐样比，找编解码延迟，返回信噪比（dB）。
    private func snr(original: [Float], decoded: [Float]) -> (lag: Int, db: Double) {
        var best = (lag: 0, error: Double.infinity)
        let frames = min(original.count, decoded.count) / 2
        let range = stride(from: frames / 4, to: frames * 3 / 4, by: 5)
        for lag in 0..<1500 where frames * 3 / 4 + lag < decoded.count / 2 {
            var error = 0.0
            for index in range {
                let diff = Double(decoded[2 * (index + lag)] - original[2 * index])
                error += diff * diff
            }
            if error < best.error { best = (lag, error) }
        }
        var signal = 0.0
        for index in range { signal += Double(original[2 * index] * original[2 * index]) }
        return (best.lag, 10 * log10(signal / max(best.error, 1e-12)))
    }

    private func roundTrip(_ codec: RemoteAudioCodec, chunk: Int) throws -> (packets: [RemoteAudioPacket], db: Double) {
        let encoder = try RemoteAudioEncoder(codec: codec, bitrate: 64_000)
        let input = sine(seconds: 1)
        var packets: [RemoteAudioPacket] = []
        var offset = 0
        var nanos: UInt64 = 1_000_000_000
        // 按采集回调那样一块一块地喂（块的大小与包的大小对不上）。
        while offset < input.count {
            let end = min(input.count, offset + chunk * 2)
            packets += try encoder.encode(Array(input[offset..<end]), captureNanos: nanos)
            nanos += UInt64(Double((end - offset) / 2) / 48_000 * 1e9)
            offset = end
        }
        let format = RemoteDesktopAudioFormat(stream: 1, codec: codec, framesPerPacket: encoder.framesPerPacket,
                                              magicCookie: encoder.magicCookie)
        let decoder = try RemoteAudioDecoder(format: format)
        var decoded: [Float] = []
        for packet in packets { decoded += try decoder.decode(packet.data) }
        return (packets, snr(original: input, decoded: decoded).db)
    }

    func test_opus_round_trip_quality_and_timestamps() throws {
        let (packets, db) = try roundTrip(.opus, chunk: 1024)
        XCTAssertGreaterThanOrEqual(packets.count, 45)
        XCTAssertGreaterThan(db, 30, "信噪比 \(db) dB")
        // 每包的时刻按 20 ms 递增。
        for (previous, next) in zip(packets, packets.dropFirst()) {
            XCTAssertEqual(Double(next.captureNanos &- previous.captureNanos), 20_000_000, accuracy: 1_000)
        }
        XCTAssertEqual(packets[0].captureNanos, 1_000_000_000)
        let average = packets.map(\.data.count).reduce(0, +) / packets.count
        XCTAssertLessThan(average, 250, "64 kbps × 20 ms ≈ 160 B")
        XCTAssertFalse(packets[10].isSilent)
    }

    /// 逐包解：每包都要解出一整包的采样（抖动缓冲按包放，解出空包就成了洞）。
    func test_each_opus_packet_decodes_to_a_full_packet() throws {
        let encoder = try RemoteAudioEncoder(codec: .opus, bitrate: 64_000)
        let packets = try encoder.encode(sine(seconds: 1), captureNanos: 0)
        let decoder = try RemoteAudioDecoder(format: RemoteDesktopAudioFormat(stream: 1, codec: .opus,
                                                                             framesPerPacket: encoder.framesPerPacket))
        let counts = try packets.map { try decoder.decode($0.data).count / 2 }
        XCTAssertEqual(Set(counts.dropFirst()), [960], "\(counts)")
    }

    func test_aac_eld_round_trip_quality() throws {
        let (packets, db) = try roundTrip(.aacELD, chunk: 441)
        XCTAssertGreaterThanOrEqual(packets.count, 80)
        XCTAssertGreaterThan(db, 20, "信噪比 \(db) dB")
    }

    func test_encoder_marks_silent_packets() throws {
        let encoder = try RemoteAudioEncoder(codec: .opus, bitrate: 64_000)
        var input = [Float](repeating: 0, count: 48_000 * 2)
        // 后半秒有声。
        let tone = sine(seconds: 0.5)
        input.replaceSubrange((24_000 * 2)..<(48_000 * 2), with: tone)
        let packets = try encoder.encode(input, captureNanos: 0)
        XCTAssertTrue(packets.prefix(20).allSatisfy(\.isSilent))
        XCTAssertTrue(packets.dropFirst(26).prefix(20).allSatisfy { !$0.isSilent })
    }

    // MARK: - 抖动缓冲

    private let packet = 960
    private func chunk(_ value: Float) -> [Float] { Array(repeating: value, count: 960 * 2) }
    private let ms: UInt64 = 1_000_000

    /// 按 20 ms 节拍到达、抖动为 0：缓到目标深度才开始放，之后逐包放出、不补洞不丢包。
    func test_jitter_buffer_waits_for_target_then_plays_in_order() {
        var buffer = RemoteAudioJitterBuffer(config: .direct)
        XCTAssertEqual(buffer.targetNanos, 40 * ms)
        buffer.insert(sequence: 0, captureNanos: 0, samples: chunk(0.1), arrivalNanos: 5 * ms)
        // 只有 20 ms，不够 40 ms：出静音。
        XCTAssertTrue(buffer.pull(frames: 480).allSatisfy { $0 == 0 })
        XCTAssertFalse(buffer.isPlaying)
        for sequence in 1...4 {
            buffer.insert(sequence: UInt32(sequence), captureNanos: UInt64(sequence) * 20 * ms,
                          samples: chunk(Float(sequence + 1) / 10), arrivalNanos: UInt64(sequence) * 20 * ms + 5 * ms)
        }
        let out = buffer.pull(frames: packet)
        XCTAssertTrue(buffer.isPlaying)
        // 淡入之后就是第一包的值。
        XCTAssertEqual(out[(packet - 1) * 2], 0.1, accuracy: 1e-6)
        let next = buffer.pull(frames: packet)
        XCTAssertEqual(next[100], 0.2, accuracy: 1e-6)
        XCTAssertEqual(buffer.counters.played, 2)
        XCTAssertEqual(buffer.counters.concealed, 0)
    }

    /// 中间丢一包：轮到它时补一包静音，接着放后面的。
    func test_jitter_buffer_conceals_missing_packet() {
        var buffer = RemoteAudioJitterBuffer(config: .direct)
        for sequence in [0, 1, 2, 4, 5] as [UInt32] {
            buffer.insert(sequence: sequence, captureNanos: UInt64(sequence) * 20 * ms, samples: chunk(0.5),
                          arrivalNanos: UInt64(sequence) * 20 * ms)
        }
        for _ in 0..<3 { _ = buffer.pull(frames: packet) }
        let gap = buffer.pull(frames: packet)
        // 先 1 ms 淡出，之后是静音。
        XCTAssertLessThan(abs(gap[200]), 1e-6)
        XCTAssertEqual(buffer.counters.concealed, 1)
        let after = buffer.pull(frames: packet)
        XCTAssertEqual(after[packet], 0.5, accuracy: 1e-6)
        XCTAssertEqual(buffer.counters.played, 4)
    }

    /// Mac 说过是静音的那段，空着不算补洞。
    func test_jitter_buffer_does_not_count_announced_silence_as_concealment() {
        var buffer = RemoteAudioJitterBuffer(config: .direct)
        for sequence in [0, 1, 2] as [UInt32] {
            buffer.insert(sequence: sequence, captureNanos: UInt64(sequence) * 20 * ms, samples: chunk(0.5),
                          arrivalNanos: UInt64(sequence) * 20 * ms)
        }
        buffer.markSilence(through: 4, captureNanos: 80 * ms, arrivalNanos: 80 * ms)
        buffer.insert(sequence: 5, captureNanos: 100 * ms, samples: chunk(0.5), arrivalNanos: 100 * ms)
        for _ in 0..<6 { _ = buffer.pull(frames: packet) }
        XCTAssertEqual(buffer.counters.concealed, 0)
        XCTAssertEqual(buffer.counters.played, 4)
    }

    /// 缓冲整个放空：回到缓冲中，等够深度再放；中间只出静音，不重复旧声音。
    func test_jitter_buffer_rebuffers_after_underrun() {
        var buffer = RemoteAudioJitterBuffer(config: .direct)
        for sequence in 0..<3 as Range<UInt32> {
            buffer.insert(sequence: sequence, captureNanos: UInt64(sequence) * 20 * ms, samples: chunk(0.5),
                          arrivalNanos: UInt64(sequence) * 20 * ms)
        }
        for _ in 0..<4 { _ = buffer.pull(frames: packet) }
        XCTAssertEqual(buffer.counters.underruns, 1)
        XCTAssertFalse(buffer.isPlaying)
        XCTAssertTrue(buffer.pull(frames: packet).allSatisfy { $0 == 0 })
        // 迟到的旧包（比已放过的还旧）不再放。
        buffer.insert(sequence: 1, captureNanos: 20 * ms, samples: chunk(0.9), arrivalNanos: 120 * ms)
        XCTAssertFalse(buffer.isPlaying)
    }

    /// Mac 停发静音（只报了「到这里都是静音」）导致缓冲放空：这是正常的停顿，不算欠载。
    func test_jitter_buffer_does_not_count_announced_silence_as_underrun() {
        var buffer = RemoteAudioJitterBuffer(config: .direct)
        for sequence in 0..<3 as Range<UInt32> {
            buffer.insert(sequence: sequence, captureNanos: UInt64(sequence) * 20 * ms, samples: chunk(0.5),
                          arrivalNanos: UInt64(sequence) * 20 * ms)
        }
        buffer.markSilence(through: 3, captureNanos: 60 * ms, arrivalNanos: 60 * ms)
        for _ in 0..<5 { _ = buffer.pull(frames: packet) }
        XCTAssertFalse(buffer.isPlaying)
        XCTAssertEqual(buffer.counters.underruns, 0)
        XCTAssertEqual(buffer.counters.played, 3)
    }

    /// SCK 声音的采集时刻取样本自带的时间戳（主机时钟），换算到单调时钟；时间戳离谱时退回「交付时刻 − 时长」。
    func test_capture_time_uses_presentation_timestamp() throws {
        func buffer(at seconds: Double) throws -> CMSampleBuffer {
            let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                                            decodeTimeStamp: .invalid)
            return try CMSampleBuffer(dataBuffer: nil, formatDescription: nil, numSamples: 1, sampleTimings: [timing],
                                      sampleSizes: [])
        }
        let now: UInt64 = 1_000_000_000_000
        let hostNow = CMTime(seconds: 500, preferredTimescale: 1_000_000_000)
        // 时间戳比现在早 35 ms：采集时刻就是 35 ms 前，与这块有多长无关。
        let early = ScreenCaptureAudioSource.captureNanos(try buffer(at: 499.965), frames: 960, now: now, hostNow: hostNow)
        XCTAssertEqual(Double(now - early) / 1e6, 35, accuracy: 0.01)
        // 时间戳在未来或太旧：退回交付时刻往前推 960 帧（20 ms）。
        for seconds in [500.5, 400.0] {
            let fallback = ScreenCaptureAudioSource.captureNanos(try buffer(at: seconds), frames: 960, now: now, hostNow: hostNow)
            XCTAssertEqual(Double(now - fallback) / 1e6, 20, accuracy: 0.01)
        }
    }

    /// 积压超过目标 + 60 ms：丢包追上，先丢静音包。到达很平稳（目标停在 40 ms），是播放这边卡了一阵、
    /// 攒下了 120 ms（两端时钟漂移攒久了也是这样）：超出 20 ms，正好丢一包。
    func test_jitter_buffer_drops_quiet_packets_first_when_backlogged() {
        var buffer = RemoteAudioJitterBuffer(config: .direct)
        for sequence in 0..<6 as Range<UInt32> {
            buffer.insert(sequence: sequence, captureNanos: UInt64(sequence) * 20 * ms,
                          samples: chunk(sequence == 3 ? 0 : 0.5), arrivalNanos: UInt64(sequence) * 20 * ms + 10 * ms)
        }
        XCTAssertEqual(buffer.targetNanos, 40 * ms)
        _ = buffer.pull(frames: packet)
        XCTAssertEqual(buffer.counters.dropped, 1)
        XCTAssertLessThanOrEqual(buffer.bufferedNanos, buffer.targetNanos + 60 * ms)
        XCTAssertFalse(buffer.contains(3), "先丢静音包")
        XCTAssertTrue([1, 2, 4, 5].allSatisfy { buffer.contains($0) })
    }

    /// 播放开始前已经攒了很多包（拉取晚开始），之后按 10 ms 拉 480 个采样、包按 20 ms 到：先丢包追上，然后逐包放。
    func test_jitter_buffer_catches_up_then_plays_with_half_packet_pulls() {
        var buffer = RemoteAudioJitterBuffer(config: .direct)
        var now: UInt64 = 0
        for sequence in 0..<100 as Range<UInt32> {
            buffer.insert(sequence: sequence, captureNanos: UInt64(sequence) * 20 * ms, samples: chunk(0.5),
                          arrivalNanos: UInt64(sequence) * 20 * ms + 5 * ms)
            now = UInt64(sequence) * 20 * ms + 5 * ms
        }
        var next: UInt32 = 100
        var heard = 0
        for step in 0..<200 {
            now += 10 * ms
            if step % 2 == 0 {
                buffer.insert(sequence: next, captureNanos: UInt64(next) * 20 * ms, samples: chunk(0.5), arrivalNanos: now)
                next += 1
            }
            if buffer.pull(frames: 480).contains(where: { $0 > 0.4 }) { heard += 1 }
        }
        XCTAssertGreaterThan(buffer.counters.played, 90, "\(buffer.counters)")
        XCTAssertEqual(buffer.counters.concealed, 0, "\(buffer.counters)")
        XCTAssertGreaterThan(heard, 190)
    }

    /// 积压里有洞（真丢了的包）：追积压时播放位置要跳过洞，不能卡在洞上把后面的包一个个丢光。
    func test_jitter_buffer_catches_up_across_a_hole() {
        var buffer = RemoteAudioJitterBuffer(config: .direct)
        for sequence in 0..<60 as Range<UInt32> where sequence != 30 {
            buffer.insert(sequence: sequence, captureNanos: UInt64(sequence) * 20 * ms, samples: chunk(0.5),
                          arrivalNanos: UInt64(sequence) * 20 * ms + 5 * ms)
        }
        var now: UInt64 = 60 * 20 * ms
        var next: UInt32 = 60
        for step in 0..<100 {
            now += 10 * ms
            if step % 2 == 0 {
                buffer.insert(sequence: next, captureNanos: UInt64(next) * 20 * ms, samples: chunk(0.5), arrivalNanos: now)
                next += 1
            }
            _ = buffer.pull(frames: 480)
        }
        XCTAssertGreaterThan(buffer.counters.played, 45, "\(buffer.counters)")
        XCTAssertLessThanOrEqual(buffer.counters.concealed, 1, "\(buffer.counters)")
    }

    /// 到达有抖动时目标会升（不超过上限），抖动过去后慢慢降回去。
    func test_jitter_buffer_target_follows_arrival_jitter() {
        var buffer = RemoteAudioJitterBuffer(config: .direct)
        // 每 5 包有一包晚到 90 ms。
        for sequence in 0..<100 as Range<UInt64> {
            let late: UInt64 = sequence % 5 == 0 ? 90 * ms : 0
            buffer.insert(sequence: UInt32(sequence), captureNanos: sequence * 20 * ms, samples: chunk(0.5),
                          arrivalNanos: sequence * 20 * ms + 10 * ms + late)
        }
        XCTAssertGreaterThanOrEqual(buffer.targetNanos, 100 * ms)
        XCTAssertLessThanOrEqual(buffer.targetNanos, 150 * ms)
        let raised = buffer.targetNanos
        // 之后 10 秒很平稳。
        for sequence in 100..<600 as Range<UInt64> {
            buffer.insert(sequence: UInt32(sequence), captureNanos: sequence * 20 * ms, samples: chunk(0.5),
                          arrivalNanos: sequence * 20 * ms + 10 * ms)
            _ = buffer.pull(frames: packet)
        }
        XCTAssertLessThan(buffer.targetNanos, raised)
        XCTAssertGreaterThanOrEqual(buffer.targetNanos, 40 * ms)
    }
}
