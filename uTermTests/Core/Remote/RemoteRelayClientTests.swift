import XCTest
@testable import uTerm

/// 手机到中继的控制连接在弱网 / 切网下的行为：请求的时限从调用算起、死连接会被换掉、网络一变就重连。
/// 用进程内的假中继（`RemoteFakeRelay`），不需要真实中继。
final class RemoteRelayClientTests: XCTestCase {

    private func elapsed(_ start: Date) -> TimeInterval { Date().timeIntervalSince(start) }

    func test_signal_gets_a_reply_through_a_healthy_relay() async throws {
        let relay = try RemoteFakeRelay()
        defer { relay.stop() }
        let client = RemoteRelayClient(config: try await relay.config())
        let reply = try await client.signal(to: UUID(), from: UUID(), session: "s1", box: "hi", timeout: 3)
        XCTAssertEqual(reply, "reply")
        await client.stop()
    }

    /// 关 Wi-Fi 后的样子：控制连接还在，但中继那头再也不说话。信令按时限失败（而不是一直挂着），
    /// 并且这条连接被扔掉：下一次自动在新连接上发，就通了。
    func test_unanswered_signal_on_a_dead_connection_fails_in_time_and_the_retry_uses_a_new_connection() async throws {
        let relay = try RemoteFakeRelay()
        defer { relay.stop() }
        let client = RemoteRelayClient(config: try await relay.config())
        _ = try await client.onlineHosts()
        XCTAssertEqual(relay.accepted, 1)
        relay.stallExisting()

        let start = Date()
        do {
            _ = try await client.signal(to: UUID(), from: UUID(), session: "s2", box: "hi", timeout: 1)
            XCTFail("死连接上的信令不该成功")
        } catch let error as RemoteRelayError {
            XCTAssertTrue(error == .noReply || error == .timeout, "\(error)")
            XCTAssertNotEqual(error, .notAllowed, "超时不能再说成「这台设备没被允许」")
        }
        XCTAssertLessThan(elapsed(start), 2.5, "时限从调用算起")

        let reply = try await client.signal(to: UUID(), from: UUID(), session: "s3", box: "hi", timeout: 3)
        XCTAssertEqual(reply, "reply")
        XCTAssertEqual(relay.accepted, 2, "重试应在新的控制连接上发")
        await client.stop()
    }

    /// 中继在线、Mac 不回：报「Mac 没有回应」，不是「这台设备没被允许」。
    func test_mac_not_answering_is_reported_as_no_reply() async throws {
        let relay = try RemoteFakeRelay()
        defer { relay.stop() }
        relay.answersSignals = false
        let client = RemoteRelayClient(config: try await relay.config())
        do {
            _ = try await client.signal(to: UUID(), from: UUID(), session: "s4", box: "hi", timeout: 1)
            XCTFail("Mac 不回时应失败")
        } catch let error as RemoteRelayError {
            XCTAssertEqual(error, .noReply)
        }
        await client.stop()
    }

    /// 安静了一阵的控制连接，再用之前先 ping：死了就换一条，请求照样成功。
    func test_stale_connection_is_pinged_and_replaced_before_reuse() async throws {
        let relay = try RemoteFakeRelay()
        defer { relay.stop() }
        let client = RemoteRelayClient(config: try await relay.config(), staleAfter: .zero)
        _ = try await client.onlineHosts()
        relay.stallExisting()

        let start = Date()
        let hosts = try await client.onlineHosts(timeout: 5)
        XCTAssertEqual(hosts, [])
        XCTAssertEqual(relay.accepted, 2)
        XCTAssertLessThan(elapsed(start), 3, "ping 最多等 1.5 秒")
        await client.stop()
    }

    func test_live_connection_answers_the_ping_and_is_kept() async throws {
        let relay = try RemoteFakeRelay()
        defer { relay.stop() }
        let client = RemoteRelayClient(config: try await relay.config(), staleAfter: .zero)
        _ = try await client.onlineHosts()
        _ = try await client.onlineHosts()
        XCTAssertEqual(relay.accepted, 1, "活着的连接不该被换掉")
        await client.stop()
    }

    func test_network_change_drops_the_control_connection() async throws {
        let relay = try RemoteFakeRelay()
        defer { relay.stop() }
        let client = RemoteRelayClient(config: try await relay.config())
        _ = try await client.onlineHosts()
        await client.networkChanged()
        _ = try await client.onlineHosts()
        XCTAssertEqual(relay.accepted, 2, "网络变了，应在新网络上重连")
        await client.stop()
    }

    /// 列在线主机也有时限：卡住的连接上不会一直等。
    func test_online_hosts_times_out_from_the_call() async throws {
        let relay = try RemoteFakeRelay()
        defer { relay.stop() }
        let client = RemoteRelayClient(config: try await relay.config())
        _ = try await client.onlineHosts()
        relay.stallExisting()
        let start = Date()
        do {
            _ = try await client.onlineHosts(timeout: 1)
            XCTFail("卡住的连接上不该拿到结果")
        } catch {
            XCTAssertEqual(error as? RemoteRelayError, .timeout)
        }
        XCTAssertLessThan(elapsed(start), 2.5)
        await client.stop()
    }

    /// 连得上、但对面一个字都不回（半路卡住的中继、假死的网络）：建连按时限失败，说的是超时，
    /// 不是「中继不接受这份配置」。
    func test_open_that_never_gets_a_challenge_reports_a_timeout() async throws {
        let relay = try RemoteFakeRelay()
        defer { relay.stop() }
        let silent = try RemoteFaultProxy(targetPort: try await relay.waitUntilReady())
        defer { silent.stop() }
        silent.setMode(.stalled)
        let deadline = Date().addingTimeInterval(5)
        while silent.port == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        var config = try await relay.config()
        config.port = Int(try XCTUnwrap(silent.port))
        let connection = RemoteRelayConnection(config: config)
        let start = Date()
        do {
            _ = try await connection.open(timeout: 1)
            XCTFail("不回挑战时不该成功")
        } catch {
            XCTAssertEqual(error as? RemoteRelayError, .timeout, "\(error)")
        }
        XCTAssertLessThan(elapsed(start), 2.5)
        connection.close()
    }
}
