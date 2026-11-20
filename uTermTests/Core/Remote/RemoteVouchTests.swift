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
                                            family: root, vouchedAt: Date(timeIntervalSince1970: 2))]
        let padPeer = RemotePeer(id: pad, name: "iPad", publicKey: key, pairedAt: Date(timeIntervalSince1970: 2))
        let rootPeer = RemotePeer(id: root, name: "iPhone", publicKey: key, pairedAt: Date(timeIntervalSince1970: 1))
        let strangerPeer = RemotePeer(id: stranger, name: "Stranger", publicKey: newKey(), pairedAt: Date(timeIntervalSince1970: 0))
        let trusted = [rootPeer, padPeer, strangerPeer]
        func decide(_ request: RemoteSiblingRevokeRequest, by requester: UUID, existing: RemotePeer?)
            -> RemoteSiblingRevokeResult.Outcome {
            RemoteVouchPolicy.decideRevoke(request, requesterID: requester, existing: existing, vouches: vouches, trusted: trusted)
        }
        let request = RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: pad, publicKey: key)
        XCTAssertEqual(decide(request, by: root, existing: padPeer), .revoked, "iPad 比 iPhone 晚")
        XCTAssertEqual(decide(request, by: pad, existing: padPeer), .revoked, "撤自己也行")
        XCTAssertEqual(decide(request, by: stranger, existing: padPeer), .notInFamily, "比它早也不行：不是同一组")
        // 被撤的那台换过钥匙（重新配对过）：不撤。
        var other = request
        other.publicKey = newKey()
        XCTAssertEqual(decide(other, by: root, existing: padPeer), .notTrusted)
        XCTAssertEqual(decide(request, by: root, existing: nil), .notTrusted)
        // 手动配对的根设备也能被组里的设备撤掉（组号就是它；它是 iPad 的上游，比 iPad 早也行）。
        let rootRequest = RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: root, publicKey: key)
        XCTAssertEqual(decide(rootRequest, by: pad, existing: rootPeer), .revoked)
    }

    /// §18 资历：谁能撤谁，撤上游时留谁；时间缺失当最早、相同按设备 ID。
    func test_seniority_policy_upstream_or_later_and_the_earliest_of_the_line_survives() {
        let root = UUID(), m = UUID(), y = UUID(), z = UUID(), late = UUID()
        func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        func vouch(_ id: UUID, by voucher: UUID) -> RemotePeerVouch {
            RemotePeerVouch(deviceID: id, deviceName: "", vouchedBy: voucher, voucherName: "", family: root, vouchedAt: at(0))
        }
        // root（手动配对）担保了 m、y；y 担保了 z；late 由 m 担保、最晚。
        let vouches = [m: vouch(m, by: root), y: vouch(y, by: root), z: vouch(z, by: y), late: vouch(late, by: m)]
        let key = newKey()
        let trusted = [(root, 1.0), (m, 2.0), (y, 3.0), (z, 4.0), (late, 5.0)].map {
            RemotePeer(id: $0.0, name: "", publicKey: key, pairedAt: at($0.1))
        }
        func decide(_ target: UUID, by requester: UUID, trusted: [RemotePeer] = trusted) -> RemoteSiblingRevokeResult.Outcome {
            RemoteVouchPolicy.decideRevoke(RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: target, publicKey: key),
                                           requesterID: requester, existing: trusted.first { $0.id == target },
                                           vouches: vouches, trusted: trusted)
        }
        XCTAssertEqual(decide(m, by: y), .notSenior, "m 比 y 早，又不是 y 的上游")
        XCTAssertEqual(decide(m, by: z), .notSenior)
        XCTAssertEqual(decide(y, by: m), .revoked, "y 比 m 晚")
        XCTAssertEqual(decide(root, by: z), .revoked, "上游再早也能撤：z → y → root")
        XCTAssertEqual(decide(y, by: z), .revoked, "直接的担保者")
        XCTAssertEqual(decide(late, by: z), .revoked, "比自己晚的别的分支")
        XCTAssertEqual(decide(z, by: z), .revoked)
        XCTAssertEqual(RemoteVouchPolicy.ancestors(of: z, trusted: Set(trusted.map(\.id)), vouches: vouches), [y, root])

        // 撤上游时留下那一串里最早的：z 撤 root → 留 m（连同 m 担保的 late），y、z 撤掉。
        XCTAssertEqual(RemoteVouchPolicy.survivor(revoking: root, requester: z, trusted: trusted, vouches: vouches), m)
        XCTAssertEqual(Set(RemoteVouchPolicy.cascade(from: root, keeping: m, trusted: trusted.map(\.id), vouches: vouches)),
                       [root, y, z])
        // z 撤 y：那一串里只剩 z 自己，留它。
        XCTAssertEqual(RemoteVouchPolicy.survivor(revoking: y, requester: z, trusted: trusted, vouches: vouches), z)
        // 请求者不在那一串里、撤自己：没有要留的。
        XCTAssertNil(RemoteVouchPolicy.survivor(revoking: y, requester: m, trusted: trusted, vouches: vouches))
        XCTAssertNil(RemoteVouchPolicy.survivor(revoking: z, requester: z, trusted: trusted, vouches: vouches))

        // 时间缺失（不在信任表里的、旧数据）：当最早。
        XCTAssertTrue(RemoteVouchPolicy.isAdded(UUID(), before: root, addedAt: RemoteVouchPolicy.addedAt(trusted)))
        let withoutTimes = RemoteVouchPolicy.addedAt(trusted).filter { $0.key != y }
        XCTAssertTrue(RemoteVouchPolicy.isAdded(y, before: root, addedAt: withoutTimes))
        // 时间相同：按设备 ID 的字符串排，小的算早，两个方向结论一致。
        let (low, high) = m.uuidString < y.uuidString ? (m, y) : (y, m)
        let tied = trusted.map { peer -> RemotePeer in
            var peer = peer
            if peer.id == m || peer.id == y { peer.pairedAt = at(9) }
            return peer
        }
        let tiedTimes = RemoteVouchPolicy.addedAt(tied)
        XCTAssertTrue(RemoteVouchPolicy.isAdded(low, before: high, addedAt: tiedTimes))
        XCTAssertFalse(RemoteVouchPolicy.isAdded(high, before: low, addedAt: tiedTimes))
        XCTAssertEqual(decide(high, by: low, trusted: tied), .revoked)
        XCTAssertEqual(decide(low, by: high, trusted: tied), .notSenior)
    }

    func test_not_senior_result_reads_as_unknown_on_an_old_controller_and_receipt_flag_is_optional() throws {
        // 老主控端照 `Outcome(rawValue:)` 认结果：认不出的是 nil（它落到「过一阵再问」）。这里核线上的样子。
        let result = RemoteSiblingRevokeResult(requestID: UUID(), outcome: .notSenior)
        let json = try JSONEncoder().encode(result)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("not-senior"))
        XCTAssertFalse(text.contains("requesterRevoked"), "没设就不带这个键")
        let old = Data(#"{"requestID":"\#(UUID().uuidString)","outcome":"revoked"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RemoteSiblingRevokeResult.self, from: old).requesterRevoked,
                     "老 Mac 的回执照样解得开")
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
        let signingKey = Curve25519.Signing.PrivateKey()

        var groupDevice: RemoteGroupDevice {
            RemoteGroupDevice(id: id, name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                              publicKey: try! identity.localIdentity().publicKey.rawRepresentation,
                              signingKey: signingKey.publicKey.rawRepresentation, updatedAt: Date())
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

        let result = try await phoneClient.vouch(for: pad.groupDevice)
        XCTAssertEqual(result.kind, .added)
        XCTAssertEqual(result.internetAccess, false)
        let record = try XCTUnwrap(server.peerVouches[pad.id])
        XCTAssertEqual(record.vouchedBy, phone.id)
        XCTAssertEqual(record.family, phone.id, "手动配对的担保者自己就是组号")
        XCTAssertEqual(vouched.map(\.deviceID), [pad.id], "Mac 上发一次通知")
        XCTAssertEqual(server.trustedPeers.first { $0.id == pad.id }?.publicKey, pad.groupDevice.publicKey)

        let padClient = try await connectWithoutApproval(pad, to: server)
        XCTAssertEqual(padClient.state, .connected)

        let again = try await phoneClient.vouch(for: pad.groupDevice)
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
        let result = try await phoneClient.vouch(for: pad.groupDevice)
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
        _ = try await phoneClient.vouch(for: pad.groupDevice)
        server.revoke(pad.id)
        XCTAssertNil(server.peerVouches[pad.id], "撤销时担保记录一并去掉")
        let result = try await phoneClient.vouch(for: pad.groupDevice)
        XCTAssertEqual(result.kind, .rejected)
        XCTAssertNil(server.identity.peer(id: pad.id))
        phoneClient.disconnect()
    }

    func test_vouch_cannot_swap_a_known_devices_key() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad")
        let phoneClient = try await pairByApproval(phone, to: server)
        _ = try await phoneClient.vouch(for: pad.groupDevice)
        var impostor = pad.groupDevice
        impostor.publicKey = newKey()
        let result = try await phoneClient.vouch(for: impostor)
        XCTAssertEqual(result.kind, .rejected)
        XCTAssertEqual(server.identity.peer(id: pad.id)?.publicKey, pad.groupDevice.publicKey)
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

        let fromPhone = try await phoneClient.vouch(for: pad.groupDevice)
        XCTAssertEqual(fromPhone.internetAccess, true)
        XCTAssertTrue(allowed.contains(pad.id))

        let fromMac = try await macClient.vouch(for: watch.groupDevice)
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
            _ = try await phoneClient.vouch(for: pad.groupDevice)
            XCTFail("老 Mac 上应当直接报版本太旧")
        } catch RemoteAttachError.rejected(_) {}
        XCTAssertEqual(phoneClient.state, .connected, "没发出去，连接还在")
        phoneClient.disconnect()
    }

    /// §8：同组设备请求的撤销只删信任与来路、不拉黑，之后同组设备可以再替它开通（设备找回来、重新进组）；
    /// Mac 主人在 Mac 上撤销的照旧拉黑（`test_device_revoked_on_the_mac_cannot_be_vouched_back`）。
    func test_group_member_reports_another_removed_and_the_mac_revokes_it_without_blocking() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad"), stranger = Device("Stranger")
        let phoneClient = try await pairByApproval(phone, to: server)
        let strangerClient = try await pairByApproval(stranger, to: server)
        _ = try await phoneClient.vouch(for: pad.groupDevice)
        let padClient = try await connectWithoutApproval(pad, to: server)
        XCTAssertTrue(phoneClient.supportsSiblingRevoke)

        // 别组的设备撤不了。
        let refused = try await strangerClient.revokeSibling(pad.id, publicKey: pad.groupDevice.publicKey)
        XCTAssertEqual(refused.kind, .notInFamily)
        XCTAssertNotNil(server.identity.peer(id: pad.id))
        // 公钥对不上（Mac 记着的是另一把）也不撤。
        let wrongKey = try await phoneClient.revokeSibling(pad.id, publicKey: newKey())
        XCTAssertEqual(wrongKey.kind, .notTrusted)
        XCTAssertNotNil(server.identity.peer(id: pad.id))

        let result = try await phoneClient.revokeSibling(pad.id, publicKey: pad.groupDevice.publicKey)
        XCTAssertEqual(result.kind, .revoked)
        let gone = await waitUntil { server.identity.peer(id: pad.id) == nil && padClient.state != .connected }
        XCTAssertTrue(gone, "撤掉并断开")
        XCTAssertNil(server.peerVouches[pad.id], "来路一并去掉")
        XCTAssertFalse(server.identity.isBlocked(pad.id), "同组撤销不拉黑")
        let again = try await phoneClient.vouch(for: pad.groupDevice)
        XCTAssertEqual(again.kind, .added, "重新进组后同组设备可以再替它开通")
        let back = try await connectWithoutApproval(pad, to: server)
        XCTAssertEqual(back.state, .connected)

        // Mac 主人在 Mac 上撤销：拉黑，谁担保都不认。
        server.revoke(pad.id)
        XCTAssertTrue(server.identity.isBlocked(pad.id))
        let blocked = try await phoneClient.vouch(for: pad.groupDevice)
        XCTAssertEqual(blocked.kind, .rejected)
        XCTAssertEqual(phoneClient.state, .connected)
        phoneClient.disconnect()
        strangerClient.disconnect()
        back.disconnect()
    }

    /// 同组撤销不会解除 Mac 主人的拉黑：被拉黑的设备已经不被信任，撤销请求什么都不改。
    func test_family_revoke_never_lifts_an_owner_block() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad")
        let phoneClient = try await pairByApproval(phone, to: server)
        _ = try await phoneClient.vouch(for: pad.groupDevice)
        server.revoke(pad.id)
        let result = try await phoneClient.revokeSibling(pad.id, publicKey: pad.groupDevice.publicKey)
        XCTAssertEqual(result.kind, .notTrusted)
        XCTAssertTrue(server.identity.isBlocked(pad.id))
        let again = try await phoneClient.vouch(for: pad.groupDevice)
        XCTAssertEqual(again.kind, .rejected)
        phoneClient.disconnect()
    }

    // MARK: - 设备组：这台 Mac 自己是组员（§7.3「组里的 Mac 互认」）

    func test_mac_in_the_group_records_members_as_controllers_with_the_group_as_provenance() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let pad = Device("iPad"), duo = Device("Duo")
        let addedReply = await server.groupAddController(vouchRequest(pad))
        let added = try XCTUnwrap(addedReply)
        XCTAssertEqual(added.kind, .added)
        XCTAssertEqual(added.internetAccess, false, "公网接入照新配对设备的默认值：不开")
        XCTAssertNil(added.relay)
        let record = try XCTUnwrap(server.peerVouches[pad.id])
        XCTAssertTrue(record.isFromDeviceGroup(hostID: hostID))
        XCTAssertEqual(record.family, hostID, "设备组记下的算一组，组号是这台 Mac")
        XCTAssertEqual(vouched.map(\.deviceID), [pad.id], "照样发一次通知")
        let padClient = try await connectWithoutApproval(pad, to: server)
        XCTAssertEqual(padClient.state, .connected)

        // 设备组记下的两台可以互相请 Mac 撤销（同一组），也可以一起撤掉。
        _ = await server.groupAddController(vouchRequest(duo))
        XCTAssertEqual(Set(server.familyMembers(of: pad.id)), [pad.id, duo.id])
        let revoked = try await padClient.revokeSibling(duo.id, publicKey: duo.groupDevice.publicKey)
        XCTAssertEqual(revoked.kind, .revoked)
        _ = await waitUntil { server.identity.peer(id: duo.id) == nil }
        XCTAssertFalse(server.identity.isBlocked(duo.id))

        let known = await server.groupAddController(vouchRequest(pad))
        XCTAssertEqual(known?.kind, .alreadyTrusted)
        padClient.disconnect()
    }

    /// 先点了一台没配对的 Mac（主控端显示核对码、Mac 上弹输码框），没输码就关掉；再加入设备组，那台 Mac 把它记成
    /// 主控端。那条还在等审批的连接要马上放行、输码框收起，不用断开重连；来路仍是设备组，不被当成手动配对重记。
    func test_pending_pairing_goes_through_once_the_group_adds_that_device() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let pad = Device("iPad")
        let padClient = try client(pad, to: server)
        let connecting = Task { await padClient.connect() }
        let asked = await waitUntil {
            if case .awaitingApproval = padClient.state { return !server.pairingRequests.isEmpty }
            return false
        }
        XCTAssertTrue(asked, "没配对的设备先等审批")

        let added = await server.groupAddController(vouchRequest(pad))
        XCTAssertEqual(added?.kind, .added)
        let passed = await waitUntil { padClient.state == .connected }
        XCTAssertTrue(passed, "设备组记下之后，等着的那条连接直接放行")
        XCTAssertTrue(server.pairingRequests.isEmpty, "Mac 上的输码框随之收起")
        await connecting.value
        XCTAssertEqual(server.peerVouches[pad.id]?.isFromDeviceGroup(hostID: hostID), true, "来路仍是设备组")
        padClient.disconnect()
    }

    func test_mac_never_adds_an_owner_blocked_device_or_swaps_a_key_and_respects_the_switch() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad")
        let phoneClient = try await pairByApproval(phone, to: server)
        phoneClient.disconnect()
        server.revoke(phone.id)
        let blocked = await server.groupAddController(vouchRequest(phone))
        XCTAssertEqual(blocked?.kind, .rejected, "Mac 主人撤销过的不自动加回来")
        XCTAssertNil(server.identity.peer(id: phone.id))

        _ = await server.groupAddController(vouchRequest(pad))
        var swapped = vouchRequest(pad)
        swapped.publicKey = newKey()
        let swappedReply = await server.groupAddController(swapped)
        XCTAssertEqual(swappedReply?.kind, .rejected)
        XCTAssertEqual(server.identity.peer(id: pad.id)?.publicKey, pad.groupDevice.publicKey)

        let off = try await makeServer(vouching: false)
        defer { off.stop() }
        let offReply = await off.groupAddController(vouchRequest(Device("Other")))
        XCTAssertEqual(offReply?.kind, .notAllowed)
    }

    func test_mac_drops_a_removed_member_without_blocking_but_never_a_device_paired_on_the_mac() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let phone = Device("iPhone"), pad = Device("iPad")
        let phoneClient = try await pairByApproval(phone, to: server)
        _ = await server.groupAddController(vouchRequest(pad))
        let padClient = try await connectWithoutApproval(pad, to: server)

        let wrong = await server.groupDropController(RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: pad.id,
                                                                                 publicKey: newKey()))
        XCTAssertEqual(wrong?.kind, .notTrusted)
        let dropped = await server.groupDropController(RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: pad.id,
                                                                                   publicKey: pad.groupDevice.publicKey))
        XCTAssertEqual(dropped?.kind, .revoked)
        let gone = await waitUntil { server.identity.peer(id: pad.id) == nil && padClient.state != .connected }
        XCTAssertTrue(gone)
        XCTAssertFalse(server.identity.isBlocked(pad.id))
        let readded = await server.groupAddController(vouchRequest(pad))
        XCTAssertEqual(readded?.kind, .added, "重新进组后再加得回来")

        let manual = await server.groupDropController(RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: phone.id,
                                                                                  publicKey: try phone.identity.localIdentity()
                                                                                      .publicKey.rawRepresentation))
        XCTAssertEqual(manual?.kind, .notInFamily, "在 Mac 上手动配对的不动")
        XCTAssertNotNil(server.identity.peer(id: phone.id))
        XCTAssertEqual(phoneClient.state, .connected)
        phoneClient.disconnect()
    }

    private func vouchRequest(_ device: Device) -> RemoteVouchRequest {
        let entry = device.groupDevice
        return RemoteVouchRequest(requestID: UUID(), deviceID: entry.id, name: entry.name, model: entry.model,
                                  platform: entry.platform, publicKey: entry.publicKey)
    }

    // MARK: - 同组撤销连带（G3 补：被撤的设备不能被它担保过的设备担保回来）

    /// 不经审批、只是连着（担保过的设备）；连不上的话返回的客户端不是 connected。
    private func trusted(_ server: RemoteHostServer, _ device: Device) -> Bool {
        server.identity.peer(id: device.id) != nil
    }

    /// 一台已不被信任的设备再来连：Mac 弹审批（不认它），这里拒掉，它连不上。
    private func assertNeedsApproval(_ device: Device, at server: RemoteHostServer,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let client = try client(device, to: server)
        let connecting = Task { await client.connect() }
        let asked = await waitUntil { server.pairingRequests.contains { $0.deviceName == device.name } }
        XCTAssertTrue(asked, "\(device.name) 不该再被认出来", file: file, line: line)
        if let request = server.pairingRequests.first(where: { $0.deviceName == device.name }) {
            server.rejectPairing(request.id)
        }
        await connecting.value
        XCTAssertNotEqual(client.state, .connected, file: file, line: line)
        client.disconnect()
    }

    /// 反例：M 手动配对，M 担保了 X；被偷的 X 在被移除前担保了 Y（它加进组的设备）、Z（谁都不知道的钥匙）和正常的
    /// M2。M 请 Mac 撤 X → 这一次请求之后 X、Y、Z、M2 都不再被信任、都没拉黑，M 还在；X、Y、Z 都没有信任了，
    /// 谁也担保不回谁；M 再替 M2 开通能成。
    func test_family_revoke_takes_everything_the_revoked_device_vouched_with_it() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let m = Device("M"), x = Device("X"), y = Device("Y"), z = Device("Z"), m2 = Device("M2")
        let mClient = try await pairByApproval(m, to: server)
        _ = try await mClient.vouch(for: x.groupDevice)
        let xClient = try await connectWithoutApproval(x, to: server)
        for device in [y, z, m2] { _ = try await xClient.vouch(for: device.groupDevice) }
        let yClient = try await connectWithoutApproval(y, to: server)
        let zClient = try await connectWithoutApproval(z, to: server)
        XCTAssertEqual(server.peerVouches[z.id]?.vouchedBy, x.id)

        let result = try await mClient.revokeSibling(x.id, publicKey: x.groupDevice.publicKey)
        XCTAssertEqual(result.kind, .revoked)
        let swept = await waitUntil { [x, y, z, m2].allSatisfy { !self.trusted(server, $0) } }
        XCTAssertTrue(swept, "一次请求连带撤掉 X 担保过的全部")
        for device in [x, y, z, m2] { XCTAssertFalse(server.identity.isBlocked(device.id), "\(device.name) 不拉黑") }
        XCTAssertTrue(trusted(server, m))
        XCTAssertTrue(server.peerVouches.isEmpty, "被撤的来路一并去掉（M 是手动配对的，本来就没有）")
        let disconnected = await waitUntil { [xClient, yClient, zClient].allSatisfy { $0.state != .connected } }
        XCTAssertTrue(disconnected, "连着的都断开")
        XCTAssertEqual(mClient.state, .connected)

        // 它们没有信任了：谁也连不上，更担保不了谁。
        try await assertNeedsApproval(y, at: server)
        try await assertNeedsApproval(z, at: server)

        let back = try await mClient.vouch(for: m2.groupDevice)
        XCTAssertEqual(back.kind, .added, "M 替正常的 M2 重新开通")
        XCTAssertEqual(server.peerVouches[m2.id]?.vouchedBy, m.id)
        mClient.disconnect()
    }

    /// 只有 X 在 Mac 上手动配对过，组里别的设备都是它担保的：M 撤 X 时 M 留下（来路改挂在自己身上，组号不变），
    /// M2 被连带撤掉，M 再替它开通就回来了；之后 M 还能撤同组的设备。
    func test_requester_keeps_access_when_the_revoked_device_was_the_only_one_paired_on_the_mac() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let x = Device("X"), m = Device("M"), m2 = Device("M2")
        let xClient = try await pairByApproval(x, to: server)
        _ = try await xClient.vouch(for: m.groupDevice)
        _ = try await xClient.vouch(for: m2.groupDevice)
        let mClient = try await connectWithoutApproval(m, to: server)

        let result = try await mClient.revokeSibling(x.id, publicKey: x.groupDevice.publicKey)
        XCTAssertEqual(result.kind, .revoked)
        let swept = await waitUntil { !self.trusted(server, x) && !self.trusted(server, m2) }
        XCTAssertTrue(swept)
        XCTAssertTrue(trusted(server, m), "发请求的那台留下")
        let record = try XCTUnwrap(server.peerVouches[m.id])
        XCTAssertEqual(record.vouchedBy, m.id, "担保者不在了：来路挂在它自己身上")
        XCTAssertEqual(record.family, x.id, "组号不变")
        XCTAssertEqual(record.voucherName, "X", "界面上照旧写当初添加它的那台")
        XCTAssertEqual(mClient.state, .connected)
        XCTAssertEqual(vouched.count, 2, "改挂来路不发通知")

        let back = try await mClient.vouch(for: m2.groupDevice)
        XCTAssertEqual(back.kind, .added)
        XCTAssertEqual(server.peerVouches[m2.id]?.family, x.id, "回来的 M2 和 M 同一组")
        XCTAssertEqual(Set(server.familyMembers(of: m.id)), [m.id, m2.id])
        let again = try await mClient.revokeSibling(m2.id, publicKey: m2.groupDevice.publicKey)
        XCTAssertEqual(again.kind, .revoked, "M 还能撤同组的设备")
        mClient.disconnect()
    }

    /// 攻击者的 Y 抢先撤 X、想保住自己。M 是 X 的担保者（不在 X 担保的那一串里）：那一串里只有 Y，Y 留下
    /// （来路改挂到 M），M 随后撤 Y（比 M 晚）→ Mac 上只剩 M。另一种情况（M 和 Y 都是 X 担保的）见下一条。
    func test_attacker_revoking_first_keeps_itself_only_until_an_ancestor_revokes_it() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let m = Device("M"), x = Device("X"), y = Device("Y")
        let mClient = try await pairByApproval(m, to: server)
        _ = try await mClient.vouch(for: x.groupDevice)
        let xClient = try await connectWithoutApproval(x, to: server)
        _ = try await xClient.vouch(for: y.groupDevice)
        let yClient = try await connectWithoutApproval(y, to: server)

        let first = try await yClient.revokeSibling(x.id, publicKey: x.groupDevice.publicKey)
        XCTAssertEqual(first.kind, .revoked)
        _ = await waitUntil { !self.trusted(server, x) }
        XCTAssertTrue(trusted(server, y), "抢先的 Y 保住了自己")
        XCTAssertEqual(server.peerVouches[y.id]?.vouchedBy, m.id, "来路改挂到 X 的担保者 M")
        XCTAssertTrue(trusted(server, m))

        let late = try await mClient.revokeSibling(x.id, publicKey: x.groupDevice.publicKey)
        XCTAssertEqual(late.kind, .notTrusted)
        let cleanup = try await mClient.revokeSibling(y.id, publicKey: y.groupDevice.publicKey)
        XCTAssertEqual(cleanup.kind, .revoked)
        let clean = await waitUntil { server.trustedPeers.map(\.id) == [m.id] }
        XCTAssertTrue(clean, "M 撤完 X、Y 之后只剩 M")
        mClient.disconnect()
        yClient.disconnect()
    }

    /// §18（原来是「Y 抢先、M 被晾在外面」的反例）：X 是唯一手动配对的，正常的 M 和被偷后 X 加的 Y 都是 X 担保的，
    /// Y 还担保了 Z。Y 抢先撤 X → 留下的是那一串里最早的 M（改挂在自己身上），X、Y、Z 都撤掉；Y 拿到「撤成了、你也被撤了」
    /// 的回执之后才断开。之后 M 撤 X 回 `not-trusted`，替正常的 M2 开通能成。
    func test_attacker_revoking_first_takes_itself_out_and_the_earliest_sibling_stays() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let x = Device("X"), m = Device("M"), y = Device("Y"), z = Device("Z"), m2 = Device("M2")
        let xClient = try await pairByApproval(x, to: server)
        _ = try await xClient.vouch(for: m.groupDevice)
        _ = try await xClient.vouch(for: y.groupDevice)
        let mClient = try await connectWithoutApproval(m, to: server)
        let yClient = try await connectWithoutApproval(y, to: server)
        _ = try await yClient.vouch(for: z.groupDevice)
        let mAddedAt = try XCTUnwrap(server.identity.peer(id: m.id)?.pairedAt)

        let first = try await yClient.revokeSibling(x.id, publicKey: x.groupDevice.publicKey)
        XCTAssertEqual(first.kind, .revoked)
        XCTAssertEqual(first.requesterRevoked, true, "回执先到：Y 知道自己也被撤了")
        let swept = await waitUntil { [x, y, z].allSatisfy { !self.trusted(server, $0) } }
        XCTAssertTrue(swept, "X、Y 和 Y 担保的 Z 都撤掉")
        XCTAssertTrue(trusted(server, m), "留下的是更早加到这台 Mac 的 M")
        for device in [x, y, z] { XCTAssertFalse(server.identity.isBlocked(device.id), "\(device.name) 不拉黑") }
        let record = try XCTUnwrap(server.peerVouches[m.id])
        XCTAssertEqual(record.vouchedBy, m.id, "X 不在了：M 挂在自己身上")
        XCTAssertEqual(record.family, x.id, "组号不变")
        XCTAssertEqual(server.identity.peer(id: m.id)?.pairedAt, mAddedAt, "改挂不改资历")
        let yGone = await waitUntil { yClient.state != .connected }
        XCTAssertTrue(yGone)
        XCTAssertEqual(mClient.state, .connected)
        try await assertNeedsApproval(y, at: server)

        let late = try await mClient.revokeSibling(x.id, publicKey: x.groupDevice.publicKey)
        XCTAssertEqual(late.kind, .notTrusted)
        let back = try await mClient.vouch(for: m2.groupDevice)
        XCTAssertEqual(back.kind, .added, "M 能替别的组员开通")
        XCTAssertEqual(server.peerVouches[m2.id]?.family, x.id)
        mClient.disconnect()
    }

    /// 正常组员里较晚的 M3 撤它们共同的担保者 X（X 依次担保了 M1、M2、M3）：回执是撤成了、M3 自己也被撤（下一拍断开），
    /// 最早的 M1 留下并改挂，M2 被连带。之后 M1 先替 M3、再替 M2 重新开通：重新加回来的按回来的时刻算，M2 现在比 M3 晚，
    /// 撤不了 M3（`not-senior`），M3 撤得了 M2。
    func test_later_sibling_revoking_the_shared_voucher_is_revoked_too_and_re_added_devices_count_as_new() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let x = Device("X"), m1 = Device("M1"), m2 = Device("M2"), m3 = Device("M3")
        let xClient = try await pairByApproval(x, to: server)
        for device in [m1, m2, m3] { _ = try await xClient.vouch(for: device.groupDevice) }
        let m1Client = try await connectWithoutApproval(m1, to: server)
        let m3Client = try await connectWithoutApproval(m3, to: server)
        let m1Record = try XCTUnwrap(server.peerVouches[m1.id])
        let m1AddedAt = try XCTUnwrap(server.identity.peer(id: m1.id)?.pairedAt)

        let result = try await m3Client.revokeSibling(x.id, publicKey: x.groupDevice.publicKey)
        XCTAssertEqual(result.kind, .revoked)
        XCTAssertEqual(result.requesterRevoked, true)
        let swept = await waitUntil { [x, m2, m3].allSatisfy { !self.trusted(server, $0) } }
        XCTAssertTrue(swept)
        XCTAssertTrue(trusted(server, m1))
        XCTAssertEqual(server.peerVouches[m1.id]?.vouchedBy, m1.id)
        XCTAssertEqual(server.peerVouches[m1.id]?.vouchedAt, m1Record.vouchedAt, "改挂不改 vouchedAt")
        XCTAssertEqual(server.identity.peer(id: m1.id)?.pairedAt, m1AddedAt, "改挂不改资历")
        let m3Gone = await waitUntil { m3Client.state != .connected }
        XCTAssertTrue(m3Gone)

        let backM3 = try await m1Client.vouch(for: m3.groupDevice)
        XCTAssertEqual(backM3.kind, .added)
        let backM2 = try await m1Client.vouch(for: m2.groupDevice)
        XCTAssertEqual(backM2.kind, .added)
        let m2Again = try await connectWithoutApproval(m2, to: server)
        let m3Again = try await connectWithoutApproval(m3, to: server)
        let m2AddedAt = try XCTUnwrap(server.identity.peer(id: m2.id)?.pairedAt)
        let m3AddedAt = try XCTUnwrap(server.identity.peer(id: m3.id)?.pairedAt)
        XCTAssertGreaterThan(m3AddedAt, m1AddedAt)
        XCTAssertGreaterThan(m2AddedAt, m3AddedAt, "重新加回来的按回来的时刻算")
        let refused = try await m2Again.revokeSibling(m3.id, publicKey: m3.groupDevice.publicKey)
        XCTAssertEqual(refused.kind, .notSenior)
        XCTAssertNotNil(refused.reason)
        XCTAssertTrue(trusted(server, m3), "什么都没改")
        let cleanup = try await m3Again.revokeSibling(m2.id, publicKey: m2.groupDevice.publicKey)
        XCTAssertEqual(cleanup.kind, .revoked)
        XCTAssertEqual(cleanup.requesterRevoked, false)
        let m2Gone = await waitUntil { !self.trusted(server, m2) }
        XCTAssertTrue(m2Gone)
        m1Client.disconnect()
        m3Again.disconnect()
    }

    /// Y 撤比它早、又不是它上游的 M：`not-senior`，信任表、来路都没变，连接也没断；M 撤比它晚的 Y：照常撤。
    func test_device_cannot_revoke_an_earlier_sibling_that_is_not_upstream_but_the_earlier_one_can() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let x = Device("X"), m = Device("M"), y = Device("Y")
        let xClient = try await pairByApproval(x, to: server)
        _ = try await xClient.vouch(for: m.groupDevice)
        _ = try await xClient.vouch(for: y.groupDevice)
        let mClient = try await connectWithoutApproval(m, to: server)
        let yClient = try await connectWithoutApproval(y, to: server)
        let peersBefore = server.identity.trustedPeers()
        let vouchesBefore = server.identity.vouches()

        let refused = try await yClient.revokeSibling(m.id, publicKey: m.groupDevice.publicKey)
        XCTAssertEqual(refused.kind, .notSenior)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(server.identity.trustedPeers(), peersBefore)
        XCTAssertEqual(server.identity.vouches(), vouchesBefore)
        XCTAssertEqual(mClient.state, .connected)
        XCTAssertEqual(yClient.state, .connected)

        let result = try await mClient.revokeSibling(y.id, publicKey: y.groupDevice.publicKey)
        XCTAssertEqual(result.kind, .revoked)
        XCTAssertEqual(result.requesterRevoked, false)
        let gone = await waitUntil { !self.trusted(server, y) }
        XCTAssertTrue(gone)
        XCTAssertTrue(trusted(server, m) && trusted(server, x))
        mClient.disconnect()
    }

    /// 撤自己的上游一直允许，哪怕上游比自己早得多（祖父辈也算）：A（手动配对）→ B → C，C 撤 A，留下那一串里最早的 B
    /// （C 在 B 下面，一起留下）。撤自己照旧：C 撤 C，回执说它自己被撤了。
    func test_revoking_your_upstream_is_always_allowed_and_revoking_yourself_still_works() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let a = Device("A"), b = Device("B"), c = Device("C")
        let aClient = try await pairByApproval(a, to: server)
        _ = try await aClient.vouch(for: b.groupDevice)
        let bClient = try await connectWithoutApproval(b, to: server)
        _ = try await bClient.vouch(for: c.groupDevice)
        let cClient = try await connectWithoutApproval(c, to: server)

        let upstream = try await cClient.revokeSibling(a.id, publicKey: a.groupDevice.publicKey)
        XCTAssertEqual(upstream.kind, .revoked)
        XCTAssertEqual(upstream.requesterRevoked, false, "C 在留下的 B 下面")
        let swept = await waitUntil { !self.trusted(server, a) }
        XCTAssertTrue(swept)
        XCTAssertTrue(trusted(server, b) && trusted(server, c))
        XCTAssertEqual(server.peerVouches[b.id]?.vouchedBy, b.id)
        XCTAssertEqual(server.peerVouches[c.id]?.vouchedBy, b.id)

        let own = try await cClient.revokeSibling(c.id, publicKey: c.groupDevice.publicKey)
        XCTAssertEqual(own.kind, .revoked)
        XCTAssertEqual(own.requesterRevoked, true)
        let gone = await waitUntil { !self.trusted(server, c) && cClient.state != .connected }
        XCTAssertTrue(gone)
        XCTAssertTrue(trusted(server, b))
        bClient.disconnect()
    }

    /// 连带不碰手动配对的设备，也不解除 Mac 主人的拉黑。
    func test_family_cascade_never_touches_manual_pairings_or_owner_blocks() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let m = Device("M"), x = Device("X"), manual = Device("Manual"), blocked = Device("Blocked")
        let mClient = try await pairByApproval(m, to: server)
        let manualClient = try await pairByApproval(manual, to: server)
        _ = try await mClient.vouch(for: x.groupDevice)
        let xClient = try await connectWithoutApproval(x, to: server)
        _ = try await xClient.vouch(for: blocked.groupDevice)
        server.revoke(blocked.id)
        XCTAssertTrue(server.identity.isBlocked(blocked.id))

        let result = try await mClient.revokeSibling(x.id, publicKey: x.groupDevice.publicKey)
        XCTAssertEqual(result.kind, .revoked)
        _ = await waitUntil { !self.trusted(server, x) }
        XCTAssertTrue(trusted(server, manual), "手动配对的不在连带里")
        XCTAssertEqual(manualClient.state, .connected)
        XCTAssertTrue(server.identity.isBlocked(blocked.id), "拉黑的照旧拉黑")
        let refused = try await mClient.vouch(for: blocked.groupDevice)
        XCTAssertEqual(refused.kind, .rejected)
        mClient.disconnect()
        manualClient.disconnect()
    }

    /// 组里的 Mac 撤掉被移除的组员时同样连带（请求者是 Mac 自己，没有要留的）：由它担保的谁都不知道的钥匙一起撤掉。
    func test_group_drop_on_a_member_mac_cascades_to_what_the_removed_member_vouched() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let x = Device("X"), z = Device("Z"), manual = Device("Manual")
        let manualClient = try await pairByApproval(manual, to: server)
        _ = await server.groupAddController(vouchRequest(x))
        let xClient = try await connectWithoutApproval(x, to: server)
        _ = try await xClient.vouch(for: z.groupDevice)
        let dropped = await server.groupDropController(RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: x.id,
                                                                                   publicKey: x.groupDevice.publicKey))
        XCTAssertEqual(dropped?.kind, .revoked)
        XCTAssertFalse(trusted(server, x))
        XCTAssertFalse(trusted(server, z), "X 担保的 Z 一起撤掉")
        XCTAssertFalse(server.identity.isBlocked(z.id))
        XCTAssertTrue(trusted(server, manual))
        manualClient.disconnect()
    }

    func test_cascade_policy_walks_the_vouch_chain_but_not_through_the_requester() {
        let host = UUID(), x = UUID(), y = UUID(), z = UUID(), r = UUID(), rChild = UUID(), manual = UUID()
        func vouch(_ id: UUID, by voucher: UUID) -> RemotePeerVouch {
            RemotePeerVouch(deviceID: id, deviceName: "", vouchedBy: voucher, voucherName: "", family: x, vouchedAt: Date())
        }
        let vouches = [y: vouch(y, by: x), z: vouch(z, by: y), r: vouch(r, by: x), rChild: vouch(rChild, by: r)]
        let all = [x, y, z, r, rChild, manual]
        XCTAssertEqual(Set(RemoteVouchPolicy.cascade(from: x, keeping: r, trusted: all, vouches: vouches)), [x, y, z],
                       "一层层往下，不经过请求者")
        XCTAssertEqual(Set(RemoteVouchPolicy.cascade(from: x, keeping: nil, trusted: all, vouches: vouches)),
                       [x, y, z, r, rChild])
        XCTAssertEqual(RemoteVouchPolicy.cascade(from: manual, keeping: nil, trusted: all, vouches: vouches), [manual])
        // 环（重新担保过）也停得下来。
        var looped = vouches
        looped[x] = vouch(x, by: z)
        XCTAssertEqual(Set(RemoteVouchPolicy.cascade(from: y, keeping: nil, trusted: all, vouches: looped)), [x, y, z, r, rChild])
        // 改挂：根的担保者还在就挂过去，是 Mac 自己就挂到 Mac，否则挂自己。
        let peers = [RemotePeer(id: host, name: "H", publicKey: Data(), pairedAt: Date()),
                     RemotePeer(id: manual, name: "Manual", publicKey: Data(), pairedAt: Date())]
        var withVoucher = vouches
        withVoucher[x] = vouch(x, by: manual)
        XCTAssertEqual(RemoteVouchPolicy.reanchor(vouches[r]!, root: x, removed: [x, y, z], hostID: host, trusted: peers,
                                                  vouches: withVoucher).vouchedBy, manual)
        withVoucher[x] = vouch(x, by: host)
        XCTAssertEqual(RemoteVouchPolicy.reanchor(vouches[r]!, root: x, removed: [x, y, z], hostID: host, trusted: peers,
                                                  vouches: withVoucher).vouchedBy, host)
        XCTAssertEqual(RemoteVouchPolicy.reanchor(vouches[r]!, root: x, removed: [x, y, z], hostID: host, trusted: peers,
                                                  vouches: vouches).vouchedBy, r)
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
        _ = try await phoneClient.vouch(for: pad.groupDevice)
        // 被担保的设备再担保：同一组。
        let padClient = try await connectWithoutApproval(pad, to: server)
        let fromPad = try await padClient.vouch(for: mac.groupDevice)
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
