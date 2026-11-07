import XCTest
@preconcurrency import Network
@testable import uTerm

/// Mac 长时间离线时远控标签少做无用的建连：没人看、断了很久才放长退避；Mac 可能回来了的迹象一出现就立即重试。
@MainActor
final class RemoteReconnectPolicyTests: XCTestCase {

    // MARK: - 退避节奏（纯函数）

    func test_watched_tab_never_waits_more_than_five_seconds() {
        for outage in [Duration.zero, .seconds(30), .seconds(90), .seconds(600), .seconds(86_400)] {
            for failures in 0...20 {
                XCTAssertLessThanOrEqual(
                    RemoteReconnectPolicy.delay(failures: failures, outage: outage, watched: true), .seconds(5),
                    "有人看着的标签 Mac 一回来就要接上（断了 \(outage)、失败 \(failures) 次）")
            }
        }
    }

    func test_backoff_matches_the_old_schedule_while_watched() {
        let delays = (0..<6).map { RemoteReconnectPolicy.delay(failures: $0, outage: .zero, watched: true) }
        XCTAssertEqual(delays, [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5)],
                       "与以前的 0.5 秒起、翻倍、封顶 5 秒一致")
    }

    func test_unwatched_short_outage_keeps_the_five_second_cap() {
        // Wi-Fi 切换、电梯里掉线这类短断线：没人看也照旧 5 秒一试，回来时不多等。
        for failures in 0...20 {
            XCTAssertLessThanOrEqual(RemoteReconnectPolicy.delay(failures: failures, outage: .seconds(59), watched: false),
                                     .seconds(5))
        }
    }

    func test_unwatched_sustained_outage_grows_gradually_up_to_a_minute() {
        XCTAssertEqual(RemoteReconnectPolicy.cap(outage: .seconds(60), watched: false), .seconds(30))
        XCTAssertEqual(RemoteReconnectPolicy.cap(outage: .seconds(299), watched: false), .seconds(30))
        XCTAssertEqual(RemoteReconnectPolicy.cap(outage: .seconds(300), watched: false), .seconds(60))
        XCTAssertEqual(RemoteReconnectPolicy.cap(outage: .seconds(86_400), watched: false), .seconds(60),
                       "无论断多久都不超过一分钟")
        // 被叫醒后（失败次数清零）仍从 0.5 秒重新长起，不是一下跳到上限。
        let delays = (0..<9).map { RemoteReconnectPolicy.delay(failures: $0, outage: .seconds(600), watched: false) }
        XCTAssertEqual(delays, [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
                                .seconds(32), .seconds(60), .seconds(60)])
    }

    func test_huge_failure_count_does_not_overflow() {
        XCTAssertEqual(RemoteReconnectPolicy.delay(failures: 10_000, outage: .seconds(600), watched: false), .seconds(60))
        XCTAssertEqual(RemoteReconnectPolicy.delay(failures: -1, outage: .zero, watched: true), .milliseconds(500))
    }

    // MARK: - 叫醒

    private func makeClient() -> RemoteMacClient {
        RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                        identity: RemoteIdentityStore(storage: RemoteMemoryStorage()))
    }

    private let lan = NWEndpoint.hostPort(host: "192.168.1.9", port: 4000)

    /// 等一个退避等待：被叫醒返回 true；`limit` 内没被叫醒返回 false。
    private func woke(_ gate: RemoteRetryGate, within limit: Duration = .seconds(2),
                      while action: () async -> Void) async -> Bool {
        let waiting = Task { await gate.wait(limit) }
        try? await Task.sleep(for: .milliseconds(50))
        await action()
        return await waiting.value
    }

    func test_rediscovered_on_lan_wakes_backoff() async {
        let client = makeClient()
        client.updateRoutes(endpoint: nil, internetDialer: nil)
        let wokeOnLAN = await woke(client.retryGate) { client.updateRoutes(endpoint: self.lan, internetDialer: nil) }
        XCTAssertTrue(wokeOnLAN, "局域网又找到 Mac：正在退避的标签马上重试")

        let wokeAgain = await woke(client.retryGate, within: .milliseconds(300)) {
            client.updateRoutes(endpoint: self.lan, internetDialer: nil)
        }
        XCTAssertFalse(wokeAgain, "路没变（目录每次重建都会调一遍）不算新迹象")

        let wokeOnLoss = await woke(client.retryGate, within: .milliseconds(300)) {
            client.updateRoutes(endpoint: nil, internetDialer: nil)
        }
        XCTAssertFalse(wokeOnLoss, "少了一条路不叫醒")
    }

    func test_newly_configured_relay_wakes_backoff() async {
        let client = makeClient()
        client.updateRoutes(endpoint: nil, internetDialer: nil)
        let woken = await woke(client.retryGate) {
            client.updateRoutes(endpoint: nil, internetDialer: { throw RemoteProtocolError.closed })
        }
        XCTAssertTrue(woken)
    }

    func test_mac_coming_online_on_relay_wakes_backoff_once() async {
        let client = makeClient()
        let stillOffline = await woke(client.retryGate, within: .milliseconds(300)) { client.relayPresenceChanged(false) }
        XCTAssertFalse(stillOffline)
        let cameOnline = await woke(client.retryGate) { client.relayPresenceChanged(true) }
        XCTAssertTrue(cameOnline, "中继报 Mac 上线：正在退避的标签马上重试")
        let stillOnline = await woke(client.retryGate, within: .milliseconds(300)) { client.relayPresenceChanged(true) }
        XCTAssertFalse(stillOnline, "一直在线时每次轮询都叫醒就成了另一种空转")
    }

    func test_tab_becoming_watched_wakes_backoff() async {
        let client = makeClient()
        let backend = RemoteTerminalBackend(client: client, sessionID: UUID())
        let hidden = await woke(client.retryGate, within: .milliseconds(300)) { backend.setWatched(false) }
        XCTAssertFalse(hidden, "切走不需要立刻重试")
        let shown = await woke(client.retryGate) { backend.setWatched(true) }
        XCTAssertTrue(shown, "用户切到正在重连的标签：可能正睡在一分钟的退避里，要立刻重试")
        let again = await woke(client.retryGate, within: .milliseconds(300)) { backend.setWatched(true) }
        XCTAssertFalse(again, "一直在看不重复叫醒")
        await backend.close()
    }

    /// 一个标签把连接接回来时，同一台 Mac 的其它标签不该还睡在各自的长退避里。
    func test_reconnected_client_wakes_other_waiting_tabs() async throws {
        let registry = TerminalSessionRegistry()
        let server = RemoteHostServer(registry: registry, identity: RemoteIdentityStore(storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        server.start()
        defer { server.stop() }
        let deadline = ContinuousClock.now + .seconds(5)
        while server.port == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1",
                                                         port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!),
                                     identity: RemoteIdentityStore(storage: RemoteMemoryStorage()))
        let otherTab = Task { await client.retryGate.wait(.seconds(30)) }
        let connecting = Task { await client.connect() }
        while server.pairingRequests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        let woken = await otherTab.value
        XCTAssertTrue(woken, "连上之后叫醒还在退避的标签，在现成的连接上接入")
        client.disconnect()
    }
}
