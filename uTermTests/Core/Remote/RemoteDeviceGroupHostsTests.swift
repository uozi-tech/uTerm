import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 组里的 Mac（G2，docs/remote-device-group-design.md §7.2）：几台设备共用一份内存名册，各自一份本机存储和一份
/// 假的「配对过的 Mac」（`RemoteGroupFakeHosts`），走真的加入流程，再看谁去问哪台 Mac、写了什么、收了什么；
/// 以及钥匙串圈里的人、被移除的组员写的记录能做到什么。
@MainActor
final class RemoteDeviceGroupHostsTests: XCTestCase {
    private let synced = RemoteMemorySyncedStorage()
    private lazy var roster = RemoteGroupRoster(storage: synced)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    /// 模型只弱引用 `hosts`：这里拿着。
    private var fakes: [UUID: RemoteGroupFakeHosts] = [:]
    private var identities: [UUID: Curve25519.KeyAgreement.PrivateKey] = [:]

    // MARK: - 夹具

    private func makeDevice(_ name: String, platform: RemoteDevicePlatform = .mobile, id: UUID = UUID(),
                            identity: Curve25519.KeyAgreement.PrivateKey = .init(),
                            withIdentityKey: Bool = true) -> RemoteDeviceGroup {
        let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
        let key = try! store.signingKey()
        let local = RemoteGroupDevice(id: id, name: name, model: nil, platform: platform.rawValue,
                                      publicKey: identity.publicKey.rawRepresentation,
                                      signingKey: key.publicKey.rawRepresentation, updatedAt: clock)
        let group = RemoteDeviceGroup(local: local, signingKey: key, identityKey: withIdentityKey ? identity : nil,
                                      roster: roster, store: store, now: { [unowned self] in clock })
        let fake = RemoteGroupFakeHosts()
        fakes[id] = fake
        identities[id] = identity
        group.hosts = fake
        return group
    }

    private func fake(_ device: RemoteDeviceGroup) -> RemoteGroupFakeHosts { fakes[device.local.id]! }

    private func tick(_ seconds: TimeInterval = 1) {
        clock = clock.addingTimeInterval(seconds)
    }

    private func refresh(_ devices: RemoteDeviceGroup...) {
        for device in devices {
            tick()
            device.refresh()
        }
    }

    /// 等这几台设备上的请求都问完（问完会再读一轮名册，可能接着问下一个组员）。
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

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private func shownCode(_ device: RemoteDeviceGroup, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .showingCode(let code, _) = device.joinState else {
            XCTFail("应当显示着数：\(String(describing: device.joinState))", file: file, line: line)
            return ""
        }
        return code
    }

    /// 走完一次加入：最后一步是组员核对 Ta、认下新设备（这一轮里就去问 Mac）。不等问完。
    private func join(_ candidate: RemoteDeviceGroup, via member: RemoteDeviceGroup,
                      file: StaticString = #filePath, line: UInt = #line) {
        tick()
        candidate.startJoin()
        refresh(member)
        XCTAssertTrue(member.submitCode(shownCode(candidate, file: file, line: line), for: candidate.local.id),
                      file: file, line: line)
        refresh(candidate, member)
        XCTAssertEqual(candidate.joinState, .joined, file: file, line: line)
        XCTAssertTrue(member.members.contains { $0.device.signingKey == candidate.local.signingKey }, file: file, line: line)
    }

    private func grants(for device: RemoteDeviceGroup) -> [RemoteGroupHostGrant] {
        roster.load().grants.filter { $0.isFor(device.local) }
    }

    private func grants(by signer: RemoteDeviceGroup) -> [RemoteGroupHostGrant] {
        roster.load().grants.filter { $0.signer == signer.local.id }
    }

    private func save(_ record: RemoteGroupRecord, account: String? = nil) throws {
        try synced.save(record.encoded(), account: account ?? record.account)
    }

    /// `signer` 签一条写给 `target` 的结果（`signer` 的签名私钥、此刻的时间）。
    private func signedGrant(by signer: RemoteDeviceGroup, for target: RemoteGroupDevice, host: RemoteGroupHostInfo,
                             outcome: RemoteVouchResult.Outcome = .added, relay: Data? = nil) throws -> RemoteGroupHostGrant {
        try RemoteGroupHostGrant.make(device: target, host: host, outcome: outcome.rawValue, reason: nil, internetAccess: nil,
                                      relay: relay, signer: signer.local, signedAt: RemoteGroupTime(clock),
                                      key: signer.signingKey)
    }

