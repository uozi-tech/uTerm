import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 确认之后的开通：开通结果的封装、已有设备逐台问 Mac、新设备只收认可的担保者封的结果、目录收下 Mac 的规则，
/// 以及真服务端上走一遍——iPhone 确认 iPad → 替它向 Mac 担保 → iPad 收下 → iPad 不经审批连上 Mac。
@MainActor
final class RemoteSiblingGrantTests: XCTestCase {
    private let syncedStorage = RemoteMemorySyncedStorage()
    private lazy var roster = RemoteSiblingRoster(storage: syncedStorage)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private struct Identity {
        let device: RemoteSiblingDevice
        let key: Curve25519.KeyAgreement.PrivateKey
    }

    private func identity(_ name: String, id: UUID = UUID(), key: Curve25519.KeyAgreement.PrivateKey = .init()) -> Identity {
        Identity(device: RemoteSiblingDevice(id: id, name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                                             publicKey: key.publicKey.rawRepresentation, updatedAt: clock),
                 key: key)
    }

    private func model(_ who: Identity, hosts: FakeHosts? = nil) -> RemoteSiblingDevices {
        let model = RemoteSiblingDevices(local: who.device, localKey: who.key, roster: roster,
                                         store: RemoteSiblingLocalStore(storage: RemoteMemoryStorage()),
                                         now: { [unowned self] in self.clock })
        model.hosts = hosts
        return model
    }

    /// 走完一次确认：在已有设备上输入新设备显示的数；`candidateAccepts` 时新设备随后点「允许」。
    private func confirm(_ voucher: RemoteSiblingDevices, _ candidate: RemoteSiblingDevices, candidateAccepts: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) {
        voucher.refresh()
        candidate.refresh()
        voucher.confirm(candidate.localDevice.id)
        candidate.refresh()
        voucher.refresh()
        let code = candidate.incoming.first?.code ?? ""
        XCTAssertFalse(candidate.incoming.first?.verified ?? true, "还没输入，新设备不能先允许", file: file, line: line)
        XCTAssertTrue(voucher.submitCode(code), file: file, line: line)
        candidate.refresh()
        XCTAssertEqual(candidate.incoming.first?.verified, true, "输对后新设备看到「核对通过」", file: file, line: line)
        if candidateAccepts { candidate.acceptIncoming(voucher.localDevice.id) }
        candidate.refresh()
    }

    private func settle(_ model: RemoteSiblingDevices) async {
        _ = await waitUntil { model.vouchTask == nil }
    }

    private func mac(_ name: String = "Mac mini") -> RemoteSiblingVouchTarget {
        RemoteSiblingVouchTarget(id: UUID(), name: name, publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                 model: "Mac mini", platform: "mac")
    }

    // MARK: - 封装

    func test_sealed_grant_opens_only_between_the_two_devices_and_only_as_written() throws {
        let phone = identity("iPhone"), pad = identity("iPad"), other = identity("Other")
        let host = mac()
        let grant = RemoteSiblingGrant(hostID: host.id, hostName: host.name, hostKey: host.publicKey, outcome: "added")
        let sealed = try RemoteSiblingSeal.seal(grant, candidate: pad.device.id, voucher: phone.device.id,
                                                key: RemoteSiblingSeal.key(local: phone.key, remote: pad.device.publicKey),
                                                now: clock)
        // 新设备用自己的私钥和担保者的公钥算出同一把钥匙。
        let padKey = try RemoteSiblingSeal.key(local: pad.key, remote: phone.device.publicKey)
        XCTAssertEqual(RemoteSiblingSeal.open(sealed, key: padKey), grant)
        // 第三台设备算不出来。
        XCTAssertNil(RemoteSiblingSeal.open(sealed, key: try RemoteSiblingSeal.key(local: other.key, remote: phone.device.publicKey)))
        // 搬成另一台 Mac 的、搬给另一台设备的都不认。
        var moved = sealed
        moved.host = UUID()
        XCTAssertNil(RemoteSiblingSeal.open(moved, key: padKey))
        moved = sealed
        moved.candidate = other.device.id
        XCTAssertNil(RemoteSiblingSeal.open(moved, key: padKey))
        // 名册里能存能读，P0 的版本看到 grant 记录会跳过（`decode` 的 default 分支）。
        XCTAssertEqual(RemoteSiblingRecord.decode(try RemoteSiblingRecord.grant(sealed).encoded()), .grant(sealed))
    }

