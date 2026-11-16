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
}
