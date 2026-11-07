import CryptoKit
@preconcurrency import Network
import XCTest
@testable import uTerm

/// 链路层排队（调研 §16.5）在真实 TCP 上的效果：两条 `RemoteLink` 经 `RemoteFaultProxy` 相连（10 Mbps、往返 100 ms），
/// Mac 一侧持续发视频把链路塞满（端到端在途最多 1 MB，模拟码控估高了带宽时的中继路径），同时每 20 ms 发一包声音。
/// 对比开 / 关 `link-flow`：声音的到达延迟、视频的吞吐。
final class RemoteLinkFlowLinkTests: XCTestCase {

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var delays: [UInt64] = []
        private var videoBytes = 0
        private var videoStart: UInt64?
        func audio(sentAt: UInt64) {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock(); delays.append(now &- sentAt); lock.unlock()
        }
        func video(_ bytes: Int) {
            lock.lock()
            if videoStart == nil { videoStart = DispatchTime.now().uptimeNanoseconds }
            videoBytes += bytes
            lock.unlock()
        }
        func reset() {
            lock.lock(); delays.removeAll(); videoBytes = 0; videoStart = DispatchTime.now().uptimeNanoseconds; lock.unlock()
        }
        func snapshot() -> (p50: Double, p95: Double, mbps: Double, count: Int) {
            lock.lock(); defer { lock.unlock() }
            let sorted = delays.sorted()
            func pct(_ p: Double) -> Double {
                sorted.isEmpty ? .infinity : Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]) / 1e6
            }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds &- (videoStart ?? 0)) / 1e9
            return (pct(0.5), pct(0.95), Double(videoBytes) * 8 / seconds / 1e6, sorted.count)
        }
    }

    /// Mac 一侧的视频发送：每帧 60 KB，手机收到回 `desktopAck`，端到端在途不超过 1 MB（与 `RemoteDesktopPacer` 的字节上限同一思路）。
    private final class VideoSource: @unchecked Sendable {
        let link: RemoteLink
        var inFlight: [UInt32: Int] = [:]
        var sequence: UInt32 = 0
        var stopped = false
        init(link: RemoteLink) { self.link = link }
        /// 在 link.queue 上调用。
        func pump() {
            while !stopped, inFlight.values.reduce(0, +) < 1_000_000 {
                sequence &+= 1
                var payload = Data(count: 60_000)
                withUnsafeBytes(of: sequence.bigEndian) { payload.replaceSubrange(0..<4, with: $0) }
                inFlight[sequence] = payload.count
                link.sendOnQueue(RemoteMessage(.desktopFrame, channel: 5, payload: payload), countsTowardBackpressure: false)
            }
        }
        func acknowledged(_ sequence: UInt32) {
            inFlight[sequence] = nil
            pump()
        }
    }

    private func hello(_ staticKey: Curve25519.KeyAgreement.PrivateKey, _ ephemeral: Curve25519.KeyAgreement.PrivateKey,
                       flow: Bool) -> RemoteHello {
        RemoteHello(version: RemoteConstants.protocolVersion, deviceID: UUID(), deviceName: "test",
                    ephemeralKey: ephemeral.publicKey.rawRepresentation, staticKey: staticKey.publicKey.rawRepresentation,
                    features: flow ? [RemoteFeature.linkFlow] : [])
    }

    private func run(flow: Bool) async throws -> (p50: Double, p95: Double, mbps: Double, count: Int) {
        let probe = Probe()
        // Mac 一侧监听，手机经代理连过来。
        let listener = try NWListener(using: RemoteLink.parameters(), on: .any)
        let accepted = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { accepted.continuation.yield($0) }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { if case .ready = $0, let port = listener.port { ready.continuation.yield(port.rawValue) } }
        listener.start(queue: DispatchQueue(label: "listener"))
        var readyIterator = ready.stream.makeAsyncIterator()
        let readyPort = await readyIterator.next()
        let macPort = try XCTUnwrap(readyPort)
        let proxy = try RemoteFaultProxy(targetPort: macPort, impairment: RemoteLinkImpairment(
            delay: 0.05, bytesPerSecond: 1_250_000))
        var proxyPort: UInt16?
        for _ in 0..<200 where proxyPort == nil {
            proxyPort = proxy.port
            try await Task.sleep(for: .milliseconds(5))
        }
        let phoneConnection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(proxyPort))!,
                                           using: RemoteLink.parameters())
        let phone = RemoteLink(connection: phoneConnection, label: "phone")
        var acceptedIterator = accepted.stream.makeAsyncIterator()
        async let macConnection = acceptedIterator.next()

        let phoneStatic = Curve25519.KeyAgreement.PrivateKey(), phoneEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let macStatic = Curve25519.KeyAgreement.PrivateKey(), macEphemeral = Curve25519.KeyAgreement.PrivateKey()
        phone.setHandlers(onMessage: { message in
            switch message.kind {
            case .desktopFrame:
                probe.video(message.payload.count)
                let sequence = message.payload.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
                var ack = RemoteByteWriter(capacity: 4)
                ack.u32(sequence)
                phone.sendOnQueue(RemoteMessage(.desktopAck, channel: 5, payload: ack.data))
            case .desktopAudioFrame:
                let sentAt = message.payload.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
                probe.audio(sentAt: sentAt)
            default:
                break
            }
        }, onClose: { _ in })
        let phoneHello = hello(phoneStatic, phoneEphemeral, flow: flow)
        let macHello = hello(macStatic, macEphemeral, flow: flow)
        async let phoneEstablished = phone.establish(role: .initiator, hello: phoneHello,
                                                     staticKey: phoneStatic, ephemeralKey: phoneEphemeral)
        let incoming = await macConnection
        let mac = RemoteLink(connection: try XCTUnwrap(incoming), label: "mac")
        let video = VideoSource(link: mac)
        mac.setHandlers(onMessage: { message in
            guard message.kind == .desktopAck else { return }
            video.acknowledged(message.payload.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
        }, onClose: { _ in })
        _ = try await mac.establish(role: .responder, hello: macHello,
                                    staticKey: macStatic, ephemeralKey: macEphemeral)
        _ = try await phoneEstablished
        mac.queue.sync { XCTAssertEqual(mac.usesLinkFlow, flow) }

        mac.queue.async { video.pump() }
        // 声音：每 20 ms 一包 160 B，负载开头是发送时刻。
        let audio = DispatchSource.makeTimerSource(queue: mac.queue)
        audio.schedule(deadline: .now(), repeating: .milliseconds(20))
        audio.setEventHandler {
            var writer = RemoteByteWriter(capacity: 160)
            writer.u64(DispatchTime.now().uptimeNanoseconds)
            writer.bytes(Data(count: 152))
            mac.sendOnQueue(RemoteMessage(.desktopAudioFrame, channel: 5, payload: writer.data))
        }
        audio.resume()
        // 先跑 2 s 让双方稳下来，再量 4 s。
        try await Task.sleep(for: .seconds(2))
        probe.reset()
        try await Task.sleep(for: .seconds(4))
        let result = probe.snapshot()
        audio.cancel()
        mac.queue.sync { video.stopped = true }
        if flow, let state = mac.queue.sync(execute: { mac.linkFlowState }) {
            print(String(format: "链路排队：在途 %d KB 预算 %d KB 排着 %d KB 送达 %.1f Mbps 最小往返 %.0f ms",
                         state.inPipe / 1024, state.budget / 1024, state.queued / 1024, (state.rate ?? 0) * 8 / 1e6,
                         Double(state.roundTripNanos ?? 0) / 1e6))
        }
        mac.close()
        phone.close()
        proxy.stop()
        listener.cancel()
        return result
    }

    func test_audio_is_not_stuck_behind_video_on_a_narrow_tcp_path() async throws {
        let off = try await run(flow: false)
        let on = try await run(flow: true)
        print(String(format: "声音到达 p50/p95：不排队 %.0f/%.0f ms，排队 %.0f/%.0f ms｜视频吞吐：%.2f → %.2f Mbps",
                     off.p50, off.p95, on.p50, on.p95, off.mbps, on.mbps))
        XCTAssertGreaterThan(on.count, 150, "声音包要都到")
        XCTAssertLessThan(on.p95, 250, "开了排队，声音 p95 应在 250 ms 内")
        XCTAssertLessThan(on.p95, off.p95 / 2, "比不排队至少快一倍")
        XCTAssertGreaterThan(on.mbps, off.mbps * 0.9, "视频吞吐不能掉 10% 以上")
    }
}
