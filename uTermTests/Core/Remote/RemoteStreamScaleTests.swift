import CryptoKit
import XCTest
@testable import uTerm

/// 窄链路降分辨率：选档（纯函数）、升降节奏，以及发送端真按新尺寸编、手机照样解得开。
final class RemoteStreamScaleTests: XCTestCase {
    typealias Policy = RemoteStreamScalePolicy

    /// 链路速率（比特 / 秒）→ 发送节奏（字节 / 秒）→ 视频份额。
    private func share(mbps: Double) -> Double {
        RemoteLossPolicy.videoShare(pacingRate: mbps * 1e6 / 8)
    }

    private func wanted(mbps: Double, limited: Bool = true, width: Int = 1856, height: Int = 1206,
                        current: RemoteStreamScale = .full) -> RemoteStreamScale {
        Policy.wanted(videoShare: share(mbps: mbps), limited: limited, width: width, height: height, current: current)
    }

    /// 宽链路上一律全尺寸：弱网矩阵的基线（20 Mbps）、丢包 / 抖动档（10 Mbps）读数不该被它改动。
    func test_wide_links_keep_full_size() {
        for mbps in [10.0, 20, 50, 100] {
            XCTAssertEqual(wanted(mbps: mbps), .full, "\(mbps) Mbps · 1856×1206")
        }
        XCTAssertEqual(wanted(mbps: 20, width: 4608, height: 2592), .full, "5K 虚拟屏 20 Mbps")
        XCTAssertEqual(wanted(mbps: 50, width: 4608, height: 2592), .full)
    }

    /// 节奏还没撞到过上限（开流从 8 Mbps 起步、屏幕静止时不涨）：不代表链路窄，不降。
    func test_not_limited_never_downscales() {
        XCTAssertEqual(wanted(mbps: 0.75, limited: false), .full)
        XCTAssertEqual(wanted(mbps: 8, limited: false, width: 4608, height: 2592), .full,
                       "5K 开流时节奏还在起步值，不能先降成 2/3")
    }

    func test_narrow_links_scale_down_in_two_steps() {
        XCTAssertEqual(wanted(mbps: 0.75), .half, "3G")
        XCTAssertEqual(wanted(mbps: 1), .half, "带宽骤降到 1 Mbps")
        XCTAssertEqual(wanted(mbps: 2), .twoThirds)
        XCTAssertEqual(wanted(mbps: 3.5), .full)
        XCTAssertEqual(wanted(mbps: 8, width: 4608, height: 2592), .twoThirds, "5K 虚拟屏要的多")
    }

    /// 往上升要多给 1.5 倍余量：在门槛附近晃时不来回换。
    func test_upgrade_needs_margin_above_the_floor() {
        // 刚过全尺寸门槛：从全尺寸看够格，从 2/3 往上看不够。
        let justAbove = Policy.fullFloor * 1.1 * 1856 * 1206 * Policy.referenceFrameRate
        XCTAssertEqual(Policy.wanted(videoShare: justAbove, limited: true, width: 1856, height: 1206, current: .full), .full)
        XCTAssertEqual(Policy.wanted(videoShare: justAbove, limited: true, width: 1856, height: 1206, current: .twoThirds),
                       .twoThirds)
        let wellAbove = Policy.fullFloor * 1.6 * 1856 * 1206 * Policy.referenceFrameRate
        XCTAssertEqual(Policy.wanted(videoShare: wellAbove, limited: true, width: 1856, height: 1206, current: .half), .full)
    }

    /// 缩完太小就停在还够大的那一档。
    func test_small_streams_do_not_shrink_below_minimum() {
        XCTAssertEqual(wanted(mbps: 0.3, width: 640, height: 400), .full)
        XCTAssertEqual(wanted(mbps: 0.3, width: 1200, height: 720), .half, "一半是 600×360，刚好够")
        XCTAssertEqual(wanted(mbps: 0.3, width: 1100, height: 700), .twoThirds, "一半短边 350 不够")
    }

    func test_scaled_sizes_keep_aspect_and_are_even() {
        XCTAssertTrue(RemoteStreamScale.full.size(width: 1856, height: 1206) == (1856, 1206))
        XCTAssertTrue(RemoteStreamScale.twoThirds.size(width: 1856, height: 1206) == (1238, 804))
        XCTAssertTrue(RemoteStreamScale.half.size(width: 1856, height: 1206) == (928, 604))
        for scale in RemoteStreamScale.allCases {
            let size = scale.size(width: 4608, height: 2592)
            XCTAssertEqual(size.width % 2, 0)
            XCTAssertEqual(size.height % 2, 0)
            XCTAssertEqual(Double(size.width) / Double(size.height), 4608.0 / 2592, accuracy: 0.01)
        }
    }

