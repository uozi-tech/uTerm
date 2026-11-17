import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 中继信箱这条线路（§7.4「中继信箱」，落地见 §17）经内存里的假中继（`FakeGroupRelay`）：两台、三台收敛，
/// 只有中继的和只有局域网的经中间那台转手，局域网优先、回落到中继，两个方向各拨一条只留一条，对端下线清理，
/// 信箱重连后靠 reset 马上重拨，配置没有 / 只有证书时不开，被顶替、满了不马上重试，一帧不超过 64 KiB，
/// 以及两台 `RemoteDeviceGroup` 只靠中继走完加入。
@MainActor
final class RemoteGroupRelayServiceTests: XCTestCase {
    private var t0: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func node(_ name: String, relay: FakeGroupRelay?, config: RelayConfigBox? = nil,
                      timing: RemoteGroupRelayService.Timing = RelayFixtures.fastTiming()) -> RelayNode {
        relayNode(name, relay: relay, config: config, timing: timing)
    }

    /// 等到两台之间经中继连上（两边的同步层都用着中继那条）。
    private func awaitRelayLink(_ a: RelayNode, _ b: RelayNode, timeout: TimeInterval = 5,
                                file: StaticString = #filePath, line: UInt = #line) {
        awaitFast("\(a.device.name)—\(b.device.name) 经中继连上", timeout: timeout, file: file, line: line) {
            a.linkKinds[b.id] == .relay && b.linkKinds[a.id] == .relay
        }
    }

    private func leaderAndFollower(_ a: RelayNode, _ b: RelayNode) -> (RelayNode, RelayNode) {
        a.id.uuidString < b.id.uuidString ? (a, b) : (b, a)
    }

    // MARK: - 收敛与转手

    func test_two_devices_converge_over_the_relay_alone() throws {
        let relay = FakeGroupRelay()
        let a = node("A", relay: relay), b = node("B", relay: relay)
        try RelayNode.registerEverywhere([a, b])
        try a.save(FastSyncFixtures.join(a.device, at: t0))
        try b.save(FastSyncFixtures.join(b.device, at: t0))
        a.startRelay()
        b.startRelay()
        awaitFast("两个信箱都注册上") { relay.onlineHosts.isSuperset(of: [a.mailboxID.uuidString, b.mailboxID.uuidString]) }
        XCTAssertFalse(relay.onlineHosts.contains(a.id.uuidString), "信箱 ID 不是设备 ID")
        awaitRelayLink(a, b)
        awaitFast("两边补齐") { a.accounts == b.accounts && a.accounts.count == 4 }
        XCTAssertEqual(b.keychain.loadAll().count, 3, "收到的只在叠加层，不写钥匙串（两条 device + 自己的 join）")

        // 之后的变化一推就到。
        let later = FastSyncFixtures.join(a.device, at: t0.addingTimeInterval(5))
        try a.save(later)
        awaitFast("改动经中继推到") { b.digests == a.digests }

        let (leader, follower) = leaderAndFollower(a, b)
        awaitFast("只留一条") { leader.relay.connectedPeers == [follower.id] && follower.relay.connectedPeers == [leader.id] }
        XCTAssertEqual(leader.relay.opener(for: follower.id), leader.id, "ID 小的那台先拨")
        XCTAssertEqual(relay.oversized, 0)
    }

    func test_records_hop_from_a_relay_only_device_to_a_lan_only_device_through_the_middle_one() throws {
        // A 只有中继；C 没有中继、只和 B 在同一个局域网；B 两条都有。
        let relay = FakeGroupRelay()
        let a = node("A", relay: relay), b = node("B", relay: relay), c = node("C", relay: nil)
        try RelayNode.registerEverywhere([a, b, c])
        a.startRelay()
        b.startRelay()
        RelayNode.connectLAN(b, c)
        awaitRelayLink(a, b)
        let fromA = FastSyncFixtures.join(a.device, at: t0), fromC = FastSyncFixtures.join(c.device, at: t0)
        try a.save(fromA)
        try c.save(fromC)
        awaitFast("A 的到了 C、C 的到了 A") { c.accounts.contains(fromA.account) && a.accounts.contains(fromC.account) }
        XCTAssertNil(a.linkKinds[c.id], "A、C 互相够不着")
        XCTAssertEqual(b.linkKinds[c.id], .localNetwork)
        XCTAssertEqual(b.linkKinds[a.id], .relay)

        // 删除也转手。
        try a.overlay.delete(account: fromA.account)
        awaitFast("C 那边也藏起来") { !c.accounts.contains(fromA.account) }
    }

