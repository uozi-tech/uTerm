import XCTest
@testable import uTerm

/// 数据报路径上的可靠字节流：真实的 KCP、加密和发送节奏，只有网络是模拟的。
final class RemoteP2PTransportTests: XCTestCase {

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var finished = false
        private var error: Error?
        private var arrivals: [(UInt64, Int)] = []
        func add(_ data: Data) {
            lock.lock()
            bytes.append(data)
            arrivals.append((DispatchTime.now().uptimeNanoseconds, bytes.count))
            lock.unlock()
        }
        func finish(_ failure: Error?) { lock.lock(); finished = true; error = failure; lock.unlock() }
        var received: Data { lock.lock(); defer { lock.unlock() }; return bytes }
        var count: Int { lock.lock(); defer { lock.unlock() }; return bytes.count }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }

    private struct Rig {
        let a: RemoteP2PTransport
        let b: RemoteP2PTransport
        let pathA: RemoteMemoryDatagramPath
        let pathB: RemoteMemoryDatagramPath
        let inboxA: Inbox
        let inboxB: Inbox
        let queue: DispatchQueue
    }

    private nonisolated static func pump(_ transport: RemoteP2PTransport, into inbox: Inbox) {
        transport.receive(maximumLength: 512 * 1024) { data, isComplete, error in
            if let data { inbox.add(data) }
            if isComplete || error != nil {
                inbox.finish(error)
            } else {
                pump(transport, into: inbox)
            }
        }
    }

    private func read(_ transport: RemoteP2PTransport, into inbox: Inbox) {
        Self.pump(transport, into: inbox)
    }

    private func makeRig(impairment: RemoteLinkImpairment = .clean, reverse: RemoteLinkImpairment? = nil) -> Rig {
        let (pathA, pathB) = RemoteMemoryDatagramPath.pair(impairment: impairment, reverse: reverse)
        let keys = makeDatagramKeys()
        let a = RemoteP2PTransport(path: pathA, keys: keys.first)
        let b = RemoteP2PTransport(path: pathB, keys: keys.second)
        let queue = DispatchQueue(label: "test.p2p")
        a.start(queue: queue) { _ in }
        b.start(queue: queue) { _ in }
        let inboxA = Inbox(), inboxB = Inbox()
        read(a, into: inboxA)
        read(b, into: inboxB)
        return Rig(a: a, b: b, pathA: pathA, pathB: pathB, inboxA: inboxA, inboxB: inboxB, queue: queue)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func pattern(_ bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 24) })
    }

    func test_bytes_arrive_intact_both_ways() async throws {
        let rig = makeRig()
        defer { rig.a.cancel(); rig.b.cancel() }
        let forward = pattern(300_000), backward = pattern(50_000)
        rig.a.send(forward) { _ in }
        rig.b.send(backward) { _ in }
        let done = await waitUntil(10) { rig.inboxB.count >= forward.count && rig.inboxA.count >= backward.count }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.inboxB.received, forward)
        XCTAssertEqual(rig.inboxA.received, backward)
    }

    func test_heavy_loss_and_reordering_do_not_corrupt_the_stream() async throws {
        let bad = RemoteLinkImpairment(delay: 0.02, jitter: 0.02, lossRate: 0.10, reorderRate: 0.05)
        let rig = makeRig(impairment: bad)
        defer { rig.a.cancel(); rig.b.cancel() }
        let data = pattern(200_000)
        rig.a.send(data) { _ in }
        let done = await waitUntil(30) { rig.inboxB.count >= data.count }
        XCTAssertTrue(done, "只收到 \(rig.inboxB.count)")
        XCTAssertEqual(rig.inboxB.received, data)
    }

    /// `canSendMore` 和终端快照兜底都靠这个：完成回调要等对端确认，不能一进缓冲就回。
    func test_send_completes_only_after_the_peer_acknowledged() async throws {
        let slow = RemoteLinkImpairment(delay: 0.1)
        let rig = makeRig(impairment: slow)
        defer { rig.a.cancel(); rig.b.cancel() }
        final class Flag: @unchecked Sendable { var at: Date?; }
        let flag = Flag()
        let started = Date()
        rig.a.send(Data(repeating: 1, count: 100)) { _ in flag.at = Date() }
        let done = await waitUntil(5) { rig.queue.sync { flag.at != nil } }
        XCTAssertTrue(done)
        let elapsed = rig.queue.sync { flag.at!.timeIntervalSince(started) }
        XCTAssertGreaterThan(elapsed, 0.19, "单程 100 ms，确认要一个往返")
    }

    /// 没东西在途时不能有定时器空转：这是耗电的关键。
    func test_idle_link_goes_silent() async throws {
        let rig = makeRig()
        defer { rig.a.cancel(); rig.b.cancel() }
        rig.a.send(Data(repeating: 1, count: 100)) { _ in }
        let done = await waitUntil(5) { rig.inboxB.count == 100 }
        XCTAssertTrue(done)
        try await Task.sleep(for: .milliseconds(300))
        let before = rig.pathA.counters.sent + rig.pathB.counters.sent
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(rig.pathA.counters.sent + rig.pathB.counters.sent, before, "空闲时不该再发包")
    }

    func test_close_reaches_the_peer() async throws {
        let rig = makeRig()
        defer { rig.b.cancel() }
        rig.a.cancel()
        let finished = await waitUntil(2) { rig.inboxB.isFinished }
        XCTAssertTrue(finished)
    }

    /// 没密钥的人往这个端口发什么都不能影响连接。
    func test_forged_datagrams_are_ignored() async throws {
        let (pathA, pathB) = RemoteMemoryDatagramPath.pair()
        let keys = makeDatagramKeys()
        let a = RemoteP2PTransport(path: pathA, keys: keys.first)
        let b = RemoteP2PTransport(path: pathB, keys: keys.second)
        defer { a.cancel(); b.cancel() }
        let queue = DispatchQueue(label: "test.p2p.forged")
        a.start(queue: queue) { _ in }
        b.start(queue: queue) { _ in }
        let inbox = Inbox()
        read(b, into: inbox)
        // 随机内容、伪造的关闭、用别的密钥加密的 KCP 包。
        var attacker = RemoteDatagramCipher(control: makeDatagramKeys().first)
        pathA.send(Data(repeating: 0xAB, count: 200))
        pathA.send(Data([RemoteDatagramKind.close.rawValue]) + Data(repeating: 0, count: 30))
        if let forged = attacker.seal(.close, Data()) { pathA.send(forged) }
        if let forged = attacker.seal(.reliable, Data(repeating: 0, count: 100)) { pathA.send(forged) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(inbox.isFinished)
        let data = pattern(10_000)
        a.send(data) { _ in }
        let done = await waitUntil(5) { inbox.count >= data.count }
        XCTAssertTrue(done)
        XCTAssertEqual(inbox.received, data)
    }

    // MARK: - 闸门：丢包的链路上还能跑满

    /// TCP 在往返 100 ms、丢包 1% 时只有约 1.4 Mbps（`RemoteWANImpairmentTests` 的读数）。这是换掉它的理由。
    func test_gate_throughput_at_100ms_and_1_percent_loss() async throws {
        let wan = RemoteLinkImpairment(delay: 0.05, jitter: 0.005, lossRate: 0.01, bytesPerSecond: 1_250_000)
        let rig = makeRig(impairment: wan, reverse: RemoteLinkImpairment(delay: 0.05, jitter: 0.005, lossRate: 0.01))
        defer { rig.a.cancel(); rig.b.cancel() }
        let chunk = Data(repeating: 7, count: 64 * 1024)
        // 像 RemoteLink 那样按完成回调限流，上限 512 KB。
        final class Writer: @unchecked Sendable {
            var inflight = 0
            var stopped = false
        }
        let writer = Writer()
        @Sendable func fill(_ transport: RemoteP2PTransport, _ queue: DispatchQueue) {
            while !writer.stopped, writer.inflight < 512 * 1024 {
                writer.inflight += chunk.count
                transport.send(chunk) { _ in
                    writer.inflight -= chunk.count
                    fill(transport, queue)
                }
            }
        }
        rig.queue.async { fill(rig.a, rig.queue) }
        try await Task.sleep(for: .seconds(3))
        let start = rig.inboxB.count
        try await Task.sleep(for: .seconds(5))
        let mbps = Double(rig.inboxB.count - start) * 8 / 5 / 1e6
        rig.queue.sync { writer.stopped = true }
        let state = rig.a.linkState
        print(String(format: "[直连探针·可靠] %.1f Mbps，往返 %.0f ms，丢包 %.1f%%，节奏 %.1f Mbps，瓶颈丢 %d",
                     mbps, Double(state.roundTripNanos ?? 0) / 1e6, state.lossRate * 100, state.pacingRate * 8 / 1e6,
                     rig.pathA.counters.droppedByBuffer))
        XCTAssertGreaterThan(mbps, 4, "同样的链路 TCP 约 1.4 Mbps")
        XCTAssertEqual(state.lossRate, 0.01, accuracy: 0.03)
    }

    /// 同时灌大流量时，一次按键也不能排在后面。
    func test_gate_echo_latency_under_load() async throws {
        let wan = RemoteLinkImpairment(delay: 0.05, jitter: 0.005, lossRate: 0.01)
        let rig = makeRig(impairment: wan)
        defer { rig.a.cancel(); rig.b.cancel() }
        var millis: [Double] = []
        for index in 0..<30 {
            try await Task.sleep(for: .milliseconds(40))
            let marker = Data("key\(index);".utf8)
            let target = rig.inboxB.count + marker.count
            let started = Date()
            rig.a.send(marker) { _ in }
            let arrived = await waitUntil(3) { rig.inboxB.count >= target }
            XCTAssertTrue(arrived)
            millis.append(Date().timeIntervalSince(started) * 1000)
        }
        millis.sort()
        print(String(format: "[直连探针·按键] 单程 p50 %.0f / p95 %.0f ms", millis[15], millis[28]))
        XCTAssertLessThan(millis[15], 80, "单程约 50 ms")
        XCTAssertLessThan(millis[28], 250, "1%% 丢包时偶尔要等一次重传")
    }
}