    private func hostInfo(_ name: String = "工作室 Mac") -> RemoteGroupHostInfo {
        RemoteGroupHostInfo(id: UUID(), name: name,
                            publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                            model: "Mac Studio", platform: RemoteDevicePlatform.mac.rawValue)
    }

    private func relay(for host: UUID) -> RemoteRelayConfig {
        RemoteRelayConfig(name: "r", host: "relay.example.invalid", port: 1, relayID: "rid",
                          key: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString(),
                          scope: host.uuidString, cert: Data([1]).base64EncodedString(), expires: 9_999_999_999)
    }

    // MARK: - 组员替新设备问 Mac

    func test_member_asks_both_of_its_macs_for_the_new_device_and_the_new_device_adopts_them() async throws {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C")
        let mac1 = fake(b).addMac("Mac mini"), mac2 = fake(b).addMac("MacBook Pro")
        join(c, via: b)
        await settle(b)
        XCTAssertEqual(Set(fake(b).calls(at: mac1.id)), [c.local.id])
        XCTAssertEqual(Set(fake(b).calls(at: mac2.id)), [c.local.id])

        join(a, via: b)
        XCTAssertEqual(b.vouchesInFlight, 2, "认下新设备的这一轮就并行去问两台 Mac")
        await settle(b)
        XCTAssertEqual(fake(b).calls(at: mac1.id), [c.local.id, a.local.id])
        XCTAssertEqual(fake(b).calls(at: mac2.id), [c.local.id, a.local.id])
        let forA = grants(for: a)
        XCTAssertEqual(Set(forA.map(\.host.id)), [mac1.id, mac2.id])
        XCTAssertTrue(forA.allSatisfy { $0.signer == b.local.id && $0.hasValidSignature && $0.isUsable })
        XCTAssertEqual(Set(roster.load().hosts.filter { $0.signer == b.local.id }.map(\.host.id)), [mac1.id, mac2.id],
                       "B 把它配对过的 Mac 写进组的目录")

        refresh(a)
        XCTAssertEqual(Set(fake(a).adopted.map(\.hostID)), [mac1.id, mac2.id])
        XCTAssertEqual(fake(a).adopted.first { $0.hostID == mac1.id }?.hostKey, mac1.publicKey)
        XCTAssertTrue(a.pendingHosts.isEmpty, "都通了，「还没通的 Mac」不显示")

        // C 没配对任何 Mac：什么都不问、不写 host / grant。结果已经在了，谁都不再问。
        for _ in 0..<5 {
            refresh(a, b, c)
            await settle(a, b, c)
            tick(3600)
        }
        XCTAssertTrue(fake(c).calls.isEmpty)
        XCTAssertTrue(grants(by: c).isEmpty)
        XCTAssertEqual(Set(roster.load().hosts.filter { $0.signer == c.local.id }.map(\.host.id)), [mac1.id, mac2.id],
                       "C 收下了 B 替它开通的两台，才把它们写进目录")
        XCTAssertEqual(fake(b).calls.count, 4, "有定论之后不再问")
        XCTAssertTrue(fake(a).calls.isEmpty, "A 收下的 Mac 此刻不在它那边在线，不问")
    }

    func test_member_vouches_devices_that_joined_via_another_member_and_skips_what_another_member_already_settled() async {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C"), d = makeDevice("D")
        let mac = fake(b).addMac("Mac mini")
        fake(c).addMac("Mac mini", id: mac.id, publicKey: mac.publicKey, online: false)
        join(b, via: a)
        join(c, via: a)
        refresh(b, c)
        await settle(b, c)
        join(d, via: a)
        XCTAssertEqual(a.vouchesInFlight, 0, "A 没配对 Mac")
        refresh(b)
        await settle(b)
        XCTAssertEqual(Set(fake(b).calls(at: mac.id)), [a.local.id, c.local.id, d.local.id],
                       "B 替每台别的组员问，包括经 A 加进来的")

        // C 现在也连得上这台 Mac：A、D 已经有 B 写下的定论，C 不再问它们；B 没人替它问过，C 问。
        fake(c).online.insert(mac.id)
        refresh(c)
        await settle(c)
        XCTAssertEqual(fake(c).calls(at: mac.id), [b.local.id])
        for _ in 0..<3 {
            tick(7 * 3600)
            refresh(a, b, c, d)
            await settle(a, b, c, d)
        }
        XCTAssertEqual(fake(c).calls(at: mac.id), [b.local.id], "定论不过期")
        XCTAssertEqual(fake(b).calls(at: mac.id).count, 3)
    }

