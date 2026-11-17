import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 经真实 `uterm-relay` 的设备组信箱（§7.4「中继信箱」，落地见 §17）：两台设备各注册信箱、互相投递、同步一批要分片的
/// 记录，一台不告而别后另一台清理，正常退出时对端马上知道；同一个信箱 ID 被顶替、绑着别的钥匙时中继怎么回。
///
/// 要有跑着的中继，由 `make test-relay-e2e` 起好后经环境变量 `TEST_RUNNER_UTERM_RELAY_CONFIG` 传进来；没有时跳过。
@MainActor
final class RemoteGroupRelayMailboxEndToEndTests: XCTestCase {
    private var t0: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private func relayConfig() throws -> RemoteRelayConfig {
        guard let json = ProcessInfo.processInfo.environment["UTERM_RELAY_CONFIG"], !json.isEmpty else {
            throw XCTSkip("没有配置真实中继，用 make test-relay-e2e 跑")
        }
        return try XCTUnwrap(RemoteRelayConfig(importing: Data(json.utf8)))
    }

    private func node(_ name: String, config: RemoteRelayConfig, idle: TimeInterval = 3) -> RelayNode {
        var timing = RelayFixtures.fastTiming(idle: idle)
        timing.refusedRetry = 60
        timing.maxRefusedRetry = 60
        return relayNode(name, relay: RemoteGroupRelayNetworkDialer(), config: RelayConfigBox(config), timing: timing)
    }

    /// 中继上此刻在线的主机。
    private func onlineHosts(_ config: RemoteRelayConfig) async throws -> Set<UUID> {
        let client = RemoteRelayClient(config: config)
        defer { Task { await client.stop() } }
        return try await client.onlineHosts()
    }

    private func awaitAsync(_ message: String, timeout: TimeInterval = 10, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return XCTFail("等不到：\(message)") }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func test_two_mailboxes_sync_a_fragmented_batch_and_clean_up_after_a_device_vanishes() async throws {
        let config = try relayConfig()
        let a = node("A", config: config), b = node("B", config: config)
        try RelayNode.registerEverywhere([a, b])
        var accounts: Set<String> = []
        for index in 0..<30 {
            // 一条三四 KiB：一批 48 KiB 的 records 要切成两片才进得了中继的一帧。
            let record = RemoteGroupRecord.device(FastSyncFixtures.device(String(repeating: "设备\(index)", count: 400)))
            try a.keychain.put(record)
            accounts.insert(record.account)
        }
        let fromB = FastSyncFixtures.join(b.device, at: t0)
        try b.save(fromB)
        a.startRelay()
        b.startRelay()

        await awaitAsync("两个信箱都在线") {
            let hosts = (try? await self.onlineHosts(config)) ?? []
            return hosts.isSuperset(of: [a.mailboxID, b.mailboxID])
        }
        let hosts = try await onlineHosts(config)
        XCTAssertFalse(hosts.contains(a.id) || hosts.contains(b.id), "信箱 ID 不是设备 ID")

        await awaitAsync("经中继连上") { a.linkKinds[b.id] == .relay && b.linkKinds[a.id] == .relay }
        await awaitAsync("一批记录到齐", timeout: 15) { b.accounts.isSuperset(of: accounts) && a.accounts.contains(fromB.account) }
        let (leader, follower) = a.id.uuidString < b.id.uuidString ? (a, b) : (b, a)
        await awaitAsync("两边只留 ID 小的那台拨的一条") {
            leader.relay.opener(for: follower.id) == leader.id && follower.relay.opener(for: leader.id) == leader.id
        }

        // 之后的改动一推就到。
        let later = FastSyncFixtures.join(a.device, at: t0.addingTimeInterval(3))
        try a.save(later)
        await awaitAsync("改动经中继到") { b.accounts.contains(later.account) && b.digests == a.digests }

        // B 不告而别（断网、进程被杀）：A 靠 undeliverable 或空闲超时收掉，之后 B 的信箱不在线就不再拨通。
        b.relay.stopAbruptlyForTesting()
        await awaitAsync("A 清理掉", timeout: 10) { a.relay.connectedPeers.isEmpty && a.linkKinds[b.id] == nil }
        await awaitAsync("B 的信箱下线") { !((try? await self.onlineHosts(config)) ?? []).contains(b.mailboxID) }
        try? await Task.sleep(for: .seconds(1))
        XCTAssertTrue(a.relay.connectedPeers.isEmpty)
    }

    func test_a_device_leaving_normally_is_noticed_at_once() async throws {
        let config = try relayConfig()
        // 空闲超时很长：对端马上知道只能是因为收到了 bye。
        let a = node("A", config: config, idle: 60), b = node("B", config: config, idle: 60)
        try RelayNode.registerEverywhere([a, b])
        a.startRelay()
        b.startRelay()
        await awaitAsync("经中继连上") { a.linkKinds[b.id] == .relay && b.linkKinds[a.id] == .relay }
        b.channel.stop()
        await awaitAsync("A 马上知道", timeout: 3) { a.linkKinds[b.id] == nil && a.relay.connectedPeers.isEmpty }
    }

    func test_the_relay_supersedes_a_second_registration_and_refuses_another_key() async throws {
        let config = try relayConfig()
        let a = node("A", config: config)
        a.startRelay()
        await awaitAsync("注册上") { a.relay.isRegistered }

        // 同一个信箱 ID、同一把钥匙：后来的顶掉先来的，先来的不马上重连。
        let dialer = RemoteGroupRelayNetworkDialer()
        let second = try await dialer.registerMailbox(a.mailboxID, hostKey: a.mailboxKey, config: config)
        second.control.start(onMessage: { _ in }, onClose: {})
        await awaitAsync("A 被顶替") { !a.relay.isRegistered }
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(a.relay.isRegistered, "被顶替不马上重连")

        // 别的钥匙：中继认绑定，回 hostKey。
        do {
            let third = try await dialer.registerMailbox(a.mailboxID, hostKey: P256.Signing.PrivateKey(), config: config)
            third.control.close()
            XCTFail("换了钥匙应当被拒")
        } catch RemoteRelayError.refused(let reason) {
            XCTAssertEqual(reason, "hostKey")
        }
        second.control.close()
    }
}