    func test_three_devices_on_the_relay_converge() throws {
        let relay = FakeGroupRelay()
        let nodes = [node("A", relay: relay), node("B", relay: relay), node("C", relay: relay)]
        try RelayNode.registerEverywhere(nodes)
        for (index, node) in nodes.enumerated() {
            try node.save(FastSyncFixtures.join(node.device, at: t0.addingTimeInterval(Double(index))))
            node.startRelay()
        }
        awaitFast("三台两两连上", timeout: 8) { nodes.allSatisfy { $0.relay.connectedPeers.count == 2 } }
        awaitFast("收敛") { nodes.allSatisfy { $0.digests == nodes[0].digests } && nodes[0].accounts.count == 6 }
    }

    // MARK: - 挑线路

    func test_lan_wins_over_the_relay_and_the_relay_takes_over_when_lan_drops() throws {
        let relay = FakeGroupRelay()
        let a = node("A", relay: relay), b = node("B", relay: relay)
        try RelayNode.registerEverywhere([a, b])

        // 局域网先连着：中继注册了、也问了在线，但不拨。
        let lan = RelayNode.connectLAN(a, b)
        a.startRelay()
        b.startRelay()
        awaitFast("两个信箱都注册上") { a.relay.isRegistered && b.relay.isRegistered }
        idleFast(1)
        XCTAssertTrue(a.relay.connectedPeers.isEmpty && b.relay.connectedPeers.isEmpty, "局域网在时中继不顶")
        XCTAssertEqual(a.linkKinds[b.id], .localNetwork)

        // 局域网断了：中继马上补上，之后的改动经中继到。
        lan.atA.close()
        awaitRelayLink(a, b, timeout: 3)
        let record = FastSyncFixtures.join(a.device, at: t0)
        try a.save(record)
        awaitFast("经中继到") { b.accounts.contains(record.account) }

        // 局域网又来了：换成局域网，中继那条关掉，不再拨。
        let again = RelayNode.connectLAN(a, b)
        awaitFast("换回局域网") { a.linkKinds[b.id] == .localNetwork && b.linkKinds[a.id] == .localNetwork }
        awaitFast("中继那条关掉") { a.relay.connectedPeers.isEmpty && b.relay.connectedPeers.isEmpty }
        idleFast(1)
        XCTAssertTrue(a.relay.connectedPeers.isEmpty && b.relay.connectedPeers.isEmpty, "局域网在时不重拨")
        let next = FastSyncFixtures.join(b.device, at: t0.addingTimeInterval(1))
        try b.save(next)
        awaitFast("换线路之后照样同步") { a.accounts.contains(next.account) }
        // 换线路时没有把全部记录重推一遍：局域网上 A 发给 B 的记录里没有 B 早就有的那条。
        let resent = again.atA.sentMessages.flatMap { message -> [Data] in
            if case .records(let records) = message { return records }
            return []
        }
        XCTAssertFalse(resent.contains(FastSyncFixtures.data(record)), "B 早就有的不重推")
    }

    func test_when_both_sides_dial_at_once_only_the_link_dialed_by_the_smaller_id_survives() throws {
        let relay = FakeGroupRelay()
        // 不等：两边一看到对方在线就拨，必然各拨一条。
        let timing = RelayFixtures.fastTiming(fallback: 0)
        let a = node("A", relay: relay, timing: timing), b = node("B", relay: relay, timing: timing)
        try RelayNode.registerEverywhere([a, b])
        a.startRelay()
        b.startRelay()
        awaitRelayLink(a, b)
        let (leader, follower) = leaderAndFollower(a, b)
        awaitFast("两边留的是同一条") {
            leader.relay.opener(for: follower.id) == leader.id && follower.relay.opener(for: leader.id) == leader.id
        }
        idleFast(1)
        XCTAssertEqual(leader.relay.connectedPeers, [follower.id])
        XCTAssertEqual(follower.relay.connectedPeers, [leader.id])
        XCTAssertEqual(leader.relay.opener(for: follower.id), leader.id, "稳住了，不来回换")
        let record = FastSyncFixtures.join(follower.device, at: t0)
        try follower.save(record)
        awaitFast("留下的那条能用") { leader.accounts.contains(record.account) }
    }

    // MARK: - 下线与重连