    // MARK: - 两台设备 + 假的 Mac

    func test_voucher_opens_confirmed_device_on_each_mac_and_candidate_adopts_them() async throws {
        let mini = mac("Mac mini"), studio = mac("Mac Studio")
        let phoneHosts = FakeHosts(targets: [mini, studio])
        let padHosts = FakeHosts()
        let phone = model(identity("iPhone"), hosts: phoneHosts)
        let pad = model(identity("iPad"), hosts: padHosts)
        confirm(phone, pad)

        phone.refresh()
        await settle(phone)
        phone.refresh()
        await settle(phone)
        XCTAssertEqual(Set(phoneHosts.asked.map(\.host)), [mini.id, studio.id], "一台一台问")
        XCTAssertTrue(phoneHosts.asked.allSatisfy { $0.device == pad.localDevice.id })

        pad.refresh()
        XCTAssertEqual(Set(padHosts.adopted.map(\.hostID)), [mini.id, studio.id])
        XCTAssertEqual(padHosts.adopted.first { $0.hostID == mini.id }?.hostKey, mini.publicKey)
        XCTAssertEqual(pad.received.count, 2)
        XCTAssertTrue(pad.received.allSatisfy { $0.status == .opened })

        phone.refresh()
        let delivery = try XCTUnwrap(phone.rows.first?.delivery)
        XCTAssertEqual(delivery.opened.count, 2)
        XCTAssertTrue(delivery.waiting.isEmpty)

        // 问过、成了的不再问。
        clock += RemoteSiblingDevices.vouchRetryInterval + 1
        phone.refresh()
        await settle(phone)
        XCTAssertEqual(phoneHosts.asked.count, 2)
    }

    func test_candidate_that_did_not_tap_match_receives_nothing() async throws {
        let mini = mac()
        let phoneHosts = FakeHosts(targets: [mini]), padHosts = FakeHosts()
        let phone = model(identity("iPhone"), hosts: phoneHosts)
        let pad = model(identity("iPad"), hosts: padHosts)
        confirm(phone, pad, candidateAccepts: false)
        phone.refresh()
        await settle(phone)
        XCTAssertEqual(phoneHosts.asked.count, 1, "已有设备照样去问")
        pad.refresh()
        XCTAssertTrue(padHosts.adopted.isEmpty, "新设备没认可这台担保者，不收它的结果")
        XCTAssertTrue(pad.received.isEmpty)
    }

    func test_candidate_cannot_allow_before_the_voucher_typed_the_code() {
        let phone = model(identity("iPhone"))
        let pad = model(identity("iPad"))
        phone.refresh()
        pad.refresh()
        phone.confirm(pad.localDevice.id)
        pad.refresh()
        pad.acceptIncoming(phone.localDevice.id)
        XCTAssertFalse(pad.rows.first?.isTrustedVoucher ?? true, "没有「核对通过」就点不了允许")
        XCTAssertEqual(pad.incoming.count, 1)
    }

