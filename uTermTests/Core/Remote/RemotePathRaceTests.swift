import XCTest
@testable import uTerm

/// 直连与中继同时拨：谁先给出能用的连接用谁、没选中的那路关掉、按网络记的打洞成败决定直连先跑多久。
final class RemotePathRaceTests: XCTestCase {

    /// 能看出有没有被关掉的传输。
    private final class Probe: RemoteTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelledValue = false
        var cancelled: Bool { lock.withLock { cancelledValue } }
        func start(queue: DispatchQueue, onEvent: @escaping @Sendable (RemoteTransportEvent) -> Void) {}
        func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) { completion(nil) }
        func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {}
        func cancel() { lock.withLock { cancelledValue = true } }
    }

    private func p2p() -> RemoteP2PTransport {
        let (path, _) = RemoteMemoryDatagramPath.pair()
        return RemoteP2PTransport(path: path, keys: makeDatagramKeys().first)
    }

    private static func after<Value: Sendable>(_ seconds: Double, _ value: Value) async -> Value {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        return value
    }

    // MARK: - 谁先到

    func test_direct_wins_when_it_connects_first() async {
        let transport = p2p()
        let direct = Task { await Self.after(0.05, (transport: Optional(transport), detail: "直连")) }
        let relay = RemoteRelayRace { await Self.after(1, Probe()) }
        guard case .direct(let picked, _) = await RemotePathPick.first(direct: direct, relay: relay) else {
            return XCTFail("应选直连")
        }
        XCTAssertTrue(picked === transport)
    }

    func test_relay_wins_while_direct_is_still_trying() async {
        let relayTransport = Probe()
        let direct = Task { await Self.after(2, (transport: Optional<RemoteP2PTransport>.none, detail: "没打通")) }
        let relay = RemoteRelayRace { await Self.after(0.05, relayTransport) }
        let start = Date()
        guard case .relay(let picked, _) = await RemotePathPick.first(direct: direct, relay: relay) else {
            return XCTFail("应选中继")
        }
        XCTAssertTrue(picked === relayTransport)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "不等直连结束")
    }

    func test_failed_direct_waits_for_the_relay() async {
        let direct = Task { (transport: Optional<RemoteP2PTransport>.none, detail: "没打通") }
        let relay = RemoteRelayRace { await Self.after(0.2, Probe()) }
        guard case .relay(_, let detail) = await RemotePathPick.first(direct: direct, relay: relay) else {
            return XCTFail("直连失败后应等中继")
        }
        XCTAssertEqual(detail, "没打通")
    }

    func test_both_failing_reports_the_relay_error() async {
        let direct = Task { (transport: Optional<RemoteP2PTransport>.none, detail: "没打通") }
        let relay = RemoteRelayRace { throw RemoteRelayError.macOffline }
        guard case .failed(let error, _) = await RemotePathPick.first(direct: direct, relay: relay) else {
            return XCTFail("两路都不通应失败")
        }
        XCTAssertEqual(error as? RemoteRelayError, .macOffline)
    }

    /// 直连先通了：之后才接通的中继连接要关掉，不然 Mac 那头一直挂着一条等握手的连接。
    func test_abandoned_relay_is_closed_when_it_arrives_late() async throws {
        let late = Probe()
        let relay = RemoteRelayRace { await Self.after(0.2, late) }
        relay.abandon()
        let deadline = Date().addingTimeInterval(3)
        while !late.cancelled, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(late.cancelled)
    }

    // MARK: - 直连先跑多久

    func test_window_shortens_after_repeated_failures_and_recovers_after_a_success() throws {
        let suite = "RemotePathRaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let history = RemoteDirectHistory(defaults: defaults)
        XCTAssertEqual(history.window(on: "蜂窝网络"), RemoteDirectHistory.fullWindow, "没记录时给满")
        for _ in 0..<2 { history.record(false, on: "蜂窝网络") }
        XCTAssertEqual(history.window(on: "蜂窝网络"), RemoteDirectHistory.fullWindow, "两次失败还不缩")
        history.record(false, on: "蜂窝网络")
        XCTAssertEqual(history.window(on: "蜂窝网络"), RemoteDirectHistory.shortWindow)
        XCTAssertEqual(history.window(on: "Wi-Fi"), RemoteDirectHistory.fullWindow, "按网络分开记")
        history.record(true, on: "蜂窝网络")
        XCTAssertEqual(history.window(on: "蜂窝网络"), RemoteDirectHistory.fullWindow, "通过一次就恢复")
        for _ in 0..<10 { history.record(false, on: "蜂窝网络") }
        XCTAssertEqual(history.outcomes(on: "蜂窝网络").count, RemoteDirectHistory.depth)
    }
}
