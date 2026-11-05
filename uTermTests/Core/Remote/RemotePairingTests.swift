import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 配对：同一 Apple ID 的名册自动配对、扫码配对、按设备 ID 与公钥认 Mac、拉黑。
/// 端到端部分是真实的 `RemoteMacClient` 经 127.0.0.1 连真实的 `RemoteHostServer`，名册与身份都在内存里。
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

    // MARK: - 名册与拉黑

    func test_roster_vouches_only_for_matching_id_and_key() {
        let roster = RemoteCloudRoster(storage: RemoteMemoryRosterStorage())
        let entry = RemoteRosterEntry(id: UUID(), name: "iPhone", publicKey: key(), platform: .mobile, updatedAt: .now)
        roster.publish(entry)
        XCTAssertEqual(roster.entries(), [entry])
        XCTAssertTrue(roster.vouches(for: entry.id, publicKey: entry.publicKey))
        XCTAssertFalse(roster.vouches(for: entry.id, publicKey: key()), "同一个 ID 换了公钥不认")
        XCTAssertFalse(roster.vouches(for: UUID(), publicKey: entry.publicKey))
        roster.withdraw(id: entry.id)
        XCTAssertTrue(roster.entries().isEmpty)
    }

    func test_revoking_blocks_roster_trust_until_paired_again() throws {
        let identity = RemoteIdentityStore(storage: RemoteMemoryStorage())
        let roster = RemoteCloudRoster(storage: RemoteMemoryRosterStorage())
        let peer = RemotePeer(id: UUID(), name: "iPhone", publicKey: key(), pairedAt: .now)
        roster.publish(RemoteRosterEntry(id: peer.id, name: peer.name, publicKey: peer.publicKey, platform: .mobile,
                                         updatedAt: .now))
        XCTAssertTrue(identity.recognizes(id: peer.id, publicKey: peer.publicKey, roster: roster))
        XCTAssertFalse(identity.recognizes(id: peer.id, publicKey: peer.publicKey, roster: nil), "没有名册就不认")

        try identity.revoke(id: peer.id)
        XCTAssertFalse(identity.recognizes(id: peer.id, publicKey: peer.publicKey, roster: roster),
                       "撤销过的设备，名册里还有也不再自动信任")
        try identity.trust(peer)
        XCTAssertFalse(identity.isBlocked(peer.id), "重新配对解除拉黑")
        XCTAssertTrue(identity.recognizes(id: peer.id, publicKey: peer.publicKey, roster: roster))
    }

    // MARK: - 端到端

    private struct Rig {
        let server: RemoteHostServer
        let macID: UUID
        let macKey: Data
        let roster: RemoteCloudRoster
        let port: NWEndpoint.Port
    }

    private func makeServer() async throws -> Rig {
        let identity = RemoteIdentityStore(storage: RemoteMemoryStorage())
        let roster = RemoteCloudRoster(storage: RemoteMemoryRosterStorage())
        let macID = UUID()
        let server = RemoteHostServer(registry: TerminalSessionRegistry(), identity: identity, roster: roster,
                                      localName: "测试 Mac", localID: macID, advertises: false)
        server.start()
        addTeardownBlock { @MainActor in server.stop() }
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: try XCTUnwrap(server.port)))
        return Rig(server: server, macID: macID, macKey: try identity.localIdentity().publicKey.rawRepresentation,
                   roster: roster, port: port)
    }

    private func phone(_ rig: Rig, expecting mac: RemotePeer?,
                       identity: RemoteIdentityStore = RemoteIdentityStore(storage: RemoteMemoryStorage()))
        -> RemoteMacClient {
        RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: rig.port), identity: identity,
                        expectedPeer: mac)
    }

    func test_same_apple_id_phone_connects_without_approval() async throws {
        let rig = try await makeServer()
        let phoneIdentity = RemoteIdentityStore(storage: RemoteMemoryStorage())
        // 手机经名册登记过自己（同一 Apple ID）。握手里报的设备 ID 是本机真实的那个。
        rig.roster.publish(RemoteRosterEntry(id: RemoteLocalDevice.id(), name: "iPhone",
                                             publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                             platform: .mobile, updatedAt: .now))
        XCTAssertEqual(rig.roster.entry(id: rig.macID)?.publicKey, rig.macKey, "Mac 开始监听时把自己登进名册")

        let client = phone(rig, expecting: RemotePeer(id: rig.macID, name: "测试 Mac", publicKey: rig.macKey,
                                                      pairedAt: .now), identity: phoneIdentity)
        await client.connect()

        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(rig.server.pairingRequests.isEmpty, "名册担保的设备不用在 Mac 上点允许")
        XCTAssertEqual(rig.server.trustedPeers.map(\.id), [RemoteLocalDevice.id()], "记进本机信任，设置里能看到、能撤销")
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

    /// Mac 重装过（新密钥）：名册给的是新公钥，手机本机信任里还是旧的。按名册连得上，并把本机记的换成新的。
    func test_expected_identity_replaces_a_stale_local_key() async throws {
        let rig = try await makeServer()
        let phoneIdentity = RemoteIdentityStore(storage: RemoteMemoryStorage())
        try phoneIdentity.trust(RemotePeer(id: rig.macID, name: "测试 Mac", publicKey: key(), pairedAt: .distantPast))
        rig.roster.publish(RemoteRosterEntry(id: RemoteLocalDevice.id(), name: "iPhone",
                                             publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                             platform: .mobile, updatedAt: .now))

        let client = phone(rig, expecting: RemotePeer(id: rig.macID, name: "测试 Mac", publicKey: rig.macKey,
                                                      pairedAt: .now), identity: phoneIdentity)
        await client.connect()

        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(phoneIdentity.peer(id: rig.macID)?.publicKey, rig.macKey)
        client.disconnect()
    }

    func test_revoked_phone_needs_approval_even_if_the_roster_vouches() async throws {
        let rig = try await makeServer()
        let phoneIdentity = RemoteIdentityStore(storage: RemoteMemoryStorage())
        rig.roster.publish(RemoteRosterEntry(id: RemoteLocalDevice.id(), name: "iPhone",
                                             publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                             platform: .mobile, updatedAt: .now))
        rig.server.revoke(RemoteLocalDevice.id())

        let client = phone(rig, expecting: RemotePeer(id: rig.macID, name: "测试 Mac", publicKey: rig.macKey,
                                                      pairedAt: .now), identity: phoneIdentity)
        let connecting = Task { await client.connect() }
        let asked = await waitUntil { !rig.server.pairingRequests.isEmpty }
        XCTAssertTrue(asked, "在 Mac 上撤销过的设备，名册里有也要重新确认")
        rig.server.rejectPairing(try XCTUnwrap(rig.server.pairingRequests.first?.id))
        await connecting.value
    }

    func test_stopping_withdraws_the_mac_from_the_roster() async throws {
        let rig = try await makeServer()
        XCTAssertNotNil(rig.roster.entry(id: rig.macID))
        rig.server.stop()
        XCTAssertNil(rig.roster.entry(id: rig.macID), "关掉远控：同一 Apple ID 的手机不再列出它")
    }
}
