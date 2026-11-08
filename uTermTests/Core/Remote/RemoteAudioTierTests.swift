import CryptoKit
import XCTest
@testable import uTerm

/// 声音分档（码率随链路容量、无损、10 ms 包）与静音恢复：纯策略、编解码，以及发送端在一条真实（内存）链路上换档。
final class RemoteAudioTierTests: XCTestCase {
    private typealias Link = RemoteAudioPolicy.Link

    // MARK: - 策略

    private func direct(_ mbps: Double, loss: Double = 0, lossless: Bool = true) -> Link {
        Link(path: .direct, capacity: mbps * 1_000_000, lossRate: loss, peerDecodesLossless: lossless)
    }

    func test_bitrate_follows_capacity_and_never_exceeds_five_percent() {
        for mbps in stride(from: 0.5, through: 39.5, by: 0.25) {
            let profile = RemoteAudioPolicy.profile(for: direct(mbps))
            let bitrate = try! XCTUnwrap(profile.bitrate)
            XCTAssertTrue(Double(bitrate) <= mbps * 1_000_000 * RemoteAudioPolicy.maxShare
                          || bitrate == RemoteAudioPolicy.floorBitrate, "\(mbps) Mbps → \(bitrate)")
        }
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(0.5)), .opus(bitrate: 32_000, frameMillis: 20), "下限")
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(1)), .opus(bitrate: 50_000, frameMillis: 20), "不够 64k 取 5%")
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(1.5)), .opus(bitrate: 64_000, frameMillis: 20))
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(2.5)), .opus(bitrate: 64_000, frameMillis: 20))
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(3)), .opus(bitrate: 128_000, frameMillis: 20))
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(5)), .opus(bitrate: 128_000, frameMillis: 20))
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(6)), .opus(bitrate: 256_000, frameMillis: 20))
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(7.5)), .opus(bitrate: 256_000, frameMillis: 20))
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(8)), .opus(bitrate: 384_000, frameMillis: 10),
                       "≥ 8 Mbps 上 384k，数据报上 10 ms 一包")
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(30)), .opus(bitrate: 384_000, frameMillis: 10))
    }

    func test_lossless_only_when_wide_clean_and_supported() {
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(40)), .lossless)
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(90)), .lossless)
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(90, loss: 0.002)), .opus(bitrate: 510_000, frameMillis: 10),
                       "有丢包退到 Opus 510k")
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(90, lossless: false)), .opus(bitrate: 384_000, frameMillis: 10),
                       "老手机不列无损")
        XCTAssertEqual(RemoteAudioPolicy.profile(for: direct(39)), .opus(bitrate: 384_000, frameMillis: 10))
        // 局域网 TCP：容量取画面码率；没有数据报，384k 也是 20 ms 一包。
        let lan = Link(path: .localNetwork, capacity: 20_000_000, peerDecodesLossless: true)
        XCTAssertEqual(RemoteAudioPolicy.profile(for: lan), .opus(bitrate: 384_000, frameMillis: 20))
        XCTAssertEqual(RemoteAudioPolicy.profile(for: Link(path: .localNetwork, capacity: 60_000_000,
                                                           peerDecodesLossless: true)), .lossless)
        // 中继固定 256k；容量未知时也先给 256k。
        XCTAssertEqual(RemoteAudioPolicy.profile(for: Link(path: .relay, capacity: 90_000_000, peerDecodesLossless: true)),
                       .opus(bitrate: 256_000, frameMillis: 20))
        XCTAssertEqual(RemoteAudioPolicy.profile(for: Link(path: .localNetwork, capacity: nil)),
                       .opus(bitrate: 256_000, frameMillis: 20))
    }

    func test_selector_drops_at_once_and_climbs_only_after_five_steady_seconds() {
        let second: UInt64 = 1_000_000_000
        var selector = RemoteAudioTierSelector(initial: .lossless)
        XCTAssertEqual(selector.current, .opus(bitrate: 256_000, frameMillis: 20), "开流不高于 256k")

        let high = RemoteAudioProfile.opus(bitrate: 384_000, frameMillis: 10)
        XCTAssertFalse(selector.update(high, now: 0))
        XCTAssertFalse(selector.update(high, now: 4 * second))
        // 中途掉回来一次：重新计时。
        XCTAssertFalse(selector.update(.opus(bitrate: 256_000, frameMillis: 20), now: 4 * second + 1))
        XCTAssertFalse(selector.update(high, now: 5 * second))
        XCTAssertFalse(selector.update(high, now: 9 * second))
        XCTAssertTrue(selector.update(high, now: 10 * second))
        XCTAssertEqual(selector.current, high)

        // 降档立刻。
        XCTAssertTrue(selector.update(.opus(bitrate: 64_000, frameMillis: 20), now: 10 * second + 1))
        XCTAssertEqual(selector.current.bitrate, 64_000)
        XCTAssertFalse(selector.update(.opus(bitrate: 64_000, frameMillis: 20), now: 11 * second))
    }

    func test_profile_switch_needs_new_encoder_only_for_codec_or_packet_length() {
        let a = RemoteAudioProfile.opus(bitrate: 128_000, frameMillis: 20)
        XCTAssertFalse(RemoteAudioProfile.opus(bitrate: 256_000, frameMillis: 20).needsNewEncoder(from: a))
        XCTAssertTrue(RemoteAudioProfile.opus(bitrate: 384_000, frameMillis: 10).needsNewEncoder(from: a))
        XCTAssertTrue(RemoteAudioProfile.lossless.needsNewEncoder(from: a))
        XCTAssertEqual(RemoteAudioProfile.lossless.framesPerPacket, 352)
        XCTAssertEqual(RemoteAudioProfile.opus(bitrate: 384_000, frameMillis: 10).framesPerPacket, 480)
    }

    /// 手机只对声明了无损的 Mac 列 `alac`：老 Mac 解不开不认识的编码，整条请求会失败。
    func test_phone_lists_lossless_only_for_macs_that_declare_it() throws {
        XCTAssertFalse(RemoteDesktopAudioRequest(enabled: true).codecs.contains(.alac))
        XCTAssertTrue(RemoteDesktopAudioRequest.codecs(lossless: true).contains(.alac))
        XCTAssertEqual(RemoteDesktopAudioRequest.codecs(lossless: true).first, .opus, "Opus 仍是首选，无损按链路条件另选")
        XCTAssertTrue(RemoteConstants.localFeatures.contains(RemoteFeature.desktopAudioLossless))
        // 老 Mac 的视角：编码只认 opus / aacELD，带了 alac 的请求整条解不开（所以手机不能发）。
        struct OldRequest: Decodable {
            enum OldCodec: String, Decodable { case opus, aacELD }
            var enabled: Bool
            var codecs: [OldCodec]
        }
        let plain = RemoteJSON.encode(RemoteDesktopAudioRequest(enabled: true))
        XCTAssertNoThrow(try RemoteJSON.decode(OldRequest.self, from: plain))
        let lossless = RemoteJSON.encode(RemoteDesktopAudioRequest(enabled: true, codecs: RemoteDesktopAudioRequest.codecs(lossless: true)))
        XCTAssertThrowsError(try RemoteJSON.decode(OldRequest.self, from: lossless))
    }

    // MARK: - 编解码

    private func sine(seconds: Double, frequency: Double = 440, amplitude: Float = 0.5) -> [Float] {
        let frames = Int(48_000 * seconds)
        var samples = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            let value = Float(sin(Double(index) * 2 * .pi * frequency / 48_000)) * amplitude
            samples[2 * index] = value
            samples[2 * index + 1] = value * 0.7
        }
        return samples
    }

    private func decodeAll(_ packets: [RemoteAudioPacket], encoder: RemoteAudioEncoder) throws -> [Float] {
        let decoder = try RemoteAudioDecoder(format: RemoteDesktopAudioFormat(
            stream: 1, codec: encoder.codec, framesPerPacket: encoder.framesPerPacket, magicCookie: encoder.magicCookie))
        return try packets.flatMap { try decoder.decode($0.data) }
    }

    func test_opus_ten_millisecond_packets_at_high_bitrate() throws {
        let encoder = try RemoteAudioEncoder(codec: .opus, bitrate: 384_000, framesPerPacket: 480)
        XCTAssertEqual(encoder.framesPerPacket, 480)
        let packets = try encoder.encode(sine(seconds: 1), captureNanos: 0)
        XCTAssertGreaterThanOrEqual(packets.count, 95)
        for (previous, next) in zip(packets, packets.dropFirst()) {
            XCTAssertEqual(Double(next.captureNanos &- previous.captureNanos), 10_000_000, accuracy: 1_000)
        }
        // 一包一定放得进数据报；平均下来带一份冗余也放得下（VBR 偶尔的大包由发送端少带冗余）。
        let sizes = packets.map(\.data.count)
        let largest = sizes.max() ?? 0, average = sizes.reduce(0, +) / max(1, sizes.count)
        XCTAssertLessThan(largest + RemoteDesktopAudioFrame.headerSize, RemoteAudioPolicy.datagramPayloadLimit,
                          "最大 \(largest) B")
        XCTAssertLessThan(RemoteDesktopAudioFrame.headerSize + 3 + average * 2, RemoteAudioPolicy.datagramPayloadLimit,
                          "平均 \(average) B")
        let decoded = try decodeAll(packets, encoder: encoder)
        XCTAssertGreaterThan(decoded.count, 40_000 * 2)
    }

    /// 无损：16-bit 精度内逐样相同（浮点 → 16-bit 量化，误差不超过半个 LSB 左右）。
    func test_alac_round_trip_is_lossless_at_sixteen_bits() throws {
        let encoder = try RemoteAudioEncoder(codec: .alac, bitrate: 0)
        XCTAssertEqual(encoder.framesPerPacket, 352)
        XCTAssertNotNil(encoder.magicCookie, "ALAC 解码要 magic cookie")
        let input = sine(seconds: 1, amplitude: 0.6)
        let packets = try encoder.encode(input, captureNanos: 0)
        XCTAssertGreaterThanOrEqual(packets.count, 130)
        let decoded = try decodeAll(packets, encoder: encoder)
        let frames = min(input.count, decoded.count) / 2
        XCTAssertGreaterThan(frames, 44_000)
        var worst: Float = 0
        for index in 0..<(frames * 2) { worst = max(worst, abs(decoded[index] - input[index])) }
        XCTAssertLessThan(worst, 2.0 / 32_768, "最大误差 \(worst)")
        let bytes = packets.map(\.data.count).reduce(0, +)
        print(String(format: "[声音探针] ALAC 正弦 1 s：%d 包，平均 %.0f B，约 %.0f kbps", packets.count,
                     Double(bytes) / Double(packets.count), Double(bytes) * 8 / 1000))
    }

    // MARK: - 发送端在真实链路上换档

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [RemoteMessage] = []
        func add(_ message: RemoteMessage) { lock.lock(); messages.append(message); lock.unlock() }
        var all: [RemoteMessage] { lock.lock(); defer { lock.unlock() }; return messages }
    }

    private final class LinkBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Link
        init(_ value: Link) { self.value = value }
        var link: Link {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private func establishedPair() async throws -> (phone: RemoteLink, mac: RemoteLink, inbox: Inbox) {
        let (phoneSide, macSide) = RemoteMemoryTransport.pair()
        let phone = RemoteLink(transport: phoneSide), mac = RemoteLink(transport: macSide)
        let inbox = Inbox()
        phone.setHandlers(onMessage: { inbox.add($0) }, onClose: { _ in })
        mac.setHandlers(onMessage: { _ in }, onClose: { _ in })
        func hello(_ staticKey: Curve25519.KeyAgreement.PrivateKey, _ ephemeral: Curve25519.KeyAgreement.PrivateKey) -> RemoteHello {
            RemoteHello(version: RemoteConstants.protocolVersion, deviceID: UUID(), deviceName: "test",
                        ephemeralKey: ephemeral.publicKey.rawRepresentation, staticKey: staticKey.publicKey.rawRepresentation)
        }
        let phoneStatic = Curve25519.KeyAgreement.PrivateKey(), phoneEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let macStatic = Curve25519.KeyAgreement.PrivateKey(), macEphemeral = Curve25519.KeyAgreement.PrivateKey()
        async let phoneDone = phone.establish(role: .initiator, hello: hello(phoneStatic, phoneEphemeral),
                                              staticKey: phoneStatic, ephemeralKey: phoneEphemeral)
        _ = try await mac.establish(role: .responder, hello: hello(macStatic, macEphemeral), staticKey: macStatic,
                                    ephemeralKey: macEphemeral)
        _ = try await phoneDone
        return (phone, mac, inbox)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// 起步 256k；链路变宽 5 秒后换成无损（新流号、新格式先到，之后的包都是新流的），手机按新格式解得出来；
    /// 链路一丢包立刻退到 Opus 510k。
    func test_streamer_climbs_to_lossless_with_a_new_stream_and_falls_back_on_loss() async throws {
        let pair = try await establishedPair()
        let box = LinkBox(Link(path: .localNetwork, capacity: 4_000_000, peerDecodesLossless: true))
        let numbers = RemoteAudioStreamNumbers()
        let first = numbers.next()
        let source = SyntheticAudioSource()
        let streamer = RemoteAudioStreamer(
            link: pair.mac, channel: 7, stream: first, codecs: RemoteDesktopAudioRequest.codecs(lossless: true),
            nextStream: { numbers.next() }, linkInfo: { box.link }, datagrams: nil, source: source,
            onSourceStopped: { _ in })
        defer { streamer.stop() }
        let format = try await streamer.start()
        XCTAssertEqual(format.codec, .opus)
        XCTAssertEqual(format.framesPerPacket, 960)

        let receiver = RemoteAudioReceiver(config: .direct)
        receiver.receive(format: format)
        let frames = { pair.inbox.all.filter { $0.kind == .desktopAudioFrame } }
        let formats = { pair.inbox.all.filter { $0.kind == .desktopAudioFormat }
            .compactMap { try? RemoteJSON.decode(RemoteDesktopAudioFormat.self, from: $0.payload) } }
        let flowing = await waitUntil(3) { frames().count >= 20 }
        XCTAssertTrue(flowing)
        // 4 Mbps × 5% → 128k（起步上限 256k 之内，降到够格的那档立刻生效）。
        XCTAssertEqual(pair.mac.queue.sync { streamer.currentProfile }, .opus(bitrate: 128_000, frameMillis: 20))

        box.link = Link(path: .localNetwork, capacity: 80_000_000, peerDecodesLossless: true)
        let switched = await waitUntil(9) { formats().contains { $0.codec == .alac } }
        XCTAssertTrue(switched, "宽裕 5 秒后应换成无损：\(formats())")
        let lossless = try XCTUnwrap(formats().first { $0.codec == .alac })
        XCTAssertNotEqual(lossless.stream, first)
        XCTAssertEqual(lossless.framesPerPacket, 352)
        receiver.receive(format: lossless)
        // 新格式之后的包解得出来。
        let arrived = await waitUntil(3) {
            frames().compactMap { try? RemoteDesktopAudioFrame(decoding: $0.payload) }
                .filter { $0.stream == lossless.stream && !$0.isSilence }.count >= 30
        }
        XCTAssertTrue(arrived)
        for message in frames() {
            guard let frame = try? RemoteDesktopAudioFrame(decoding: message.payload), frame.stream == lossless.stream else { continue }
            receiver.receive(frame: message.payload)
        }
        let decodedOK = await waitUntil(2) { receiver.snapshot().received >= 30 }
        XCTAssertTrue(decodedOK, "\(receiver.snapshot())")
        XCTAssertEqual(receiver.snapshot().codec, .alac)

        // 丢包：立刻退到 Opus 510k（局域网 TCP 上 20 ms 一包）。
        box.link = Link(path: .localNetwork, capacity: 80_000_000, lossRate: 0.01, peerDecodesLossless: true)
        let fellBack = await waitUntil(2) { formats().last?.codec == .opus }
        XCTAssertTrue(fellBack)
        XCTAssertEqual(pair.mac.queue.sync { streamer.currentProfile }, .opus(bitrate: 510_000, frameMillis: 20))
        XCTAssertGreaterThan(formats().last!.stream, lossless.stream)
    }

    /// 只记声音包的假数据报通道。
    private final class AudioDatagrams: RemoteVideoDatagramChannel, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [Data] = []
        var payloads: [Data] { lock.lock(); defer { lock.unlock() }; return sent }
        func startVideoSending(channel: UInt32, callbackQueue: DispatchQueue,
                               onLinkState: @escaping @Sendable (RemoteLinkState) -> Void,
                               onExpired: @escaping @Sendable ([UInt32]) -> Void) {}
        func sendVideo(_ payload: Data, sequence: UInt32, kind: RemoteLossPolicy.FrameKind) {}
        func acknowledgeVideo(sequence: UInt32) {}
        func videoLost(_ videoSequences: [UInt32], completion: @escaping @Sendable ([UInt32]) -> Void) {}
        func setVideoFEC(groupSize: Int) {}
        func stopVideoSending() {}
        func startVideoReceiving(onFrame: @escaping @Sendable (Data, UInt32) -> Void,
                                 onLost: @escaping @Sendable ([UInt32], UInt32) -> Void) {}
        func stopVideoReceiving() {}
        func sendAudio(_ payload: Data, channel: UInt32) { lock.lock(); sent.append(payload); lock.unlock() }
        func startAudioReceiving(onFrame: @escaping @Sendable (Data, UInt32) -> Void) {}
        func stopAudioReceiving() {}
    }

    /// 直连数据报上的无损：每个数据报都不超过上限，放不下的那几包改走可靠通道（不丢、手机照样收）。
    func test_datagram_packets_stay_under_the_limit_and_oversize_goes_reliable() async throws {
        let pair = try await establishedPair()
        let datagrams = AudioDatagrams()
        let numbers = RemoteAudioStreamNumbers()
        // 很「满」的声音（白噪声）：无损压不下去，352 采样一包常常超过数据报上限。
        final class NoiseSource: RemoteAudioSource, @unchecked Sendable {
            private let queue = DispatchQueue(label: "test.noise")
            private var timer: DispatchSourceTimer?
            func start(onSamples: @escaping @Sendable ([Float], UInt64) -> Void,
                       onStop: @escaping @Sendable (Error?) -> Void) async throws {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(10))
                timer.setEventHandler {
                    onSamples((0..<960).map { _ in Float.random(in: -0.8...0.8) }, DispatchTime.now().uptimeNanoseconds)
                }
                self.timer = timer
                timer.resume()
            }
            func stop() { timer?.cancel() }
        }
        let box = LinkBox(Link(path: .direct, capacity: 80_000_000, peerDecodesLossless: true))
        let streamer = RemoteAudioStreamer(
            link: pair.mac, channel: 7, stream: numbers.next(), codecs: RemoteDesktopAudioRequest.codecs(lossless: true),
            nextStream: { numbers.next() }, linkInfo: { box.link }, datagrams: datagrams, source: NoiseSource(),
            onSourceStopped: { _ in })
        defer { streamer.stop() }
        _ = try await streamer.start()
        let switched = await waitUntil(9) { pair.mac.queue.sync { streamer.currentProfile } == .lossless }
        XCTAssertTrue(switched)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(datagrams.payloads.isEmpty)
        XCTAssertTrue(datagrams.payloads.allSatisfy { $0.count <= RemoteAudioPolicy.datagramPayloadLimit },
                      "最大 \(datagrams.payloads.map(\.count).max() ?? 0) B")
        XCTAssertGreaterThan(streamer.stats.snapshot().reliable, 0, "白噪声的无损包放不进数据报，应改走可靠通道")
        let reliable = pair.inbox.all.filter { $0.kind == .desktopAudioFrame }
        XCTAssertFalse(reliable.isEmpty)
    }

    /// 静音停发后有声：第一包把停发前最后一包当冗余带上，手机的解码器先接上状态。
    func test_resuming_after_silence_carries_the_last_quiet_packet() async throws {
        let pair = try await establishedPair()
        let numbers = RemoteAudioStreamNumbers()
        let source = SyntheticAudioSource()
        let streamer = RemoteAudioStreamer(
            link: pair.mac, channel: 7, stream: numbers.next(), codecs: [.opus, .aacELD],
            nextStream: { numbers.next() },
            linkInfo: { Link(path: .localNetwork, capacity: 10_000_000) }, datagrams: nil, source: source,
            onSourceStopped: { _ in })
        defer { streamer.stop() }
        _ = try await streamer.start()
        let decodedFrames = { pair.inbox.all.filter { $0.kind == .desktopAudioFrame }
            .compactMap { try? RemoteDesktopAudioFrame(decoding: $0.payload) } }
        _ = await waitUntil(3) { decodedFrames().count >= 10 }
        source.setSilent(true)
        let markerSeen = await waitUntil(3) { decodedFrames().contains(where: \.isSilence) }
        XCTAssertTrue(markerSeen, "静了 200 ms 后应停发、只发静音标记")
        let quietUntil = decodedFrames().count
        source.setSilent(false)
        let resumed = await waitUntil(3) { decodedFrames().dropFirst(quietUntil).contains { !$0.isSilence } }
        XCTAssertTrue(resumed)
        let firstLoud = try XCTUnwrap(decodedFrames().dropFirst(quietUntil).first { !$0.isSilence })
        XCTAssertEqual(firstLoud.redundant.count, 1, "恢复的第一包带上停发前最后一包")
        XCTAssertTrue(firstLoud.flags.contains(.redundancy))
    }
}