    func test_forged_or_stale_confirmation_does_not_verify() throws {
        let phoneIdentity = identity("iPhone")
        let phone = model(phoneIdentity)
        let padIdentity = identity("iPad")
        let pad = model(padIdentity)
        phone.refresh()
        pad.refresh()
        phone.confirm(pad.localDevice.id)
        pad.refresh()
        let challenge = try XCTUnwrap(roster.load().message(.challenge, candidate: padIdentity.device.id, voucher: phoneIdentity.device.id))
        func write(_ value: Data) throws {
            try roster.save(.message(RemoteSiblingMessage(kind: .confirmed, candidate: padIdentity.device.id,
                                                          candidateKey: padIdentity.device.publicKey,
                                                          voucher: phoneIdentity.device.id, voucherKey: phoneIdentity.device.publicKey,
                                                          value: value, createdAt: clock)))
        }
        // 钥匙串圈里的冒充者：没有 iPhone 的私钥，封不出 iPad 打得开的。
        let impostor = Curve25519.KeyAgreement.PrivateKey()
        try write(RemoteSiblingSeal.sealConfirmation(candidate: padIdentity.device.id, voucher: phoneIdentity.device.id,
                                                     challenge: challenge.value,
                                                     key: RemoteSiblingSeal.key(local: impostor, remote: padIdentity.device.publicKey)))
        pad.refresh()
        XCTAssertEqual(pad.incoming.first?.verified, false)
        // 真 iPhone 封的、但属于上一次确认的：也不算。
        try write(RemoteSiblingSeal.sealConfirmation(candidate: padIdentity.device.id, voucher: phoneIdentity.device.id,
                                                     challenge: RemoteSiblingCode.newNonce(),
                                                     key: RemoteSiblingSeal.key(local: phoneIdentity.key, remote: padIdentity.device.publicKey)))
        pad.refresh()
        XCTAssertEqual(pad.incoming.first?.verified, false)
    }

    func test_allowing_clears_the_records_and_trusts_the_voucher() {
        let phone = model(identity("iPhone"))
        let pad = model(identity("iPad"))
        confirm(phone, pad)
        XCTAssertTrue(pad.incoming.isEmpty)
        XCTAssertTrue(pad.rows.first?.isTrustedVoucher ?? false)
        let left = roster.load().messages.filter { $0.candidate == pad.localDevice.id && $0.kind != .commitment }
        XCTAssertTrue(left.isEmpty, "challenge / reveal / confirmed 都清掉：\(left.map(\.kind))")
    }

    func test_dismissing_the_code_on_the_candidate_hides_it_and_trusts_nothing() {
        let phone = model(identity("iPhone"))
        let pad = model(identity("iPad"))
        phone.refresh()
        pad.refresh()
        phone.confirm(pad.localDevice.id)
        pad.refresh()
        XCTAssertEqual(pad.incoming.count, 1)
        pad.dismissIncoming(phone.localDevice.id)
        XCTAssertTrue(pad.incoming.isEmpty)
        XCTAssertFalse(pad.rows.first?.isTrustedVoucher ?? true)
    }

    func test_grant_sealed_by_an_unaccepted_device_is_ignored() throws {
        let padHosts = FakeHosts()
        let padIdentity = identity("iPad")
        let pad = model(padIdentity, hosts: padHosts)
        let phone = model(identity("iPhone"))
        confirm(phone, pad)
        // 钥匙串圈里的冒充者：自己登记、自己封一条结果给 iPad，冒充一台 Mac。
        let impostor = identity("iPhone")
        try roster.save(.device(impostor.device))
        let fake = mac("Mac mini")
        let sealed = try RemoteSiblingSeal.seal(
            RemoteSiblingGrant(hostID: fake.id, hostName: fake.name, hostKey: fake.publicKey, outcome: "added"),
            candidate: padIdentity.device.id, voucher: impostor.device.id,
            key: RemoteSiblingSeal.key(local: impostor.key, remote: padIdentity.device.publicKey))
        try roster.save(.grant(sealed))
        // 冒用真 iPhone 的 ID 也不行：封它的钥匙不是 iPhone 的。
        var spoofed = sealed
        spoofed.voucher = phone.localDevice.id
        try roster.save(.grant(spoofed))
        pad.refresh()
        XCTAssertTrue(padHosts.adopted.isEmpty)
        XCTAssertTrue(pad.received.isEmpty)
    }

