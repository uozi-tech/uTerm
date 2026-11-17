import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 快通道叠加层（§7.4「叠加层」）：上层读到的 = 钥匙串 ∪ 快通道收到的，按 account 合并、后到的赢、墓碑、上限、垃圾不收。
final class RemoteGroupOverlayStorageTests: XCTestCase {
    private let clock = FastSyncClock()
    private let keychain = LaggingKeychain()
    private lazy var overlay = RemoteGroupOverlayStorage(base: keychain, now: clock.closure)
    private let peer = UUID()
    private let writer = FastSyncFixtures.device("iPhone")
    private var t0: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private func joins() -> [RemoteGroupJoin] {
        RemoteGroupRoster(storage: overlay).load().joins
    }

    private func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    // MARK: - 本机写、删

    func test_save_writes_the_keychain_and_reports_a_local_change() throws {
        let log = ChangeLog()
        overlay.addObserver { log.append($0) }
        let record = FastSyncFixtures.join(writer, at: t0)
        try overlay.save(FastSyncFixtures.data(record), account: record.account)
        XCTAssertEqual(keychain.loadAll().count, 1, "照写钥匙串")
        XCTAssertEqual(overlay.loadAll().count, 1, "钥匙串和叠加层一样时只出一份")
        XCTAssertEqual(log.changes.first, .local)
        XCTAssertEqual(overlay.snapshot().items.map(\.account), [record.account])
    }

    func test_the_account_of_a_record_is_its_own_not_the_one_it_was_saved_under() throws {
        let record = FastSyncFixtures.join(writer, at: t0)
        try overlay.save(FastSyncFixtures.data(record), account: "join.somewhere-else")
        XCTAssertEqual(overlay.snapshot().items.map(\.account), [record.account])
    }

    func test_delete_leaves_a_tombstone_that_hides_a_slow_keychain_on_other_devices() throws {
        let record = FastSyncFixtures.join(writer, at: t0)
        let data = FastSyncFixtures.data(record)
        try overlay.save(data, account: record.account)
        try overlay.delete(account: record.account)
        XCTAssertTrue(overlay.loadAll().isEmpty)
        let tombstones = overlay.snapshot().tombstones
        XCTAssertEqual(tombstones.map(\.account), [record.account])
        XCTAssertEqual(tombstones.map(\.digest), [digest(data)])

        // 另一台设备：钥匙串里还有（删除在路上），快通道先送来墓碑。
        let otherKeychain = LaggingKeychain()
        try otherKeychain.put(record)
        let other = RemoteGroupOverlayStorage(base: otherKeychain, now: clock.closure)
        XCTAssertEqual(other.loadAll().count, 1)
        let ingest = other.ingest(records: [], tombstones: tombstones, from: peer)
        XCTAssertEqual(ingest.tombstones.count, 1)
        XCTAssertTrue(other.loadAll().isEmpty, "墓碑命中的钥匙串那份也藏起来")
        XCTAssertTrue(other.ingest(records: [data], tombstones: [], from: peer).isEmpty, "被删掉的再送来也不收")
        XCTAssertTrue(other.ingest(records: [], tombstones: tombstones, from: peer).isEmpty, "同一个墓碑不算新的")
    }

    func test_a_tombstone_does_not_block_new_content_for_the_same_account() throws {
        let old = FastSyncFixtures.join(writer, at: t0)
        try keychain.put(old)
        try overlay.delete(account: old.account)
        XCTAssertTrue(overlay.loadAll().isEmpty)
        let new = FastSyncFixtures.join(writer, at: t0.addingTimeInterval(5))
        XCTAssertEqual(overlay.ingest(records: [FastSyncFixtures.data(new)], tombstones: [], from: peer).records.count, 1)
        XCTAssertEqual(joins().map(\.sid), [try XCTUnwrap(sid(new))])
        // 本机自己再写一份新的也照常。
        let newer = FastSyncFixtures.join(writer, at: t0.addingTimeInterval(9))
        try overlay.save(FastSyncFixtures.data(newer), account: newer.account)
        XCTAssertEqual(joins().map(\.sid), [try XCTUnwrap(sid(newer))])
    }

