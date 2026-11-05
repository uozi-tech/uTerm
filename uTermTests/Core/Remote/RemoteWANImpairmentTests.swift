import CoreVideo
import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// G1 闸门：模拟公网（往返 100 ms、1% 丢包）下，走公网路径规则的真实连接还能用。
/// 手机 → `RemoteFaultProxy`（差网络）→ 测试监听 → `RemoteHostServer.accept(origin: .internet)`。
@MainActor
final class RemoteWANImpairmentTests: XCTestCase {

    /// 公网常见水平：单程 50 ms，抖动 10 ms，丢 1%（TCP 上表现为约 200 ms 的重传等待）。
    private let wan = RemoteLinkImpairment(delay: 0.05, jitter: 0.01, lossRate: 0.01, retransmitPenalty: 0.2)

    private struct Rig {
        let server: RemoteHostServer
        let client: RemoteMacClient
        let proxy: RemoteFaultProxy
        let listener: NWListener
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return true
    }

    private func makeRig(registry: TerminalSessionRegistry = TerminalSessionRegistry(),
                         desktop: RemoteDesktopEnvironment = .disabled,
                         impairment: RemoteLinkImpairment, path: RemoteLinkPath = .relay) async throws -> Rig {
        let phoneIdentity = RemoteIdentityStore(storage: RemoteMemoryStorage())
        let phoneID = RemoteLocalDevice.id()
        let server = RemoteHostServer(registry: registry, identity: RemoteIdentityStore(storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      desktopEnvironment: desktop)
        server.internetAccessPolicy = { $0 == phoneID }
        try server.trust(RemotePeer(id: phoneID, name: "测试 iPhone",
                                    publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                    pairedAt: Date()))
        let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
        let macKeys = RemoteHandshakeKeys(send: b, receive: a)
        let phoneKeys = RemoteHandshakeKeys(send: a, receive: b)

        let listener = try NWListener(using: RemoteLink.parameters(), on: .any)
        let accepted = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { accepted.continuation.yield(port) }
        }
        listener.newConnectionHandler = { [weak server] connection in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    server?.accept(transport: RemoteNWTransport(connection: connection),
                                   origin: .internet(peerID: phoneID, keys: macKeys, path: path))
                }
            }
        }
        listener.start(queue: DispatchQueue(label: "test.wan.listener"))
        var ports = accepted.stream.makeAsyncIterator()
        let readyPort = await ports.next()
        let port = try XCTUnwrap(readyPort)

        let proxy = try RemoteFaultProxy(targetPort: port, impairment: impairment)
        let ready = await waitUntil { proxy.port != nil }
        XCTAssertTrue(ready)
        let proxyPort = try XCTUnwrap(proxy.port)
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: phoneIdentity)
        client.updateRoutes(endpoint: nil, internetDialer: {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!,
                                          using: RemoteLink.parameters())
            return RemoteDialedPath(transport: RemoteNWTransport(connection: connection), handshakeKeys: phoneKeys, path: path)
        })
        return Rig(server: server, client: client, proxy: proxy, listener: listener)
    }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * quantile))]
    }

    // MARK: - 终端

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func add(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
        func contains(_ needle: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return bytes.range(of: needle) != nil }
    }

    func test_terminal_stays_usable_at_100ms_round_trip_and_1_percent_loss() async throws {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "测试主机",
                                               windowKind: TerminalWindowKind.workspace, title: "zsh",
                                               connectedAt: Date()), session: session)
        let rig = try await makeRig(registry: registry, impairment: wan)
        defer {
            rig.client.disconnect()
            rig.server.stop()
            rig.proxy.stop()
            rig.listener.cancel()
            session.dispose()
        }
        await rig.client.connect()
        XCTAssertEqual(rig.client.state, .connected)
        XCTAssertEqual(rig.client.path, .relay)

        let received = Received()
        let attachment = try await rig.client.attach(sessionID: sessionID, size: try RemoteGridSize(decoding: Data([0, 80, 0, 24])),
                                                     sink: RemoteChannelSink(onOutput: { received.add($0) },
                                                                             onClosed: { _, _ in }))
        var echoMillis: [Double] = []
        for index in 0..<30 {
            try await Task.sleep(for: .milliseconds(30))
            let key = Data("k\(index);".utf8), marker = Data("<\(index)>".utf8)
            let started = Date()
            attachment.link.send(RemoteMessage(.input, channel: attachment.channel, payload: key))
            let wrote = await waitUntil(5) { await backend.writtenData.contains(key) }
            XCTAssertTrue(wrote, "第 \(index) 次按键没到 Mac")
            await backend.emitOutput(marker)
            let echoed = await waitUntil(5) { received.contains(marker) }
            XCTAssertTrue(echoed, "第 \(index) 次回显没到手机")
            echoMillis.append(Date().timeIntervalSince(started) * 1000)
        }
        let p50 = percentile(echoMillis, 0.5), p95 = percentile(echoMillis, 0.95)
        print(String(format: "[公网探针·终端] 按键→回显 p50 %.0f / p95 %.0f ms", p50, p95))
        XCTAssertGreaterThanOrEqual(p50, 90, "差网络没生效：往返应不少于 100 ms 左右")
        XCTAssertLessThan(p95, 900, "1% 丢包时偶尔慢一点可以，但不能一直卡")
        XCTAssertEqual(rig.client.state, .connected)
    }

    /// 心跳 5 秒 ping 一次，1% 丢包和百毫秒延迟不能把活着的连接判死。
    func test_heartbeat_does_not_kill_a_slow_but_alive_link() async throws {
        let rig = try await makeRig(impairment: wan)
        defer {
            rig.client.disconnect()
            rig.server.stop()
            rig.proxy.stop()
            rig.listener.cancel()
        }
        await rig.client.connect()
        XCTAssertEqual(rig.client.state, .connected)
        let measured = await waitUntil(8) { rig.client.roundTripMillis != nil }
        XCTAssertTrue(measured, "连着时应该测到往返时间")
        XCTAssertGreaterThanOrEqual(rig.client.roundTripMillis ?? 0, 90)
        XCTAssertEqual(rig.client.state, .connected)
    }

    // MARK: - 桌面

    private final class Shown: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Date] = []
        func add() { lock.lock(); times.append(Date()); lock.unlock() }
        var all: [Date] { lock.lock(); defer { lock.unlock() }; return times }
    }

    /// 带宽只有约 10 Mbps 时，码控要自己降下来，画面不能长时间卡死，延迟不能越排越长。
    func test_desktop_adapts_to_a_narrow_lossy_link() async throws {
        let mac = FakeDesktopMac()
        mac.detail = true
        var narrow = wan
        narrow.bytesPerSecond = 1_250_000
        let rig = try await makeRig(desktop: mac.environment(), impairment: narrow)
        defer {
            rig.client.disconnect()
            rig.server.stop()
            rig.proxy.stop()
            rig.listener.cancel()
        }
        await rig.client.connect()
        XCTAssertEqual(rig.client.state, .connected)

        let session = RemoteDesktopSession(client: rig.client, maxWidth: 1206, maxHeight: 2622, codec: .hevc)
        defer { session.stop() }
        let shown = Shown()
        session.receiver.setHandlers(onImage: { _, _ in shown.add() }, onCursor: { _ in })
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        let first = await waitUntil(15) { !shown.all.isEmpty }
        XCTAssertTrue(first, "公网起始码率下首帧应该能到")

        let source = try XCTUnwrap(mac.latestSource)
        source.prepareCycle(count: 12)
        let stats = try XCTUnwrap(rig.server.desktopStats)
        XCTAssertLessThanOrEqual(stats.snapshot().bitrate, RemoteRateController.internetInitialBitrate,
                                 "公网路径从低码率起步")
        source.run(fps: 30)
        try await Task.sleep(for: .seconds(12))
        source.pause()

        let snapshot = stats.snapshot()
        let times = shown.all
        let gaps = zip(times.dropFirst(), times).map { $0.0.timeIntervalSince($0.1) }
        let recentRoundTrip = snapshot.roundTripNanos.suffix(30).map { Double($0) / 1e6 }
        let throughput = Double(snapshot.bytes) * 8 / 12 / 1e6
        print(String(format: "[公网探针·桌面] 显示 %d 帧，最长间隔 %.2f s，最后 30 帧往返 p50 %.0f ms，发送约 %.1f Mbps，码率 %@",
                     times.count, gaps.max() ?? 0, percentile(recentRoundTrip, 0.5), throughput,
                     snapshot.bitrateHistory.map { String(format: "%.1f", Double($0) / 1e6) }.joined(separator: "→")))
        XCTAssertGreaterThan(times.count, 60, "12 秒里应该能持续出画面")
        XCTAssertLessThan(gaps.max() ?? 0, 3, "不能长时间卡死")
        XCTAssertLessThan(percentile(recentRoundTrip, 0.5), 1500, "延迟不能越排越长")
        XCTAssertLessThan(throughput, 12, "发送量不能超过链路能力太多")
        XCTAssertEqual(rig.client.state, .connected)
    }
}