    func test_a_device_vanishing_without_saying_goodbye_is_cleaned_up() throws {
        let relay = FakeGroupRelay()
        let timing = RelayFixtures.fastTiming(idle: 1.5)
        let a = node("A", relay: relay, timing: timing), b = node("B", relay: relay, timing: timing)
        try RelayNode.registerEverywhere([a, b])
        a.startRelay()
        b.startRelay()
        awaitRelayLink(a, b)
        b.relay.stopAbruptlyForTesting()
        awaitFast("B 的信箱下线") { !relay.onlineHosts.contains(b.mailboxID.uuidString) }
        awaitFast("A 发现并清理", timeout: 5) { a.relay.connectedPeers.isEmpty && a.linkKinds[b.id] == nil }
        idleFast(0.5)
        XCTAssertTrue(a.relay.connectedPeers.isEmpty, "B 不在线就不再拨通")
    }

    func test_after_the_mailbox_forgets_its_links_the_dialer_is_reset_and_redials_at_once() throws {
        let relay = FakeGroupRelay()
        // 空闲超时设得很长：恢复只能靠 reset，不能靠超时。
        let timing = RelayFixtures.fastTiming(idle: 60)
        let a = node("A", relay: relay, timing: timing), b = node("B", relay: relay, timing: timing)
        try RelayNode.registerEverywhere([a, b])
        a.startRelay()
        b.startRelay()
        awaitRelayLink(a, b)
        let (leader, follower) = leaderAndFollower(a, b)
        awaitFast("留下的是 leader 拨的") { follower.relay.opener(for: leader.id) == leader.id }

        follower.relay.forgetInboundForTesting()
        awaitFast("leader 被 reset、重拨连上", timeout: 4) {
            relay.resetCount > 0 && follower.relay.connectedPeers == [leader.id] && leader.relay.connectedPeers == [follower.id]
        }
        let record = FastSyncFixtures.join(leader.device, at: t0)
        try leader.save(record)
        awaitFast("新的那条能用") { follower.accounts.contains(record.account) }
    }

    func test_after_the_relay_drops_a_mailbox_both_sides_reconnect() throws {
        let relay = FakeGroupRelay()
        let a = node("A", relay: relay), b = node("B", relay: relay)
        try RelayNode.registerEverywhere([a, b])
        a.startRelay()
        b.startRelay()
        awaitRelayLink(a, b)
        let (leader, follower) = leaderAndFollower(a, b)
        relay.kick(host: follower.mailboxID)
        awaitFast("信箱重新注册、线路重新连上", timeout: 6) {
            follower.relay.isRegistered && follower.relay.connectedPeers == [leader.id]
                && leader.relay.connectedPeers == [follower.id]
        }
        let record = FastSyncFixtures.join(leader.device, at: t0)
        try leader.save(record)
        awaitFast("能用") { follower.accounts.contains(record.account) }
    }

    func test_a_mailbox_that_is_superseded_waits_before_registering_again() async throws {
        let relay = FakeGroupRelay()
        let a = node("A", relay: relay)
        a.startRelay()
        awaitFast("注册上") { a.relay.isRegistered }
        // 另一个进程拿同一台设备的身份注册了同一个信箱。
        let other = try await relay.registerMailbox(a.mailboxID, hostKey: a.mailboxKey, config: RelayFixtures.memberConfig())
        other.control.start(onMessage: { _ in }, onClose: {})
        awaitFast("被顶替") { !a.relay.isRegistered }
        let attempts = relay.registrationAttempts
        idleFast(1)
        XCTAssertFalse(a.relay.isRegistered, "被顶替不马上重连")
        XCTAssertEqual(relay.registrationAttempts, attempts, "一次都没再试")
        other.control.close()
    }

    func test_a_full_relay_or_a_bound_mailbox_id_is_not_retried_every_second() async throws {
        let relay = FakeGroupRelay()
        relay.maxHosts = 0
        let a = node("A", relay: relay)
        a.startRelay()
        awaitFast("试过一次") { relay.registrationAttempts == 1 }
        idleFast(1)
        XCTAssertEqual(relay.registrationAttempts, 1, "满了：过一阵再试")
        XCTAssertTrue(a.relay.isListening, "投递那条照常连着")

        // 信箱 ID 在中继上绑着别的钥匙（重装过、钥匙丢了）。
        let other = FakeGroupRelay()
        let b = node("B", relay: other)
        _ = try await other.registerMailbox(b.mailboxID, hostKey: P256.Signing.PrivateKey(),
                                            config: RelayFixtures.memberConfig()).control.close()
        b.startRelay()
        awaitFast("试过一次") { other.registrationAttempts == 2 }
        idleFast(1)
        XCTAssertEqual(other.registrationAttempts, 2)
        XCTAssertFalse(b.relay.isRegistered)
    }

    // MARK: - 配置

