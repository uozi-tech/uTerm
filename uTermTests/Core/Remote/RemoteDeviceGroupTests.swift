import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 设备组：几台设备共用一份名册（各自一份本机存储）走完加入、补签、移除，以及钥匙串圈里的冒充者
///（能读写名册里任何一条、没有任何组员的私钥、没见过新设备屏幕上的数）能做到什么、做不到什么。
@MainActor
final class RemoteDeviceGroupTests: XCTestCase {
    // XCTest 每个用例建一个新实例，所以每个用例各有一份名册。
    private let synced = RemoteMemorySyncedStorage()
    private lazy var roster = RemoteGroupRoster(storage: synced)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - 夹具

    private func makeDevice(_ name: String, platform: RemoteDevicePlatform = .mobile) -> RemoteDeviceGroup {
        let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
        let key = try! store.signingKey()
        let local = RemoteGroupDevice(id: UUID(), name: name, model: nil, platform: platform.rawValue,
                                      publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                      signingKey: key.publicKey.rawRepresentation, updatedAt: clock)
        return RemoteDeviceGroup(local: local, signingKey: key, roster: roster, store: store, now: { [unowned self] in clock })
    }

    /// App 重启：同一份本机存储、同一把签名私钥，内存里的东西全没了。
    private func restart(_ device: RemoteDeviceGroup) -> RemoteDeviceGroup {
        RemoteDeviceGroup(local: device.local, signingKey: device.signingKey, roster: roster, store: device.store,
                          now: { [unowned self] in clock })
    }

    private func tick(_ seconds: TimeInterval = 1) {
        clock = clock.addingTimeInterval(seconds)
    }

    private func refresh(_ devices: RemoteDeviceGroup...) {
        for device in devices {
            tick()
            device.refresh()
        }
    }

    private func shownCode(_ device: RemoteDeviceGroup, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .showingCode(let code, _) = device.joinState else {
            XCTFail("应当显示着数：\(String(describing: device.joinState))", file: file, line: line)
            return ""
        }
        return code
    }

    private func attemptsLeft(_ device: RemoteDeviceGroup) -> Int? {
        guard case .showingCode(_, let left) = device.joinState else { return nil }
        return left
    }

    /// 走完一次正常的加入，之后两台各刷新一次让回执落地。
    private func join(_ candidate: RemoteDeviceGroup, via member: RemoteDeviceGroup,
                      file: StaticString = #filePath, line: UInt = #line) {
        tick()
        candidate.startJoin()
        refresh(member)
        XCTAssertTrue(member.submitCode(shownCode(candidate, file: file, line: line), for: candidate.local.id),
                      file: file, line: line)
        refresh(candidate, member, candidate)
        XCTAssertEqual(candidate.joinState, .joined, file: file, line: line)
    }

    /// 本机认的组员（不含本机）。
    private func names(_ device: RemoteDeviceGroup) -> Set<String> {
        Set(device.members.filter { !$0.isLocal }.map(\.device.name))
    }

    private func keys(_ device: RemoteDeviceGroup) -> Set<Data> {
        Set(device.members.filter { !$0.isLocal }.map(\.device.signingKey))
    }

    private func admits(of key: Data) -> [RemoteGroupAdmit] {
        roster.load().admits.filter { $0.device.signingKey == key }
    }

    private func currentJoin(_ candidate: RemoteDeviceGroup) throws -> RemoteGroupJoin {
        try XCTUnwrap(roster.load().join(for: candidate.local.id))
    }

    // MARK: 冒充者

    /// 钥匙串圈里的冒充者：自己的两把钥匙，能往名册里写任何记录。
    private struct Attacker {
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        let device: RemoteGroupDevice

        init(name: String, id: UUID = UUID(), at clock: Date) {
            device = RemoteGroupDevice(id: id, name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                                       publicKey: identity.publicKey.rawRepresentation,
                                       signingKey: signing.publicKey.rawRepresentation, updatedAt: clock)
        }
    }

    private func save(_ record: RemoteGroupRecord, account: String? = nil) throws {
        try synced.save(record.encoded(), account: account ?? record.account)
    }

    /// 一个肯定不是 `code` 的数（冒充者猜的）。
    private func wrongGuess(_ code: String) -> String {
        String(format: "%06d", ((Int(code) ?? 0) + 1) % 1_000_000)
    }