    func test_new_device_is_vouched_in_the_same_round_it_is_admitted() async {
        let a = makeDevice("A"), b = makeDevice("B")
        fake(b).addMac("Mac mini")
        tick()
        a.startJoin()
        refresh(b)
        XCTAssertTrue(b.submitCode(shownCode(a), for: a.local.id))
        refresh(a)
        XCTAssertEqual(a.joinState, .joined)
        XCTAssertEqual(b.vouchesInFlight, 0, "还没核对 Ta，不问")
        refresh(b)
        XCTAssertEqual(b.vouchesInFlight, 1, "核对通过的这一轮就开始问")
        let written = await waitUntil { !self.grants(for: a).isEmpty }
        XCTAssertTrue(written, "不用再调 refresh，问完就写")
    }

    /// 组员还要在一台此刻不算在线的 Mac 上开通：请目录补问在不在线（§20）；Mac 在线了直接去问，之后没事要做不再补问。
    func test_member_still_to_be_opened_at_an_offline_mac_asks_for_reachability() async {
        let a = makeDevice("A"), b = makeDevice("B")
        let mini = fake(b).addMac("Mac mini", online: false)
        refresh(b)
        XCTAssertEqual(fake(b).reachabilityRefreshes, 0, "只有自己一台：没事要做")
        join(a, via: b)
        XCTAssertEqual(fake(b).reachabilityRefreshes, 1, "认下新组员的这一轮：它在这台 Mac 上还没开通")
        XCTAssertTrue(fake(b).calls.isEmpty)

        fake(b).online.insert(mini.id)
        refresh(b)
        await settle(b)
        XCTAssertEqual(fake(b).calls(at: mini.id), [a.local.id])
        XCTAssertEqual(fake(b).reachabilityRefreshes, 1, "在线：直接去问")

        fake(b).online.remove(mini.id)
        for _ in 0..<3 {
            refresh(b)
            await settle(b)
        }
        XCTAssertEqual(fake(b).reachabilityRefreshes, 1, "开通好了：没事要做，不问")
    }

    func test_offline_mac_is_retried_after_a_minute_and_refusals_after_six_hours() async {
        let a = makeDevice("A"), b = makeDevice("B")
        let offline = fake(b).addMac("睡着的 Mac")
        let closed = fake(b).addMac("没开的 Mac")
        let old = fake(b).addMac("旧的 Mac")
        fake(b).replies = [offline.id: .unreachable, closed.id: .outcome(.notAllowed, reason: "没允许"), old.id: .tooOld]
        join(a, via: b)
        await settle(b)
        XCTAssertEqual(fake(b).calls.count, 3)
        let written = Dictionary(uniqueKeysWithValues: grants(for: a).map { ($0.host.id, $0.outcome) })
        XCTAssertNil(written[offline.id], "连不上不写结果")
        XCTAssertEqual(written[closed.id], RemoteVouchResult.Outcome.notAllowed.rawValue)
        XCTAssertEqual(written[old.id], RemoteGroupGrant.unsupported)

        for _ in 0..<5 {
            refresh(b)
            await settle(b)
        }
        XCTAssertEqual(fake(b).calls.count, 3, "一分钟内谁都不再问")
        tick(61)
        refresh(b)
        await settle(b)
        XCTAssertEqual(fake(b).calls(at: offline.id).count, 2, "连不上的过一分钟再问")
        XCTAssertEqual(fake(b).calls(at: closed.id).count, 1)
        XCTAssertEqual(fake(b).calls(at: old.id).count, 1)

        tick(3 * 3600)
        refresh(b)
        await settle(b)
        XCTAssertEqual(fake(b).calls(at: closed.id).count, 1, "不允许的 6 小时内不再问")
        tick(3 * 3600 + 1)
        fake(b).replies[closed.id] = .outcome(.added)
        refresh(b)
        await settle(b)
        XCTAssertEqual(fake(b).calls(at: closed.id).count, 2)
        XCTAssertEqual(fake(b).calls(at: old.id).count, 2, "版本太旧的也是 6 小时后再问")
        XCTAssertEqual(grants(for: a).first { $0.host.id == closed.id }?.isUsable, true, "Mac 打开开关后写下新结果")
    }