    /// 挨饿：画面在动（采集 ≥ 8 fps），送出去的不到 35%；看的时间不够 2 s 不下结论。
    func test_starved_needs_motion_and_most_frames_held_back() {
        XCTAssertTrue(Policy.starved(captured: 60, sent: 4, seconds: 2), "3G 满屏在变：全尺寸只送出 4–7%")
        XCTAssertFalse(Policy.starved(captured: 60, sent: 58, seconds: 2), "1 Mbps 上局部滚动照样 30 fps")
        XCTAssertFalse(Policy.starved(captured: 60, sent: 33, seconds: 2), "3G 局部滚动送出五成多：降了反而少")
        XCTAssertFalse(Policy.starved(captured: 10, sent: 2, seconds: 2), "画面几乎不动")
        XCTAssertFalse(Policy.starved(captured: 45, sent: 2, seconds: 1.5), "看得还不够久：骤降前的积压还没过去")
    }

    /// 只有降档要挨饿；升档不看。
    func test_gate_holds_downgrades_unless_starved() {
        XCTAssertEqual(Policy.gated(.half, current: .full, starved: false), .full)
        XCTAssertEqual(Policy.gated(.half, current: .full, starved: true), .half)
        XCTAssertEqual(Policy.gated(.full, current: .half, starved: false), .full)
        XCTAssertEqual(Policy.gated(.twoThirds, current: .twoThirds, starved: false), .twoThirds)
    }

    /// 降档立刻；升档连续 5 秒够格、一次一档；中途不够格就重新计时。
    func test_selector_drops_at_once_and_climbs_one_step_after_five_seconds() {
        let second: UInt64 = 1_000_000_000
        var selector = RemoteStreamScaleSelector()
        XCTAssertEqual(selector.current, .full)
        XCTAssertTrue(selector.update(.half, now: 0))
        XCTAssertEqual(selector.current, .half)

        XCTAssertFalse(selector.update(.full, now: 1 * second))
        XCTAssertFalse(selector.update(.full, now: 5 * second))
        XCTAssertFalse(selector.update(.half, now: 5 * second + 1), "中途不够格")
        XCTAssertFalse(selector.update(.full, now: 6 * second))
        XCTAssertFalse(selector.update(.full, now: 10 * second))
        XCTAssertTrue(selector.update(.full, now: 11 * second))
        XCTAssertEqual(selector.current, .twoThirds, "一次只升一档")
        XCTAssertFalse(selector.update(.full, now: 15 * second))
        XCTAssertTrue(selector.update(.full, now: 16 * second))
        XCTAssertEqual(selector.current, .full)

        XCTAssertTrue(selector.update(.twoThirds, now: 16 * second + 1), "降档立刻")
        XCTAssertFalse(selector.update(.twoThirds, now: 17 * second))
    }

    // MARK: - 发送端

