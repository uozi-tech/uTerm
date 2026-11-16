import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 设备组替组员向 Mac 开通要用的那一层（G2 接上调用方）：目录收下别的组员替本机开通的 Mac 的规则，
/// 以及真服务端上走一遍——iPhone 替 iPad 向 Mac 担保 → iPad 的目录收下这台 Mac → iPad 不经审批连上 Mac。
@MainActor
final class RemoteGroupHostAccessTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private struct Identity {
        let device: RemoteGroupDevice
        let key: Curve25519.KeyAgreement.PrivateKey
    }

    private func identity(_ name: String) -> Identity {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return Identity(device: RemoteGroupDevice(id: UUID(), name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                                                  publicKey: key.publicKey.rawRepresentation,
                                                  signingKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                                                  updatedAt: Date()),
                        key: key)
    }

    private func mac(_ name: String = "Mac mini") -> RemoteGroupVouchTarget {
        RemoteGroupVouchTarget(id: UUID(), name: name, publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                               model: "Mac mini", platform: "mac")
    }

    func test_grant_counts_as_usable_and_final_only_for_the_right_outcomes() {
        func grant(_ outcome: String) -> RemoteGroupGrant {
            RemoteGroupGrant(hostID: UUID(), hostName: "Mac", hostKey: Data(repeating: 1, count: 32), outcome: outcome)
        }
        XCTAssertTrue(grant(RemoteVouchResult.Outcome.added.rawValue).isUsable)
        XCTAssertTrue(grant(RemoteVouchResult.Outcome.alreadyTrusted.rawValue).isUsable)
        XCTAssertFalse(grant(RemoteVouchResult.Outcome.rejected.rawValue).isUsable)
        XCTAssertTrue(grant(RemoteVouchResult.Outcome.rejected.rawValue).isFinal, "Mac 拒绝了就不再问")
        XCTAssertFalse(grant(RemoteGroupGrant.unsupported).isFinal, "Mac 版本太旧：过一阵再问")
        XCTAssertFalse(grant(RemoteGroupGrant.unsupported).isUsable)
    }

    // MARK: - 目录收下 Mac

    func test_directory_adopts_new_macs_but_never_overrides_or_brings_back_forgotten_ones() throws {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let directory = RemoteMacDirectory(identity: identity, adoptsRelayAsDefault: false)
        let host = mac()
        let relay = RemoteRelayConfig(name: "r", host: "relay.example.invalid", port: 1, relayID: "rid",
                                      key: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString(),
                                      scope: host.id.uuidString, cert: Data([1]).base64EncodedString(), expires: 9_999_999_999)
        var grant = RemoteGroupGrant(hostID: host.id, hostName: host.name, hostKey: host.publicKey, hostModel: "Mac mini",
                                     hostPlatform: "mac", outcome: "added", relay: relay)
        XCTAssertEqual(directory.adopt(grant), .added)
        XCTAssertEqual(identity.peer(id: host.id)?.publicKey, host.publicKey)
        XCTAssertEqual(identity.peer(id: host.id)?.relay, relay, "成员证书只给这台 Mac 用")
        XCTAssertTrue(directory.macs.contains { $0.deviceID == host.id })
        XCTAssertEqual(directory.pairedHostNames()[host.id], host.name)
        XCTAssertEqual(directory.pairedHosts().map(\.publicKey), [host.publicKey], "不在线也列出来（发 host 用）")
        XCTAssertEqual(directory.pairedHosts().first?.platform, "mac")
        XCTAssertTrue(directory.vouchTargets().isEmpty, "不在线的 Mac 不去问")
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

    func test_end_to_end_vouched_device_connects_to_the_mac_without_approval() async throws {
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
        let phone = identity("iPhone")
        let phoneHostsTable = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try phoneHostsTable.saveRaw(phone.key.rawRepresentation, account: "identity")
        let phoneClient = RemoteMacClient(macName: "测试 Mac", endpoint: endpoint, identity: phoneHostsTable)
        phoneClient.localDeviceOverride = (phone.device.id, "iPhone")
        let connecting = Task { await phoneClient.connect() }
        _ = await waitUntil { !server.pairingRequests.isEmpty }
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(phoneClient.state, .connected)
        defer { phoneClient.disconnect() }

        // iPad：从没连过这台 Mac。iPhone 经已认证的连接替它担保（消息 50 / 51）。
        let pad = identity("iPad")
        let padHostsTable = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try padHostsTable.saveRaw(pad.key.rawRepresentation, account: "identity")
        let result = try await phoneClient.vouch(for: pad.device)
        XCTAssertEqual(result.kind, .added, result.reason ?? "")
        XCTAssertNotNil(server.peerVouches[pad.device.id], "Mac 记下了 iPad，来路是 iPhone")

        // 结果交给 iPad（G2 封进名册），iPad 的目录收下这台 Mac。
        let grant = RemoteGroupGrant(hostID: server.localID, hostName: "测试 Mac", hostKey: serverKey, hostPlatform: "mac",
                                     outcome: result.outcome, reason: result.reason, internetAccess: result.internetAccess,
                                     relay: result.relay)
        XCTAssertTrue(grant.isUsable)
        let padDirectory: any RemoteGroupHostAccess = RemoteMacDirectory(identity: padHostsTable, adoptsRelayAsDefault: false)
        XCTAssertEqual(padDirectory.adopt(grant), .added)
        let adopted = try XCTUnwrap(padHostsTable.peer(id: server.localID))
        XCTAssertEqual(adopted.publicKey, serverKey)

        let padClient = RemoteMacClient(macName: "测试 Mac", endpoint: endpoint, identity: padHostsTable,
                                        expectedPeer: adopted)
        padClient.localDeviceOverride = (pad.device.id, "iPad")
        let padConnecting = Task { await padClient.connect() }
        _ = await waitUntil(3) { padClient.state == .connected || !server.pairingRequests.isEmpty }
        XCTAssertTrue(server.pairingRequests.isEmpty, "不弹审批")
        await padConnecting.value
        XCTAssertEqual(padClient.state, .connected)
        padClient.disconnect()
    }

    // MARK: - 真服务端 + 设备组

    /// 问一台真测试服务端的「本机配对过的 Mac」：iPhone 那条已认证的 `RemoteMacClient`。
    @MainActor
    private final class ClientHosts: RemoteGroupHostAccess {
        let target: RemoteGroupVouchTarget
        let client: RemoteMacClient

        init(target: RemoteGroupVouchTarget, client: RemoteMacClient) {
            self.target = target
            self.client = client
        }

        func vouchTargets() -> [RemoteGroupVouchTarget] { [target] }
        func pairedHosts() -> [RemoteGroupVouchTarget] { [target] }
        func vouch(_ device: RemoteGroupDevice, at host: UUID) async throws -> RemoteVouchResult {
            try await client.vouch(for: device)
        }
        func adopt(_ grant: RemoteGroupGrant) -> RemoteGroupAdoption { .alreadyKnown }
        func revokeSibling(_ deviceID: UUID, publicKey: Data, at host: UUID) async throws -> RemoteSiblingRevokeResult {
            try await client.revokeSibling(deviceID, publicKey: publicKey)
        }
        func trustedHost(_ id: UUID) -> RemoteGroupTrustedHost? {
            id == target.id ? RemoteGroupTrustedHost(publicKey: target.publicKey, pairedAt: .distantPast) : nil
        }
        func dropAdoptedHost(_ id: UUID, publicKey: Data, pairedAt: Date) -> Bool { false }
    }

    /// 两台设备经核对码组成设备组 → 组员 iPhone 在真服务端上替新设备 iPad 担保、写下签名的 grant →
    /// iPad 读到、它的目录收下这台 Mac → iPad 不经审批连上。
    func test_end_to_end_group_member_vouches_the_new_device_which_then_connects_without_approval() async throws {
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

        let roster = RemoteGroupRoster(storage: RemoteMemorySyncedStorage())
        func member(_ name: String) -> (group: RemoteDeviceGroup, key: Curve25519.KeyAgreement.PrivateKey) {
            let key = Curve25519.KeyAgreement.PrivateKey()
            let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
            let signing = try! store.signingKey()
            let local = RemoteGroupDevice(id: UUID(), name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                                          publicKey: key.publicKey.rawRepresentation,
                                          signingKey: signing.publicKey.rawRepresentation, updatedAt: Date())
            return (RemoteDeviceGroup(local: local, signingKey: signing, identityKey: key, roster: roster, store: store), key)
        }
        let (phone, phoneKey) = member("iPhone")
        let (pad, padKey) = member("iPad")

        // iPhone：在 Mac 上审批配对过。
        let phoneHostsTable = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try phoneHostsTable.saveRaw(phoneKey.rawRepresentation, account: "identity")
        let phoneClient = RemoteMacClient(macName: "测试 Mac", endpoint: endpoint, identity: phoneHostsTable)
        phoneClient.localDeviceOverride = (phone.local.id, "iPhone")
        let connecting = Task { await phoneClient.connect() }
        _ = await waitUntil { !server.pairingRequests.isEmpty }
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(phoneClient.state, .connected)
        defer { phoneClient.disconnect() }
        let phoneHosts = ClientHosts(target: RemoteGroupVouchTarget(id: server.localID, name: "测试 Mac", publicKey: serverKey,
                                                                    model: "Mac mini", platform: "mac"),
                                     client: phoneClient)
        phone.hosts = phoneHosts

        // iPad：从没连过这台 Mac。目录是真的 `RemoteMacDirectory`。
        let padHostsTable = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try padHostsTable.saveRaw(padKey.rawRepresentation, account: "identity")
        let padDirectory = RemoteMacDirectory(identity: padHostsTable, adoptsRelayAsDefault: false)
        pad.hosts = padDirectory

        // 加入：iPad 显示数，iPhone 输入，iPad 核对，iPhone 核对 Ta、认下它，这一轮就去问 Mac。
        phone.refresh()
        pad.startJoin()
        phone.refresh()
        guard case .showingCode(let code, _) = pad.joinState else { return XCTFail("iPad 没显示核对码") }
        XCTAssertTrue(phone.submitCode(code, for: pad.local.id))
        pad.refresh()
        XCTAssertEqual(pad.joinState, .joined)
        XCTAssertTrue(pad.pendingHosts.isEmpty, "iPhone 还没认 iPad，目录也还没发")
        phone.refresh()
        XCTAssertEqual(phone.vouchesInFlight, 1)
        let written = await waitUntil { roster.load().grants.contains { $0.isFor(pad.local) } }
        XCTAssertTrue(written)
        let grant = try XCTUnwrap(roster.load().grants.first { $0.isFor(pad.local) })
        XCTAssertEqual(grant.outcome, RemoteVouchResult.Outcome.added.rawValue, grant.reason ?? "")
        XCTAssertEqual(grant.signer, phone.local.id)
        XCTAssertNotNil(server.peerVouches[pad.local.id], "Mac 记下了 iPad，来路是 iPhone")

        pad.refresh()
        let adopted = try XCTUnwrap(padHostsTable.peer(id: server.localID))
        XCTAssertEqual(adopted.publicKey, serverKey)
        XCTAssertTrue(pad.pendingHosts.isEmpty)
        XCTAssertEqual(padDirectory.pairedHostNames()[server.localID], "测试 Mac")

        let padClient = RemoteMacClient(macName: "测试 Mac", endpoint: endpoint, identity: padHostsTable, expectedPeer: adopted)
        padClient.localDeviceOverride = (pad.local.id, "iPad")
        let padConnecting = Task { await padClient.connect() }
        _ = await waitUntil(3) { padClient.state == .connected || !server.pairingRequests.isEmpty }
        XCTAssertTrue(server.pairingRequests.isEmpty, "不弹审批")
        await padConnecting.value
        XCTAssertEqual(padClient.state, .connected)
        padClient.disconnect()
    }

    // MARK: - 真服务端 + G3

    private func makeMember(_ name: String, id: UUID = UUID(), platform: RemoteDevicePlatform = .mobile,
                            key: Curve25519.KeyAgreement.PrivateKey = .init(),
                            roster: RemoteGroupRoster) -> RemoteDeviceGroup {
        let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
        let signing = try! store.signingKey()
        let local = RemoteGroupDevice(id: id, name: name, model: nil, platform: platform.rawValue,
                                      publicKey: key.publicKey.rawRepresentation,
                                      signingKey: signing.publicKey.rawRepresentation, updatedAt: Date())
        return RemoteDeviceGroup(local: local, signingKey: signing, identityKey: key, roster: roster, store: store)
    }

    private func joinForReal(_ candidate: RemoteDeviceGroup, via member: RemoteDeviceGroup) throws {
        member.refresh()
        candidate.startJoin()
        member.refresh()
        guard case .showingCode(let code, _) = candidate.joinState else { throw XCTSkip("没显示核对码") }
        XCTAssertTrue(member.submitCode(code, for: candidate.local.id))
        candidate.refresh()
        XCTAssertEqual(candidate.joinState, .joined)
        member.refresh()
    }

    private func startServer() async throws -> (RemoteHostServer, NWEndpoint, Data) {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        server.vouchPolicy = { true }
        server.groupControllerPolicy = { true }
        server.start()
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(server.port)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        return (server, endpoint, try server.identity.localIdentity().publicKey.rawRepresentation)
    }

    /// 组里的 Mac 互认：这台 Mac 自己是组员（模型的被控端就是真服务端），iPad 经它加入 → Mac 把 iPad 记成主控端、
    /// 写一条自己签的 grant → iPad 的真目录收下这台 Mac → 不经审批连上。
    func test_end_to_end_mac_member_records_a_new_member_which_then_connects_without_approval() async throws {
        let (server, endpoint, serverKey) = try await startServer()
        defer { server.stop() }
        let roster = RemoteGroupRoster(storage: RemoteMemorySyncedStorage())
        let mac = makeMember("测试 Mac", id: server.localID, platform: .mac, key: try server.identity.localIdentity(),
                             roster: roster)
        mac.localHost = server
        let padKey = Curve25519.KeyAgreement.PrivateKey()
        let pad = makeMember("iPad", key: padKey, roster: roster)
        let padHostsTable = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try padHostsTable.saveRaw(padKey.rawRepresentation, account: "identity")
        let padDirectory = RemoteMacDirectory(identity: padHostsTable, adoptsRelayAsDefault: false)
        pad.hosts = padDirectory

        try joinForReal(pad, via: mac)
        let written = await waitUntil {
            roster.load().grants.contains { $0.isFor(pad.local) && $0.signer == server.localID }
        }
        XCTAssertTrue(written, "Mac 认下 iPad 的这一轮就记下它、写结果")
        let grant = try XCTUnwrap(roster.load().grants.first { $0.isFor(pad.local) })
        XCTAssertEqual(grant.outcome, RemoteVouchResult.Outcome.added.rawValue, grant.reason ?? "")
        XCTAssertEqual(grant.host.publicKey, serverKey)
        XCTAssertTrue(try XCTUnwrap(server.peerVouches[pad.local.id]).isFromDeviceGroup(hostID: server.localID))

        pad.refresh()
        let adopted = try XCTUnwrap(padHostsTable.peer(id: server.localID))
        XCTAssertEqual(adopted.publicKey, serverKey)
        let padClient = RemoteMacClient(macName: "测试 Mac", endpoint: endpoint, identity: padHostsTable, expectedPeer: adopted)
        padClient.localDeviceOverride = (pad.local.id, "iPad")
        let connecting = Task { await padClient.connect() }
        _ = await waitUntil(3) { padClient.state == .connected || !server.pairingRequests.isEmpty }
        XCTAssertTrue(server.pairingRequests.isEmpty, "不弹审批")
        await connecting.value
        XCTAssertEqual(padClient.state, .connected)

        // iPad 被移除：Mac 自己把它撤掉，不拉黑。
        mac.remove([pad.local.id])
        mac.refresh()
        let dropped = await waitUntil { server.identity.peer(id: pad.local.id) == nil && padClient.state != .connected }
        XCTAssertTrue(dropped)
        XCTAssertFalse(server.identity.isBlocked(pad.local.id))
        padClient.disconnect()
    }

    /// 重装过的设备：iPhone 替旧的 iPad 开通过；iPad 重装（同一个设备 ID、新钥匙）后经 iPhone 重新加入 →
    /// iPhone 先在 Mac 上撤掉旧钥匙（不拉黑），再替新钥匙开通 → 新的 iPad 不经审批连上。
    func test_end_to_end_reinstalled_device_old_key_is_revoked_and_new_key_connects_without_approval() async throws {
        let (server, endpoint, serverKey) = try await startServer()
        defer { server.stop() }
        let roster = RemoteGroupRoster(storage: RemoteMemorySyncedStorage())
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let phone = makeMember("iPhone", key: phoneKey, roster: roster)
        let phoneHostsTable = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try phoneHostsTable.saveRaw(phoneKey.rawRepresentation, account: "identity")
        let phoneClient = RemoteMacClient(macName: "测试 Mac", endpoint: endpoint, identity: phoneHostsTable)
        phoneClient.localDeviceOverride = (phone.local.id, "iPhone")
        let connecting = Task { await phoneClient.connect() }
        _ = await waitUntil { !server.pairingRequests.isEmpty }
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(phoneClient.state, .connected)
        defer { phoneClient.disconnect() }
        let phoneHosts = ClientHosts(target: RemoteGroupVouchTarget(id: server.localID, name: "测试 Mac", publicKey: serverKey,
                                                                    model: "Mac mini", platform: "mac"),
                                     client: phoneClient)
        phone.hosts = phoneHosts

        let padID = UUID()
        let oldPad = makeMember("iPad", id: padID, roster: roster)
        try joinForReal(oldPad, via: phone)
        let oldKey = oldPad.local.publicKey
        let vouchedOld = await waitUntil { server.identity.peer(id: padID)?.publicKey == oldKey }
        XCTAssertTrue(vouchedOld)
        _ = await waitUntil { phone.vouchesInFlight == 0 }

        let newKey = Curve25519.KeyAgreement.PrivateKey()
        let newPad = makeMember("iPad", id: padID, key: newKey, roster: roster)
        let newHostsTable = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try newHostsTable.saveRaw(newKey.rawRepresentation, account: "identity")
        let newDirectory = RemoteMacDirectory(identity: newHostsTable, adoptsRelayAsDefault: false)
        newPad.hosts = newDirectory
        try joinForReal(newPad, via: phone)
        let replaced = await waitUntil {
            phone.refresh()
            return server.identity.peer(id: padID)?.publicKey == newKey.publicKey.rawRepresentation
                && roster.load().grants.contains { $0.isFor(newPad.local) && $0.isUsable }
        }
        XCTAssertTrue(replaced, "先撤旧钥匙、再开通新的：\(String(describing: roster.load().grants.first { $0.isFor(newPad.local) }?.reason))")
        XCTAssertFalse(server.identity.isBlocked(padID), "同组撤销不拉黑")

        newPad.refresh()
        let adopted = try XCTUnwrap(newHostsTable.peer(id: server.localID))
        let padClient = RemoteMacClient(macName: "测试 Mac", endpoint: endpoint, identity: newHostsTable, expectedPeer: adopted)
        padClient.localDeviceOverride = (padID, "iPad")
        let padConnecting = Task { await padClient.connect() }
        _ = await waitUntil(3) { padClient.state == .connected || !server.pairingRequests.isEmpty }
        XCTAssertTrue(server.pairingRequests.isEmpty, "不弹审批")
        await padConnecting.value
        XCTAssertEqual(padClient.state, .connected)
        XCTAssertNotNil(newDirectory.pairedHostNames()[server.localID])
        padClient.disconnect()
    }
}
