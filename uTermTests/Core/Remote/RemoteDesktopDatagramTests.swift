import CoreVideo
import CryptoKit
import XCTest
@testable import uTerm

/// 公网直连时桌面走数据报的闸门：真实的编码器和解码器，真实的 `RemoteHostServer` / `RemoteMacClient`，只有网络是模拟的。
@MainActor
final class RemoteDesktopDatagramTests: XCTestCase {

    /// 和 `RemoteWANImpairmentTests` 同样的链路：单程 50 ms、丢 1%、上行 10 Mbps。那边走 TCP 只能收敛到约 1.4 Mbps。
    private let wan = RemoteLinkImpairment(delay: 0.05, jitter: 0.005, lossRate: 0.01, bytesPerSecond: 1_250_000)
    private let wanReverse = RemoteLinkImpairment(delay: 0.05, jitter: 0.005, lossRate: 0.01)

    private struct Rig {
        let server: RemoteHostServer
        let client: RemoteMacClient
        let macPath: RemoteMemoryDatagramPath
        let phonePath: RemoteMemoryDatagramPath
        let macTransport: RemoteP2PTransport
    }

    private final class Shown: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Date] = []
        func add() { lock.lock(); times.append(Date()); lock.unlock() }
        var all: [Date] { lock.lock(); defer { lock.unlock() }; return times }
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return true
    }

    private func makeRig(desktop: RemoteDesktopEnvironment) throws -> Rig {
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let phoneID = RemoteLocalDevice.id()
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      desktopEnvironment: desktop)
        server.internetAccessPolicy = { $0 == phoneID }
        try server.trust(RemotePeer(id: phoneID, name: "测试 iPhone",
                                    publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                    pairedAt: Date()))
        let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
        let macHandshake = RemoteHandshakeKeys(send: b, receive: a)
        let phoneHandshake = RemoteHandshakeKeys(send: a, receive: b)
        let (macPath, phonePath) = RemoteMemoryDatagramPath.pair(impairment: wan, reverse: wanReverse)
        let datagramKeys = makeDatagramKeys()
        let macTransport = RemoteP2PTransport(path: macPath, keys: datagramKeys.first)
        server.accept(transport: macTransport,
                      origin: .internet(peerID: phoneID, keys: macHandshake, path: .direct))
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: phoneIdentity)
        client.updateRoutes(endpoint: nil, internetDialer: {
            RemoteDialedPath(transport: RemoteP2PTransport(path: phonePath, keys: datagramKeys.second),
                             handshakeKeys: phoneHandshake, path: .direct)
        })
        return Rig(server: server, client: client, macPath: macPath, phonePath: phonePath, macTransport: macTransport)
    }

    private func startDesktop(_ rig: Rig, shown: Shown) async throws -> RemoteDesktopSession {
        await rig.client.connect()
        XCTAssertEqual(rig.client.state, .connected)
        let session = RemoteDesktopSession(client: rig.client, maxWidth: 1206, maxHeight: 2622, codec: .hevc)
        session.receiver.setHandlers(onImage: { _, _ in shown.add() }, onCursor: { _ in })
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        let first = await waitUntil(15) { !shown.all.isEmpty }
        XCTAssertTrue(first, "首帧应该能到")
        return session
    }

    private func linkState(_ rig: Rig) -> RemoteLinkState {
        rig.macTransport.linkState
    }

    private func longestGap(_ times: [Date]) -> TimeInterval {
        zip(times.dropFirst(), times).map { $0.0.timeIntervalSince($0.1) }.max() ?? 0
    }

    private func report(_ tag: String, _ stats: RemoteDesktopStreamerStats.Snapshot, shown: Int, gap: TimeInterval,
                        seconds: Double, startBytes: Int = 0) {
        let megabits = Double(stats.bytes - startBytes) * 8 / seconds / 1e6
        print(String(format: "[直连探针·%@] 显示 %d 帧，最长间隔 %.2f s，发送 %.1f Mbps，关键帧 %d，放弃 %d，编码器丢 %d，在途满丢 %d，纠错组 %@，码率 %@",
                     tag, shown, gap, megabits, stats.keyframes, stats.lostFrames, stats.encoderDrops, stats.congestionDrops,
                     String(describing: stats.fecGroupSizes),
                     stats.bitrateHistory.suffix(12).map { String(format: "%.1f", Double($0) / 1e6) }.joined(separator: "→")))
    }

    /// 换掉 TCP 的理由：同样的链路，码率不再被 1% 的随机丢包压到 1.4 Mbps。
    func test_gate_desktop_uses_the_link_despite_random_loss() async throws {
        let mac = FakeDesktopMac()
        mac.detail = true
        let rig = try makeRig(desktop: mac.environment())
        defer {
            rig.client.disconnect()
            rig.server.stop()
        }
        let shown = Shown()
        let session = try await startDesktop(rig, shown: shown)
        defer { session.stop() }
        let source = try XCTUnwrap(mac.latestSource)
        source.prepareCycle(count: 12)
        let statsSource = try XCTUnwrap(rig.server.desktopStats)
        // 准备夹具的这段时间屏幕没动，不算卡顿。
        let started = Date()
        let startBytes = statsSource.snapshot().bytes
        source.run(fps: 30)
        try await Task.sleep(for: .seconds(12))
        source.pause()

        let stats = statsSource.snapshot()
        let times = shown.all.filter { $0 > started }
        report("桌面", stats, shown: times.count, gap: longestGap(times), seconds: 12, startBytes: startBytes)
        print(String(format: "[直连探针·桌面] 链路：往返 %.0f ms，丢包 %.1f%%，节奏 %.1f Mbps；瓶颈缓冲丢 %d",
                     Double(linkState(rig).roundTripNanos ?? 0) / 1e6, linkState(rig).lossRate * 100,
                     linkState(rig).pacingRate * 8 / 1e6, rig.macPath.counters.droppedByBuffer))
        XCTAssertGreaterThan(times.count, 150, "细节拉满的画面。同样的链路 TCP 上只显示 89 帧")
        XCTAssertLessThan(longestGap(times), 1.0, "不能卡顿")
        XCTAssertGreaterThan(stats.bitrate, 3_000_000, "1% 随机丢包不能把码率压下去（TCP 上只有约 1.4 Mbps）")
        XCTAssertLessThanOrEqual(stats.keyframes, 3, "丢包恢复不能靠关键帧")
        XCTAssertEqual(rig.client.state, .connected)
    }

    /// 突然一阵重度丢包：过去之后靠 LTR 恢复帧接上，不用等关键帧，也不断连。
    func test_loss_burst_recovers_without_keyframes() async throws {
        let mac = FakeDesktopMac()
        mac.detail = true
        let rig = try makeRig(desktop: mac.environment())
        defer {
            rig.client.disconnect()
            rig.server.stop()
        }
        let shown = Shown()
        let session = try await startDesktop(rig, shown: shown)
        defer { session.stop() }
        let source = try XCTUnwrap(mac.latestSource)
        source.prepareCycle(count: 12)
        let statsSource = try XCTUnwrap(rig.server.desktopStats)
        source.run(fps: 30)
        try await Task.sleep(for: .seconds(4))

        let before = statsSource.snapshot()
        var burst = wan
        burst.lossRate = 0.5
        var burstReverse = wanReverse
        burstReverse.lossRate = 0.5
        rig.macPath.setImpairment(burst)
        rig.phonePath.setImpairment(burstReverse)
        try await Task.sleep(for: .milliseconds(1500))
        rig.macPath.setImpairment(wan)
        rig.phonePath.setImpairment(wanReverse)
        let healed = Date()
        try await Task.sleep(for: .seconds(4))
        source.pause()

        let stats = statsSource.snapshot()
        let after = shown.all.filter { $0 > healed }
        let firstAfter = after.first?.timeIntervalSince(healed) ?? .infinity
        report("重度丢包", stats, shown: after.count, gap: firstAfter, seconds: 9.5)
        print(String(format: "[直连探针·重度丢包] 恢复后首帧 %.2f s；手机放弃 %d，跳过 %d", firstAfter,
                     session.receiver.stats.snapshot().lostFrames, session.receiver.stats.snapshot().skippedFrames))
        XCTAssertEqual(rig.client.state, .connected, "这一阵不能把连接打断")
        XCTAssertLessThan(firstAfter, 1.5, "网络好了要很快有画面")
        XCTAssertGreaterThan(after.count, 15, "恢复后继续出画面。码率被这一阵压低了，细节拉满时帧率上不去")
        XCTAssertLessThanOrEqual(stats.keyframes - before.keyframes, 1, "恢复靠 LTR，不靠关键帧")
    }

    /// 视频占满上行的时候，按键不能跟在后面排队。
    func test_gate_keystrokes_are_not_held_back_by_video() async throws {
        let (a, b) = RemoteMemoryDatagramPath.pair(impairment: wan, reverse: wanReverse)
        let keys = makeDatagramKeys()
        let mac = RemoteP2PTransport(path: a, keys: keys.first)
        let phone = RemoteP2PTransport(path: b, keys: keys.second)
        defer { mac.cancel(); phone.cancel() }
        let queue = DispatchQueue(label: "test.keystrokes")
        mac.start(queue: queue) { _ in }
        phone.start(queue: queue) { _ in }
        let session = SymmetricKey(size: .bits256)
        mac.installMediaKeys(.media(sessionSend: session, sessionReceive: session))
        phone.installMediaKeys(.media(sessionSend: session, sessionReceive: session))

        final class Inbox: @unchecked Sendable {
            let lock = NSLock()
            var bytes = 0
            var frames = 0
        }
        let inbox = Inbox()
        @Sendable func pump() {
            mac.receive(maximumLength: 65536) { data, done, error in
                inbox.lock.lock()
                inbox.bytes += data?.count ?? 0
                inbox.lock.unlock()
                if !done, error == nil { pump() }
            }
        }
        pump()
        phone.startVideoReceiving(onFrame: { _, _ in
            inbox.lock.lock()
            inbox.frames += 1
            inbox.lock.unlock()
        }, onLost: { _, _ in })
        mac.startVideoSending(channel: 1, callbackQueue: queue, onLinkState: { _ in }, onExpired: { _ in })

        // 30 fps、每帧 40 KB ≈ 9.6 Mbps，几乎占满 10 Mbps。
        let sender = Task.detached {
            var sequence: UInt32 = 0
            while !Task.isCancelled {
                sequence += 1
                mac.sendVideo(Data(repeating: UInt8(truncatingIfNeeded: sequence), count: 40_000), sequence: sequence)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        defer { sender.cancel() }
        try await Task.sleep(for: .seconds(3))

        var millis: [Double] = []
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(60))
            let target = inbox.lock.withLock { inbox.bytes } + 8
            let started = Date()
            phone.send(Data(repeating: 1, count: 8)) { _ in }
            let arrived = await waitUntil(3) { inbox.lock.withLock { inbox.bytes } >= target }
            XCTAssertTrue(arrived)
            millis.append(Date().timeIntervalSince(started) * 1000)
        }
        millis.sort()
        let frames = inbox.lock.withLock { inbox.frames }
        let state = mac.linkState
        print(String(format: "[直连探针·按键(有视频)] 单程 p50 %.0f / p95 %.0f ms；视频帧 %d；往返 %.0f ms，节奏 %.1f Mbps", millis[15], millis[28],
                     frames, Double(state.roundTripNanos ?? 0) / 1e6, state.pacingRate * 8 / 1e6))
        XCTAssertGreaterThan(frames, 60, "视频也在跑")
        XCTAssertLessThan(millis[15], 100, "单程约 50 ms，手机到 Mac 这个方向不限速")
    }
}
