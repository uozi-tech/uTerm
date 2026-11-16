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

    /// 走完一次确认：已有设备点「一致」，`candidateAccepts` 时新设备也点。
    private func confirm(_ voucher: RemoteSiblingDevices, _ candidate: RemoteSiblingDevices, candidateAccepts: Bool = true) {
        voucher.refresh()
        candidate.refresh()
        voucher.confirm(candidate.localDevice.id)
        candidate.refresh()
        voucher.refresh()
        if candidateAccepts { candidate.acceptIncoming(voucher.localDevice.id) }
        voucher.accept()
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
    private(set) var asked: [(device: UUID, host: UUID)] = []
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
}
