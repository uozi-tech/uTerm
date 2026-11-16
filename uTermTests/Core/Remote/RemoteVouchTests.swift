import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 已配对设备担保：Mac 的判断规则（纯函数），以及真服务端 + 真客户端走一遍——担保、新设备免审批连上、
/// 开关关掉、撤销过的设备、换钥匙、公网接入只继承不放大、老 Mac、整组撤销。
@MainActor
final class RemoteVouchTests: XCTestCase {
    private let hostID = UUID()

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func newKey() -> Data { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }

    private func request(id: UUID = UUID(), name: String = "iPad", key: Data? = nil) -> RemoteVouchRequest {
        RemoteVouchRequest(requestID: UUID(), deviceID: id, name: name, model: "iPad Pro", platform: "mobile",
                           publicKey: key ?? newKey())
    }

    // MARK: - 规则

    func test_policy_adds_an_unknown_device_when_allowed() {
        XCTAssertEqual(RemoteVouchPolicy.decide(request(), voucherID: UUID(), hostID: hostID, enabled: true,
                                                isBlocked: false, existing: nil), .add)
    }

    func test_policy_refuses_when_the_mac_turned_vouching_off() {
        guard case .notAllowed = RemoteVouchPolicy.decide(request(), voucherID: UUID(), hostID: hostID, enabled: false,
                                                          isBlocked: false, existing: nil) else { return XCTFail() }
    }

    func test_policy_never_brings_back_a_device_the_mac_revoked() {
        guard case .rejected = RemoteVouchPolicy.decide(request(), voucherID: UUID(), hostID: hostID, enabled: true,
                                                        isBlocked: true, existing: nil) else { return XCTFail() }
    }

    func test_policy_never_replaces_a_known_devices_key() {
        let id = UUID(), key = newKey()
        let known = RemotePeer(id: id, name: "iPad", publicKey: key, pairedAt: Date())
        XCTAssertEqual(RemoteVouchPolicy.decide(request(id: id, key: key), voucherID: UUID(), hostID: hostID, enabled: false,
                                                isBlocked: false, existing: known), .alreadyTrusted)
        guard case .rejected = RemoteVouchPolicy.decide(request(id: id), voucherID: UUID(), hostID: hostID, enabled: true,
                                                        isBlocked: false, existing: known) else { return XCTFail() }
    }

    func test_policy_rejects_self_and_invalid_identities() {
        let voucher = UUID()
        for bad in [request(id: voucher), request(id: hostID), request(key: Data(repeating: 1, count: 31)),
                    request(name: "  ")] {
            guard case .rejected = RemoteVouchPolicy.decide(bad, voucherID: voucher, hostID: hostID, enabled: true,
                                                            isBlocked: false, existing: nil) else {
                return XCTFail("应当拒绝：\(bad)")
            }
        }
    }

    func test_family_is_the_root_device_and_members_are_the_trusted_ones() {
        let root = UUID(), pad = UUID(), mac = UUID(), stranger = UUID()
        let vouches = [
            pad: RemotePeerVouch(deviceID: pad, deviceName: "iPad", vouchedBy: root, voucherName: "iPhone", family: root,
                                 vouchedAt: Date()),
            mac: RemotePeerVouch(deviceID: mac, deviceName: "Mac", vouchedBy: pad, voucherName: "iPad", family: root,
                                 vouchedAt: Date()),
        ]
        let trusted = [root, pad, mac, stranger].map { RemotePeer(id: $0, name: "x", publicKey: newKey(), pairedAt: Date()) }
        XCTAssertEqual(RemoteVouchPolicy.family(of: mac, vouches: vouches), root)
        XCTAssertEqual(RemoteVouchPolicy.family(of: root, vouches: vouches), root)
        XCTAssertEqual(Set(RemoteVouchPolicy.familyMembers(of: mac, trusted: trusted, vouches: vouches)), [root, pad, mac])
        XCTAssertEqual(RemoteVouchPolicy.familyMembers(of: stranger, trusted: trusted, vouches: vouches), [stranger])
    }