    /// 冒充者以「组员」身份回一条 answer：自己的钥匙、猜的数。
    private func forgedAnswer(to join: RemoteGroupJoin, guess: String, from attacker: Attacker) throws -> RemoteGroupAnswer {
        let cpace = try RemoteGroupJoinCrypto.session(.responder, code: guess, candidate: join.device.id, sid: join.sid,
                                                      local: attacker.device)
        let keys = try cpace.finish(peerShare: join.share, peerAssociatedData: join.device.associatedData)
        let admission = RemoteGroupAdmission(admitterID: attacker.device.id, admitterKey: attacker.device.signingKey,
                                             admittedAt: RemoteGroupTime(clock))
        let package = RemoteGroupAdmissionPackage(member: RemoteGroupMember(device: attacker.device, admission: admission),
                                                  others: [], removals: [], admission: admission)
        let sealed = try RemoteGroupJoinCrypto.sealPackage(package, key: RemoteGroupJoinCrypto.packageKey(keys), sid: join.sid,
                                                           candidate: join.device.id, member: attacker.device.id)
        return RemoteGroupAnswer(candidate: join.device.id, sid: join.sid, member: attacker.device, share: cpace.publicShare,
                                 confirmation: keys.localConfirmation, package: sealed, createdAt: clock)
    }

    /// 冒充者以「新设备」身份跑完自己那一端，按组员的 answer 写出 done（它只知道自己猜的数）。
    private func forgedDone(_ cpace: CPaceSession, candidate: RemoteGroupDevice, answer: RemoteGroupAnswer) throws -> RemoteGroupDone {
        let keys = try cpace.finish(peerShare: answer.share, peerAssociatedData: answer.member.associatedData)
        let entry = try RemoteGroupJoinCrypto.sealEntry(candidate, key: RemoteGroupJoinCrypto.entryKey(keys), sid: answer.sid,
                                                        candidate: candidate.id, member: answer.member.id)
        return RemoteGroupDone(candidate: candidate.id, member: answer.member.id, sid: answer.sid,
                               confirmation: keys.localConfirmation, entry: entry, createdAt: clock)
    }

    private func answer(from member: RemoteDeviceGroup, to candidate: RemoteDeviceGroup) throws -> RemoteGroupAnswer {
        try answer(from: member, to: candidate.local.id)
    }

    private func answer(from member: RemoteDeviceGroup, to candidateID: UUID) throws -> RemoteGroupAnswer {
        try XCTUnwrap(roster.load().answers.first { $0.candidate == candidateID && $0.member.id == member.local.id })
    }

    // MARK: - 正常加入

    func test_two_solo_devices_join_and_the_member_admits_only_after_done() throws {
        let mac = makeDevice("Mac", platform: .mac), phone = makeDevice("iPhone")
        refresh(mac, phone, mac)
        XCTAssertFalse(mac.isInGroup)
        XCTAssertEqual(mac.members.map(\.isLocal), [true], "只有自己一台")
        XCTAssertEqual(mac.otherDevices.map(\.name), ["iPhone"], "名册里登记过的别的设备")

        phone.startJoin()
        let code = shownCode(phone)
        XCTAssertEqual(attemptsLeft(phone), RemoteDeviceGroup.codeAttempts)
        refresh(mac)
        XCTAssertEqual(mac.joinRequests.map(\.status), [.waitingForCode(attemptsLeft: RemoteDeviceGroup.submissionLimit)])
        XCTAssertTrue(mac.submitCode(String(code.prefix(3)) + " " + String(code.suffix(3)), for: phone.local.id), "空格不算")
        XCTAssertEqual(mac.joinRequests.map(\.status), [.verifying], "组员输完码不能当场知道对错")
        XCTAssertTrue(admits(of: phone.local.signingKey).isEmpty, "输码后、Ta 回来之前组员还不认新设备")

        refresh(phone)
        XCTAssertEqual(phone.joinState, .joined)
        XCTAssertEqual(names(phone), ["Mac"], "新设备一核对通过就拿到名单")
        XCTAssertNil(roster.load().join(for: phone.local.id), "加入后撤下请求")
        XCTAssertTrue(admits(of: phone.local.signingKey).isEmpty, "Ta 还没被组员读到")
        XCTAssertFalse(names(mac).contains("iPhone"))

        refresh(mac)
        XCTAssertEqual(names(mac), ["iPhone"])
        XCTAssertEqual(mac.joinRequests.map(\.status), [.admitted])
        XCTAssertEqual(admits(of: phone.local.signingKey).map(\.signer), [mac.local.id], "Ta 对了才签 admit")
        XCTAssertTrue(roster.load().answers.isEmpty, "组员收起 answer")

        refresh(phone, mac)
        XCTAssertTrue(roster.load().dones.isEmpty, "新设备看到 admit 后收起 done")
        XCTAssertTrue(mac.isInGroup)
        XCTAssertTrue(phone.isInGroup)
        XCTAssertEqual(phone.members.first { !$0.isLocal }?.device.name, "Mac")
        XCTAssertEqual(phone.members.first { $0.isLocal }?.admittedByName, "Mac")
        XCTAssertTrue(mac.otherDevices.isEmpty, "进了组的不再列在「其它设备」里")
        mac.dismissJoin(phone.local.id)
        XCTAssertTrue(mac.joinRequests.isEmpty)
    }

