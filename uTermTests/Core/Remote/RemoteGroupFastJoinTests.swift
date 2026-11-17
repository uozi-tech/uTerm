import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 端到端：几台 `RemoteDeviceGroup` 各自一份「钥匙串」，彼此**不同步**（只预先放好大家的 `device` 记录），只靠快通道
///（内存线路 + 真的叠加层与同步层）走完加入 → 输码 → 进组。再看钥匙串慢半拍送到时不出重复、不回退。
@MainActor
final class RemoteGroupFastJoinTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    private final class Peer {
        let model: RemoteDeviceGroup
        let keychain: LaggingKeychain
        let overlay: RemoteGroupOverlayStorage
        let sync: RemoteGroupFastSync

        init(model: RemoteDeviceGroup, keychain: LaggingKeychain, overlay: RemoteGroupOverlayStorage, sync: RemoteGroupFastSync) {
            self.model = model
            self.keychain = keychain
            self.overlay = overlay
            self.sync = sync
        }

        var id: UUID { model.local.id }
        var digests: Set<Data> { Set(overlay.snapshot().items.map(\.digest)) }
        var tombstones: Set<Data> { Set(overlay.snapshot().tombstones.map(\.key)) }
        var names: Set<String> { Set(model.members.filter { !$0.isLocal }.map(\.device.name)) }
    }

    private func makePeer(_ name: String) -> Peer {
        let keychain = LaggingKeychain()
        let overlay = RemoteGroupOverlayStorage(base: keychain)
        let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
        let key = try! store.signingKey()
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let local = RemoteGroupDevice(id: UUID(), name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                                      publicKey: identity.publicKey.rawRepresentation,
                                      signingKey: key.publicKey.rawRepresentation, updatedAt: clock)
        let model = RemoteDeviceGroup(local: local, signingKey: key, identityKey: identity,
                                      roster: RemoteGroupRoster(storage: overlay), store: store,
                                      now: { [unowned self] in clock })
        let sync = RemoteGroupFastSync(overlay: overlay, coalesceDelay: 0.005, syncInterval: 0.5) { _ in }
        addTeardownBlock { sync.stop() }
        return Peer(model: model, keychain: keychain, overlay: overlay, sync: sync)
    }

    /// 每台设备首次启动就写了自己的 `device`，钥匙串早同步到了：只有这些记录两边都有。
    private func registerEverywhere(_ peers: [Peer]) throws {
        for peer in peers {
            for other in peers { try other.keychain.put(.device(peer.model.local)) }
        }
    }

    private func connect(_ a: Peer, _ b: Peer) {
        let pair = MemoryGroupLink.pair(a.model.local, b.model.local)
        a.sync.add(pair.atA)
        b.sync.add(pair.atB)
    }

    /// 所有设备的叠加层合并结果一样（记录与墓碑）。
    private func converge(_ peers: [Peer], file: StaticString = #filePath, line: UInt = #line) {
        awaitFast("快通道收敛", file: file, line: line) {
            let first = peers[0]
            return peers.dropFirst().allSatisfy { $0.digests == first.digests && $0.tombstones == first.tombstones }
        }
    }

    private func step(_ peer: Peer, _ all: [Peer]) {
        clock = clock.addingTimeInterval(1)
        peer.model.refresh()
        converge(all)
    }

    private func code(_ peer: Peer, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .showingCode(let code, _) = peer.model.joinState else {
            XCTFail("应当显示着数：\(String(describing: peer.model.joinState))", file: file, line: line)
            return ""
        }
        return code
    }

    /// `candidate` 经 `member` 加入，每一步之后等快通道收敛（不碰钥匙串）。
    private func join(_ candidate: Peer, via member: Peer, all: [Peer], file: StaticString = #filePath, line: UInt = #line) {
        clock = clock.addingTimeInterval(1)
        candidate.model.startJoin()
        converge(all, file: file, line: line)
        step(member, all)
        XCTAssertEqual(member.model.joinRequests.filter { $0.status != .admitted }.map(\.candidate.id), [candidate.id], "组员看到加入请求", file: file, line: line)
        XCTAssertTrue(member.model.submitCode(code(candidate, file: file, line: line), for: candidate.id), file: file, line: line)
        converge(all, file: file, line: line)
        step(candidate, all)
        XCTAssertEqual(candidate.model.joinState, .joined, "新设备收到 answer、核对通过", file: file, line: line)
        step(member, all)
        XCTAssertTrue(member.names.contains(candidate.model.local.name), "组员收到 done、认下新设备", file: file, line: line)
        step(candidate, all)
        XCTAssertNil(candidate.model.awaitingAcknowledgement, "新设备收到 admit", file: file, line: line)
    }

    // MARK: -

    func test_two_devices_join_over_the_fast_channel_alone() throws {
        let mac = makePeer("Mac"), phone = makePeer("iPhone")
        let all = [mac, phone]
        try registerEverywhere(all)
        connect(mac, phone)
        converge(all)
        join(phone, via: mac, all: all)
        XCTAssertEqual(mac.names, ["iPhone"])
        XCTAssertEqual(phone.names, ["Mac"])
        XCTAssertTrue(mac.model.isInGroup && phone.model.isInGroup)
        // 钥匙串之间什么都没同步：Mac 的钥匙串里没有 iPhone 写的任何记录（除了预先放的 device）。
        let phoneWrites = Set(phone.keychain.log.map(\.account)).subtracting([RemoteGroupRecord.deviceAccount(phone.id)])
        XCTAssertFalse(phoneWrites.isEmpty)
        let macKeychain = Set(mac.keychain.loadAll().compactMap(RemoteGroupRecord.decode).map(\.account))
        XCTAssertTrue(macKeychain.isDisjoint(with: phoneWrites))
    }

    func test_three_devices_in_a_chain_join_through_the_middle_one() throws {
        // A—B—C：C 和 A 不直连，C 经 A 加入时每一步都由 B 转手。
        let a = makePeer("A"), b = makePeer("B"), c = makePeer("C")
        let all = [a, b, c]
        try registerEverywhere(all)
        connect(a, b)
        connect(b, c)
        converge(all)
        join(b, via: a, all: all)
        join(c, via: a, all: all)
        for _ in 0..<2 {
            for peer in all { step(peer, all) }
        }
        XCTAssertEqual(a.names, ["B", "C"])
        XCTAssertEqual(b.names, ["A", "C"], "B 没参与，读到 A 签的 admit 也认 C")
        XCTAssertEqual(c.names, ["A", "B"])
    }

    func test_a_slow_keychain_arriving_afterwards_neither_duplicates_nor_rolls_back() throws {
        let mac = makePeer("Mac"), phone = makePeer("iPhone")
        let all = [mac, phone]
        try registerEverywhere(all)
        connect(mac, phone)
        converge(all)
        // 记下 iPhone 写了 join 那一刻它钥匙串里的操作数：之后只把到这为止的送到 Mac（旧的 join 慢半拍才到）。
        clock = clock.addingTimeInterval(1)
        phone.model.startJoin()
        let staleUpTo = phone.keychain.operationCount
        phone.model.cancelJoin()
        converge(all)
        join(phone, via: mac, all: all)
        let macMembers = mac.model.members, phoneMembers = phone.model.members

        // 钥匙串终于送到：先是过时的一段（含早就撤下的 join）。
        mac.keychain.deliver(from: phone.keychain, 0..<staleUpTo)
        for peer in all { step(peer, all) }
        XCTAssertTrue(mac.model.roster.load().joins.isEmpty, "撤下过的 join 被墓碑藏住")
        XCTAssertTrue(mac.model.joinRequests.allSatisfy { $0.status == .admitted }, "不再弹输码框")
        XCTAssertEqual(mac.model.members, macMembers)

        // 再是全部。
        mac.keychain.deliver(from: phone.keychain, staleUpTo..<phone.keychain.operationCount)
        phone.keychain.deliver(from: mac.keychain, 0..<mac.keychain.operationCount)
        for _ in 0..<2 {
            for peer in all { step(peer, all) }
        }
        XCTAssertEqual(mac.model.members, macMembers, "不回退")
        XCTAssertEqual(phone.model.members, phoneMembers)
        XCTAssertTrue(mac.model.joinRequests.allSatisfy { $0.status == .admitted })
        XCTAssertNil(phone.model.awaitingAcknowledgement)
        for peer in all {
            let accounts = peer.overlay.snapshot().items.map(\.account)
            XCTAssertEqual(accounts.count, Set(accounts).count, "同一个 account 只出一份")
            let snapshot = peer.model.roster.load()
            XCTAssertTrue(snapshot.joins.isEmpty)
            XCTAssertEqual(snapshot.admits.map(\.signer), [mac.id], "Mac 签的那一条（第一台不补签）")
        }
    }
    /// 服务：后台轮询在跑才开快通道，`stop()` 关掉；收到新东西马上 `refresh()`，不等下一拍。
    func test_the_service_runs_the_fast_channel_while_polling_and_refreshes_on_receipt() throws {
        let mac = makePeer("Mac"), phone = makePeer("iPhone")
        try registerEverywhere([mac, phone])
        let hosts = RemoteGroupFakeHosts()
        var made = 0
        var received: (@Sendable () -> Void)?
        let service = RemoteDeviceGroupService(makeModel: { _ in mac.model }, makeFastChannel: { model, onReceive in
            made += 1
            received = onReceive
            return RemoteGroupFastChannel(local: model.local, identityKey: try! XCTUnwrap(model.identityKey),
                                          overlay: mac.overlay, advertises: false, browses: false) { _ in onReceive() }
        })
        service.tick()
        XCTAssertNil(service.fastChannel, "后台轮询没在跑时不开")
        service.start(hosts: hosts)
        awaitFast("开始轮询就开") { service.fastChannel != nil }
        service.tick()
        XCTAssertEqual(made, 1, "只建一个")

        // iPhone 的 join 经快通道到了 Mac（这里直接交给叠加层）：服务马上读，不等 10 秒那一拍。
        clock = clock.addingTimeInterval(1)
        phone.model.startJoin()
        let joinData = try XCTUnwrap(phone.overlay.snapshot().items.first { $0.account == RemoteGroupJoin.account(phone.id) }?.data)
        XCTAssertFalse(mac.overlay.ingest(records: [joinData], tombstones: [], from: phone.id).isEmpty)
        received?()
        awaitFast("收到就读") { mac.model.joinRequests.contains { $0.candidate.id == phone.id } }

        service.stop()
        XCTAssertNil(service.fastChannel, "停了就关")
    }
}
