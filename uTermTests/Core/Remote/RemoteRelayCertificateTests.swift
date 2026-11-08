import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 中继成员证书：主机给每台配对设备签一把只能连自己的成员密钥，忘记设备时吊销。
/// 经真实中继的部分在 `RemoteRelayEndToEndTests`。
@MainActor
final class RemoteRelayCertificateTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "RemoteRelayCertificateTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private let rootKey = P256.Signing.PrivateKey()

    private var root: RemoteRelayConfig {
        RemoteRelayConfig(name: "家里", host: "relay.example.com", port: 47310, relayID: "6f1c00aa",
                          key: rootKey.rawRepresentation.base64EncodedString())
    }

    func testCertificateIsSignedByTheRelayKeyForOneHost() throws {
        let host = UUID()
        let certificate = try root.certificate(for: host)
        XCTAssertTrue(certificate.isCertificate)
        XCTAssertTrue(certificate.isValid)
        XCTAssertEqual(certificate.scope, host.uuidString)
        XCTAssertEqual(certificate.relayID, root.relayID)
        XCTAssertNotEqual(certificate.key, root.key)
        let member = try XCTUnwrap(certificate.memberPublicKey)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(certificate.cert))))
        let message = RemoteRelayConfig.certificateMessage(relayID: root.relayID, member: member, scope: host.uuidString)
        XCTAssertTrue(rootKey.publicKey.isValidSignature(signature, for: message))
        XCTAssertEqual(String(decoding: message, as: UTF8.self),
                       "uterm-relay-member-v1\n6f1c00aa\n\(member)\n\(host.uuidString)")

        XCTAssertThrowsError(try certificate.certificate(for: host), "证书不能再签证书")
        XCTAssertNotEqual(try root.certificate(for: host).key, certificate.key, "每次一把新钥匙")
    }

    func testCertificateRoundTripsThroughFileQRAndInvitation() throws {
        let certificate = try root.certificate(for: UUID())
        let json = try JSONEncoder().encode(certificate)
        XCTAssertEqual(RemoteRelayConfig(importing: json), certificate)
        XCTAssertEqual(RemoteRelayConfig(scanned: try XCTUnwrap(certificate.url).absoluteString), certificate)

        let invitation = RemotePairingInvitation(macID: UUID(), macName: "Mac", macKey: Data(repeating: 1, count: 32),
                                                 token: RemotePairingInvitation.newToken(), relay: certificate)
        XCTAssertEqual(RemotePairingInvitation(scanned: invitation.url.absoluteString)?.relay, certificate)

        // 老版本的成员密钥配置不受影响。
        XCTAssertEqual(RemoteRelayConfig(importing: try JSONEncoder().encode(root)), root)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(root), as: UTF8.self).contains("scope"))
    }

    func testHalfACertificateIsInvalid() throws {
        var noCert = try root.certificate(for: UUID())
        noCert.cert = nil
        XCTAssertFalse(noCert.isValid)
        var noScope = try root.certificate(for: UUID())
        noScope.scope = nil
        XCTAssertFalse(noScope.isValid)
        var emptyScope = try root.certificate(for: UUID())
        emptyScope.scope = ""
        XCTAssertFalse(emptyScope.isValid)
    }

    func testMemberRequestCarriesTheCertificate() throws {
        let host = UUID()
        let certificate = try root.certificate(for: host)
        let request = try RemoteRelayRequest.member(role: "dial", config: certificate, nonce: "bm9uY2U=",
                                                    parameter: host.uuidString, hostID: host.uuidString, session: "s")
        XCTAssertEqual(request.member, certificate.memberPublicKey)
        XCTAssertEqual(request.cert, certificate.cert)
        XCTAssertEqual(request.scope, host.uuidString)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(request.sig))))
        let signed = Data(["uterm-relay-v1", "dial", root.relayID, "bm9uY2U=", host.uuidString]
            .joined(separator: "\n").utf8)
        XCTAssertTrue(try XCTUnwrap(certificate.memberKey).publicKey.isValidSignature(signature, for: signed),
                      "证书持有者用自己的钥匙签")

        let plain = try RemoteRelayRequest.member(role: "client", config: root, nonce: "bm9uY2U=")
        XCTAssertNil(plain.member)
        XCTAssertNil(plain.cert)
        XCTAssertNil(plain.scope)
    }

    func testCertificatesNeverBecomeTheDefault() throws {
        let mine = try root.certificate(for: UUID())
        let theirs = try root.certificate(for: UUID())
        var elsewhere = root
        elsewhere.relayID = "other"
        let foreign = try elsewhere.certificate(for: UUID())

        // 已有同一台中继的成员密钥：什么都能连，证书不用记。
        XCTAssertEqual(RemoteRelayPlacement.place(mine, current: root), .keep)
        XCTAssertEqual(RemoteRelayPlacement.place(mine, current: root, adoptsAsDefault: false), .keep)
        // 其余情况证书只记在发证的那台主机上：默认中继会经 iCloud 同步到本人的 Mac，Mac 拿证书注册不了。
        XCTAssertEqual(RemoteRelayPlacement.place(mine, current: nil), .perHost)
        XCTAssertEqual(RemoteRelayPlacement.place(mine, current: theirs), .perHost)
        XCTAssertEqual(RemoteRelayPlacement.place(foreign, current: root), .perHost)
        // 成员密钥的规则不变。
        XCTAssertEqual(RemoteRelayPlacement.place(root, current: nil), .setDefault)
        XCTAssertEqual(RemoteRelayPlacement.place(root, current: root), .keep)
        XCTAssertEqual(RemoteRelayPlacement.place(elsewhere, current: root), .perHost)
        XCTAssertEqual(RemoteRelayPlacement.place(root, current: mine), .setDefault)
        XCTAssertEqual(RemoteRelayPlacement.place(root, current: nil, adoptsAsDefault: false), .perHost)
    }

    func testMemberIdentitySeparatesCertificatesOnOneRelay() throws {
        let a = try root.certificate(for: UUID())
        let b = try root.certificate(for: UUID())
        XCTAssertEqual(root.memberIdentity, root.relayID)
        XCTAssertNotEqual(a.memberIdentity, b.memberIdentity)
        XCTAssertTrue(a.memberIdentity.hasPrefix(root.relayID + "/"))
    }

    func testRelayVersionDecidesWhetherCertificatesWork() {
        XCTAssertNil(RemoteRelayVersion.supportsMemberCertificates(nil))
        XCTAssertNil(RemoteRelayVersion.supportsMemberCertificates("dev"))
        XCTAssertEqual(RemoteRelayVersion.supportsMemberCertificates("1.1.1"), false)
        XCTAssertEqual(RemoteRelayVersion.supportsMemberCertificates("1.2.0"), true)
        XCTAssertEqual(RemoteRelayVersion.supportsMemberCertificates("1.10"), true)
    }

    func testRevocationQueueKeepsUntilConfirmed() {
        let queue = RemoteRelayRevocations(defaults: defaults)
        queue.add("a", relayID: "r1")
        queue.add("a", relayID: "r1")
        queue.add("b", relayID: "r1")
        queue.add("c", relayID: "r2")
        XCTAssertEqual(queue.pending(relayID: "r1"), ["a", "b"])
        queue.confirm("a", relayID: "r1")
        queue.confirm("zzz", relayID: "r1")
        XCTAssertEqual(RemoteRelayRevocations(defaults: defaults).pending(relayID: "r1"), ["b"], "存下来，重启后还在")
        queue.confirm("c", relayID: "r2")
        XCTAssertEqual(queue.pending(relayID: "r2"), [])
        for index in 0..<(RemoteRelayRevocations.limit + 3) { queue.add("m\(index)", relayID: "r3") }
        XCTAssertEqual(queue.pending(relayID: "r3").count, RemoteRelayRevocations.limit)
        XCTAssertEqual(queue.pending(relayID: "r3").last, "m\(RemoteRelayRevocations.limit + 2)")
    }

    /// 主控端导入证书（链接、扫码、主机发来）：记到发证的那台 Mac 名下，不当默认；没配对那台就导入不了。
    func testControllerKeepsCertificatesOnTheirMac() throws {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let mac = RemotePeer(id: UUID(), name: "Mac", publicKey: Data(repeating: 3, count: 32), pairedAt: .now,
                             platform: RemoteDevicePlatform.mac.rawValue)
        try identity.trust(mac)
        let directory = RemoteMacDirectory(identity: identity, defaults: defaults, adoptsRelayAsDefault: true)
        let certificate = try root.certificate(for: mac.id)

        XCTAssertTrue(directory.importRelayConfig(certificate))
        XCTAssertEqual(identity.peer(id: mac.id)?.relay, certificate)
        XCTAssertNil(directory.relayServerName(), "默认中继没动")
        XCTAssertFalse(directory.importRelayConfig(try root.certificate(for: UUID())), "没配对的 Mac 发的证书导入不了")

        // 之后导入同一台中继的成员密钥：成了默认；同一台中继再来的证书不用另记。
        XCTAssertTrue(directory.importRelayConfig(root))
        XCTAssertEqual(directory.relayServerName(), root.name)
        directory.receiveRelayConfig(try root.certificate(for: mac.id), from: mac.id)
        XCTAssertEqual(identity.peer(id: mac.id)?.relay, certificate, "有成员密钥时新证书不覆盖")
    }

    // MARK: - 被控端怎么发

    private func makeServer(version: String?) throws -> (RemoteHostServer, RemoteIdentityStore, RemotePeer) {
        let identity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        let updates = RemoteRelayUpdateMonitor.inert()
        updates.noteRunning(version)
        let server = RemoteHostServer(registry: TerminalSessionRegistry(), identity: identity, localName: "Mac",
                                      localID: UUID(), advertises: false, relayUpdates: updates,
                                      relayRevocations: RemoteRelayRevocations(defaults: defaults))
        server.relayConfig = root
        let peer = RemotePeer(id: UUID(), name: "手机", publicKey: Data(repeating: 2, count: 32), pairedAt: .now)
        try server.trust(peer)
        return (server, identity, peer)
    }

    func testHostGivesEachDeviceItsOwnCertificateAndRevokesItOnForget() throws {
        let (server, identity, peer) = try makeServer(version: "1.2.0")
        let first = try XCTUnwrap(server.relayConfig(forPeer: peer.id))
        XCTAssertEqual(first.scope, server.localID.uuidString)
        XCTAssertEqual(identity.peer(id: peer.id)?.relayGrant, first, "记到这台设备名下")
        XCTAssertEqual(server.relayConfig(forPeer: peer.id), first, "下次连上复用同一张")

        var moved = root
        moved.host = "relay2.example.com"
        server.relayConfig = moved
        let followed = try XCTUnwrap(server.relayConfig(forPeer: peer.id))
        XCTAssertEqual(followed.key, first.key, "中继换了地址，证书不变")
        XCTAssertEqual(followed.host, "relay2.example.com")

        server.revoke(peer.id)
        XCTAssertEqual(server.relayRevocations.pending(relayID: root.relayID), [try XCTUnwrap(first.memberPublicKey)])
        XCTAssertNil(server.relayConfig(forPeer: peer.id), "忘记了就什么都不给")
    }

    func testOldRelayGetsTheSharedKeyAndUnknownGetsNothing() throws {
        let (old, _, oldPeer) = try makeServer(version: "1.1.1")
        XCTAssertEqual(old.relayConfig(forPeer: oldPeer.id), root, "老中继不认证书，照旧发成员密钥")
        let (unknown, _, unknownPeer) = try makeServer(version: nil)
        XCTAssertNil(unknown.relayConfig(forPeer: unknownPeer.id), "还不知道中继版本时不发，注册上再发")
    }

    func testUnusedInvitationCertificateIsRevokedWhenReplaced() throws {
        let (server, _, _) = try makeServer(version: "1.2.0")
        // 没有中继注册：邀请不带中继，也就没有要吊销的。
        XCTAssertNil(try server.makePairingInvitation().relay)
        server.cancelPairingInvitation()
        XCTAssertEqual(server.relayRevocations.pending(relayID: root.relayID), [])
    }
}