    func test_old_mac_is_recorded_and_asked_again_much_later_while_unreachable_macs_retry_soon() async throws {
        let old = mac("Old Mac"), offline = mac("Offline Mac")
        let phoneHosts = FakeHosts(targets: [old, offline])
        phoneHosts.failures[old.id] = RemoteAttachError.rejected("这台 Mac 上的 uTerm 版本太旧")
        phoneHosts.failures[offline.id] = RemoteProtocolError.timeout
        let padHosts = FakeHosts()
        let phone = model(identity("iPhone"), hosts: phoneHosts)
        let pad = model(identity("iPad"), hosts: padHosts)
        confirm(phone, pad)
        for _ in 0..<3 {
            phone.refresh()
            await settle(phone)
        }
        XCTAssertEqual(phoneHosts.asked.count, 2, "两台各问一次，连不上的不会立刻重问")
        pad.refresh()
        XCTAssertEqual(pad.received.map(\.hostName), ["Old Mac"], "版本太旧的告诉新设备；连不上的什么都不写")
        guard case .refused = pad.received.first?.status else { return XCTFail() }
        XCTAssertTrue(padHosts.adopted.isEmpty)

        clock += RemoteSiblingDevices.vouchRetryInterval + 1
        phone.refresh()
        await settle(phone)
        XCTAssertEqual(phoneHosts.asked.last?.host, offline.id, "连不上的过一分钟再问")
        phone.refresh()
        await settle(phone)
        XCTAssertEqual(phoneHosts.asked.filter { $0.host == old.id }.count, 1, "太旧的几个小时内不再问")

        phone.refresh()
        XCTAssertEqual(phone.rows.first?.delivery?.refused, ["Old Mac"])
        XCTAssertEqual(phone.rows.first?.delivery?.waiting, ["Offline Mac"])
    }

    func test_mac_that_changed_its_key_is_asked_again() async throws {
        var mini = mac()
        let phoneHosts = FakeHosts(targets: [mini])
        let phone = model(identity("iPhone"), hosts: phoneHosts)
        let pad = model(identity("iPad"))
        confirm(phone, pad)
        phone.refresh()
        await settle(phone)
        mini.publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        phoneHosts.targets = [mini]
        clock += RemoteSiblingDevices.vouchRetryInterval + 1
        phone.refresh()
        await settle(phone)
        XCTAssertEqual(phoneHosts.asked.count, 2)
    }

    func test_only_confirmed_devices_are_vouched_for() async {
        let phoneHosts = FakeHosts(targets: [mac()])
        let phone = model(identity("iPhone"), hosts: phoneHosts)
        let pad = model(identity("iPad"))
        phone.refresh()
        pad.refresh()
        phone.refresh()
        await settle(phone)
        XCTAssertTrue(phoneHosts.asked.isEmpty)
        confirm(phone, pad)
        phone.forgetConfirmation(pad.localDevice.id)
        phone.refresh()
        await settle(phone)
        XCTAssertTrue(phoneHosts.asked.isEmpty, "取消确认后不再替它开通")
    }

    // MARK: - 丢了的设备