    func test_mac_that_changed_its_key_is_asked_again_and_the_old_result_no_longer_counts() async {
        let a = makeDevice("A"), b = makeDevice("B")
        let mac = fake(b).addMac("Mac mini")
        join(a, via: b)
        await settle(b)
        refresh(a)
        XCTAssertEqual(fake(a).adopted.map(\.hostKey), [mac.publicKey])

        // Mac 重装后 B 重新配对，公钥变了。
        let newKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        fake(b).repair(mac.id, publicKey: newKey)
        tick(120)
        refresh(b)
        await settle(b)
        XCTAssertEqual(fake(b).calls(at: mac.id), [a.local.id, a.local.id])
        XCTAssertEqual(grants(for: a).map(\.host.publicKey), [newKey], "同一个 account，换成新钥匙的结果")
        XCTAssertEqual(roster.load().hosts.first { $0.signer == b.local.id }?.host.publicKey, newKey, "host 也重签")

        // A 记着的还是旧钥匙：不覆盖，行上写「对不上」。
        refresh(a)
        XCTAssertEqual(fake(a).paired.first?.publicKey, mac.publicKey)
        XCTAssertEqual(a.pendingHosts.map(\.status), [.needsPairing(.conflict)])
    }

    func test_a_mac_member_is_never_vouched_to_itself_and_does_not_list_itself() async {
        let phone = makeDevice("iPhone"), pad = makeDevice("iPad")
        let mini = makeDevice("Mac mini", platform: .mac)
        // iPhone 配对过 mini（mini 是被控端，也是组员）。
        let target = fake(phone).addMac("Mac mini", id: mini.local.id, publicKey: mini.local.publicKey)
        join(mini, via: phone)
        await settle(phone)
        XCTAssertTrue(fake(phone).calls.isEmpty, "不替 mini 向 mini 自己开通")
        join(pad, via: phone)
        await settle(phone)
        XCTAssertEqual(fake(phone).calls(at: target.id), [pad.local.id])
        refresh(mini)
        XCTAssertTrue(mini.pendingHosts.isEmpty, "组的目录里有 mini 自己，但不列给它自己")
        XCTAssertTrue(fake(mini).adopted.isEmpty)
    }

    func test_different_macs_are_asked_concurrently_and_one_mac_one_request_at_a_time() async {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C")
        let slow = fake(b).addMac("慢的 Mac"), fast = fake(b).addMac("快的 Mac")
        fake(b).held = [slow.id]
        join(c, via: b)
        let ok1 = await waitUntil { self.grants(for: c).contains { $0.host.id == fast.id } }
        XCTAssertTrue(ok1)
        XCTAssertEqual(b.vouchesInFlight, 1, "慢的那台还在问")

        join(a, via: b)
        XCTAssertEqual(b.vouchesInFlight, 2)
        let ok2 = await waitUntil { self.grants(for: a).contains { $0.host.id == fast.id } }
        XCTAssertTrue(ok2, "慢的 Mac 不耽误快的")
        XCTAssertEqual(fake(b).calls(at: slow.id), [c.local.id], "同一台 Mac 一次只问一个")
        XCTAssertFalse(grants(for: c).contains { $0.host.id == slow.id })

        fake(b).held = []
        let ok3 = await waitUntil { self.grants(for: a).contains { $0.host.id == slow.id } }
        XCTAssertTrue(ok3, "放开后接着问下一个")
        XCTAssertEqual(fake(b).calls(at: slow.id), [c.local.id, a.local.id])
        XCTAssertTrue(grants(for: c).contains { $0.host.id == slow.id })
    }

    // MARK: - 取消