    /// 只记视频、能推链路状态的假数据报通道。
    private final class VideoDatagrams: RemoteVideoDatagramChannel, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [Data] = []
        private var onLinkState: (@Sendable (RemoteLinkState) -> Void)?
        private var queue: DispatchQueue?
        var payloads: [Data] { lock.lock(); defer { lock.unlock() }; return sent }
        func push(_ state: RemoteLinkState) {
            lock.lock(); let handler = onLinkState, queue = queue; lock.unlock()
            queue?.async { handler?(state) }
        }
        func startVideoSending(channel: UInt32, callbackQueue: DispatchQueue,
                               onLinkState: @escaping @Sendable (RemoteLinkState) -> Void,
                               onExpired: @escaping @Sendable ([UInt32]) -> Void) {
            lock.lock(); self.onLinkState = onLinkState; queue = callbackQueue; lock.unlock()
        }
        func sendVideo(_ payload: Data, sequence: UInt32, kind: RemoteLossPolicy.FrameKind) {
            lock.lock(); sent.append(payload); lock.unlock()
        }
        func acknowledgeVideo(sequence: UInt32) {}
        func videoLost(_ videoSequences: [UInt32], completion: @escaping @Sendable ([UInt32]) -> Void) {}
        func setVideoFEC(groupSize: Int) {}
        func stopVideoSending() {}
        func startVideoReceiving(onFrame: @escaping @Sendable (Data, UInt32) -> Void,
                                 onLost: @escaping @Sendable ([UInt32], UInt32) -> Void) {}
        func stopVideoReceiving() {}
        func sendAudio(_ payload: Data, channel: UInt32) {}
        func startAudioReceiving(onFrame: @escaping @Sendable (Data, UInt32) -> Void) {}
        func stopAudioReceiving() {}
    }

    private func establishedPair() async throws -> (phone: RemoteLink, mac: RemoteLink) {
        let (phoneSide, macSide) = RemoteMemoryTransport.pair()
        let phone = RemoteLink(transport: phoneSide), mac = RemoteLink(transport: macSide)
        phone.setHandlers(onMessage: { _ in }, onClose: { _ in })
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
        return (phone, mac)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// 一条直连桌面流：真实发送端 + 假数据报通道，手机这边解码、确认。
    private final class Rig {
        let pair: (phone: RemoteLink, mac: RemoteLink)
        let datagrams = VideoDatagrams()
        let source = SyntheticFrameSource(width: 1856, height: 1206)
        let streamer: RemoteDesktopStreamer
        private let decoder = RemoteVideoDecoder()
        private var acked = 0
        static let narrow = RemoteLinkState(roundTripNanos: 100_000_000, lossRate: 0, deliveryRate: 90_000,
                                            pacingRate: 0.75e6 / 8, queueDelayNanos: 0, limited: true)

        init(pair: (phone: RemoteLink, mac: RemoteLink)) {
            self.pair = pair
            let display = RemoteDesktopDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 928, height: 603),
                                               pixelWidth: 1856, pixelHeight: 1206)
            streamer = RemoteDesktopStreamer(
                link: pair.mac, channel: 3, codec: .hevc, width: 1856, height: 1206, display: display, path: .direct,
                video: datagrams, source: source, injector: nil, cursorLocation: nil,
                onFirstInput: {}, onSourceStopped: { _ in })
        }

        func start() async throws {
            try await streamer.start()
            streamer.activate(started: RemoteMessage(.desktopStarted, channel: 3, payload: Data()))
        }

        func stop() {
            source.pause()
            streamer.stop()
        }

        /// 解码并确认新收到的帧，按顺序返回（帧、解出的画面）。
        func drain() -> [(RemoteDesktopFrame, CVPixelBuffer?)] {
            var frames: [(RemoteDesktopFrame, CVPixelBuffer?)] = []
            let payloads = datagrams.payloads
            while acked < payloads.count {
                defer { acked += 1 }
                guard let frame = try? RemoteDesktopFrame(decoding: payloads[acked]) else { continue }
                let image = try? decoder.decode(frame)
                let ack = RemoteDesktopAck(sequence: frame.sequence, captureNanos: frame.captureNanos, decodeMicros: 1,
                                           failed: image == nil, ltrToken: image != nil ? frame.ltrToken : nil)
                let streamer = self.streamer
                pair.mac.queue.async { streamer.handle(RemoteMessage(.desktopAck, channel: 3, payload: ack.encoded())) }
                frames.append((frame, image))
            }
            return frames
        }
    }

    /// 直连链路撞到上限、窄到 3G、主流在挨饿：主编码器按一半尺寸重建，下一帧是那个尺寸的关键帧，手机的解码器
    /// 照样解得开（按参数集重建会话），解出来就是缩后的尺寸——显示层按 Mac 屏幕的点尺寸拉伸，坐标与它无关。
    func test_streamer_rebuilds_encoder_at_half_size_when_starved_on_a_narrow_direct_link() async throws {
        let rig = Rig(pair: try await establishedPair())
        defer { rig.stop() }
        try await rig.start()
        let first = await waitUntil(10) { !rig.datagrams.payloads.isEmpty }
        XCTAssertTrue(first, "第一帧没发出来")
        XCTAssertEqual(rig.drain().first?.0.width, 1856, "开流全尺寸")

        // 链路窄了、画面满屏在变：手机这段时间不回确认（在途满了，新帧一直被替掉），主流挨饿 2 秒多。
        rig.source.prepareCycle(count: 6)
        rig.source.run(fps: 30)
        let starvedUntil = Date().addingTimeInterval(3)
        while Date() < starvedUntil {
            rig.datagrams.push(Rig.narrow)
            try await Task.sleep(for: .milliseconds(100))
        }
        // 接着照常解码、确认：挨饿时选了档，在途清掉后换成，第一张小尺寸的帧是关键帧。
        var scaled: (RemoteDesktopFrame, CVPixelBuffer?)?
        let arrived = await waitUntil(10) {
            rig.datagrams.push(Rig.narrow)
            scaled = scaled ?? rig.drain().first { $0.0.width != 1856 }
            return scaled != nil
        }
        XCTAssertTrue(arrived, "链路变窄、主流挨饿后没有按小尺寸发帧")
        let (frame, image) = try XCTUnwrap(scaled)
        XCTAssertEqual(frame.width, 928)
        XCTAssertEqual(frame.height, 604)
        XCTAssertTrue(frame.isKeyframe, "换尺寸后的第一帧是关键帧")
        let decoded = try XCTUnwrap(image, "手机解不开缩后的关键帧")
        XCTAssertEqual(CVPixelBufferGetWidth(decoded), 928)
        XCTAssertEqual(CVPixelBufferGetHeight(decoded), 604)
    }

    /// 链路一样窄，但帧照样发得出去（手机一直在确认、没有挨饿）：不降档，不白发关键帧。
    func test_streamer_keeps_full_size_on_a_narrow_link_while_frames_get_through() async throws {
        let rig = Rig(pair: try await establishedPair())
        defer { rig.stop() }
        try await rig.start()
        let first = await waitUntil(10) { !rig.datagrams.payloads.isEmpty }
        XCTAssertTrue(first, "第一帧没发出来")
        _ = rig.drain()

        rig.source.prepareCycle(count: 6)
        rig.source.run(fps: 30)
        var widths: Set<UInt16> = []
        let until = Date().addingTimeInterval(3)
        while Date() < until {
            rig.datagrams.push(Rig.narrow)
            rig.drain().forEach { widths.insert($0.0.width) }
            try await Task.sleep(for: .milliseconds(30))
        }
        widths.formUnion(rig.drain().map(\.0.width))
        XCTAssertEqual(widths, [1856])
    }
}