    func test_lost_device_is_dropped_everywhere_and_revoked_on_each_mac() async throws {
        let mini = mac("Mac mini"), old = mac("Old Mac"), foreign = mac("Friend Mac")
        let phoneHosts = FakeHosts(targets: [mini, old, foreign])
        phoneHosts.revokeFailures[old.id] = RemoteAttachError.rejected("这台 Mac 上的 uTerm 版本太旧")
        phoneHosts.revokeOutcomes[foreign.id] = .notInFamily
        let macHosts = FakeHosts()
        let phone = model(identity("iPhone"), hosts: phoneHosts)
        let pad = model(identity("iPad"))
        let laptop = model(identity("MacBook"), hosts: macHosts)
        // iPhone 确认过 iPad；MacBook 认可 iPad 当担保者（iPad 确认过 MacBook）。
        confirm(phone, pad)
        confirm(pad, laptop)
        phone.refresh()
        await settle(phone)
        phone.refresh()
        await settle(phone)
        phone.refresh()
        await settle(phone)
        let vouchedBefore = phoneHosts.asked.count

        // MacBook 上报告 iPad 丢了。
        laptop.markLost(pad.localDevice.id)
        XCTAssertFalse(laptop.rows.contains { $0.id == pad.localDevice.id }, "从列表里去掉")
        XCTAssertFalse(laptop.rows.contains { $0.isTrustedVoucher }, "不再收它开通的结果")
        XCTAssertEqual(laptop.lost.map(\.id), [pad.localDevice.id])

        // iPhone 看到墓碑：撤掉对它的确认，逐台请 Mac 撤销。
        for _ in 0..<4 {
            phone.refresh()
            await settle(phone)
        }
        XCTAssertFalse(phone.rows.contains { $0.id == pad.localDevice.id })
        XCTAssertEqual(Set(phoneHosts.revoked.map(\.host)), [mini.id, old.id, foreign.id])
        XCTAssertTrue(phoneHosts.revoked.allSatisfy { $0.device == pad.localDevice.id && $0.key == pad.localDevice.publicKey })
        XCTAssertEqual(phoneHosts.asked.count, vouchedBefore, "不再替它开通")
        let progress = try XCTUnwrap(phone.lost.first)
        XCTAssertEqual(progress.revoked, ["Mac mini"])
        XCTAssertEqual(Set(progress.refused.keys), ["Old Mac", "Friend Mac"])

        // 撤过的不再问；太旧的几个小时后再问。
        clock += RemoteSiblingDevices.vouchRetryInterval + 1
        phone.refresh()
        await settle(phone)
        XCTAssertEqual(phoneHosts.revoked.count, 3)
        clock += RemoteSiblingDevices.vouchRefusedRetryInterval
        phone.refresh()
        await settle(phone)
        XCTAssertEqual(phoneHosts.revoked.last?.host, old.id)

        // 丢了的那台自己：不再登记、不再答确认。
        pad.refresh()
        XCTAssertTrue(pad.localReportedLost)
        XCTAssertNil(roster.load().device(pad.localDevice.id), "条目被别的设备删了，它也不再写回去")
    }

    func test_found_device_can_be_unreported_and_reinstalled_device_is_unaffected() {
        let phone = model(identity("iPhone"))
        let padIdentity = identity("iPad")
        let pad = model(padIdentity)
        confirm(phone, pad)
        phone.markLost(pad.localDevice.id)
        pad.refresh()
        XCTAssertTrue(pad.localReportedLost)

        // 换了钥匙（重装）的同一台设备不受墓碑影响。
        let reinstalled = model(identity("iPad", id: padIdentity.device.id))
        reinstalled.refresh()
        XCTAssertFalse(reinstalled.localReportedLost)
        phone.refresh()
        XCTAssertEqual(phone.rows.first { $0.id == padIdentity.device.id }?.status, .unconfirmed, "要重新确认")

        phone.clearLostReport(padIdentity.device.id)
        XCTAssertTrue(phone.lost.isEmpty)
        XCTAssertTrue(roster.load().tombstones.isEmpty)
    }

    func test_tombstones_expire() throws {
        let phone = model(identity("iPhone"))
        let pad = model(identity("iPad"))
        phone.refresh()
        pad.refresh()
        phone.markLost(pad.localDevice.id)
        XCTAssertEqual(roster.load().tombstones.count, 1)
        clock += RemoteSiblingTombstone.lifetime + 1
        phone.refresh()
        XCTAssertTrue(roster.load().tombstones.isEmpty)
        XCTAssertTrue(phone.lost.isEmpty)
    }