    func test_third_and_fourth_devices_converge_without_the_uninvolved_member() {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C"), d = makeDevice("D")
        join(b, via: a)
        // C 经 B 加入：A 什么都不用做，读到 B 签的 admit 就认 C。
        join(c, via: b)
        refresh(a, c)
        XCTAssertEqual(names(a), ["B", "C"])
        XCTAssertEqual(names(b), ["A", "C"])
        XCTAssertEqual(names(c), ["A", "B"])
        // D 经 C 加入：A、B 都不用做任何事。
        join(d, via: c)
        refresh(a, b, d)
        XCTAssertEqual(names(a), ["B", "C", "D"])
        XCTAssertEqual(names(b), ["A", "C", "D"])
        XCTAssertEqual(names(c), ["A", "B", "D"])
        XCTAssertEqual(names(d), ["A", "B", "C"])
        XCTAssertEqual(Set(admits(of: d.local.signingKey).map(\.signer)), [a.local.id, b.local.id, c.local.id],
                       "每台认它的组员各补签一条")
    }

    func test_countersign_keeps_a_device_after_its_admitter_is_removed_for_an_offline_member() {
        let a = makeDevice("A"), x = makeDevice("X"), y = makeDevice("Y"), b = makeDevice("B")
        join(x, via: a)
        join(y, via: a)
        refresh(x, y, a, x)
        XCTAssertEqual(names(x), ["A", "Y"])
        // X 离线期间：A 加了 B，Y 补签后把 A 移除（不连带）。
        join(b, via: a)
        refresh(y)
        XCTAssertTrue(names(y).contains("B"))
        y.remove([a.local.id])
        XCTAssertEqual(names(y), ["B", "X"])
        // X 回来：A 已被移除，A 签的 admit 不再认，但 Y 补签的那条还在。
        refresh(x)
        XCTAssertEqual(names(x), ["B", "Y"])
    }

    func test_removed_device_can_rejoin_with_a_new_code() {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C")
        join(b, via: a)
        join(c, via: a)
        refresh(b, c)
        a.remove([b.local.id])
        refresh(b, c)
        XCTAssertTrue(b.isSelfRemoved)
        XCTAssertEqual(names(c), ["A"])
        XCTAssertEqual(names(a), ["C"])

        join(b, via: a)
        XCTAssertFalse(b.isSelfRemoved)
        refresh(c, b, c)
        XCTAssertEqual(names(a), ["B", "C"])
        XCTAssertEqual(names(c), ["A", "B"], "重新加入的时间晚于那次移除，各台都重新认它")
        XCTAssertEqual(names(b), ["A", "C"])
        XCTAssertFalse(b.isSelfRemoved, "旧的那条移除早于这次加入，不再算数")
    }

