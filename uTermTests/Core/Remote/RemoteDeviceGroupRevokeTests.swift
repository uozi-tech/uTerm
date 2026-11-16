import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// G3（docs/remote-device-group-design.md §7.3）：移除之后请 Mac 撤销、重装过的设备、组里的 Mac 互认、
/// 回滚只凭被移除的组员开通才记下的 Mac。几台设备共用一份内存名册，各自一份本机存储和一份假的「配对过的 Mac」
/// （`RemoteGroupFakeHosts`），Mac 组员另有一份假的被控端（`RemoteGroupFakeLocalHost`），走真的加入流程。
@MainActor
final class RemoteDeviceGroupRevokeTests: XCTestCase {
    private let synced = RemoteMemorySyncedStorage()
    private lazy var roster = RemoteGroupRoster(storage: synced)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    /// 模型只弱引用 `hosts` / `localHost`：这里拿着。按模型对象分（重装过的设备和旧的那份 ID 相同）。
    private var fakes: [ObjectIdentifier: RemoteGroupFakeHosts] = [:]
    private var localHosts: [ObjectIdentifier: RemoteGroupFakeLocalHost] = [:]

    // MARK: - 夹具

    private func makeDevice(_ name: String, platform: RemoteDevicePlatform = .mobile, id: UUID = UUID()) -> RemoteDeviceGroup {
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
        let key = try! store.signingKey()
        let local = RemoteGroupDevice(id: id, name: name, model: nil, platform: platform.rawValue,
                                      publicKey: identity.publicKey.rawRepresentation,
                                      signingKey: key.publicKey.rawRepresentation, updatedAt: clock)
        let group = RemoteDeviceGroup(local: local, signingKey: key, identityKey: identity, roster: roster, store: store,
                                      now: { [unowned self] in clock })
        let fake = RemoteGroupFakeHosts()
        fakes[ObjectIdentifier(group)] = fake
        group.hosts = fake
        return group
    }

    private func fake(_ device: RemoteDeviceGroup) -> RemoteGroupFakeHosts { fakes[ObjectIdentifier(device)]! }