    func test_request_still_running_when_the_model_goes_away_is_cancelled_and_writes_nothing() async {
        let a = makeDevice("A")
        var b: RemoteDeviceGroup? = makeDevice("B")
        let bID = b!.local.id
        let hosts = fakes[bID]!
        let mac = hosts.addMac("Mac mini")
        hosts.held = [mac.id]
        join(a, via: b!)
        let ok4 = await waitUntil { hosts.calls.count == 1 }
        XCTAssertTrue(ok4)
        b = nil
        let ok5 = await waitUntil { hosts.cancelled == 1 }
        XCTAssertTrue(ok5, "模型释放时取消还在问的请求")
        hosts.held = []
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(roster.load().grants.isEmpty, "取消的那一次什么都不写")
    }

    func test_service_stop_cancels_requests_and_start_asks_again() async {
        let a = makeDevice("A"), b = makeDevice("B")
        let mac = fake(b).addMac("Mac mini")
        fake(b).held = [mac.id]
        join(a, via: b)
        let ok6 = await waitUntil { self.fake(b).calls.count == 1 }
        XCTAssertTrue(ok6)
        let service = RemoteDeviceGroupService { _ in b }
        service.start(hosts: fake(b))
        service.tick()
        XCTAssertTrue(service.model === b)
        service.stop()
        let ok7 = await waitUntil { self.fake(b).cancelled == 1 }
        XCTAssertTrue(ok7, "iOS 退到后台：取消还在问的请求")
        fake(b).held = []
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(grants(for: a).isEmpty)
        XCTAssertEqual(b.vouchesInFlight, 0)

        b.refresh()
        await settle(b)
        XCTAssertEqual(fake(b).calls.count, 2, "回到前台接着问")
        XCTAssertEqual(grants(for: a).count, 1)
    }

    func test_device_without_identity_private_key_does_not_vouch_and_adopts_without_relay() async throws {
        let a = makeDevice("A", withIdentityKey: false), b = makeDevice("B", withIdentityKey: false)
        let mac = fake(b).addMac("Mac mini")
        join(a, via: b)
        await settle(b)
        XCTAssertTrue(fake(b).calls.isEmpty, "没有远控私钥：不担保")

        // 一台有私钥的组员替 A 开通，带封给 A 的中继：A 打不开包，照样收下 Mac、不带中继。
        let c = makeDevice("C")
        join(c, via: b)
        let info = mac.hostInfo
        let box = try RemoteGroupRelaySeal.seal(relay(for: info.id),
                                                key: RemoteGroupRelaySeal.key(local: identities[c.local.id]!,
                                                                              remote: a.local.publicKey),
                                                signer: c.local.id, target: a.local.id, host: info.id)
        refresh(a, c)
        try save(.grant(signedGrant(by: c, for: a.local, host: info, relay: box)))
        refresh(a)
        XCTAssertEqual(fake(a).adopted.map(\.hostID), [mac.id])
        XCTAssertNil(fake(a).adopted.first?.relay)
    }

    // MARK: - 收

    /// A 经 B 加入、C 经 B 加入，三台都认彼此。
    private func threeMembers() -> (a: RemoteDeviceGroup, b: RemoteDeviceGroup, c: RemoteDeviceGroup) {
        let a = makeDevice("A"), b = makeDevice("B"), c = makeDevice("C")
        join(a, via: b)
        join(c, via: b)
        refresh(a, b, c, a)
        XCTAssertEqual(Set(a.members.map(\.device.name)), ["A", "B", "C"])
        return (a, b, c)
    }

