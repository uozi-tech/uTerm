import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 弱网 / 切网下的建连：总时限、局域网限时、切网直接断开、用户打开时自动重试、时间线。
/// 「公网」那条路用一个拨号闭包代替（返回连到本机 `RemoteHostServer` 的传输），不需要中继。
@MainActor
final class RemoteWeakConnectTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    private struct Mac {
        let server: RemoteHostServer
        let port: NWEndpoint.Port
        let phone: RemoteIdentityStore
    }

    /// 一台认得这台「手机」的 Mac。
    private func makeMac() async throws -> Mac {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        server.start()
        addTeardownBlock { @MainActor in server.stop() }
        let deadline = Date().addingTimeInterval(5)
        while server.port == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let port = try XCTUnwrap(server.port.flatMap { NWEndpoint.Port(rawValue: $0) })
        let phone = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "测试 iPhone",
                                    publicKey: try phone.localIdentity().publicKey.rawRepresentation, pairedAt: Date()))
        return Mac(server: server, port: port, phone: phone)
    }

    nonisolated private static func transport(to port: NWEndpoint.Port) -> RemoteDialedPath {
        RemoteDialedPath(transport: RemoteNWTransport(connection: NWConnection(
            to: .hostPort(host: "127.0.0.1", port: port), using: RemoteLink.parameters())),
                         handshakeKeys: nil, path: .localNetwork)
    }

    private func makeClient(_ mac: Mac, endpoint: NWEndpoint? = nil) -> RemoteMacClient {
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: endpoint ?? .hostPort(host: "0.0.0.0", port: 1),
                                     identity: mac.phone)
        addTeardownBlock { @MainActor in client.disconnect() }
        return client
    }

    // MARK: - 自动重试

    func test_interactive_connect_retries_a_network_failure_and_then_connects() async throws {
        let mac = try await makeMac()
        let client = makeClient(mac)
        let attempts = Counter()
        let port = mac.port
        client.updateRoutes(endpoint: nil, internetDialer: { _ in
            if attempts.next() == 1 { throw RemoteRelayError.noReply }
            return Self.transport(to: port)
        })
        await client.connectInteractively()
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertFalse(client.isAutoRetrying)
    }

    func test_interactive_connect_gives_up_after_three_attempts_and_says_where_it_stopped() async throws {
        let mac = try await makeMac()
        let client = makeClient(mac)
        let attempts = Counter()
        client.updateRoutes(endpoint: nil, internetDialer: { context in
            _ = attempts.next()
            context.trace.begin(.signal)
            throw RemoteRelayError.noReply
        })
        let start = Date()
        await client.connectInteractively()
        guard case .failed(let message) = client.state else { return XCTFail("\(client.state)") }
        XCTAssertEqual(message, RemoteRelayError.noReply.localizedDescription)
        XCTAssertEqual(attempts.count, 3, "第一次 + 自动重试两次")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6, "重试间隔 0.5 s + 2 s")
        XCTAssertFalse(client.isAutoRetrying)
        XCTAssertTrue(client.failureContext?.contains(RemoteConnectStage.signal.label) ?? false,
                      client.failureContext ?? "nil")
    }

    func test_permanent_failure_is_not_retried() async throws {
        let mac = try await makeMac()
        let client = makeClient(mac)
        let attempts = Counter()
        client.updateRoutes(endpoint: nil, internetDialer: { _ in
            _ = attempts.next()
            throw RemoteProtocolError.peerIdentityChanged
        })
        await client.connectInteractively()
        XCTAssertEqual(attempts.count, 1)
    }

    // MARK: - 时限

    /// 拨号卡住（不响应取消的等待）：总时限到了就判失败，说明停在哪一步，不让界面一直转圈。
    func test_connect_deadline_fails_a_stuck_dial_and_names_the_step() async throws {
        let mac = try await makeMac()
        let client = makeClient(mac)
        client.connectDeadline = .milliseconds(600)
        client.updateRoutes(endpoint: nil, internetDialer: { context in
            context.trace.begin(.signal)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { continuation.resume() }
            }
            throw RemoteProtocolError.closed
        })
        let start = Date()
        await client.connect()
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        guard case .failed(let message) = client.state else { return XCTFail("\(client.state)") }
        XCTAssertTrue(message.contains(RemoteConnectStage.signal.label), message)
    }

    /// 局域网地址过时（刚关 Wi-Fi，Bonjour 结果还挂着；对面接受但不说话）：限时一到改走公网。
    func test_stale_lan_endpoint_gives_up_after_its_limit_and_falls_back_to_the_internet() async throws {
        let mac = try await makeMac()
        let stalled = try RemoteFaultProxy(targetPort: mac.port.rawValue)
        defer { stalled.stop() }
        stalled.setMode(.stalled)
        let deadline = Date().addingTimeInterval(5)
        while stalled.port == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let lan = NWEndpoint.hostPort(host: "127.0.0.1", port: try XCTUnwrap(stalled.port.flatMap(NWEndpoint.Port.init(rawValue:))))
        let client = makeClient(mac, endpoint: lan)
        client.localNetworkLimit = .milliseconds(500)
        let port = mac.port
        client.updateRoutes(endpoint: lan, internetDialer: { _ in Self.transport(to: port) })
        let start = Date()
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "局域网不该等满握手的 10 秒")
    }

    // MARK: - 切网

    func test_link_whose_interface_vanished_is_closed_right_away() async throws {
        let mac = try await makeMac()
        let client = makeClient(mac, endpoint: .hostPort(host: "127.0.0.1", port: mac.port))
        await client.connect()
        XCTAssertEqual(client.state, .connected)

        // 回环还在：只探一下，不断。
        client.networkChanged(RemoteNetworkSnapshot(isSatisfied: true, interfaces: ["lo0", "en0"],
                                                    hasLocalNetwork: true, label: "Wi-Fi"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(client.state, .connected)

        // 连接走的网卡没了：立刻断开，不等 5 秒探测超时。
        client.networkChanged(RemoteNetworkSnapshot(isSatisfied: true, interfaces: ["pdp_ip0"],
                                                    hasLocalNetwork: false, label: "蜂窝网络"))
        let deadline = Date().addingTimeInterval(1)
        while client.state == .connected, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(client.state, .connected)
    }

    // MARK: - 时间线

    func test_a_connect_leaves_a_timeline_with_its_steps() async throws {
        let mac = try await makeMac()
        let client = makeClient(mac, endpoint: .hostPort(host: "127.0.0.1", port: mac.port))
        let before = RemoteConnectTraceLog.standard.load().first?.id
        await client.connect()
        let record = try XCTUnwrap(RemoteConnectTraceLog.standard.load().first)
        XCTAssertNotEqual(record.id, before)
        XCTAssertTrue(record.ok)
        XCTAssertEqual(record.kind, .connect)
        XCTAssertEqual(record.steps.map(\.stage), [.localNetwork, .pairing])
        XCTAssertTrue(record.steps.allSatisfy { $0.ok == true && $0.durationMillis != nil })
        XCTAssertNotNil(record.network)
    }
}

/// 时间线本身与时限工具，不连任何东西。
final class RemoteConnectTraceTests: XCTestCase {
    private func log() throws -> RemoteConnectTraceLog {
        let suite = "RemoteConnectTraceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return RemoteConnectTraceLog(defaults: defaults)
    }

    func test_steps_are_recorded_in_order_with_results() throws {
        let store = try log()
        let trace = RemoteConnectTrace(kind: .connect, macName: "Mac")
        trace.setNetwork("蜂窝网络 · 无 IPv6")
        let first = trace.begin(.relayControl)
        trace.end(first, ok: true, detail: "蜂窝网络")
        let second = trace.begin(.signal)
        trace.end(second, ok: false, detail: "Mac 没有回应")
        trace.begin(.relayDial)
        trace.event("网络变化")
        let record = try XCTUnwrap(trace.finish(ok: false, outcome: "失败", log: store))
        XCTAssertEqual(record.steps.map(\.stage), [.relayControl, .signal, .relayDial])
        XCTAssertEqual(record.steps.map(\.ok), [true, false, nil])
        XCTAssertNil(record.steps[2].durationMillis, "没结束的一步留空")
        XCTAssertEqual(record.network, "蜂窝网络 · 无 IPv6")
        XCTAssertEqual(record.events.count, 1)
        XCTAssertEqual(store.load(), [record])
        XCTAssertNil(trace.finish(ok: true, outcome: "又一次", log: store), "只收工一次")
        XCTAssertTrue(record.exportText.contains(RemoteConnectStage.signal.label))
    }

    func test_log_keeps_the_newest_twenty() throws {
        let store = try log()
        for index in 0..<25 {
            RemoteConnectTrace(kind: .connect, macName: "Mac \(index)").finish(ok: true, outcome: "", log: store)
        }
        let records = store.load()
        XCTAssertEqual(records.count, RemoteConnectTraceLog.limit)
        XCTAssertEqual(records.first?.macName, "Mac 24")
    }

    func test_silent_trace_is_not_stored() throws {
        let store = try log()
        RemoteConnectTrace.silent().finish(ok: true, outcome: "", log: store)
        XCTAssertTrue(store.load().isEmpty)
    }

    func test_deadline_returns_the_value_in_time() async throws {
        let value = try await RemoteDeadline.run(.seconds(2), timeoutError: RemoteProtocolError.timeout) { 42 }
        XCTAssertEqual(value, 42)
    }

    /// 操作不响应取消：时限照样从调用算起，到点就返回；它之后交出的结果交给 `discard` 收尾。
    func test_deadline_does_not_wait_for_an_operation_that_ignores_cancellation() async throws {
        let discarded = expectation(description: "迟到的结果被收尾")
        let start = Date()
        do {
            _ = try await RemoteDeadline.run(.milliseconds(200), timeoutError: RemoteProtocolError.timeout,
                                             discard: { (value: Int) in
                XCTAssertEqual(value, 7)
                discarded.fulfill()
            }) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.resume(returning: 7) }
                }
            }
            XCTFail("应该超时")
        } catch {
            guard case RemoteProtocolError.timeout = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
        await fulfillment(of: [discarded], timeout: 3)
    }
}
