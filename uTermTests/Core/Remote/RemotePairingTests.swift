import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 配对：每对设备都要配对一次（局域网审批或邀请），同一 Apple ID 不算数；按设备 ID 与公钥认对端、拉黑；
/// 两个方向的信任表分开。端到端部分是真实的 `RemoteMacClient` 经 127.0.0.1 连真实的 `RemoteHostServer`，身份都在内存里。
@MainActor
final class RemotePairingTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func key() -> Data { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }

    // MARK: - 邀请与凭据

    func test_invitation_round_trips_through_the_qr_text() throws {
        let invitation = RemotePairingInvitation(macID: UUID(), macName: "我的 MacBook Pro", macKey: key(),
                                                 token: RemotePairingInvitation.newToken())
        let text = invitation.url.absoluteString
        XCTAssertTrue(text.hasPrefix("uterm://pair?"))
        XCTAssertEqual(RemotePairingInvitation(scanned: text), invitation)
        XCTAssertEqual(RemotePairingInvitation(scanned: " \(text)\n"), invitation, "首尾空白不影响")
    }

    func test_foreign_or_damaged_codes_are_not_invitations() throws {
        let text = RemotePairingInvitation(macID: UUID(), macName: "Mac", macKey: key(),
                                           token: RemotePairingInvitation.newToken()).url.absoluteString
        XCTAssertNil(RemotePairingInvitation(scanned: "https://example.com/pair?v=1"))
        XCTAssertNil(RemotePairingInvitation(scanned: text.replacingOccurrences(of: "v=1", with: "v=2")), "版本不认识")
        XCTAssertNil(RemotePairingInvitation(scanned: text.replacingOccurrences(of: "&t=", with: "&x=")), "缺令牌")
        XCTAssertNil(RemotePairingInvitation(scanned: "WIFI:S:home;T:WPA;P:secret;;"))
    }

    func test_proof_is_bound_to_the_token_and_both_keys() {
        let token = RemotePairingInvitation.newToken()
        let phone = key(), mac = key()
        let proof = RemotePairingInvitation.proof(token: token, phoneKey: phone, macKey: mac)
        XCTAssertTrue(RemotePairingInvitation.verify(proof, token: token, phoneKey: phone, macKey: mac))
        XCTAssertFalse(RemotePairingInvitation.verify(proof, token: RemotePairingInvitation.newToken(), phoneKey: phone,
                                                      macKey: mac), "令牌不对")
        XCTAssertFalse(RemotePairingInvitation.verify(proof, token: token, phoneKey: key(), macKey: mac),
                       "截到的凭据换一台手机用不了")
        XCTAssertFalse(RemotePairingInvitation.verify(proof, token: token, phoneKey: phone, macKey: key()))
    }

    // MARK: - 信任与拉黑

    func test_only_local_pairing_is_recognized_and_revoking_blocks_until_paired_again() throws {
        let identity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        let peer = RemotePeer(id: UUID(), name: "iPhone", publicKey: key(), pairedAt: .now)
        XCTAssertFalse(identity.recognizes(id: peer.id, publicKey: peer.publicKey), "没配对过不认")

        try identity.trust(peer)
        XCTAssertTrue(identity.recognizes(id: peer.id, publicKey: peer.publicKey))
        XCTAssertFalse(identity.recognizes(id: peer.id, publicKey: key()), "同一个 ID 换了公钥不认")

        try identity.revoke(id: peer.id)
        XCTAssertFalse(identity.recognizes(id: peer.id, publicKey: peer.publicKey))
        XCTAssertTrue(identity.isBlocked(peer.id))
        try identity.trust(peer)
        XCTAssertFalse(identity.isBlocked(peer.id), "重新配对解除拉黑")
    }

    /// 同一台 Mac 既能被控制又能去控制别人：「我要控制的主机」不能被被控端当成「允许来控制我」。
    func test_trusted_hosts_are_not_trusted_controllers() throws {
        let storage = RemoteMemoryStorage()
        let hosts = RemoteIdentityStore(role: .hosts, storage: storage)
        let controllers = RemoteIdentityStore(role: .controllers, storage: storage)
        let mac = RemotePeer(id: UUID(), name: "办公室 Mac", publicKey: key(), pairedAt: .now)
        try hosts.trust(mac)

        XCTAssertTrue(hosts.recognizes(id: mac.id, publicKey: mac.publicKey))
        XCTAssertFalse(controllers.recognizes(id: mac.id, publicKey: mac.publicKey))
        XCTAssertTrue(controllers.trustedPeers().isEmpty)
        try hosts.revoke(id: mac.id)
        XCTAssertFalse(controllers.isBlocked(mac.id), "拉黑也分方向")
        XCTAssertEqual(try hosts.localIdentity().rawRepresentation, try controllers.localIdentity().rawRepresentation,
                       "本机长期密钥两个方向共用")
    }

    func test_legacy_roster_withdraw_removes_only_this_device() throws {
        let storage = RemoteMemorySyncedStorage()
        let mine = UUID(), other = UUID()
        try storage.save(Data("mine".utf8), account: mine.uuidString)
        try storage.save(Data("other".utf8), account: other.uuidString)
        RemoteLegacyRoster.withdraw(id: mine, storage: storage)
        XCTAssertEqual(storage.loadAll(), [Data("other".utf8)])
    }

    // MARK: - 端到端

    private struct Rig {
        let server: RemoteHostServer
        let macID: UUID
        let macKey: Data
        let port: NWEndpoint.Port
    }

    private func makeServer(storage: RemoteMemoryStorage = RemoteMemoryStorage(), localID: UUID = UUID()) async throws
        -> Rig {
        let identity = RemoteIdentityStore(role: .controllers, storage: storage)
        let macID = localID
        let server = RemoteHostServer(registry: TerminalSessionRegistry(), identity: identity,
                                      localName: "测试 Mac", localID: macID, advertises: false)
        server.start()
        addTeardownBlock { @MainActor in server.stop() }
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: try XCTUnwrap(server.port)))
        return Rig(server: server, macID: macID, macKey: try identity.localIdentity().publicKey.rawRepresentation,
                   port: port)
    }

    private func phone(_ rig: Rig, expecting mac: RemotePeer?,
                       identity: RemoteIdentityStore = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        -> RemoteMacClient {
        RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: rig.port), identity: identity,
                        expectedPeer: mac)
    }

    /// 局域网里发现的 Mac（还不知道它的公钥）：Mac 上审批通过后两边都记住对方，之后直接放行。
    func test_unpaired_device_pairs_after_approval_and_is_recognized_next_time() async throws {
        let rig = try await makeServer()
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let client = phone(rig, expecting: nil, identity: phoneIdentity)
        var paired = 0
        client.onPaired = { paired += 1 }
        let connecting = Task { await client.connect() }
        let asked = await waitUntil {
            guard !rig.server.pairingRequests.isEmpty, case .awaitingApproval = client.state else { return false }
            return true
        }
        XCTAssertTrue(asked, "没配对过的设备要在 Mac 上点允许")
        guard case .awaitingApproval(let code) = client.state else { return XCTFail("手机应显示核对码，实际 \(client.state)") }
        XCTAssertEqual(rig.server.pairingRequests.first?.code, code, "两端核对码一致")
        rig.server.approvePairing(try XCTUnwrap(rig.server.pairingRequests.first?.id))
        await connecting.value

        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(paired, 1)
        let mac = try XCTUnwrap(phoneIdentity.peer(id: rig.macID))
        XCTAssertEqual(mac.publicKey, rig.macKey)
        XCTAssertTrue(mac.isMac, "Mac 在握手里报了自己是 Mac")
        XCTAssertEqual(rig.server.trustedPeers.map(\.id), [RemoteLocalDevice.id()])
        XCTAssertEqual(rig.server.trustedPeers.first?.platform, RemoteDevicePlatform.current.rawValue)
        client.disconnect()

        let again = phone(rig, expecting: mac, identity: phoneIdentity)
        again.onPaired = { paired += 1 }
        await again.connect()
        XCTAssertEqual(again.state, .connected)
        XCTAssertTrue(rig.server.pairingRequests.isEmpty, "配对过的不再审批")
        XCTAssertEqual(paired, 1, "已经记着的不算新配对")
        again.disconnect()
    }

    /// Mac A 配对去控制 Mac B 之后，B 反过来连 A 仍要在 A 上审批：A 记下的「我控制的 B」不是「允许 B 控制我」。
    func test_controlling_a_mac_does_not_let_it_control_you_back() async throws {
        let storageA = RemoteMemoryStorage(), storageB = RemoteMemoryStorage()
        // 进程里的客户端都报 `RemoteLocalDevice.id()`：让 B 的主机 ID 也用它，B 的客户端才和 A 记下的 B 是同一个身份。
        let macB = try await makeServer(storage: storageB, localID: RemoteLocalDevice.id())
        let macA = try await makeServer(storage: storageA)

        let aControlsB = phone(macB, expecting: nil, identity: RemoteIdentityStore(role: .hosts, storage: storageA))
        let connecting = Task { await aControlsB.connect() }
        let asked = await waitUntil { !macB.server.pairingRequests.isEmpty }
        XCTAssertTrue(asked)
        macB.server.approvePairing(try XCTUnwrap(macB.server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(aControlsB.state, .connected)
        aControlsB.disconnect()
        XCTAssertTrue(macA.server.trustedPeers.isEmpty, "A 允许来控制它的设备里没有 B")

        let bControlsA = phone(macA, expecting: nil, identity: RemoteIdentityStore(role: .hosts, storage: storageB))
        let reverse = Task { await bControlsA.connect() }
        let askedA = await waitUntil { !macA.server.pairingRequests.isEmpty }
        XCTAssertTrue(askedA, "B 控制 A 要另外配对")
        macA.server.rejectPairing(try XCTUnwrap(macA.server.pairingRequests.first?.id))
        await reverse.value
        XCTAssertNotEqual(bControlsA.state, .connected)
    }

    func test_trusted_phone_name_follows_what_it_reports() async throws {
        let rig = try await makeServer()
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let phoneKey = try phoneIdentity.localIdentity().publicKey.rawRepresentation
        let pairedAt = Date(timeIntervalSince1970: 1_800_000_000)
        // 早先配对时手机只报得出「iPhone」（iOS 16 起没有权限拿不到用户起的名字）。
        try rig.server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "iPhone", publicKey: phoneKey,
                                        pairedAt: pairedAt))

        let client = phone(rig, expecting: RemotePeer(id: rig.macID, name: "测试 Mac", publicKey: rig.macKey,
                                                      pairedAt: .now), identity: phoneIdentity)
        await client.connect()
        XCTAssertEqual(client.state, .connected)

        let stored = try XCTUnwrap(rig.server.trustedPeers.first { $0.id == RemoteLocalDevice.id() })
        XCTAssertEqual(stored.name, LANSyncCoordinator.localDeviceName(), "再连上来时换成手机现在报的名字")
        XCTAssertEqual(stored.pairedAt, pairedAt, "配对时间不变")
        XCTAssertEqual(stored.publicKey, phoneKey)
        XCTAssertEqual(rig.server.trustedPeers.count, 1)
        client.disconnect()
    }

    func test_alias_set_on_mac_survives_reconnect_and_names_the_connection() async throws {
        let rig = try await makeServer()
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let phoneKey = try phoneIdentity.localIdentity().publicKey.rawRepresentation
        try rig.server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "iPhone", publicKey: phoneKey,
                                        pairedAt: .now, model: "iPhone 16 Pro", alias: "办公室手机"))

        let client = phone(rig, expecting: RemotePeer(id: rig.macID, name: "测试 Mac", publicKey: rig.macKey,
                                                      pairedAt: .now), identity: phoneIdentity)
        await client.connect()
        XCTAssertEqual(client.state, .connected)

        let stored = try XCTUnwrap(rig.server.trustedPeers.first { $0.id == RemoteLocalDevice.id() })
        XCTAssertEqual(stored.alias, "办公室手机", "设备报的新名字不覆盖 Mac 上起的名字")
        // 测试里的客户端跑在 Mac 上：Apple 芯片会报自己的商品名，Intel 不报，此时不清掉上次记的。
        XCTAssertEqual(stored.model, RemoteDeviceModel.current() ?? "iPhone 16 Pro", "没报机型的连接不清掉上次记的机型")
        XCTAssertEqual(rig.server.connectedDevices, ["办公室手机"])
        client.disconnect()
    }

    func test_renaming_connected_phone_updates_its_live_name() async throws {
        let rig = try await makeServer()
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let phoneKey = try phoneIdentity.localIdentity().publicKey.rawRepresentation
        let id = RemoteLocalDevice.id()
        try rig.server.trust(RemotePeer(id: id, name: "iPhone", publicKey: phoneKey, pairedAt: .now))
        let client = phone(rig, expecting: RemotePeer(id: rig.macID, name: "测试 Mac", publicKey: rig.macKey,
                                                      pairedAt: .now), identity: phoneIdentity)
        await client.connect()
        XCTAssertEqual(client.state, .connected)

        try rig.server.rename(id, to: "  卧室 iPad  ")
        XCTAssertEqual(rig.server.trustedPeers.first?.displayName, "卧室 iPad")
        XCTAssertEqual(rig.server.connectedDevices, ["卧室 iPad"], "正连着的不用等重连就换名字")

        try rig.server.rename(id, to: "")
        let reported = try XCTUnwrap(rig.server.trustedPeers.first)
        XCTAssertNil(reported.alias, "留空 = 恢复设备自己报的名字")
        XCTAssertEqual(rig.server.connectedDevices, [reported.name])
        client.disconnect()
    }

    func test_scanned_invitation_pairs_once_without_approval() async throws {
        let rig = try await makeServer()
        let invitation = try rig.server.makePairingInvitation()
        XCTAssertEqual(invitation.macKey, rig.macKey)
        let mac = RemotePeer(id: invitation.macID, name: invitation.macName, publicKey: invitation.macKey, pairedAt: .now)

        let client = phone(rig, expecting: mac)
        client.pairingToken = invitation.token
        await client.connect()

        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(rig.server.pairingRequests.isEmpty)
        XCTAssertNil(rig.server.pairingInvitation, "用过一次就作废")
        XCTAssertNil(client.pairingToken)
        client.disconnect()

        // 同一张码第二台手机再用：已经作废，退回到在 Mac 上审批。
        let late = phone(rig, expecting: mac)
        late.pairingToken = invitation.token
        let connecting = Task { await late.connect() }
        let asked = await waitUntil { !rig.server.pairingRequests.isEmpty }
        XCTAssertTrue(asked)
        rig.server.rejectPairing(try XCTUnwrap(rig.server.pairingRequests.first?.id))
        await connecting.value
    }

    func test_phone_refuses_a_mac_whose_key_does_not_match() async throws {
        let rig = try await makeServer()
        let impostor = RemotePeer(id: rig.macID, name: "测试 Mac", publicKey: key(), pairedAt: .now)
        let client = phone(rig, expecting: impostor)
        await client.connect()

        guard case .failed(let message) = client.state else { return XCTFail("应拒绝连接，实际 \(client.state)") }
        XCTAssertEqual(message, RemoteProtocolError.peerIdentityChanged.localizedDescription)
        XCTAssertFalse(client.canAutoReconnect, "身份不对，重试也没用")
    }

    /// Mac 重装过（新密钥）、重新出了邀请：邀请给的是新公钥，手机本机信任里还是旧的。按邀请连得上，
    /// 并把本机记的换成新的。
    func test_expected_identity_replaces_a_stale_local_key() async throws {
        let rig = try await makeServer()
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try phoneIdentity.trust(RemotePeer(id: rig.macID, name: "测试 Mac", publicKey: key(), pairedAt: .distantPast))
        try rig.server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "iPhone",
                                        publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                        pairedAt: .now))

        let client = phone(rig, expecting: RemotePeer(id: rig.macID, name: "测试 Mac", publicKey: rig.macKey,
                                                      pairedAt: .now), identity: phoneIdentity)
        await client.connect()

        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(phoneIdentity.peer(id: rig.macID)?.publicKey, rig.macKey)
        client.disconnect()
    }

    func test_revoked_phone_needs_approval_again() async throws {
        let rig = try await makeServer()
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try rig.server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "iPhone",
                                        publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                        pairedAt: .now))
        rig.server.revoke(RemoteLocalDevice.id())

        let client = phone(rig, expecting: RemotePeer(id: rig.macID, name: "测试 Mac", publicKey: rig.macKey,
                                                      pairedAt: .now), identity: phoneIdentity)
        let connecting = Task { await client.connect() }
        let asked = await waitUntil { !rig.server.pairingRequests.isEmpty }
        XCTAssertTrue(asked, "在 Mac 上撤销过的设备要重新确认")
        rig.server.rejectPairing(try XCTUnwrap(rig.server.pairingRequests.first?.id))
        await connecting.value
    }
}
