import XCTest
@preconcurrency import Network
@testable import uTerm

/// 差网络夹具自证：它说丢 10% 就真丢 10%，说限速就真限速。否则后面拿它做闸门没有意义。
final class RemoteFaultProxyTests: XCTestCase {

    // MARK: - 计算

    func test_schedule_is_deterministic_for_a_seed() {
        let impairment = RemoteLinkImpairment(delay: 0.01, jitter: 0.01, lossRate: 0.2, reorderRate: 0.1)
        func run(_ seed: UInt64) -> [TimeInterval?] {
            var schedule = RemoteImpairmentSchedule(impairment: impairment, isOrdered: false, seed: seed)
            return (0..<200).map { schedule.delivery(bytes: 1000, now: Double($0) * 0.001) }
        }
        XCTAssertEqual(run(7), run(7))
        XCTAssertNotEqual(run(7), run(8))
    }

    func test_datagram_loss_rate_matches_configuration() {
        var schedule = RemoteImpairmentSchedule(impairment: RemoteLinkImpairment(lossRate: 0.1), isOrdered: false, seed: 3)
        let lost = (0..<10_000).filter { _ in schedule.delivery(bytes: 100, now: 0) == nil }.count
        XCTAssertEqual(Double(lost) / 10_000, 0.1, accuracy: 0.02)
    }

    func test_stream_never_drops_or_reorders_and_loss_costs_a_retransmit() {
        let impairment = RemoteLinkImpairment(delay: 0.05, jitter: 0.02, lossRate: 0.1, retransmitPenalty: 0.2)
        var schedule = RemoteImpairmentSchedule(impairment: impairment, isOrdered: true, seed: 5)
        var previous = 0.0
        var worst = 0.0
        for index in 0..<2000 {
            let now = Double(index) * 0.01
            let delivery = try! XCTUnwrap(schedule.delivery(bytes: 100, now: now))
            XCTAssertGreaterThanOrEqual(delivery, previous, "TCP 不能乱序")
            previous = delivery
            worst = max(worst, delivery - now)
        }
        XCTAssertGreaterThan(worst, 0.2, "丢包要表现成额外等待")
    }

    func test_datagrams_can_overtake_when_reordering_is_on() {
        var schedule = RemoteImpairmentSchedule(impairment: RemoteLinkImpairment(delay: 0.02, reorderRate: 0.2),
                                                isOrdered: false, seed: 11)
        let deliveries = (0..<500).compactMap { schedule.delivery(bytes: 100, now: Double($0) * 0.001) }
        XCTAssertNotEqual(deliveries, deliveries.sorted())
    }

    func test_rate_limit_spaces_packets() {
        var schedule = RemoteImpairmentSchedule(impairment: RemoteLinkImpairment(bytesPerSecond: 1_000_000),
                                                isOrdered: true, seed: 1)
        var last: TimeInterval = 0
        for _ in 0..<1000 { last = schedule.delivery(bytes: 1000, now: 0)! }
        XCTAssertEqual(last, 1.0, accuracy: 0.001, "1 MB 按 1 MB/s 要 1 秒")
    }

    // MARK: - 真实收发

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var datagrams = 0
        func add(_ data: Data) { lock.lock(); bytes.append(data); datagrams += 1; lock.unlock() }
        var received: Data { lock.lock(); defer { lock.unlock() }; return bytes }
        var count: Int { lock.lock(); defer { lock.unlock() }; return datagrams }
    }

    /// 起一个 TCP 接收端，收到的都记下来。
    private func tcpSink(_ counter: Counter) async throws -> (NWListener, UInt16) {
        let queue = DispatchQueue(label: "test.tcp-sink")
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            @Sendable func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                    if let data { counter.add(data) }
                    if !isComplete, error == nil { read() }
                }
            }
            read()
        }
        return (listener, try await start(listener, queue: queue))
    }

    private func udpSink(_ counter: Counter) async throws -> (NWListener, UInt16) {
        let queue = DispatchQueue(label: "test.udp-sink")
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            @Sendable func read() {
                connection.receiveMessage { data, _, _, error in
                    if let data { counter.add(data) }
                    if error == nil { read() }
                }
            }
            read()
        }
        return (listener, try await start(listener, queue: queue))
    }

    private func start(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: queue)
        var iterator = ready.stream.makeAsyncIterator()
        let port = await iterator.next()
        return try XCTUnwrap(port)
    }

    func test_tcp_proxy_keeps_bytes_intact_under_delay_loss_and_rate_limit() async throws {
        let counter = Counter()
        let (sink, sinkPort) = try await tcpSink(counter)
        defer { sink.cancel() }
        let impairment = RemoteLinkImpairment(delay: 0.03, jitter: 0.01, lossRate: 0.01, bytesPerSecond: 2_000_000,
                                              retransmitPenalty: 0.05)
        let proxy = try RemoteFaultProxy(targetPort: sinkPort, impairment: impairment)
        defer { proxy.stop() }
        let ok = await waitUntil { proxy.port != nil }
        XCTAssertTrue(ok)

        let payload = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let queue = DispatchQueue(label: "test.tcp-client")
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(proxy.port))!, using: .tcp)
        client.start(queue: queue)
        defer { client.cancel() }
        let started = Date()
        client.send(content: payload, completion: .contentProcessed { _ in })

        let delivered = await waitUntil(15) { counter.received.count >= payload.count }
        XCTAssertTrue(delivered, "只收到 \(counter.received.count) 字节")
        XCTAssertEqual(counter.received, payload, "字节不能丢、不能乱")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.45, "1 MB 按 2 MB/s 不该快过 0.5 秒")
    }

    func test_udp_proxy_drops_about_the_configured_share_and_can_block_everything() async throws {
        let counter = Counter()
        let (sink, sinkPort) = try await udpSink(counter)
        defer { sink.cancel() }
        let proxy = try RemoteUDPFaultProxy(targetPort: sinkPort, impairment: RemoteLinkImpairment(lossRate: 0.2))
        defer { proxy.stop() }
        let ok = await waitUntil { proxy.port != nil }
        XCTAssertTrue(ok)

        let queue = DispatchQueue(label: "test.udp-client")
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(proxy.port))!, using: .udp)
        client.start(queue: queue)
        defer { client.cancel() }
        for index in 0..<500 {
            client.send(content: Data("\(index)".utf8), completion: .contentProcessed { _ in })
            if index % 20 == 0 { try await Task.sleep(for: .milliseconds(2)) }
        }
        let settled = await waitUntil { counter.count + proxy.dropped >= 500 }
        XCTAssertTrue(settled, "收到 \(counter.count)，丢弃 \(proxy.dropped)")
        XCTAssertEqual(Double(proxy.dropped) / 500, 0.2, accuracy: 0.07)

        proxy.setMode(.blocked)
        let before = counter.count
        for _ in 0..<20 { client.send(content: Data("x".utf8), completion: .contentProcessed { _ in }) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(counter.count, before, "封死后一个都不能过")
    }
}