    func test_revoke_policy_only_within_the_same_group_and_the_same_key() {
        let root = UUID(), pad = UUID(), stranger = UUID(), key = newKey()
        let vouches = [pad: RemotePeerVouch(deviceID: pad, deviceName: "iPad", vouchedBy: root, voucherName: "iPhone",
                                            family: root, vouchedAt: Date())]
        let padPeer = RemotePeer(id: pad, name: "iPad", publicKey: key, pairedAt: Date())
        let request = RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: pad, publicKey: key)
        XCTAssertEqual(RemoteVouchPolicy.decideRevoke(request, requesterID: root, existing: padPeer, vouches: vouches), .revoked)
        XCTAssertEqual(RemoteVouchPolicy.decideRevoke(request, requesterID: pad, existing: padPeer, vouches: vouches), .revoked,
                       "撤自己也行")
        XCTAssertEqual(RemoteVouchPolicy.decideRevoke(request, requesterID: stranger, existing: padPeer, vouches: vouches),
                       .notInFamily)
        // 被撤的那台换过钥匙（重新配对过）：不撤。
        var other = request
        other.publicKey = newKey()
        XCTAssertEqual(RemoteVouchPolicy.decideRevoke(other, requesterID: root, existing: padPeer, vouches: vouches), .notTrusted)
        XCTAssertEqual(RemoteVouchPolicy.decideRevoke(request, requesterID: root, existing: nil, vouches: vouches), .notTrusted)
        // 手动配对的根设备也能被组里的设备撤掉（组号就是它）。
        let rootPeer = RemotePeer(id: root, name: "iPhone", publicKey: key, pairedAt: Date())
        let rootRequest = RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: root, publicKey: key)
        XCTAssertEqual(RemoteVouchPolicy.decideRevoke(rootRequest, requesterID: pad, existing: rootPeer, vouches: vouches), .revoked)
    }

    func test_result_with_an_unknown_outcome_still_decodes() throws {
        let json = Data(#"{"requestID":"\#(UUID().uuidString)","outcome":"later-version"}"#.utf8)
        let result = try JSONDecoder().decode(RemoteVouchResult.self, from: json)
        XCTAssertNil(result.kind)
    }

    func test_vouch_records_live_in_their_own_account_handed_to_the_agent() {
        XCTAssertTrue(RemoteHostAgentBridge.secretAccounts.contains(RemoteIdentityStore.vouchAccount),
                      "远控进程要拿到担保记录才能整组撤销、显示来路")
        XCTAssertNotEqual(RemoteIdentityStore.vouchAccount, "trustedPeers", "不能和信任表同一个账号：旧远控进程会丢字段")
    }

    // MARK: - 真服务端 + 真客户端

    private struct Device {
        let id: UUID
        let name: String
        let identity: RemoteIdentityStore

        var sibling: RemoteSiblingDevice {
            RemoteSiblingDevice(id: id, name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                                publicKey: try! identity.localIdentity().publicKey.rawRepresentation, updatedAt: Date())
        }

        init(_ name: String) {
            id = UUID()
            self.name = name
            identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        }
    }

    private var vouched: [RemotePeerVouch] = []

    private func makeServer(features: [String] = RemoteConstants.localFeatures, vouching: Bool = true) async throws -> RemoteHostServer {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: hostID, advertises: false, localFeatures: features)
        server.vouchPolicy = { vouching }
        server.onDeviceVouched = { [weak self] in self?.vouched.append($0) }
        server.start()
        _ = await waitUntil { server.port != nil }
        return server
    }

    private func client(_ device: Device, to server: RemoteHostServer) throws -> RemoteMacClient {
        let port = try XCTUnwrap(server.port)
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: device.identity)
        client.localDeviceOverride = (device.id, device.name)
        return client
    }

    /// 在 Mac 上审批配对，返回连上的客户端。
    private func pairByApproval(_ device: Device, to server: RemoteHostServer) async throws -> RemoteMacClient {
        let client = try client(device, to: server)
        let connecting = Task { await client.connect() }
        let asked = await waitUntil { server.pairingRequests.contains { $0.deviceName == device.name } }
        XCTAssertTrue(asked)
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first { $0.deviceName == device.name }?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        return client
    }

    /// 不审批直接连：认识它就连上，不认识就卡在等审批。
    private func connectWithoutApproval(_ device: Device, to server: RemoteHostServer) async throws -> RemoteMacClient {
        let client = try client(device, to: server)
        let connecting = Task { await client.connect() }
        _ = await waitUntil(3) { client.state == .connected || !server.pairingRequests.isEmpty }
        XCTAssertTrue(server.pairingRequests.isEmpty, "被担保过的设备不该弹审批框")
        await connecting.value
        return client
    }

    func test_vouched_device_connects_without_any_prompt() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad")
        let phoneClient = try await pairByApproval(phone, to: server)
        XCTAssertTrue(phoneClient.supportsDeviceVouch)

        let result = try await phoneClient.vouch(for: pad.sibling)
        XCTAssertEqual(result.kind, .added)
        XCTAssertEqual(result.internetAccess, false)
        let record = try XCTUnwrap(server.peerVouches[pad.id])
        XCTAssertEqual(record.vouchedBy, phone.id)
        XCTAssertEqual(record.family, phone.id, "手动配对的担保者自己就是组号")
        XCTAssertEqual(vouched.map(\.deviceID), [pad.id], "Mac 上发一次通知")
        XCTAssertEqual(server.trustedPeers.first { $0.id == pad.id }?.publicKey, pad.sibling.publicKey)

        let padClient = try await connectWithoutApproval(pad, to: server)
        XCTAssertEqual(padClient.state, .connected)

        let again = try await phoneClient.vouch(for: pad.sibling)
        XCTAssertEqual(again.kind, .alreadyTrusted)
        XCTAssertEqual(vouched.count, 1, "已经认识的不再通知")
        phoneClient.disconnect()
        padClient.disconnect()
    }

    func test_vouching_turned_off_records_nothing() async throws {
        let server = try await makeServer(vouching: false)
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad")
        let phoneClient = try await pairByApproval(phone, to: server)
        let result = try await phoneClient.vouch(for: pad.sibling)
        XCTAssertEqual(result.kind, .notAllowed)
        XCTAssertNotNil(result.reason)
        XCTAssertNil(server.identity.peer(id: pad.id))
        XCTAssertTrue(server.peerVouches.isEmpty)
        XCTAssertTrue(vouched.isEmpty)
        XCTAssertEqual(phoneClient.state, .connected, "拒绝不影响担保者自己的连接")
        phoneClient.disconnect()
    }

    func test_device_revoked_on_the_mac_cannot_be_vouched_back() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad")
        let phoneClient = try await pairByApproval(phone, to: server)
        _ = try await phoneClient.vouch(for: pad.sibling)
        server.revoke(pad.id)
        XCTAssertNil(server.peerVouches[pad.id], "撤销时担保记录一并去掉")
        let result = try await phoneClient.vouch(for: pad.sibling)
        XCTAssertEqual(result.kind, .rejected)
        XCTAssertNil(server.identity.peer(id: pad.id))
        phoneClient.disconnect()
    }

    func test_vouch_cannot_swap_a_known_devices_key() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad")
        let phoneClient = try await pairByApproval(phone, to: server)
        _ = try await phoneClient.vouch(for: pad.sibling)
        var impostor = pad.sibling
        impostor.publicKey = newKey()
        let result = try await phoneClient.vouch(for: impostor)
        XCTAssertEqual(result.kind, .rejected)
        XCTAssertEqual(server.identity.peer(id: pad.id)?.publicKey, pad.sibling.publicKey)
        phoneClient.disconnect()
    }

    func test_internet_access_is_inherited_from_the_voucher_never_granted_beyond_it() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        var allowed: Set<UUID> = []
        server.internetAccessPolicy = { allowed.contains($0) }
        server.grantInternetAccess = { allowed.insert($0) }
        let phone = Device("iPhone"), mac = Device("Mac"), pad = Device("iPad"), watch = Device("Other")
        let phoneClient = try await pairByApproval(phone, to: server)
        let macClient = try await pairByApproval(mac, to: server)
        allowed.insert(phone.id)

        let fromPhone = try await phoneClient.vouch(for: pad.sibling)
        XCTAssertEqual(fromPhone.internetAccess, true)
        XCTAssertTrue(allowed.contains(pad.id))

        let fromMac = try await macClient.vouch(for: watch.sibling)
        XCTAssertEqual(fromMac.kind, .added)
        XCTAssertEqual(fromMac.internetAccess, false)
        XCTAssertFalse(allowed.contains(watch.id), "担保者自己不能经公网接入，新设备也不能")
        phoneClient.disconnect()
        macClient.disconnect()
    }

    func test_old_mac_is_never_sent_the_request() async throws {
        let server = try await makeServer(features: RemoteConstants.localFeatures.filter { $0 != RemoteFeature.deviceVouch })
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad")
        let phoneClient = try await pairByApproval(phone, to: server)
        XCTAssertFalse(phoneClient.supportsDeviceVouch)
        do {
            _ = try await phoneClient.vouch(for: pad.sibling)
            XCTFail("老 Mac 上应当直接报版本太旧")
        } catch RemoteAttachError.rejected(_) {}
        XCTAssertEqual(phoneClient.state, .connected, "没发出去，连接还在")
        phoneClient.disconnect()
    }

    func test_group_member_reports_another_lost_and_the_mac_revokes_it_for_good() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad"), stranger = Device("Stranger")
        let phoneClient = try await pairByApproval(phone, to: server)
        let strangerClient = try await pairByApproval(stranger, to: server)
        _ = try await phoneClient.vouch(for: pad.sibling)
        let padClient = try await connectWithoutApproval(pad, to: server)
        XCTAssertTrue(phoneClient.supportsSiblingRevoke)

        // 别组的设备撤不了。
        let refused = try await strangerClient.revokeSibling(pad.id, publicKey: pad.sibling.publicKey)
        XCTAssertEqual(refused.kind, .notInFamily)
        XCTAssertNotNil(server.identity.peer(id: pad.id))

        let result = try await phoneClient.revokeSibling(pad.id, publicKey: pad.sibling.publicKey)
        XCTAssertEqual(result.kind, .revoked)
        let gone = await waitUntil { server.identity.peer(id: pad.id) == nil && padClient.state != .connected }
        XCTAssertTrue(gone, "撤掉并断开")
        XCTAssertTrue(server.identity.isBlocked(pad.id))
        let again = try await phoneClient.vouch(for: pad.sibling)
        XCTAssertEqual(again.kind, .rejected, "撤掉的设备不能借担保回来")
        XCTAssertEqual(phoneClient.state, .connected)
        phoneClient.disconnect()
        strangerClient.disconnect()
    }

    func test_old_mac_is_never_sent_a_revocation() async throws {
        let server = try await makeServer(features: RemoteConstants.localFeatures.filter { $0 != RemoteFeature.siblingRevoke })
        defer { server.stop() }
        let phone = Device("iPhone")
        let phoneClient = try await pairByApproval(phone, to: server)
        do {
            _ = try await phoneClient.revokeSibling(UUID(), publicKey: newKey())
            XCTFail("老 Mac 上应当直接报版本太旧")
        } catch RemoteAttachError.rejected(_) {}
        XCTAssertEqual(phoneClient.state, .connected)
        phoneClient.disconnect()
    }

    func test_vouched_devices_form_one_group_that_can_be_revoked_together() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad"), mac = Device("Mac"), stranger = Device("Stranger")
        let phoneClient = try await pairByApproval(phone, to: server)
        let strangerClient = try await pairByApproval(stranger, to: server)
        _ = try await phoneClient.vouch(for: pad.sibling)
        // 被担保的设备再担保：同一组。
        let padClient = try await connectWithoutApproval(pad, to: server)
        let fromPad = try await padClient.vouch(for: mac.sibling)
        XCTAssertEqual(fromPad.kind, .added)
        XCTAssertEqual(server.peerVouches[mac.id]?.family, phone.id)
        XCTAssertEqual(server.peerVouches[mac.id]?.vouchedBy, pad.id)
        XCTAssertEqual(Set(server.familyMembers(of: mac.id)), [phone.id, pad.id, mac.id])
        XCTAssertEqual(server.familyMembers(of: stranger.id), [stranger.id])

        server.revokeFamily(of: pad.id)
        XCTAssertEqual(server.trustedPeers.map(\.id), [stranger.id], "整组撤掉，别人不受影响")
        let dropped = await waitUntil { phoneClient.state != .connected && padClient.state != .connected }
        XCTAssertTrue(dropped, "连着的组员立即断开")
        XCTAssertEqual(strangerClient.state, .connected)
        strangerClient.disconnect()
    }
}