    func test_the_relay_line_stays_off_without_a_default_relay_or_with_only_a_certificate_and_follows_changes() throws {
        let relay = FakeGroupRelay()
        let box = RelayConfigBox(nil)
        let a = node("A", relay: relay, config: box)
        a.startRelay()
        idleFast(0.6)
        XCTAssertTrue(relay.onlineHosts.isEmpty && relay.clientCount == 0, "没有默认中继：不开")

        box.config = try RelayFixtures.memberConfig().certificate(for: UUID())
        idleFast(0.6)
        XCTAssertTrue(relay.onlineHosts.isEmpty && relay.clientCount == 0, "只有成员证书：注册不了信箱，不开")

        box.config = RelayFixtures.memberConfig()
        awaitFast("配置来了就跟上") { a.relay.isRegistered && a.relay.isListening }

        box.config = nil
        awaitFast("配置没了就收掉") { relay.onlineHosts.isEmpty && relay.clientCount == 0 }
    }

    // MARK: - 帧大小

    func test_large_batches_are_fragmented_to_fit_the_relays_64_kib_frames() throws {
        let relay = FakeGroupRelay()
        let a = node("A", relay: relay), b = node("B", relay: relay)
        try RelayNode.registerEverywhere([a, b])
        var accounts: Set<String> = []
        for index in 0..<40 {
            let record = RemoteGroupRecord.device(FastSyncFixtures.device(String(repeating: "设备\(index)", count: 400)))
            try a.keychain.put(record)
            accounts.insert(record.account)
        }
        a.startRelay()
        b.startRelay()
        awaitFast("全部到齐", timeout: 10) { b.accounts.isSuperset(of: accounts) }
        XCTAssertEqual(relay.oversized, 0, "没有一帧超过 64 KiB")
        XCTAssertLessThanOrEqual(relay.largestFrame, FakeGroupRelay.maxFrameBytes)
        XCTAssertGreaterThan(relay.largestFrame, 32 * 1024, "确实是要分片的大小")
    }

    // MARK: - 端到端加入

    func test_two_groups_join_over_the_relay_alone() throws {
        let relay = FakeGroupRelay()
        func peer(_ name: String) -> (RemoteDeviceGroup, RelayNode) {
            let node = node(name, relay: relay)
            let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
            let key = try! store.signingKey()
            var device = node.device
            device.signingKey = key.publicKey.rawRepresentation
            // 名册里的 `device` 用带组员凭证的那份（模型以它为本机）。
            let model = RemoteDeviceGroup(local: device, signingKey: key, identityKey: node.identity,
                                          roster: RemoteGroupRoster(storage: node.overlay), store: store,
                                          now: { [unowned self] in clock })
            return (model, node)
        }
        let (mac, macNode) = peer("Mac"), (phone, phoneNode) = peer("iPhone")
        for model in [mac, phone] {
            for node in [macNode, phoneNode] { try node.keychain.put(.device(model.local)) }
        }
        macNode.startRelay()
        phoneNode.startRelay()
        awaitRelayLink(macNode, phoneNode)
        func converge() {
            awaitFast("收敛") { macNode.digests == phoneNode.digests && macNode.overlay.snapshot().tombstones.count == phoneNode.overlay.snapshot().tombstones.count }
        }
        func step(_ model: RemoteDeviceGroup) {
            clock = clock.addingTimeInterval(1)
            model.refresh()
            converge()
        }
        clock = clock.addingTimeInterval(1)
        phone.startJoin()
        converge()
        step(mac)
        XCTAssertEqual(mac.joinRequests.filter { $0.status != .admitted }.map(\.candidate.id), [phone.local.id])
        guard case .showingCode(let code, _) = phone.joinState else { return XCTFail("应当显示着数：\(String(describing: phone.joinState))") }
        XCTAssertTrue(mac.submitCode(code, for: phone.local.id))
        converge()
        step(phone)
        XCTAssertEqual(phone.joinState, .joined)
        step(mac)
        XCTAssertTrue(mac.members.contains { $0.device.id == phone.local.id })
        step(phone)
        XCTAssertNil(phone.awaitingAcknowledgement)
        XCTAssertTrue(mac.isInGroup && phone.isInGroup)
        // 钥匙串之间什么都没同步：全靠中继。
        let phoneWrites = Set(phoneNode.keychain.log.map(\.account)).subtracting([RemoteGroupRecord.deviceAccount(phone.local.id)])
        XCTAssertFalse(phoneWrites.isEmpty)
        let macKeychain = Set(macNode.keychain.loadAll().compactMap(RemoteGroupRecord.decode).map(\.account))
        XCTAssertTrue(macKeychain.isDisjoint(with: phoneWrites))
        XCTAssertEqual(macNode.linkKinds[phone.local.id], .relay)
    }
}