    func test_tombstones_expire_after_ten_minutes() throws {
        let record = FastSyncFixtures.join(writer, at: t0)
        try keychain.put(record)
        let tombstone = RemoteGroupTombstone(account: record.account, digest: digest(FastSyncFixtures.data(record)),
                                             deletedAt: RemoteGroupTime(clock.now))
        overlay.ingest(records: [], tombstones: [tombstone], from: peer)
        XCTAssertTrue(overlay.loadAll().isEmpty)
        clock.advance(RemoteGroupOverlayStorage.tombstoneLifetime + 1)
        XCTAssertEqual(overlay.loadAll().count, 1, "过期之后钥匙串说了算")
        XCTAssertTrue(overlay.snapshot().tombstones.isEmpty)
        XCTAssertTrue(overlay.ingest(records: [], tombstones: [tombstone], from: peer).isEmpty,
                      "转手转回来的过期墓碑不再收（不会被一直续下去）")
        // 删除时间写在将来的，也最多留 10 分钟。
        let future = RemoteGroupTombstone(account: record.account, digest: tombstone.digest,
                                          deletedAt: RemoteGroupTime(clock.now.addingTimeInterval(86_400)))
        XCTAssertEqual(overlay.ingest(records: [], tombstones: [future], from: peer).tombstones.count, 1)
        clock.advance(RemoteGroupOverlayStorage.tombstoneLifetime + 1)
        XCTAssertEqual(overlay.loadAll().count, 1)
    }

    func test_deleting_then_rewriting_the_same_content_ignores_the_echoed_tombstone() throws {
        let record = FastSyncFixtures.join(writer, at: t0)
        let data = FastSyncFixtures.data(record)
        try overlay.save(data, account: record.account)
        try overlay.delete(account: record.account)
        let tombstones = overlay.snapshot().tombstones
        try overlay.save(data, account: record.account)
        XCTAssertEqual(overlay.loadAll().count, 1)
        XCTAssertTrue(overlay.ingest(records: [], tombstones: tombstones, from: peer).isEmpty)
        XCTAssertEqual(overlay.loadAll().count, 1, "别的设备转回来的旧墓碑不把本机刚写回去的藏掉")
    }

    func test_the_same_record_always_encodes_to_the_same_bytes() throws {
        // 叠加层按字节的摘要认「同一份」：重写一遍同样的内容不能变成「新内容」。
        let record = FastSyncFixtures.join(writer, at: t0)
        let first = try record.encoded()
        for _ in 0..<20 { XCTAssertEqual(try record.encoded(), first) }
    }

    // MARK: - 合并

    func test_the_later_content_wins_and_the_keychain_catching_up_drops_the_overlay_copy() throws {
        let v1 = FastSyncFixtures.join(writer, at: t0)
        let v2 = FastSyncFixtures.join(writer, at: t0.addingTimeInterval(10))
        try keychain.put(v1)
        XCTAssertEqual(joins().map(\.sid), [try XCTUnwrap(sid(v1))])

        clock.advance(1)
        XCTAssertEqual(overlay.ingest(records: [FastSyncFixtures.data(v2)], tombstones: [], from: peer).records.count, 1)
        XCTAssertEqual(joins().map(\.sid), [try XCTUnwrap(sid(v2))], "同一个 account 只出一份：后到的")
        XCTAssertTrue(overlay.ingest(records: [FastSyncFixtures.data(v2)], tombstones: [], from: peer).isEmpty)

        // 钥匙串追上了：叠加层那条丢掉（之后钥匙串再变，就按钥匙串的来）。
        try keychain.put(v2)
        XCTAssertEqual(overlay.loadAll().count, 1)
        try keychain.put(v1)
        XCTAssertEqual(joins().map(\.sid), [try XCTUnwrap(sid(v1))], "叠加层那条已经丢了")
    }

    func test_an_older_copy_arriving_later_does_not_roll_back() throws {
        let v1 = FastSyncFixtures.join(writer, at: t0)
        let v2 = FastSyncFixtures.join(writer, at: t0.addingTimeInterval(10))
        overlay.ingest(records: [FastSyncFixtures.data(v1)], tombstones: [], from: peer)
        clock.advance(1)
        overlay.ingest(records: [FastSyncFixtures.data(v2)], tombstones: [], from: peer)
        XCTAssertEqual(joins().map(\.sid), [try XCTUnwrap(sid(v2))])

        // 慢一拍的钥匙串送来旧的那份。
        clock.advance(1)
        try keychain.put(v1)
        XCTAssertEqual(joins().map(\.sid), [try XCTUnwrap(sid(v2))], "钥匙串慢半拍不回退")
        // 另一台没见过新的对端转来旧的那份（它从自己的钥匙串读到的）。
        let v0 = FastSyncFixtures.join(writer, at: t0.addingTimeInterval(-10))
        XCTAssertTrue(overlay.ingest(records: [FastSyncFixtures.data(v0), FastSyncFixtures.data(v1)], tombstones: [],
                                     from: peer).isEmpty, "写得更早的、见过的旧内容都不收")
        XCTAssertEqual(joins().map(\.sid), [try XCTUnwrap(sid(v2))])
    }