    func test_new_device_adopts_with_the_relay_only_it_can_open() throws {
        let (a, b, c) = threeMembers()
        let info = hostInfo()
        let config = relay(for: info.id)
        let bKey = identities[b.local.id]!
        let forA = try RemoteGroupRelaySeal.seal(config, key: RemoteGroupRelaySeal.key(local: bKey, remote: a.local.publicKey),
                                                 signer: b.local.id, target: a.local.id, host: info.id)
        try save(.grant(signedGrant(by: b, for: a.local, host: info, relay: forA)))
        refresh(a)
        XCTAssertEqual(fake(a).adopted.map(\.relay), [config])

        // 同一个包，别的设备（C）打不开：钥匙是 B 和 A 的。
        let cKey = try RemoteGroupRelaySeal.key(local: identities[c.local.id]!, remote: b.local.publicKey)
        XCTAssertNil(RemoteGroupRelaySeal.open(forA, key: cKey, signer: b.local.id, target: a.local.id, host: info.id))
        XCTAssertNil(RemoteGroupRelaySeal.open(forA, key: cKey, signer: b.local.id, target: c.local.id, host: info.id))
        // 搬到别的 Mac 上也打不开。
        let aKey = try RemoteGroupRelaySeal.key(local: identities[a.local.id]!, remote: b.local.publicKey)
        XCTAssertNotNil(RemoteGroupRelaySeal.open(forA, key: aKey, signer: b.local.id, target: a.local.id, host: info.id))
        XCTAssertNil(RemoteGroupRelaySeal.open(forA, key: aKey, signer: b.local.id, target: a.local.id, host: UUID()))
        XCTAssertNil(RemoteGroupRelaySeal.open(forA, key: aKey, signer: c.local.id, target: a.local.id, host: info.id))
    }

    func test_relay_sealed_for_another_device_or_garbled_means_adopted_without_relay() throws {
        let (a, b, c) = threeMembers()
        let first = hostInfo("第一台"), second = hostInfo("第二台")
        let bKey = identities[b.local.id]!
        // B 签的、写给 A 的结果，包却是封给 C 的。
        let forC = try RemoteGroupRelaySeal.seal(relay(for: first.id),
                                                 key: RemoteGroupRelaySeal.key(local: bKey, remote: c.local.publicKey),
                                                 signer: b.local.id, target: a.local.id, host: first.id)
        try save(.grant(signedGrant(by: b, for: a.local, host: first, relay: forC)))
        // 包是乱码（签名照样对得上：签名者自己写坏的）。
        try save(.grant(signedGrant(by: b, for: a.local, host: second, relay: Data(repeating: 7, count: 80))))
        refresh(a)
        XCTAssertEqual(Set(fake(a).adopted.map(\.hostID)), [first.id, second.id])
        XCTAssertTrue(fake(a).adopted.allSatisfy { $0.relay == nil })
        XCTAssertTrue(a.pendingHosts.isEmpty)
    }

    func test_grants_from_outsiders_removed_members_tampered_or_for_others_are_ignored() throws {
        let (a, b, c) = threeMembers()
        let d = makeDevice("D")
        join(d, via: b)
        refresh(a, c, a)

        // 钥匙串圈里的冒充者：自己的签名钥匙，自称 B。
        let attackerKey = Curve25519.Signing.PrivateKey()
        var impostor = b.local
        impostor.signingKey = attackerKey.publicKey.rawRepresentation
        let fakeMac = hostInfo("冒充的 Mac")
        try save(.grant(RemoteGroupHostGrant.make(device: a.local, host: fakeMac, outcome: "added", reason: nil,
                                                  internetAccess: nil, relay: nil, signer: impostor,
                                                  signedAt: RemoteGroupTime(clock), key: attackerKey)))
        try save(.host(RemoteGroupHost.make(host: fakeMac, signer: impostor, signedAt: RemoteGroupTime(clock),
                                            key: attackerKey)))

        // 改了一个字段（Mac 的公钥）的 B 的结果。
        let realMac = hostInfo("真的 Mac")
        var tampered = try signedGrant(by: b, for: a.local, host: realMac)
        tampered.host.publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        try save(.grant(tampered))

        // B 写给 C 的结果，放到 A 的 account 下。
        let otherMac = hostInfo("给 C 的 Mac")
        let forC = try signedGrant(by: b, for: c.local, host: otherMac)
        try save(.grant(forC), account: RemoteGroupHostGrant.account(device: a.local.id, host: otherMac.id, signer: b.local.id))

        // D 被移除后再签的。
        b.remove([d.local.id])
        refresh(a, c, d)
        XCTAssertTrue(d.isSelfRemoved)
        tick(10)
        let removedMac = hostInfo("被移除者的 Mac")
        try save(.grant(signedGrant(by: d, for: a.local, host: removedMac)))
        try save(.host(RemoteGroupHost.make(host: removedMac, signer: d.local, signedAt: RemoteGroupTime(clock),
                                            key: d.signingKey)))

        refresh(a)
        XCTAssertTrue(fake(a).adopted.isEmpty, "\(fake(a).adopted.map(\.hostName))")
        XCTAssertTrue(a.pendingHosts.isEmpty, "这些 Mac 也不进「还没通的 Mac」：\(a.pendingHosts.map(\.name))")
    }