    func test_member_still_verifies_after_restarting_before_done_arrives() throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        refresh(mac)
        XCTAssertTrue(mac.submitCode(shownCode(phone), for: phone.local.id))
        let restarted = restart(mac)
        refresh(phone, restarted)
        XCTAssertEqual(names(restarted), ["iPhone"], "期望的 Ta 存在本机，App 重启后照样核对")
        XCTAssertEqual(admits(of: phone.local.signingKey).map(\.signer), [mac.local.id])
    }

    func test_cascade_helper_lists_exactly_the_devices_a_device_added() {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C"), d = makeDevice("D")
        join(b, via: a)
        join(c, via: a)
        join(d, via: b)
        refresh(a, b, c, d, a, b, c, d)
        XCTAssertEqual(Set(a.devicesAdmitted(by: a.local.id).map(\.name)), ["B", "C"])
        XCTAssertEqual(Set(a.devicesAdmitted(by: b.local.id).map(\.name)), ["D"])
        XCTAssertEqual(Set(c.devicesAdmitted(by: b.local.id).map(\.name)), ["D"], "别的组员上也知道是谁加的")
        XCTAssertEqual(Set(d.devicesAdmitted(by: a.local.id).map(\.name)), ["B", "C"])
        XCTAssertTrue(a.devicesAdmitted(by: c.local.id).isEmpty)
        XCTAssertTrue(a.devicesAdmitted(by: UUID()).isEmpty)
    }

    func test_switching_groups_takes_no_old_member_along_even_with_replayed_countersigns() throws {
        let a = makeDevice("A"), b = makeDevice("B"), z = makeDevice("Z")
        join(b, via: a)
        join(z, via: a)
        refresh(b, z, a, b)
        let oldCountersigns = roster.load().admits.filter { $0.signer == b.local.id }
        XCTAssertEqual(Set(oldCountersigns.map(\.device.name)), ["A", "Z"])
        // Z 丢了，被移除；B 跟着删了自己给 Z 签的那条。
        a.remove([z.local.id])
        refresh(b)
        XCTAssertEqual(names(b), ["A"])

        let c = makeDevice("C"), d = makeDevice("D")
        join(d, via: c)
        // B 换到 C、D 的组：先离开原组，原来的组员不跟过去。
        join(b, via: c)
        refresh(d, a, b, c, d)
        XCTAssertEqual(names(b), ["C", "D"])
        XCTAssertEqual(names(c), ["B", "D"])
        XCTAssertEqual(names(d), ["B", "C"])
        XCTAssertEqual(names(a), [], "B 离开了 A 的组")

        // 冒充者把 B 当年在旧组签的 admit 写回来：新组认 B，但只认 B 进组之后签的。
        for admit in oldCountersigns { try save(.admit(admit)) }
        refresh(c, d)
        XCTAssertEqual(names(c), ["B", "D"], "已经移除的 Z 不能借旧签名进新组")
        XCTAssertEqual(names(d), ["B", "C"])
    }

    // MARK: - 签名记录的伪造

    func test_forged_admits_and_removes_change_nothing() throws {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C")
        join(b, via: a)
        join(c, via: a)
        refresh(b, c, a, b)
        let attacker = Attacker(name: "Evil", at: clock)
        let t = RemoteGroupTime(clock)
        let selfAdmission = RemoteGroupAdmission(admitterID: attacker.device.id, admitterKey: attacker.device.signingKey,
                                                 admittedAt: t)
        // 不认识的钥匙签的。
        try save(.admit(try RemoteGroupAdmit.make(device: attacker.device, admission: selfAdmission, signer: attacker.device,
                                                  signedAt: t, key: attacker.signing)))
        try save(.remove(try RemoteGroupRemove.make(target: b.local, removedAt: t, signer: attacker.device,
                                                    key: attacker.signing)))
        // 冒用 A 的 ID、配自己的钥匙签。
        var impostor = attacker.device
        impostor.id = a.local.id
        impostor.name = "A"
        try save(.admit(try RemoteGroupAdmit.make(device: attacker.device, admission: selfAdmission, signer: impostor,
                                                  signedAt: t, key: attacker.signing)))
        try save(.remove(try RemoteGroupRemove.make(target: c.local, removedAt: t, signer: impostor, key: attacker.signing)))
        // 改 A 签的真记录：名字、钥匙、时间都改不了（签名验不过）。
        let honest = try XCTUnwrap(roster.load().admits.first { $0.signer == a.local.id && $0.device.id == c.local.id })
        var renamed = honest
        renamed.device.name = "Evil"
        var rekeyed = honest
        rekeyed.device.signingKey = attacker.device.signingKey
        rekeyed.device.publicKey = attacker.device.publicKey
        var redated = honest
        redated.admission.admittedAt = RemoteGroupTime(clock.addingTimeInterval(86_400 * 365))
        for (index, forged) in [renamed, rekeyed, redated].enumerated() {
            try save(.admit(forged), account: "admit.forged.\(index)")
        }
        // 把 A 移除 C 的「签名」挪到别的目标上。
        var moved = try RemoteGroupRemove.make(target: c.local, removedAt: t, signer: a.local, key: a.signingKey)
        moved.signingKey = b.local.signingKey
        try save(.remove(moved), account: "remove.forged")

        refresh(a, b, c)
        XCTAssertEqual(names(a), ["B", "C"])
        XCTAssertEqual(names(b), ["A", "C"])
        XCTAssertEqual(names(c), ["A", "B"])
        XCTAssertFalse([a, b, c].contains { $0.isSelfRemoved })
        XCTAssertFalse(keys(a).contains(attacker.device.signingKey))
    }

    func test_records_signed_by_a_removed_member_are_ignored() throws {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C")
        join(b, via: a)
        join(c, via: a)
        refresh(b, c)
        a.remove([c.local.id])
        refresh(b)
        // 拿着 C 私钥的人（C 被偷了）在被移除之后签的记录。
        let evil = Attacker(name: "Evil", at: clock)
        tick(60)
        let t = RemoteGroupTime(clock)
        let admission = RemoteGroupAdmission(admitterID: c.local.id, admitterKey: c.local.signingKey, admittedAt: t)
        try save(.admit(try RemoteGroupAdmit.make(device: evil.device, admission: admission, signer: c.local, signedAt: t,
                                                  key: c.signingKey)))
        try save(.remove(try RemoteGroupRemove.make(target: b.local, removedAt: t, signer: c.local, key: c.signingKey)))
        try save(.remove(try RemoteGroupRemove.make(target: a.local, removedAt: t, signer: c.local, key: c.signingKey)))
        refresh(a, b)
        XCTAssertEqual(names(a), ["B"])
        XCTAssertEqual(names(b), ["A"])
        XCTAssertFalse(a.isSelfRemoved)
    }

    func test_fake_device_entries_change_no_membership() throws {
        let a = makeDevice("A"), b = makeDevice("B")
        join(b, via: a)
        refresh(a, b)
        let sameID = Attacker(name: "B", id: b.local.id, at: clock)
        let sameName = Attacker(name: "B", at: clock)
        try save(.device(sameID.device), account: "device.fake.1")
        try save(.device(sameName.device))
        refresh(a, b)
        XCTAssertEqual(keys(a), [b.local.signingKey], "名单按签名认人，条目谁都能写")
        XCTAssertEqual(keys(b), [a.local.signingKey])
        XCTAssertEqual(Set(a.otherDevices.map(\.signingKey)), [sameID.device.signingKey, sameName.device.signingKey],
                       "只出现在「其它设备」里（只显示，不可信）")
    }

    func test_member_signed_admit_dated_far_in_the_future_can_still_be_removed() throws {
        let a = makeDevice("A"), b = makeDevice("B"), s = makeDevice("S")
        join(b, via: a)
        join(s, via: a)
        refresh(b, s)
        // S 被偷了，移除之前小偷加了一台设备，并把加入时间写到很远的将来，想让它移不掉。
        let x = Attacker(name: "X", at: clock)
        let future = RemoteGroupTime(clock.addingTimeInterval(86_400 * 365 * 50))
        try save(.admit(try RemoteGroupAdmit.make(device: x.device, admission: RemoteGroupAdmission(
            admitterID: s.local.id, admitterKey: s.local.signingKey, admittedAt: future),
                                                  signer: s.local, signedAt: RemoteGroupTime(clock), key: s.signingKey)))
        refresh(a)
        XCTAssertTrue(names(a).contains("X"), "移除之前，被偷的组员能加设备（方案接受这一条）")
        a.remove([x.device.id, s.local.id])
        XCTAssertEqual(names(a), ["B"])
        // B 一直离线：同时读到 S 签的 admit 与 A 签的移除。
        refresh(b)
        XCTAssertEqual(names(b), ["A"], "移除时间取不早于被移除者的加入时间，写到将来也躲不过")
    }

    // MARK: - 加入协议上的攻击

    func test_fake_answer_burns_the_code_and_three_of_them_stop_the_join() throws {
        let phone = makeDevice("iPhone")
        let attacker = Attacker(name: "Mac", at: clock)
        phone.startJoin()
        var sids: [Data] = []
        for round in 1...RemoteDeviceGroup.codeAttempts {
            let join = try currentJoin(phone)
            sids.append(join.sid)
            try save(.answer(try forgedAnswer(to: join, guess: wrongGuess(shownCode(phone)), from: attacker)))
            refresh(phone)
            XCTAssertNotEqual(phone.joinState, .joined)
            if round < RemoteDeviceGroup.codeAttempts {
                XCTAssertEqual(attemptsLeft(phone), RemoteDeviceGroup.codeAttempts - round, "作废一个、换一个新数")
                XCTAssertNotEqual(try currentJoin(phone).sid, join.sid)
            }
        }
        guard case .failed = phone.joinState else { return XCTFail("作废够 3 次就停：\(String(describing: phone.joinState))") }
        XCTAssertNil(roster.load().join(for: phone.local.id), "停了就撤下请求")
        XCTAssertFalse(phone.isInGroup)
        XCTAssertEqual(Set(sids).count, RemoteDeviceGroup.codeAttempts)
    }

    func test_fake_join_is_never_admitted_even_when_the_real_code_is_typed_into_it() throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        let realCode = shownCode(phone)
        // 冒充者登记一台同名的「iPhone」发加入请求，它不知道真设备上的数，只能猜。
        let attacker = Attacker(name: "iPhone", at: clock)
        let sid = RemoteGroupJoinCrypto.newSessionID()
        let cpace = try RemoteGroupJoinCrypto.session(.initiator, code: wrongGuess(realCode), candidate: attacker.device.id,
                                                      sid: sid, local: attacker.device)
        try save(.join(RemoteGroupJoin(device: attacker.device, sid: sid, share: cpace.publicShare, createdAt: clock)))
        refresh(mac)
        XCTAssertEqual(mac.joinRequests.count, 2, "两条请求都弹出来，名字一样")
        // 你把真 iPhone 上的数输进了冒充者那条。
        XCTAssertTrue(mac.submitCode(realCode, for: attacker.device.id))
        let answer = try answer(from: mac, to: attacker.device.id)
        let attackerKeys = try cpace.finish(peerShare: answer.share, peerAssociatedData: answer.member.associatedData)
        XCTAssertNil(RemoteGroupJoinCrypto.openPackage(answer.package, key: RemoteGroupJoinCrypto.packageKey(attackerKeys),
                                                       sid: sid, candidate: attacker.device.id, member: mac.local.id),
                     "猜错了数就打不开入组包，看不到名单")
        try save(.done(try forgedDone(cpace, candidate: attacker.device, answer: answer)))
        refresh(mac)
        XCTAssertFalse(keys(mac).contains(attacker.device.signingKey))
        // 再换个随便的 done 也不行。
        try save(.done(RemoteGroupDone(candidate: attacker.device.id, member: mac.local.id, sid: sid,
                                       confirmation: Data(repeating: 7, count: 64), entry: Data([1, 2, 3]), createdAt: clock)))
        refresh(mac, mac)
        XCTAssertTrue(names(mac).isEmpty)
        XCTAssertTrue(admits(of: attacker.device.signingKey).isEmpty, "从没写过认它的 admit")
        XCTAssertEqual(mac.joinRequests.first { $0.id == attacker.device.id }?.status, .verifying)
    }

    func test_relayed_join_with_attacker_keys_and_the_honest_share_admits_no_one() throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        let attacker = Attacker(name: "iPhone", id: phone.local.id, at: clock)
        var relayed = try currentJoin(phone)
        relayed.device = attacker.device
        try save(.join(relayed))
        refresh(mac)
        XCTAssertTrue(mac.submitCode(shownCode(phone), for: phone.local.id))
        refresh(phone)
        XCTAssertEqual(attemptsLeft(phone), RemoteDeviceGroup.codeAttempts - 1, "两端看到的 AD 不同，Tb 对不上，数作废")
        refresh(mac, phone, mac)
        XCTAssertTrue(names(mac).isEmpty)
        XCTAssertTrue(names(phone).isEmpty)
        XCTAssertTrue(admits(of: attacker.device.signingKey).isEmpty)
        XCTAssertTrue(admits(of: phone.local.signingKey).isEmpty)
    }

    func test_relayed_join_with_honest_keys_and_an_attacker_share_admits_no_one() throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        let realCode = shownCode(phone)
        var relayed = try currentJoin(phone)
        let cpace = try RemoteGroupJoinCrypto.session(.initiator, code: wrongGuess(realCode), candidate: phone.local.id,
                                                      sid: relayed.sid, local: phone.local)
        relayed.share = cpace.publicShare
        try save(.join(relayed))
        refresh(mac)
        XCTAssertTrue(mac.submitCode(realCode, for: phone.local.id))
        let answer = try answer(from: mac, to: phone)
        try save(.done(try forgedDone(cpace, candidate: phone.local, answer: answer)))
        refresh(mac)
        XCTAssertTrue(names(mac).isEmpty, "冒充者没猜中数，算不出 Ta")
        refresh(phone)
        XCTAssertEqual(attemptsLeft(phone), RemoteDeviceGroup.codeAttempts - 1, "组员用的不是真设备的 Ya，Tb 对不上")
        XCTAssertTrue(names(phone).isEmpty)
        refresh(mac)
        XCTAssertTrue(admits(of: phone.local.signingKey).isEmpty)
    }

    func test_answer_with_swapped_member_keys_admits_no_one() throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        refresh(mac)
        XCTAssertTrue(mac.submitCode(shownCode(phone), for: phone.local.id))
        let attacker = Attacker(name: "Mac", id: mac.local.id, at: clock)
        var swapped = try answer(from: mac, to: phone)
        swapped.member = attacker.device
        try save(.answer(swapped))
        refresh(phone)
        XCTAssertEqual(attemptsLeft(phone), RemoteDeviceGroup.codeAttempts - 1, "新设备只认喂进 finish 的 AD")
        XCTAssertTrue(names(phone).isEmpty)
        refresh(mac)
        XCTAssertTrue(names(mac).isEmpty)
        XCTAssertTrue(roster.load().admits.isEmpty)
    }

    func test_replayed_answer_from_an_earlier_join_is_rejected() throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        refresh(mac)
        XCTAssertTrue(mac.submitCode(shownCode(phone), for: phone.local.id))
        let old = try answer(from: mac, to: phone)
        refresh(phone, mac, phone)
        phone.leave()
        refresh(mac)
        XCTAssertTrue(names(mac).isEmpty)

        phone.startJoin()
        let code = shownCode(phone)
        try save(.answer(old))
        refresh(phone)
        XCTAssertEqual(phone.joinState, .showingCode(code, attemptsLeft: RemoteDeviceGroup.codeAttempts),
                       "旧 sid 的 answer 不是给这一轮的，看都不看")
        var rewritten = old
        rewritten.sid = try currentJoin(phone).sid
        try save(.answer(rewritten))
        refresh(phone)
        XCTAssertEqual(attemptsLeft(phone), RemoteDeviceGroup.codeAttempts - 1, "改成新 sid 也对不上 Tb，只能让数作废")
        XCTAssertFalse(phone.isInGroup)
    }

    func test_replayed_done_from_an_earlier_join_is_rejected() throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        refresh(mac)
        XCTAssertTrue(mac.submitCode(shownCode(phone), for: phone.local.id))
        refresh(phone)
        let old = try XCTUnwrap(roster.load().dones.first)
        refresh(mac, phone)
        phone.leave()
        refresh(mac)
        XCTAssertTrue(names(mac).isEmpty)

        phone.startJoin()
        refresh(mac)
        XCTAssertTrue(mac.submitCode(shownCode(phone), for: phone.local.id))
        var rewritten = old
        rewritten.sid = try currentJoin(phone).sid
        try save(.done(old), account: "done.replay")
        try save(.done(rewritten))
        refresh(mac)
        XCTAssertTrue(names(mac).isEmpty, "旧的 Ta 对不上这一轮")
        XCTAssertTrue(admits(of: phone.local.signingKey).isEmpty)
        // 真设备回的 done 到了照常认。
        refresh(phone, mac)
        XCTAssertEqual(names(mac), ["iPhone"])
    }

    func test_each_code_is_tried_once_even_if_a_correct_answer_follows() throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        let attacker = Attacker(name: "Mac", at: clock)
        let join = try currentJoin(phone)
        var fake = try forgedAnswer(to: join, guess: wrongGuess(shownCode(phone)), from: attacker)
        fake.createdAt = clock.addingTimeInterval(-60)
        try save(.answer(fake))
        refresh(mac)
        XCTAssertTrue(mac.submitCode(shownCode(phone), for: phone.local.id), "你输的是对的")
        refresh(phone)
        XCTAssertEqual(attemptsLeft(phone), RemoteDeviceGroup.codeAttempts - 1, "先看到的那条不对，这个数就作废了")
        refresh(phone)
        XCTAssertNotEqual(phone.joinState, .joined, "同一个 sid 的第二条（哪怕是对的）不再处理")
        refresh(mac)
        XCTAssertEqual(mac.joinRequests.map(\.status), [.wrongCode(attemptsLeft: RemoteDeviceGroup.submissionLimit - 1)])
        XCTAssertTrue(names(mac).isEmpty)
    }

    func test_when_two_members_answer_only_the_first_is_used_and_the_other_closes_its_popup() throws {
        let a = makeDevice("A"), b = makeDevice("B"), phone = makeDevice("iPhone")
        join(b, via: a)
        refresh(a, b)
        phone.startJoin()
        refresh(a, b)
        XCTAssertTrue(a.submitCode(shownCode(phone), for: phone.local.id))
        tick()
        XCTAssertTrue(b.submitCode(shownCode(phone), for: phone.local.id))
        refresh(phone)
        XCTAssertEqual(phone.joinState, .joined)
        XCTAssertEqual(roster.load().dones.map(\.member), [a.local.id], "只回了先到的那台")
        refresh(b)
        XCTAssertEqual(b.joinRequests.map(\.status), [.verifying])
        refresh(a, b)
        XCTAssertEqual(names(b), ["A", "iPhone"])
        XCTAssertTrue(b.joinRequests.isEmpty, "别的组员先认了它，弹窗自己关掉")
        XCTAssertEqual(names(phone), ["A", "B"])
    }

    func test_wrong_code_shows_try_again_and_the_submission_limit_holds() throws {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        refresh(mac)
        XCTAssertTrue(mac.submitCode(wrongGuess(shownCode(phone)), for: phone.local.id))
        refresh(phone)
        XCTAssertEqual(attemptsLeft(phone), RemoteDeviceGroup.codeAttempts - 1)
        refresh(mac)
        XCTAssertEqual(mac.joinRequests.map(\.status), [.wrongCode(attemptsLeft: RemoteDeviceGroup.submissionLimit - 1)],
                       "不对，「iPhone」上换了新数")
        XCTAssertTrue(names(mac).isEmpty)

        XCTAssertTrue(mac.submitCode(wrongGuess(shownCode(phone)), for: phone.local.id))
        XCTAssertTrue(mac.submitCode(wrongGuess(shownCode(phone)), for: phone.local.id))
        XCTAssertFalse(mac.submitCode(shownCode(phone), for: phone.local.id), "10 分钟内最多输 3 次")
        refresh(phone, mac)
        XCTAssertEqual(mac.joinRequests.map(\.status), [.limitReached])
        XCTAssertFalse(mac.submitCode(shownCode(phone), for: phone.local.id))
        XCTAssertTrue(names(mac).isEmpty)
        XCTAssertTrue(roster.load().admits.isEmpty)

        tick(RemoteDeviceGroup.submissionWindow)
        phone.startJoin()
        refresh(mac)
        XCTAssertEqual(mac.joinRequests.map(\.status), [.waitingForCode(attemptsLeft: RemoteDeviceGroup.submissionLimit)],
                       "过了 10 分钟又能输")
    }

    func test_malformed_code_is_not_submitted_and_not_counted() {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        refresh(mac)
        XCTAssertFalse(mac.submitCode("12345", for: phone.local.id))
        XCTAssertFalse(mac.submitCode(shownCode(phone), for: UUID()), "没有这条请求")
        XCTAssertEqual(mac.joinRequests.map(\.status), [.waitingForCode(attemptsLeft: RemoteDeviceGroup.submissionLimit)])
    }

    // MARK: - 移出、过期、取消

    func test_removed_device_stops_writing_and_its_later_records_are_ignored() throws {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C")
        join(b, via: a)
        join(c, via: a)
        refresh(b, c, a)
        a.remove([c.local.id])
        let before = synced.loadAll()
        refresh(c)
        XCTAssertTrue(c.isSelfRemoved)
        XCTAssertEqual(synced.loadAll(), before, "发现自己被移出的那一轮就不写")
        let other = makeDevice("Other")
        other.startJoin()
        let afterJoin = synced.loadAll()
        refresh(c, c)
        XCTAssertEqual(synced.loadAll(), afterJoin, "之后也不登记、不补签、不回请求")
        XCTAssertTrue(c.joinRequests.isEmpty)
        XCTAssertFalse(c.submitCode(shownCode(other), for: other.local.id))

        // 拿着 C 私钥的人在移除之后签的：B 一直没刷新，同时读到 C 被移除和这两条，也不认。
        let t = RemoteGroupTime(clock)
        try save(.remove(try RemoteGroupRemove.make(target: b.local, removedAt: t, signer: c.local, key: c.signingKey)))
        try save(.remove(try RemoteGroupRemove.make(target: a.local, removedAt: t, signer: c.local, key: c.signingKey)))
        refresh(a, b)
        XCTAssertEqual(names(a), ["B"])
        XCTAssertEqual(names(b), ["A"])
        XCTAssertFalse(b.isSelfRemoved)

        // 确认之后回到只有自己一台。
        c.leave()
        XCTAssertFalse(c.isSelfRemoved)
        XCTAssertFalse(c.isInGroup)
    }

    func test_code_expires_after_ten_minutes() {
        let phone = makeDevice("iPhone")
        phone.startJoin()
        tick(RemoteDeviceGroup.codeLifetime + 1)
        phone.refresh()
        guard case .failed = phone.joinState else { return XCTFail("过期就停：\(String(describing: phone.joinState))") }
        XCTAssertNil(roster.load().join(for: phone.local.id))
    }

    func test_cancel_and_restart_clear_the_join_request() {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        phone.cancelJoin()
        XCTAssertNil(phone.joinState)
        XCTAssertNil(roster.load().join(for: phone.local.id))
        phone.startJoin()
        let restarted = restart(phone)
        refresh(restarted)
        XCTAssertNil(roster.load().join(for: phone.local.id), "App 重开后内存里的数没了，旧请求撤下")
        refresh(mac)
        XCTAssertTrue(mac.joinRequests.isEmpty)
    }

    func test_dismissed_request_stays_hidden_for_that_round() {
        let mac = makeDevice("Mac"), phone = makeDevice("iPhone")
        phone.startJoin()
        refresh(mac)
        mac.dismissJoin(phone.local.id)
        refresh(mac)
        XCTAssertTrue(mac.joinRequests.isEmpty)
        phone.startJoin()
        refresh(mac)
        XCTAssertEqual(mac.joinRequests.count, 1, "重新点了「加入」是新的一轮")
    }

    // MARK: - 存储

    func test_background_construction_creates_neither_identity_nor_signing_key() throws {
        let secrets = RemoteMemoryStorage()
        let identity = RemoteIdentityStore(role: .hosts, storage: secrets)
        let store = RemoteGroupLocalStore(storage: secrets)
        XCTAssertNil(RemoteDeviceGroup.make(name: "Mac", model: nil, identity: identity, store: store, roster: roster,
                                            createsIdentity: false))
        XCTAssertNil(try secrets.load("identity"), "后台不生成远控身份")
        XCTAssertNil(store.existingSigningKey(), "也不生成签名私钥")

        _ = try identity.localIdentity()
        XCTAssertNil(RemoteDeviceGroup.make(name: "Mac", model: nil, identity: identity, store: store, roster: roster,
                                            createsIdentity: false), "有身份、没签名私钥也不行")
        XCTAssertNil(store.existingSigningKey())

        let foreground = try XCTUnwrap(RemoteDeviceGroup.make(name: "Mac", model: nil, identity: identity, store: store,
                                                              roster: roster, createsIdentity: true))
        let key = try XCTUnwrap(store.existingSigningKey())
        XCTAssertEqual(foreground.local.signingKey, key.publicKey.rawRepresentation)
        let background = try XCTUnwrap(RemoteDeviceGroup.make(name: "Mac", model: nil, identity: identity, store: store,
                                                              roster: roster, createsIdentity: false))
        XCTAssertEqual(background.local.signingKey, foreground.local.signingKey, "都有了以后后台照样能用")
        background.refresh()
        XCTAssertEqual(store.existingSigningKey()?.rawRepresentation, key.rawRepresentation)
    }

    func test_unreadable_local_store_reports_an_error_and_keeps_the_roster_untouched() {
        let local = RemoteGroupDevice(id: UUID(), name: "Mac", model: nil, platform: nil,
                                      publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                      signingKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, updatedAt: clock)
        let model = RemoteDeviceGroup(local: local, signingKey: .init(), roster: roster,
                                      store: RemoteGroupLocalStore(storage: FailingSecretStorage()), now: { [unowned self] in clock })
        model.refresh()
        XCTAssertNotNil(model.storageError)
        XCTAssertTrue(synced.loadAll().isEmpty)
    }
}