    func test_the_keychain_wins_after_ten_minutes_of_disagreement() throws {
        // 写入者的钟往回拨过：钥匙串里的才是新的，可是记录里的时间更早。
        let fast = FastSyncFixtures.join(writer, at: t0.addingTimeInterval(60))
        let real = FastSyncFixtures.join(writer, at: t0)
        overlay.ingest(records: [FastSyncFixtures.data(fast)], tombstones: [], from: peer)
        clock.advance(1)
        try keychain.put(real)
        XCTAssertEqual(joins().map(\.sid), [try XCTUnwrap(sid(fast))])
        clock.advance(RemoteGroupOverlayStorage.disagreementLifetime + 1)
        XCTAssertEqual(joins().map(\.sid), [try XCTUnwrap(sid(real))], "一直对不上就以钥匙串为准")
    }

    func test_keychain_changes_are_reported_once() throws {
        let log = ChangeLog()
        _ = overlay.loadAll()
        overlay.addObserver { log.append($0) }
        try keychain.put(FastSyncFixtures.join(writer, at: t0))
        _ = overlay.loadAll()
        _ = overlay.loadAll()
        XCTAssertEqual(log.changes, [.base])
    }

    // MARK: - 上限、垃圾

    func test_limits_drop_the_oldest_records_from_other_devices_first() throws {
        // 本机写的这条钥匙串还没「读得到」：用一份只写不读的钥匙串，让它一直待在叠加层里。
        let writeOnly = WriteOnlyStorage()
        let overlay = RemoteGroupOverlayStorage(base: writeOnly, now: clock.closure)
        let mine = FastSyncFixtures.join(writer, at: t0)
        try overlay.save(FastSyncFixtures.data(mine), account: mine.account)
        var received: [RemoteGroupRecord] = []
        for index in 0..<(RemoteGroupOverlayStorage.maxItems + 20) {
            clock.advance(0.01)
            let record = FastSyncFixtures.join(FastSyncFixtures.device("D\(index)"), at: t0)
            received.append(record)
            overlay.ingest(records: [FastSyncFixtures.data(record)], tombstones: [], from: peer)
        }
        let accounts = Set(overlay.snapshot().items.map(\.account))
        XCTAssertEqual(accounts.count, RemoteGroupOverlayStorage.maxItems)
        XCTAssertTrue(accounts.contains(mine.account), "本机写的最后才丢")
        XCTAssertFalse(accounts.contains(received[0].account), "最旧的先丢")
        XCTAssertTrue(accounts.contains(received.last!.account))
    }

    func test_garbage_oversized_and_unknown_records_are_not_taken() throws {
        let huge = RemoteGroupRecord.device(FastSyncFixtures.device(String(repeating: "x", count: 17 * 1024)))
        let wrongLength = RemoteGroupRecord.device(RemoteGroupDevice(id: UUID(), name: "short", model: nil, platform: nil,
                                                                     publicKey: Data(count: 31), signingKey: Data(count: 32),
                                                                     updatedAt: t0))
        let records = [Data("not json".utf8), Data(#"{"v":2,"record":"device"}"#.utf8),
                       Data(#"{"v":1,"record":"bogus"}"#.utf8), FastSyncFixtures.data(huge),
                       try wrongLength.encoded()]
        XCTAssertTrue(overlay.ingest(records: records, tombstones: [], from: peer).isEmpty)
        let badTombstones = [RemoteGroupTombstone(account: "join.x", digest: Data(count: 3), deletedAt: RemoteGroupTime(clock.now)),
                             RemoteGroupTombstone(account: "", digest: Data(count: 32), deletedAt: RemoteGroupTime(clock.now))]
        XCTAssertTrue(overlay.ingest(records: [], tombstones: badTombstones, from: peer).isEmpty)
        XCTAssertTrue(overlay.loadAll().isEmpty)
        // 太大的本机记录只进钥匙串，不经快通道。
        try overlay.save(FastSyncFixtures.data(huge), account: huge.account)
        XCTAssertEqual(keychain.loadAll().count, 1)
    }

    func test_only_keychain_devices_count_as_trusted() throws {
        let listed = FastSyncFixtures.device("Mac")
        try keychain.put(.device(listed))
        let injected = FastSyncFixtures.device("Stranger")
        overlay.ingest(records: [FastSyncFixtures.data(.device(injected))], tombstones: [], from: peer)
        XCTAssertEqual(Set(RemoteGroupRoster(storage: overlay).load().devices.map(\.name)), ["Mac", "Stranger"],
                       "上层照样列出来")
        XCTAssertEqual(overlay.baseDevices().map(\.name), ["Mac"], "快通道收到的 device 不给人进快通道的资格")
    }

    private func sid(_ record: RemoteGroupRecord) -> Data? {
        guard case .join(let join) = record else { return nil }
        return join.sid
    }
}

/// 写进去之后读不出来的钥匙串（让本机写的那条一直留在叠加层里）。
private final class WriteOnlyStorage: RemoteSyncedStorage, @unchecked Sendable {
    func loadAll() -> [Data] { [] }
    func save(_ data: Data, account: String) throws {}
    func delete(account: String) throws {}
    func deleteAll() throws {}
}