    /// 签名者进组之前签的（比如它在别的组里时签下、被钥匙串圈里的人重放过来的）不算。
    func test_grant_signed_before_its_signer_joined_is_ignored() throws {
        let (a, b, c) = threeMembers()
        let cJoined = try XCTUnwrap(try a.store.state().member(signingKey: c.local.signingKey)?.admission.admittedAt)
        let early = hostInfo("早签的")
        try save(.grant(RemoteGroupHostGrant.make(device: a.local, host: early, outcome: "added", reason: nil,
                                                  internetAccess: nil, relay: nil, signer: c.local,
                                                  signedAt: RemoteGroupTime(milliseconds: cJoined.milliseconds - 1),
                                                  key: c.signingKey)))
        try save(.host(RemoteGroupHost.make(host: early, signer: c.local,
                                            signedAt: RemoteGroupTime(milliseconds: cJoined.milliseconds - 1),
                                            key: c.signingKey)))
        refresh(a)
        XCTAssertTrue(fake(a).adopted.isEmpty)
        XCTAssertTrue(a.pendingHosts.isEmpty)
        // 同一台、进组之后签的就收。
        try save(.grant(signedGrant(by: c, for: a.local, host: early)))
        refresh(a)
        XCTAssertEqual(fake(a).adopted.map(\.hostID), [early.id])
        _ = b
    }

    func test_usable_result_wins_when_two_members_asked_the_same_mac() throws {
        let (a, b, c) = threeMembers()
        let info = hostInfo()
        try save(.grant(signedGrant(by: b, for: a.local, host: info, outcome: .added)))
        tick(60)
        try save(.grant(signedGrant(by: c, for: a.local, host: info, outcome: .notAllowed)))
        refresh(a)
        XCTAssertEqual(fake(a).adopted.map(\.hostID), [info.id], "后写的不允许也压不过能用的")
        XCTAssertTrue(a.pendingHosts.isEmpty)
    }

    func test_pending_list_shows_opening_until_a_result_arrives_and_the_reason_on_refusal() async {
        let a = makeDevice("A"), b = makeDevice("B")
        let asleep = fake(b).addMac("睡着的 Mac", online: false)
        let closed = fake(b).addMac("没开的 Mac")
        let old = fake(b).addMac("旧的 Mac")
        let rejecting = fake(b).addMac("拒绝的 Mac")
        let forgotten = fake(b).addMac("忘记过的 Mac")
        let fine = fake(b).addMac("能用的 Mac")
        fake(b).replies = [closed.id: .outcome(.notAllowed), old.id: .tooOld, rejecting.id: .outcome(.rejected)]
        fake(a).forgotten = [forgotten.id]
        join(a, via: b)
        refresh(a)
        XCTAssertEqual(Set(a.pendingHosts.map(\.status)), [.opening], "结果还没到：都是「正在开通」")
        XCTAssertEqual(a.pendingHosts.count, 6)
        XCTAssertTrue(a.isOpeningHosts, "刚进组，轮询要快")

        await settle(b)
        refresh(a)
        let status = Dictionary(uniqueKeysWithValues: a.pendingHosts.map { ($0.id, $0.status) })
        XCTAssertEqual(status, [asleep.id: .opening, closed.id: .needsPairing(.notAllowed), old.id: .needsPairing(.tooOld),
                                rejecting.id: .needsPairing(.rejected), forgotten.id: .needsPairing(.forgotten)])
        XCTAssertNil(status[fine.id], "能用的不列")
        XCTAssertEqual(a.pendingHosts.first { $0.id == closed.id }?.name, "没开的 Mac")

        // 睡着的 Mac 醒了；不允许的那台你在 A 上单独配对了；剩下的结果都不在了（比如 B 不再配对它们）。
        fake(b).online.insert(asleep.id)
        tick(61)
        refresh(b)
        await settle(b)
        fake(a).addMac("没开的 Mac", id: closed.id, publicKey: closed.publicKey, online: false)
        for id in [old.id, rejecting.id, forgotten.id] { fake(b).paired.removeAll { $0.id == id } }
        refresh(b, a)
        XCTAssertTrue(a.pendingHosts.isEmpty, "\(a.pendingHosts)")
    }