    /// 给一台 Mac 组员接上它自己的被控端。
    private func localHost(_ device: RemoteDeviceGroup) -> RemoteGroupFakeLocalHost {
        let host = RemoteGroupFakeLocalHost()
        host.hostID = device.local.id
        localHosts[ObjectIdentifier(device)] = host
        device.localHost = host
        return host
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

    private func settle(_ devices: RemoteDeviceGroup..., file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while devices.contains(where: { $0.vouchesInFlight > 0 }) {
            if Date() > deadline {
                XCTFail("还有请求没问完", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// 刷新几轮、每轮等请求问完。
    private func converge(_ devices: RemoteDeviceGroup..., rounds: Int = 3) async {
        for _ in 0..<rounds {
            for device in devices {
                tick()
                device.refresh()
            }
            for device in devices { await settleOne(device) }
        }
    }

    private func settleOne(_ device: RemoteDeviceGroup) async {
        let deadline = Date().addingTimeInterval(5)
        while device.vouchesInFlight > 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(device.vouchesInFlight, 0, "还有请求没问完")
    }

    private func join(_ candidate: RemoteDeviceGroup, via member: RemoteDeviceGroup,
                      file: StaticString = #filePath, line: UInt = #line) {
        tick()
        candidate.startJoin()
        refresh(member)
        guard case .showingCode(let code, _) = candidate.joinState else {
            return XCTFail("应当显示着数", file: file, line: line)
        }
        XCTAssertTrue(member.submitCode(code, for: candidate.local.id), file: file, line: line)
        refresh(candidate, member)
        XCTAssertEqual(candidate.joinState, .joined, file: file, line: line)
        XCTAssertTrue(member.members.contains { $0.device.signingKey == candidate.local.signingKey }, file: file, line: line)
    }

    private func isMember(_ device: RemoteDeviceGroup, of other: RemoteDeviceGroup) -> Bool {
        other.members.contains { $0.device.signingKey == device.local.signingKey }
    }

    private func save(_ record: RemoteGroupRecord) throws {
        try synced.save(record.encoded(), account: record.account)
    }

    private func signedGrant(by signer: RemoteDeviceGroup, for target: RemoteGroupDevice,
                             host: RemoteGroupHostInfo) throws -> RemoteGroupHostGrant {
        try RemoteGroupHostGrant.make(device: target, host: host, outcome: RemoteVouchResult.Outcome.added.rawValue,
                                      reason: nil, internetAccess: nil, relay: nil, signer: signer.local,
                                      signedAt: RemoteGroupTime(clock), key: signer.signingKey)
    }

    private func hostInfo(_ name: String, id: UUID = UUID(), key: Data? = nil) -> RemoteGroupHostInfo {
        RemoteGroupHostInfo(id: id, name: name,
                            publicKey: key ?? Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                            model: "Mac Studio", platform: RemoteDevicePlatform.mac.rawValue)
    }

    private func selfGrants(of mac: RemoteDeviceGroup) -> [RemoteGroupHostGrant] {
        roster.load().grants.filter { $0.signer == mac.local.id && $0.host.id == mac.local.id }
    }

    // MARK: - 移除之后请 Mac 撤销

    func test_removal_asks_each_paired_mac_once_and_the_removed_list_empties_when_all_are_done() async {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C")
        let mini = fake(a).addMac("Mac mini"), laptop = fake(a).addMac("MacBook Pro", online: false)
        fake(c).addMac("C 的 Mac")
        join(b, via: a)
        join(c, via: a)
        await converge(a, b, c)
        XCTAssertTrue(fake(a).revokeCalls.isEmpty)

        let removedKey = c.local.publicKey
        a.remove([c.local.id])
        refresh(a)
        await settle(a)
        XCTAssertEqual(fake(a).revokeCalls(at: mini.id), [c.local.id])
        XCTAssertEqual(fake(a).events[mini.id]?.last, .revoke(device: c.local.id, key: removedKey),
                       "带着被移除那台的远控公钥")
        XCTAssertEqual(a.removedDevices.map(\.name), ["C"])
        XCTAssertEqual(a.removedDevices.first?.waitingHosts, ["MacBook Pro"], "不在线的那台还没撤")

        fake(a).online.insert(laptop.id)
        refresh(a)
        await settle(a)
        XCTAssertEqual(fake(a).revokeCalls(at: laptop.id), [c.local.id])
        XCTAssertTrue(a.removedDevices.isEmpty, "都撤完了，「已移除的设备」不显示")

        for _ in 0..<3 {
            tick(7 * 3600)
            await converge(a, b, c, rounds: 1)
        }
        XCTAssertEqual(fake(a).revokeCalls.count, 2, "撤完了不再问")
        XCTAssertTrue(fake(b).revokeCalls.isEmpty, "B 没配对 Mac")
        XCTAssertTrue(c.isSelfRemoved)
        XCTAssertTrue(fake(c).revokeCalls.isEmpty, "被移除的设备自己什么都不撤")
        XCTAssertTrue(c.removedDevices.isEmpty)
    }

    func test_revoke_retry_rules_unreachable_a_minute_too_old_six_hours_not_in_family_is_done() async {
        let a = makeDevice("A"), b = makeDevice("B")
        let away = fake(a).addMac("不在家的 Mac"), old = fake(a).addMac("旧的 Mac")
        let other = fake(a).addMac("别人配对的 Mac"), unknown = fake(a).addMac("不认识它的 Mac")
        fake(a).revokeReplies = [away.id: .unreachable, old.id: .tooOld, other.id: .outcome(.notInFamily),
                                 unknown.id: .outcome(.notTrusted)]
        join(b, via: a)
        await converge(a, b)
        a.remove([b.local.id])
        refresh(a)
        await settle(a)
        for mac in [away, old, other, unknown] {
            XCTAssertEqual(fake(a).revokeCalls(at: mac.id), [b.local.id], mac.name)
        }
        XCTAssertEqual(Set(a.removedDevices.first?.waitingHosts ?? []), [away.name, old.name],
                       "不是同一组的、本来就不认识的算做完")

        tick(30)
        refresh(a)
        await settle(a)
        XCTAssertEqual(fake(a).revokeCalls(at: away.id).count, 1, "60 秒内不再问")
        tick(31)
        refresh(a)
        await settle(a)
        XCTAssertEqual(fake(a).revokeCalls(at: away.id).count, 2, "连不上的 60 秒后再问")
        XCTAssertEqual(fake(a).revokeCalls(at: old.id).count, 1, "太旧的 6 小时内不再问")

        fake(a).revokeReplies[away.id] = .outcome(.revoked)
        tick(61)
        refresh(a)
        await settle(a)
        XCTAssertEqual(a.removedDevices.first?.waitingHosts, [old.name])
        fake(a).revokeReplies[old.id] = .outcome(.revoked)
        tick(5 * 3600)
        refresh(a)
        await settle(a)
        XCTAssertEqual(fake(a).revokeCalls(at: old.id).count, 1)
        tick(3600)
        refresh(a)
        await settle(a)
        XCTAssertEqual(fake(a).revokeCalls(at: old.id).count, 2, "6 小时后再问")
        XCTAssertTrue(a.removedDevices.isEmpty)
        XCTAssertEqual(fake(a).revokeCalls(at: other.id).count, 1)
        XCTAssertEqual(fake(a).revokeCalls(at: unknown.id).count, 1)
    }

    func test_removal_learned_while_offline_is_revoked_when_the_member_comes_back() async {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C")
        let mac = fake(b).addMac("Mac mini")
        join(b, via: a)
        join(c, via: a)
        await converge(a, b, c)
        // B 不在线的时候 A 移除了 C；B 回来读到这条移除，照样去撤。
        a.remove([c.local.id])
        await converge(a, c)
        XCTAssertTrue(fake(b).revokeCalls.isEmpty)
        refresh(b)
        await settle(b)
        XCTAssertFalse(isMember(c, of: b))
        XCTAssertEqual(fake(b).revokeCalls(at: mac.id), [c.local.id])
    }

    func test_every_cascaded_removal_is_revoked() async {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C")
        let mac = fake(a).addMac("Mac mini")
        join(b, via: a)
        join(c, via: b)
        await converge(a, b, c)
        let cascade = a.devicesAdmitted(by: b.local.id)
        XCTAssertEqual(cascade.map(\.id), [c.local.id])
        a.remove([b.local.id] + cascade.map(\.id))
        await converge(a)
        XCTAssertEqual(Set(fake(a).revokeCalls(at: mac.id)), [b.local.id, c.local.id])
        XCTAssertTrue(a.removedDevices.isEmpty)
    }

    func test_revokes_still_run_after_removing_the_last_other_member_and_macs_paired_later_are_not_asked() async {
        let a = makeDevice("A"), b = makeDevice("B")
        let mac = fake(a).addMac("Mac mini")
        join(b, via: a)
        await converge(a, b)
        a.remove([b.local.id])
        XCTAssertFalse(a.isInGroup)
        await converge(a)
        XCTAssertEqual(fake(a).revokeCalls(at: mac.id), [b.local.id], "只剩自己一台也照样撤")

        let later = fake(a).addMac("后来配对的 Mac")
        await converge(a)
        XCTAssertTrue(fake(a).revokeCalls(at: later.id).isEmpty, "移除之后才配对的 Mac 不问")
        XCTAssertTrue(a.removedDevices.isEmpty)
    }

    func test_a_device_that_joins_later_does_not_revoke_the_groups_old_removals() async {
        let a = makeDevice("A"), b = makeDevice("B"), d = makeDevice("D")
        fake(d).addMac("D 的 Mac")
        join(b, via: a)
        await converge(a, b)
        a.remove([b.local.id])
        await converge(a)
        join(d, via: a)
        await converge(a, d)
        XCTAssertTrue(fake(d).revokeCalls.isEmpty, "组里早就处理过的移除，新进组的设备不去撤")
        XCTAssertTrue(d.removedDevices.isEmpty)
    }

    // MARK: - 重装过的设备

    func test_reinstalled_device_replaces_its_old_self_and_macs_revoke_the_old_key_before_vouching_the_new_one() async throws {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C")
        let mac = fake(a).addMac("Mac mini")
        join(b, via: a)
        join(c, via: b)
        await converge(a, b, c)
        XCTAssertEqual(fake(a).events[mac.id]?.filter { $0 == .vouch(device: b.local.id, key: b.local.publicKey) }.count, 1)

        // B 重装了 uTerm：同一个设备 ID，新的两把钥匙，本机状态是空的。经 A 重新加入；A 的 Mac 这时还撤不了
        // （太旧，6 小时后再问；这段时间 Mac 照样连得上）。
        let oldKey = b.local.publicKey
        let reinstalled = makeDevice("B", id: b.local.id)
        fake(a).revokeReplies[mac.id] = .tooOld
        join(reinstalled, via: a)
        XCTAssertFalse(isMember(b, of: a), "认下新的这一份时移除了旧的")
        XCTAssertTrue(isMember(reinstalled, of: a))
        XCTAssertTrue(isMember(c, of: a), "不连带：旧的那份加进来的设备不受影响")
        XCTAssertEqual(roster.load().removes.filter { $0.deviceID == b.local.id }.map(\.publicKey), [oldKey])
        await settle(a)
        XCTAssertEqual(fake(a).events[mac.id]?.last, .revoke(device: b.local.id, key: oldKey))
        tick(61)
        refresh(a)
        await settle(a)
        XCTAssertEqual(fake(a).events[mac.id]?.last, .revoke(device: b.local.id, key: oldKey),
                       "旧钥匙没撤掉之前不替新钥匙开通")

        fake(a).revokeReplies[mac.id] = .outcome(.revoked)
        tick(6 * 3600)
        refresh(a)
        await settle(a)
        let events = fake(a).events[mac.id] ?? []
        let revokedAt = try XCTUnwrap(events.lastIndex(of: .revoke(device: b.local.id, key: oldKey)))
        let vouchedAt = try XCTUnwrap(events.firstIndex(of: .vouch(device: b.local.id, key: reinstalled.local.publicKey)))
        XCTAssertGreaterThan(vouchedAt, revokedAt, "先撤旧钥匙、再开通新的")
        let afterRevoke = events.suffix(from: revokedAt + 1)
        XCTAssertFalse(afterRevoke.contains { if case .revoke = $0 { true } else { false } },
                       "撤成功之后只剩开通（连同把别的组员再问一遍）")

        await converge(a, c, reinstalled)
        XCTAssertFalse(isMember(b, of: c))
        XCTAssertTrue(isMember(reinstalled, of: c))
        XCTAssertFalse(reinstalled.members.contains { !$0.isLocal && $0.device.id == reinstalled.local.id },
                       "新的这一份不把旧的自己当组员")
        XCTAssertEqual(Set(fake(reinstalled).adopted.map(\.hostID)), [mac.id])
        XCTAssertTrue(fake(reinstalled).revokeCalls.isEmpty)
    }

    // MARK: - 组里的 Mac 互认

    func test_mac_member_records_the_others_as_controllers_only_when_in_the_group_and_allowed() async throws {
        let mini = makeDevice("Mac mini", platform: .mac), phone = makeDevice("iPhone"), pad = makeDevice("iPad")
        let controlled = localHost(mini)
        controlled.accepts = false
        await converge(mini)
        join(phone, via: mini)
        join(pad, via: phone)
        await converge(mini, phone, pad)
        XCTAssertTrue(controlled.addCalls.isEmpty, "没开被控或「允许担保」时不记")

        controlled.accepts = true
        controlled.ownerRevoke(pad.local.id)
        await converge(mini, phone, pad)
        XCTAssertEqual(controlled.addCalls, [phone.local.id], "Mac 主人撤销过的不自动加")
        XCTAssertEqual(controlled.peers[phone.local.id]?.isFromGroup, true)
        let grants = selfGrants(of: mini)
        XCTAssertEqual(grants.map(\.deviceID), [phone.local.id])
        XCTAssertEqual(grants.first?.host.publicKey, mini.local.publicKey, "签名者就是这台 Mac，写的是它自己的远控公钥")
        XCTAssertEqual(grants.first?.internetAccess, false)
        XCTAssertEqual(Set(fake(phone).adopted.map(\.hostID)), [mini.local.id], "iPhone 照 §7.2 收下这台 Mac")
        XCTAssertEqual(fake(phone).adopted.first?.hostKey, mini.local.publicKey)
        XCTAssertTrue(fake(pad).adopted.isEmpty)

        await converge(mini, phone, pad)
        XCTAssertEqual(controlled.addCalls, [phone.local.id], "有了结果不再记")
    }

    func test_mac_member_waits_when_the_service_process_is_unavailable_and_writes_already_known_for_manual_pairings() async {
        let mini = makeDevice("Mac mini", platform: .mac), phone = makeDevice("iPhone")
        let controlled = localHost(mini)
        controlled.available = false
        controlled.pairManually(phone.local)
        join(phone, via: mini)
        await converge(mini)
        XCTAssertTrue(selfGrants(of: mini).isEmpty, "转不到远控进程：不写")
        controlled.available = true
        tick(30)
        await converge(mini, rounds: 1)
        XCTAssertTrue(selfGrants(of: mini).isEmpty, "一分钟内不再试")
        tick(31)
        await converge(mini, rounds: 1)
        XCTAssertEqual(selfGrants(of: mini).map(\.outcome), [RemoteVouchResult.Outcome.alreadyTrusted.rawValue],
                       "手动配对过的：早就认识，结果照样写给它")
        XCTAssertEqual(controlled.peers[phone.local.id]?.isFromGroup, false, "来路不改")
    }

    func test_mac_member_drops_removed_members_without_blocking_but_keeps_manual_pairings() async {
        let mini = makeDevice("Mac mini", platform: .mac), phone = makeDevice("iPhone"), pad = makeDevice("iPad")
        let controlled = localHost(mini)
        controlled.pairManually(pad.local)
        join(phone, via: mini)
        join(pad, via: mini)
        await converge(mini, phone, pad)
        XCTAssertEqual(Set(selfGrants(of: mini).map(\.deviceID)), [phone.local.id, pad.local.id])

        pad.remove([phone.local.id])
        await converge(pad, mini)
        XCTAssertNil(controlled.peers[phone.local.id], "组员被移除：这台 Mac 自己撤掉它")
        XCTAssertFalse(controlled.blocked.contains(phone.local.id), "不拉黑")
        XCTAssertFalse(selfGrants(of: mini).contains { $0.deviceID == phone.local.id })

        mini.remove([pad.local.id])
        await converge(mini)
        XCTAssertNotNil(controlled.peers[pad.local.id], "在这台 Mac 上手动配对的不动")
        XCTAssertFalse(controlled.dropCalls.contains(pad.local.id))
    }

    func test_mac_owner_revoking_a_group_added_controller_deletes_the_grant_and_it_is_not_added_back() async {
        let mini = makeDevice("Mac mini", platform: .mac), phone = makeDevice("iPhone")
        let controlled = localHost(mini)
        join(phone, via: mini)
        await converge(mini, phone)
        XCTAssertEqual(selfGrants(of: mini).count, 1)
        controlled.ownerRevoke(phone.local.id)
        tick(120)
        await converge(mini, phone)
        XCTAssertTrue(selfGrants(of: mini).isEmpty, "过时的结果删掉")
        XCTAssertEqual(controlled.addCalls, [phone.local.id], "拉黑的不再加回来")
        XCTAssertNil(controlled.peers[phone.local.id])
    }

    func test_mac_that_leaves_the_group_drops_the_controllers_it_added_for_the_group() async {
        let mini = makeDevice("Mac mini", platform: .mac), phone = makeDevice("iPhone")
        let controlled = localHost(mini)
        join(phone, via: mini)
        await converge(mini, phone)
        XCTAssertNotNil(controlled.peers[phone.local.id])
        mini.leave()
        await converge(mini)
        XCTAssertNil(controlled.peers[phone.local.id])
        XCTAssertTrue(controlled.blocked.isEmpty)
    }

    /// 组里的 Mac：被移除的组员担保过的设备（谁都不知道的钥匙 Z）跟着撤掉；正常的组员被连带撤掉后下一轮由本机记回来；
    /// 被移除的设备担保回来的，下一轮又被撤掉。都不拉黑。
    func test_mac_member_drops_what_a_removed_member_vouched_and_re_adds_the_honest_members() async throws {
        let mini = makeDevice("Mac mini", platform: .mac), phone = makeDevice("iPhone"), thief = makeDevice("被偷的 iPad")
        let honest = makeDevice("MacBook")
        let controlled = localHost(mini)
        join(phone, via: mini)
        join(thief, via: mini)
        join(honest, via: mini)
        await converge(mini, phone, thief, honest)
        XCTAssertEqual(controlled.peers[thief.local.id]?.isFromGroup, true)
        // 换成：honest 在这台 Mac 上是 thief 担保的（消息 50）。
        controlled.peers[honest.local.id] = nil
        XCTAssertTrue(controlled.vouch(honest.local, by: thief.local.id))
        let zKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let z = RemoteGroupDevice(id: UUID(), name: "Z", model: nil, platform: "mobile", publicKey: zKey,
                                  signingKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, updatedAt: clock)
        XCTAssertTrue(controlled.vouch(z, by: thief.local.id))

        phone.remove([thief.local.id])
        await converge(phone, mini)
        XCTAssertNil(controlled.peers[thief.local.id])
        XCTAssertNil(controlled.peers[z.id], "被移除的组员担保的 Z 一起撤掉")
        XCTAssertEqual(controlled.dropCalls, [thief.local.id], "一次撤销连带撤掉")
        // 刚记过它的一分钟内不再问；之后记回来。
        tick(61)
        await converge(mini)
        XCTAssertNotNil(controlled.peers[honest.local.id], "被连带撤掉的正常组员记回来")
        XCTAssertEqual(controlled.peers[honest.local.id]?.isFromGroup, true)
        XCTAssertTrue(controlled.blocked.isEmpty)

        // 被移除的设备又被担保回来（比如另一台被移除的设备还连着时做的）：下一轮再撤掉，它担保的也一样。
        controlled.peers[z.id] = RemoteGroupLocalController(id: z.id, publicKey: zKey, isVouched: true, isFromGroup: false,
                                                            vouchedBy: thief.local.id)
        await converge(mini, rounds: 1)
        XCTAssertNil(controlled.peers[z.id], "由被移除的设备担保的，下一轮就撤掉")
        XCTAssertNotNil(controlled.peers[phone.local.id])
        XCTAssertNotNil(controlled.peers[honest.local.id])
    }

    /// 组员在一台 Mac 上撤成功（`revoked`）之后，把这台 Mac 上别的组员都再问一遍（Mac 可能连带撤掉了正常的组员），
    /// 只问一遍；撤不动（`not-trusted`）不补问。
    func test_member_re_asks_the_mac_once_after_a_successful_revoke_and_not_after_a_no_op() async {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C"), d = makeDevice("D")
        let mac = fake(a).addMac("Mac mini")
        join(b, via: a)
        join(c, via: a)
        join(d, via: a)
        await converge(a, b, c, d)
        XCTAssertEqual(Set(fake(a).calls(at: mac.id)), [b.local.id, c.local.id, d.local.id])
        let before = fake(a).calls(at: mac.id).count

        tick(61)
        a.remove([c.local.id])
        await converge(a, rounds: 1)
        XCTAssertEqual(Set(fake(a).calls(at: mac.id).dropFirst(before)), [b.local.id, d.local.id],
                       "撤成功后把还在组里的再问一遍")
        let after = fake(a).calls(at: mac.id).count
        for _ in 0..<3 {
            tick(7 * 3600)
            await converge(a, b, d, rounds: 1)
        }
        XCTAssertEqual(fake(a).calls(at: mac.id).count, after, "只补问一遍")

        fake(a).revokeReplies[mac.id] = .outcome(.notTrusted)
        tick(61)
        a.remove([d.local.id])
        await converge(a)
        XCTAssertEqual(fake(a).calls(at: mac.id).count, after, "Mac 本来就不认它：没有连带，不补问")
        XCTAssertTrue(a.removedDevices.isEmpty)
    }

    func test_grant_that_claims_a_member_mac_with_another_key_is_ignored() async throws {
        let mini = makeDevice("Mac mini", platform: .mac), phone = makeDevice("iPhone"), thief = makeDevice("被偷的 iPad")
        join(phone, via: mini)
        join(thief, via: mini)
        await converge(mini, phone, thief)
        // 被偷的组员签一条「Mac mini 记下了 iPhone」，公钥换成攻击者的：iPhone 不收。
        let forged = hostInfo("Mac mini", id: mini.local.id)
        try save(.grant(signedGrant(by: thief, for: phone.local, host: forged)))
        refresh(phone)
        XCTAssertFalse(fake(phone).adopted.contains { $0.hostID == mini.local.id })
        // Mac 自己签、但公钥不是它的：同样不收。
        try save(.grant(signedGrant(by: mini, for: phone.local, host: forged)))
        refresh(phone)
        XCTAssertFalse(fake(phone).adopted.contains { $0.hostID == mini.local.id })
    }

    // MARK: - 回滚只凭被移除的组员开通才记下的 Mac

    func test_mac_adopted_only_from_a_stolen_members_grant_is_rolled_back_when_it_is_removed() async throws {
        let a = makeDevice("A"), thief = makeDevice("被偷的 iPhone"), b = makeDevice("B")
        join(thief, via: a)
        join(b, via: a)
        await converge(a, thief, b)
        // 被偷的组员在被移除之前签了一条能用的结果，Mac 的公钥是攻击者的。
        let attacker = hostInfo("工作室 Mac")
        try save(.grant(signedGrant(by: thief, for: a.local, host: attacker)))
        refresh(a)
        XCTAssertTrue(fake(a).pairedHosts().contains { $0.id == attacker.id && $0.publicKey == attacker.publicKey })

        b.remove([thief.local.id])
        await converge(b, a)
        XCTAssertEqual(fake(a).dropped, [attacker.id])
        XCTAssertFalse(fake(a).pairedHosts().contains { $0.id == attacker.id }, "A 不再列出它")
        XCTAssertFalse(fake(a).forgotten.contains(attacker.id), "不算「忘记」")

        // 以后有还在组里的组员替 A 开通同一台 Mac，照样记得回来。
        try save(.grant(signedGrant(by: b, for: a.local, host: attacker)))
        await converge(a)
        XCTAssertTrue(fake(a).pairedHosts().contains { $0.id == attacker.id })
    }

    func test_mac_granted_by_two_members_stays_when_one_of_them_is_removed() async throws {
        let a = makeDevice("A"), x = makeDevice("X"), b = makeDevice("B")
        join(x, via: a)
        join(b, via: a)
        await converge(a, x, b)
        let mac = hostInfo("Mac mini")
        try save(.grant(signedGrant(by: x, for: a.local, host: mac)))
        refresh(a)
        try save(.grant(signedGrant(by: b, for: a.local, host: mac)))
        refresh(a)
        b.remove([x.local.id])
        await converge(b, a)
        XCTAssertTrue(fake(a).dropped.isEmpty)
        XCTAssertTrue(fake(a).pairedHosts().contains { $0.id == mac.id }, "还有别的组员开通过同一把钥匙")
    }

    func test_mac_this_device_already_knew_is_never_rolled_back() async throws {
        let a = makeDevice("A"), x = makeDevice("X"), b = makeDevice("B")
        let mine = fake(a).addMac("自己配对的 Mac")
        join(x, via: a)
        join(b, via: a)
        await converge(a, x, b)
        try save(.grant(signedGrant(by: x, for: a.local, host: mine.hostInfo)))
        refresh(a)
        XCTAssertEqual(fake(a).adopted.last?.hostID, mine.id)
        b.remove([x.local.id])
        await converge(b, a)
        XCTAssertTrue(fake(a).dropped.isEmpty)
        XCTAssertTrue(fake(a).pairedHosts().contains { $0.id == mine.id })
    }
}