    func test_stale_reveal_and_grants_for_unpaired_macs_are_cleaned_up() async throws {
        let mini = mac()
        let phoneHosts = FakeHosts(targets: [mini])
        let phoneIdentity = identity("iPhone")
        let phone = model(phoneIdentity, hosts: phoneHosts)
        let pad = model(identity("iPad"))
        phone.refresh()
        pad.refresh()
        phone.confirm(pad.localDevice.id)
        pad.refresh()
        XCTAssertNotNil(roster.load().message(.reveal, candidate: pad.localDevice.id, voucher: phone.localDevice.id))
        // 已有设备那边 App 被关、challenge 留着没删：重开后它清掉 challenge，新设备随后清掉自己的回答。
        model(phoneIdentity).refresh()
        pad.refresh()
        XCTAssertNil(roster.load().message(.reveal, candidate: pad.localDevice.id, voucher: phone.localDevice.id))

        confirm(phone, pad)
        phone.refresh()
        await settle(phone)
        XCTAssertEqual(roster.load().grants.count, 1)
        phoneHosts.targets = []
        phone.refresh()
        XCTAssertTrue(roster.load().grants.isEmpty, "不再配对的 Mac 的开通结果清掉")
    }

    // MARK: - 目录收下 Mac

    func test_directory_adopts_new_macs_but_never_overrides_or_brings_back_forgotten_ones() throws {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let directory = RemoteMacDirectory(identity: identity, adoptsRelayAsDefault: false)
        let host = mac()
        let relay = RemoteRelayConfig(name: "r", host: "relay.example.invalid", port: 1, relayID: "rid",
                                      key: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString(),
                                      scope: host.id.uuidString, cert: Data([1]).base64EncodedString(), expires: 9_999_999_999)
        var grant = RemoteSiblingGrant(hostID: host.id, hostName: host.name, hostKey: host.publicKey, hostModel: "Mac mini",
                                       hostPlatform: "mac", outcome: "added", relay: relay)
        XCTAssertEqual(directory.adopt(grant), .added)
        XCTAssertEqual(identity.peer(id: host.id)?.publicKey, host.publicKey)
        XCTAssertEqual(identity.peer(id: host.id)?.relay, relay, "成员证书只给这台 Mac 用")
        XCTAssertTrue(directory.macs.contains { $0.deviceID == host.id })
        XCTAssertEqual(directory.adopt(grant), .alreadyKnown)

        var other = grant
        other.hostKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertEqual(directory.adopt(other), .conflict)
        XCTAssertEqual(identity.peer(id: host.id)?.publicKey, host.publicKey, "不覆盖本机记着的公钥")

        try identity.revoke(id: host.id)
        XCTAssertEqual(directory.adopt(grant), .forgotten)
        XCTAssertNil(identity.peer(id: host.id))

        grant.hostID = UUID()
        grant.relay = nil
        XCTAssertEqual(directory.adopt(grant), .added)
    }

    // MARK: - 真服务端

    func test_end_to_end_confirmed_device_connects_to_the_mac_without_approval() async throws {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        server.vouchPolicy = { true }
        server.start()
        defer { server.stop() }
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(server.port)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let serverKey = try server.identity.localIdentity().publicKey.rawRepresentation

        // iPhone：在 Mac 上审批配对过。
        let phoneIdentity = identity("iPhone")
        let phoneHostsTable = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try phoneHostsTable.saveRaw(phoneIdentity.key.rawRepresentation, account: "identity")
        let phoneClient = RemoteMacClient(macName: "测试 Mac", endpoint: endpoint, identity: phoneHostsTable)
        phoneClient.localDeviceOverride = (phoneIdentity.device.id, "iPhone")
        let connecting = Task { await phoneClient.connect() }
        _ = await waitUntil { !server.pairingRequests.isEmpty }
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(phoneClient.state, .connected)
        defer { phoneClient.disconnect() }

        // iPad：从没连过这台 Mac。
        let padIdentity = identity("iPad")
        let padHostsTable = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try padHostsTable.saveRaw(padIdentity.key.rawRepresentation, account: "identity")
        let padDirectory = RemoteMacDirectory(identity: padHostsTable, adoptsRelayAsDefault: false)

        let target = RemoteSiblingVouchTarget(id: server.localID, name: "测试 Mac", publicKey: serverKey, platform: "mac")
        let phoneHosts = ClientHosts(target: target, client: phoneClient)
        let phone = model(phoneIdentity, hosts: nil)
        phone.hosts = phoneHosts
        let pad = model(padIdentity)
        pad.hosts = padDirectory
        confirm(phone, pad)
        phone.refresh()
        await settle(phone)
        XCTAssertNotNil(server.peerVouches[padIdentity.device.id], "Mac 记下了 iPad，来路是 iPhone")

        pad.refresh()
        XCTAssertEqual(pad.received.first?.status, .opened)
        let adopted = try XCTUnwrap(padHostsTable.peer(id: server.localID))
        XCTAssertEqual(adopted.publicKey, serverKey)

        let padClient = RemoteMacClient(macName: "测试 Mac", endpoint: endpoint, identity: padHostsTable,
                                        expectedPeer: adopted)
        padClient.localDeviceOverride = (padIdentity.device.id, "iPad")
        let padConnecting = Task { await padClient.connect() }
        _ = await waitUntil(3) { padClient.state == .connected || !server.pairingRequests.isEmpty }
        XCTAssertTrue(server.pairingRequests.isEmpty, "不弹审批")
        await padConnecting.value
        XCTAssertEqual(padClient.state, .connected)
        padClient.disconnect()
    }
}