    // MARK: - 被移除

    func test_removed_device_publishes_and_adopts_nothing_and_its_grants_are_deleted_by_their_signers() async throws {
        let (a, b, c) = threeMembers()
        fake(b).addMac("Mac mini")
        fake(c).addMac("C 的 Mac")
        refresh(b, c)
        await settle(b, c)
        refresh(c)
        await settle(c)
        XCTAssertEqual(Set(fake(c).adopted.map(\.hostName)), ["Mac mini"], "被移除之前照常收")
        XCTAssertTrue(grants(by: c).contains { $0.deviceID == a.local.id }, "C 替 A 问过它的 Mac")
        let cAdopted = fake(c).adopted.count
        XCTAssertFalse(grants(for: c).isEmpty)
        XCTAssertTrue(roster.load().hosts.contains { $0.signer == c.local.id })
        let cCalls = fake(c).calls.count
        let cHostRecords = roster.load().hosts.filter { $0.signer == c.local.id }

        a.remove([c.local.id])
        refresh(b)
        await settle(b)
        XCTAssertTrue(grants(for: c).isEmpty, "B 删掉替它写的结果")
        refresh(c)
        XCTAssertTrue(c.isSelfRemoved)
        XCTAssertTrue(c.pendingHosts.isEmpty)

        // 被移出后：新配对的 Mac 不写 host，别人写给它的结果不收，新来的组员也不替它问。
        fake(c).addMac("C 新配的 Mac")
        try save(.grant(signedGrant(by: b, for: c.local, host: hostInfo("给 C 的"))))
        let d = makeDevice("D")
        join(d, via: a)
        for _ in 0..<3 {
            refresh(c)
            await settle(c)
        }
        XCTAssertEqual(roster.load().hosts.filter { $0.signer == c.local.id }, cHostRecords)
        XCTAssertEqual(fake(c).calls.count, cCalls)
        XCTAssertEqual(fake(c).adopted.count, cAdopted, "被移出后不再收")
        XCTAssertFalse(grants(by: c).contains { $0.deviceID == d.local.id })
        // C 在被移出之前替 A 写的结果，A 读到时 C 已经不是组员：不收。
        refresh(a)
        XCTAssertFalse(fake(a).adopted.contains { $0.hostName == "C 的 Mac" }, "\(fake(a).adopted.map(\.hostName))")
    }

    // MARK: - 轮询

    func test_fast_polling_for_ten_minutes_after_joining_then_idle() {
        let a = makeDevice("A"), b = makeDevice("B")
        join(a, via: b)
        refresh(b, a)
        XCTAssertTrue(a.isOpeningHosts)
        XCTAssertTrue(RemoteDeviceGroupService.isBusy(demand: 0, model: a))
        tick(9 * 60)
        a.refresh()
        XCTAssertTrue(a.isOpeningHosts)
        tick(2 * 60)
        a.refresh()
        XCTAssertFalse(a.isOpeningHosts)
        XCTAssertFalse(RemoteDeviceGroupService.isBusy(demand: 0, model: a), "10 分钟后回到 10 秒一轮")
        XCTAssertFalse(b.isOpeningHosts, "B 是组里的第一台，不是「刚进组」")
    }

    func test_stuck_request_keeps_polling_fast_for_at_most_ten_minutes() async {
        let a = makeDevice("A"), b = makeDevice("B")
        let mac = fake(b).addMac("Mac mini")
        fake(b).held = [mac.id]
        join(a, via: b)
        XCTAssertTrue(b.isOpeningHosts)
        tick(11 * 60)
        b.refresh()
        XCTAssertEqual(b.vouchesInFlight, 1)
        XCTAssertFalse(b.isOpeningHosts, "卡住的请求不让轮询一直快")
        XCTAssertFalse(RemoteDeviceGroupService.isBusy(demand: 0, model: b))
        fake(b).held = []
        await settle(b)
    }
}
