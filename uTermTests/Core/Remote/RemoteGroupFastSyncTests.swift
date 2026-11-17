import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 快通道的同步层（§7.4「同步」）：内存线路连起两台、三台（链式），收敛、转手、删除传播、不回声、分批。
@MainActor
final class RemoteGroupFastSyncTests: XCTestCase {
    /// 一台设备：自己的「钥匙串」、叠加层、同步层。
    private final class Node {
        let device: RemoteGroupDevice
        let keychain = LaggingKeychain()
        let overlay: RemoteGroupOverlayStorage
        let sync: RemoteGroupFastSync
        private let inbox = Inbox()

        init(_ name: String) {
            device = FastSyncFixtures.device(name)
            overlay = RemoteGroupOverlayStorage(base: keychain)
            let inbox = inbox
            sync = RemoteGroupFastSync(overlay: overlay, coalesceDelay: 0.005, syncInterval: 0.5) { inbox.append($0) }
        }

        var receipts: [RemoteGroupFastSync.Received] { inbox.items }

        var accounts: Set<String> { Set(overlay.snapshot().items.map(\.account)) }

        func save(_ record: RemoteGroupRecord) throws {
            try overlay.save(record.encoded(), account: record.account)
        }
    }

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [RemoteGroupFastSync.Received] = []
        func append(_ value: RemoteGroupFastSync.Received) { lock.withLock { received.append(value) } }
        var items: [RemoteGroupFastSync.Received] { lock.withLock { received } }
    }


    private func node(_ name: String) -> Node {
        let node = Node(name)
        let sync = node.sync
        addTeardownBlock { sync.stop() }
        return node
    }

    @discardableResult
    private func connect(_ a: Node, _ b: Node) -> (atA: MemoryGroupLink, atB: MemoryGroupLink) {
        let pair = MemoryGroupLink.pair(a.device, b.device)
        a.sync.add(pair.atA)
        b.sync.add(pair.atB)
        return pair
    }

    private var t0: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    // MARK: -

    func test_two_devices_converge_both_ways_on_connect_and_after_changes() throws {
        let a = node("A"), b = node("B")
        let onlyA = FastSyncFixtures.join(a.device, at: t0), onlyB = FastSyncFixtures.join(b.device, at: t0)
        try a.save(onlyA)
        try b.save(onlyB)
        connect(a, b)
        awaitFast("连上就互相补齐") { a.accounts == b.accounts && a.accounts.count == 2 }
        XCTAssertTrue(b.keychain.loadAll().count == 1, "收到的只在叠加层，不写钥匙串")

        let later = FastSyncFixtures.join(a.device, at: t0.addingTimeInterval(5))
        try a.save(later)
        awaitFast("本机一有变化就推过去") {
            RemoteGroupRoster(storage: b.overlay).load().joins.contains { $0.device.id == a.device.id && $0.createdAt == later.writtenAt }
        }
        XCTAssertEqual(RemoteGroupRoster(storage: b.overlay).load().joins.filter { $0.device.id == a.device.id }.count, 1,
                       "同一个 account 只有一份")
        XCTAssertFalse(b.receipts.isEmpty, "告诉上层有新东西")
        XCTAssertEqual(b.receipts.first?.peer.id, a.device.id)
        XCTAssertEqual(b.receipts.first?.kind, .localNetwork)
    }

    func test_a_chain_relays_records_and_deletions_to_the_far_end() throws {
        // A—B—C：A 和 C 不直连。
        let a = node("A"), b = node("B"), c = node("C")
        connect(a, b)
        connect(b, c)
        let record = FastSyncFixtures.join(a.device, at: t0)
        let data = try record.encoded()
        try a.overlay.save(data, account: record.account)
        awaitFast("经 B 转手到 C") { c.accounts.contains(record.account) }
        // C 的钥匙串慢半拍：A 删了之后才送来那条旧记录，墓碑照样把它藏起来。
        try a.overlay.delete(account: record.account)
        awaitFast("删除也转手") { !c.accounts.contains(record.account) && !b.accounts.contains(record.account) }
        c.keychain.put(data, account: record.account)
        XCTAssertFalse(c.accounts.contains(record.account), "墓碑命中钥匙串那份")
        XCTAssertTrue(RemoteGroupRoster(storage: c.overlay).load().joins.isEmpty)

        // C 写的也到 A。
        let fromC = FastSyncFixtures.join(c.device, at: t0)
        try c.save(fromC)
        awaitFast("反方向也转手") { a.accounts.contains(fromC.account) }
    }

    func test_records_received_from_a_peer_are_not_echoed_back_to_it() throws {
        let a = node("A"), b = node("B"), c = node("C")
        let ab = connect(a, b)
        connect(b, c)
        awaitFast { a.sync.connectedPeers.count == 1 && c.sync.connectedPeers.count == 1 }
        idleFast()
        let record = FastSyncFixtures.join(a.device, at: t0)
        let data = try record.encoded()
        try a.save(record)
        awaitFast { c.accounts.contains(record.account) }
        idleFast(1.2) // 再过两次 30 秒那种定时 sync（测试里 0.5 秒）
        let echoed = ab.atB.sentMessages.contains {
            if case .records(let items) = $0 { return items.contains(data) }
            return false
        }
        XCTAssertFalse(echoed, "B 不把从 A 收到的原样回给 A")
        let toC = b.sync.connectedPeers.contains(c.device.id)
        XCTAssertTrue(toC)
    }

    func test_large_sets_are_sent_in_batches_under_the_payload_limit() throws {
        let a = node("A"), b = node("B")
        var accounts: Set<String> = []
        for index in 0..<40 {
            let device = FastSyncFixtures.device(String(repeating: "设备\(index)", count: 400))
            let record = RemoteGroupRecord.device(device)
            XCTAssertLessThanOrEqual(try record.encoded().count, RemoteGroupOverlayStorage.maxItemBytes)
            try a.keychain.put(record)
            accounts.insert(record.account)
        }
        let pair = connect(a, b)
        awaitFast("全部到齐", timeout: 10) { b.accounts.isSuperset(of: accounts) }
        let frames = pair.atA.sentFrames
        XCTAssertTrue(frames.allSatisfy { $0.count <= RemoteGroupFastSync.maxPayload }, "每帧不超过 48 KiB")
        let batches = pair.atA.sentMessages.filter { if case .records = $0 { return true } else { return false } }
        XCTAssertGreaterThan(batches.count, 1, "一帧放不下就分批")
        XCTAssertTrue(b.keychain.loadAll().isEmpty)
    }

    func test_a_big_digest_list_is_split_across_sync_messages() throws {
        // 两边的钥匙串里已经有同样的 1050 条（叠加层最多只放 512 条，这里只看 `sync` 怎么切、对端认不认）。
        let a = node("A"), b = node("B")
        for index in 0..<(RemoteGroupFastSync.digestsPerSync + 50) {
            let record = FastSyncFixtures.join(FastSyncFixtures.device("D\(index)"), at: t0)
            let data = try record.encoded()
            a.keychain.put(data, account: record.account)
            b.keychain.put(data, account: record.account)
        }
        let pair = connect(a, b)
        awaitFast { a.sync.connectedPeers.count == 1 && b.sync.connectedPeers.count == 1 }
        idleFast()
        let extra = FastSyncFixtures.join(a.device, at: t0)
        try a.save(extra)
        awaitFast("分条的 sync 收完之后照常推", timeout: 10) { b.accounts.contains(extra.account) }
        XCTAssertEqual(b.accounts.count, RemoteGroupFastSync.digestsPerSync + 51)
        let pushed = pair.atA.sentMessages.reduce(0) { count, message in
            if case .records(let items) = message { return count + items.count }
            return count
        }
        // 对端那份 `sync` 要是在新记录到之前拍的，收到时会再推一次这一条（无害）；早就有的 1050 条一条都不发。
        XCTAssertGreaterThanOrEqual(pushed, 1)
        XCTAssertLessThan(pushed, 5)
        let syncs = pair.atA.sentMessages.compactMap { message -> Bool? in
            if case .sync(_, _, _, let more) = message { return more }
            return nil
        }
        XCTAssertTrue(syncs.contains(true), "摘要多了分几条发")
        XCTAssertTrue(pair.atA.sentFrames.allSatisfy { $0.count <= RemoteGroupFastSync.maxPayload })
    }

    func test_unknown_messages_and_versions_are_ignored() throws {
        let a = node("A"), b = node("B")
        let pair = connect(a, b)
        awaitFast { a.sync.connectedPeers.count == 1 }
        pair.atB.send(Data(#"{"v":1,"type":"future-thing","x":1}"#.utf8))
        pair.atB.send(Data(#"{"v":9,"type":"records","records":[]}"#.utf8))
        pair.atB.send(Data("garbage".utf8))
        let record = FastSyncFixtures.join(b.device, at: t0)
        try b.save(record)
        awaitFast("之后的正常消息照收") { a.accounts.contains(record.account) }
        XCTAssertEqual(a.sync.connectedPeers, [b.device.id], "不认识的消息不断开")
    }

    func test_closing_a_link_removes_it_and_a_reconnect_catches_up() throws {
        let a = node("A"), b = node("B")
        let first = connect(a, b)
        awaitFast { a.sync.connectedPeers.count == 1 }
        first.atA.close()
        awaitFast { a.sync.connectedPeers.isEmpty && b.sync.connectedPeers.isEmpty }
        let record = FastSyncFixtures.join(a.device, at: t0)
        try a.save(record)
        idleFast()
        XCTAssertFalse(b.accounts.contains(record.account))
        connect(a, b)
        awaitFast("重连时补上断开期间的") { b.accounts.contains(record.account) }
    }

    func test_message_round_trip() throws {
        let digest = Data(SHA256.hash(data: Data("x".utf8)))
        let messages: [RemoteGroupSyncMessage] = [
            .sync(have: digest + digest, dead: digest, reply: true, more: false),
            .records([Data("a".utf8), Data("b".utf8)]),
            .tombstones([RemoteGroupTombstone(account: "join.x", digest: digest, deletedAt: RemoteGroupTime(milliseconds: 5))]),
        ]
        for message in messages {
            XCTAssertEqual(RemoteGroupSyncMessage.decode(try message.encoded()), message)
        }
        XCTAssertNil(RemoteGroupSyncMessage.decode(Data(#"{"v":1,"type":"sync","have":"AAA="}"#.utf8)),
                     "摘要长度不是 32 的倍数")
        XCTAssertEqual(RemoteGroupSyncMessage.digests(in: digest + digest), [digest, digest])
    }
}