/// 假的 Mac：记下问了谁，按设定回结果或抛错；新设备收下的结果也记下来。
@MainActor
private final class FakeHosts: RemoteSiblingHostAccess {
    var targets: [RemoteSiblingVouchTarget]
    var failures: [UUID: Error] = [:]
    var revokeFailures: [UUID: Error] = [:]
    var revokeOutcomes: [UUID: RemoteSiblingRevokeResult.Outcome] = [:]
    private(set) var asked: [(device: UUID, host: UUID)] = []
    private(set) var revoked: [(device: UUID, key: Data, host: UUID)] = []
    private(set) var adopted: [RemoteSiblingGrant] = []

    init(targets: [RemoteSiblingVouchTarget] = []) {
        self.targets = targets
    }

    func vouchTargets() -> [RemoteSiblingVouchTarget] { targets }

    func pairedHostNames() -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.name) })
    }

    func vouch(_ device: RemoteSiblingDevice, at host: UUID) async throws -> RemoteVouchResult {
        asked.append((device.id, host))
        if let failure = failures[host] { throw failure }
        return RemoteVouchResult(requestID: UUID(), outcome: .added, internetAccess: false)
    }

    func adopt(_ grant: RemoteSiblingGrant) -> RemoteSiblingAdoption {
        if adopted.contains(where: { $0.hostID == grant.hostID }) { return .alreadyKnown }
        adopted.append(grant)
        return .added
    }

    func revokeSibling(_ deviceID: UUID, publicKey: Data, at host: UUID) async throws -> RemoteSiblingRevokeResult {
        revoked.append((deviceID, publicKey, host))
        if let failure = revokeFailures[host] { throw failure }
        return RemoteSiblingRevokeResult(requestID: UUID(), outcome: revokeOutcomes[host] ?? .revoked)
    }
}

/// 已有设备一侧：经真的 `RemoteMacClient` 问一台真的测试服务端。
@MainActor
private final class ClientHosts: RemoteSiblingHostAccess {
    let target: RemoteSiblingVouchTarget
    let client: RemoteMacClient

    init(target: RemoteSiblingVouchTarget, client: RemoteMacClient) {
        self.target = target
        self.client = client
    }

    func vouchTargets() -> [RemoteSiblingVouchTarget] { [target] }
    func pairedHostNames() -> [UUID: String] { [target.id: target.name] }

    func vouch(_ device: RemoteSiblingDevice, at host: UUID) async throws -> RemoteVouchResult {
        try await client.vouch(for: device)
    }

    func adopt(_ grant: RemoteSiblingGrant) -> RemoteSiblingAdoption { .alreadyKnown }

    func revokeSibling(_ deviceID: UUID, publicKey: Data, at host: UUID) async throws -> RemoteSiblingRevokeResult {
        try await client.revokeSibling(deviceID, publicKey: publicKey)
    }
}
