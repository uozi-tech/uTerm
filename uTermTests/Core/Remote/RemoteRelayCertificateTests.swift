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
        let expires = try XCTUnwrap(certificate.expires)
        let message = RemoteRelayConfig.certificateMessage(relayID: root.relayID, member: member, scope: host.uuidString,
                                                           expires: expires)
        XCTAssertTrue(rootKey.publicKey.isValidSignature(signature, for: message))
        XCTAssertEqual(String(decoding: message, as: UTF8.self),
                       "uterm-relay-member-v2\n6f1c00aa\n\(member)\n\(host.uuidString)\n\(expires)")
        XCTAssertEqual(TimeInterval(expires), Date().timeIntervalSince1970 + RemoteRelayConfig.certificateLifetime,
                       accuracy: 5, "一年后到期")
        XCTAssertEqual(RemoteRelayConfig.certificateLifetime, 365 * 86_400)

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

    /// 老版本只收格式版本 1：证书写成 2，它们整份丢掉，不会把证书里设备自己的私钥当成中继密钥存成默认、
    /// 再经 iCloud 钥匙串同步给本人的 Mac（Mac 拿它注册中继一律被拒）。
    func testOldVersionsCannotMistakeACertificateForTheRelayKey() throws {
        let certificate = try root.certificate(for: UUID())
        struct OldDecoder: Decodable { var version: Int; var key: String }
        let json = try JSONEncoder().encode(certificate)
        XCTAssertEqual(try JSONDecoder().decode(OldDecoder.self, from: json).version,
                       RemoteRelayConfig.certificateVersion, "老版本校验 version == 1，2 就不收")
        let qr = try XCTUnwrap(URLComponents(url: try XCTUnwrap(certificate.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(qr.queryItems?.first { $0.name == "v" }?.value, "2")
        XCTAssertEqual(try XCTUnwrap(RemoteRelayConfig(importing: json)), certificate)
        XCTAssertEqual(RemoteRelayConfig(scanned: try XCTUnwrap(certificate.url).absoluteString), certificate)

        // 根配置照旧是 1，老版本照常认。
        XCTAssertEqual(try JSONDecoder().decode(OldDecoder.self, from: JSONEncoder().encode(root)).version, 1)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(root.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "v" }?.value, "1")

        // 修正之前存下的证书写的是 1：读得回来，再发出去时写 2。
        var legacy = certificate
        legacy.version = RemoteRelayConfig.version
        let stored = try JSONEncoder().encode(legacy)
        let reloaded = try XCTUnwrap(RemoteRelayConfig(importing: stored))
        XCTAssertEqual(try JSONDecoder().decode(OldDecoder.self, from: JSONEncoder().encode(reloaded)).version, 2)

        // 版本 2 却没有证书：不合法。
        var forged = root
        forged.version = RemoteRelayConfig.certificateVersion
        XCTAssertNil(RemoteRelayConfig(importing: try JSONEncoder().encode(forged)))
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
        XCTAssertEqual(RemoteRelayVersion.supportsMemberCertificates("1.2.0"), false, "1.2.x 的证书没有到期时间，不再发")
        XCTAssertEqual(RemoteRelayVersion.supportsMemberCertificates("1.3.0"), true)
        XCTAssertEqual(RemoteRelayVersion.supportsMemberCertificates("1.10"), true)
    }

    func testRevocationQueueKeepsUntilConfirmed() {
        let later = Int64(Date().timeIntervalSince1970) + 86_400
        let queue = RemoteRelayRevocations(defaults: defaults)
        queue.add("a", relayID: "r1", expires: later)
        queue.add("a", relayID: "r1", expires: later - 100)
        queue.add("b", relayID: "r1", expires: nil)
        queue.add("c", relayID: "r2", expires: later)
        XCTAssertEqual(queue.pending(relayID: "r1").map(\.member), ["a", "b"])
        XCTAssertEqual(queue.pending(relayID: "r1").first?.expires, later, "续过期的证书按更晚的到期时间吊销")
        XCTAssertNil(queue.pending(relayID: "r1").last?.expires, "1.2.x 的证书没有到期时间，中继按最长记")
        queue.confirm("a", relayID: "r1")
        queue.confirm("zzz", relayID: "r1")
        XCTAssertEqual(RemoteRelayRevocations(defaults: defaults).pending(relayID: "r1").map(\.member), ["b"],
                       "存下来，重启后还在")
        queue.confirm("c", relayID: "r2")
        XCTAssertEqual(queue.pending(relayID: "r2"), [])
        for index in 0..<(RemoteRelayRevocations.limit + 3) {
            queue.add(String(format: "m%05d", index), relayID: "r3", expires: later + Int64(index))
        }
        let kept = queue.pending(relayID: "r3")
        XCTAssertEqual(kept.count, RemoteRelayRevocations.limit)
        XCTAssertFalse(kept.contains { $0.member == "m00000" }, "满了丢最快到期的")
        XCTAssertTrue(kept.contains { $0.member == String(format: "m%05d", RemoteRelayRevocations.limit + 2) })

        // 证书过期了就不用再发。
        var clock = RemoteRelayRevocations(defaults: defaults)
        clock.now = { Date(timeIntervalSince1970: TimeInterval(later + 10_000)) }
        XCTAssertEqual(clock.pending(relayID: "r1").map(\.member), ["b"], "没有到期时间的留着")
        XCTAssertEqual(clock.pending(relayID: "r3"), [], "全过期了")
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

    // MARK: - 有效期

    func testRenewalKeepsTheKeyAndPushesTheExpiryOut() throws {
        let issued = Date(timeIntervalSince1970: 1_800_000_000)
        let certificate = try root.certificate(for: UUID(), now: issued)
        XCTAssertFalse(certificate.needsRenewal(now: issued + 6 * 86_400), "签发一周内不续")
        XCTAssertTrue(certificate.needsRenewal(now: issued + 8 * 86_400), "签发超过一周就续")
        XCTAssertFalse(certificate.isExpired(now: issued + 364 * 86_400))
        XCTAssertTrue(certificate.isExpired(now: issued + 365 * 86_400))
        let invitation = try root.certificate(for: UUID(), lifetime: RemoteRelayConfig.invitationCertificateLifetime,
                                              now: issued)
        XCTAssertTrue(invitation.needsRenewal(now: issued), "邀请里那张一天的：配上就续")

        let renewed = try certificate.renewed(by: root, now: issued + 31 * 86_400)
        XCTAssertEqual(renewed.key, certificate.key, "同一把钥匙：吊销仍认同一个公钥")
        XCTAssertEqual(renewed.scope, certificate.scope)
        XCTAssertEqual(renewed.expires, Int64(issued.timeIntervalSince1970) + (31 + 365) * 86_400)
        XCTAssertNotEqual(renewed.cert, certificate.cert)
        XCTAssertTrue(renewed.sameMember(as: certificate))
        XCTAssertThrowsError(try certificate.renewed(by: certificate), "只有中继本身的成员密钥能续")

        var legacy = certificate
        legacy.expires = nil
        XCTAssertTrue(legacy.isValid, "1.2.x 发的证书读得回来")
        XCTAssertTrue(legacy.needsRenewal(), "没有到期时间：马上续")
        XCTAssertFalse(legacy.isExpired())

        var rootWithExpiry = root
        rootWithExpiry.expires = 1
        XCTAssertFalse(rootWithExpiry.isValid, "只有证书有到期时间")
    }

    func testExpiryRoundTripsThroughFileQRAndInvitation() throws {
        let certificate = try root.certificate(for: UUID())
        XCTAssertEqual(RemoteRelayConfig(importing: try JSONEncoder().encode(certificate))?.expires, certificate.expires)
        XCTAssertEqual(RemoteRelayConfig(scanned: try XCTUnwrap(certificate.url).absoluteString)?.expires,
                       certificate.expires)
        let invitation = RemotePairingInvitation(macID: UUID(), macName: "Mac", macKey: Data(repeating: 1, count: 32),
                                                 token: RemotePairingInvitation.newToken(), relay: certificate)
        XCTAssertEqual(RemotePairingInvitation(scanned: invitation.url.absoluteString)?.relay, certificate)
    }

    func testExpiredCertificateFailsLocallyWithAWayOut() throws {
        let expired = try root.certificate(for: UUID(), lifetime: -60)
        XCTAssertThrowsError(try RemoteRelayRequest.member(role: "client", config: expired, nonce: "bm9uY2U=")) { error in
            XCTAssertEqual(error as? RemoteRelayError, .certificateExpired)
            XCTAssertTrue(error.localizedDescription.contains("重新扫码"), error.localizedDescription)
        }
        let request = try RemoteRelayRequest.member(role: "client", config: try root.certificate(for: UUID()),
                                                    nonce: "bm9uY2U=")
        XCTAssertNotNil(request.exp, "请求带上到期时间，中继按它验签")
    }

    func testHostRenewsAnAgingGrantWhenTheDeviceComesBack() throws {
        let (server, identity, peer) = try makeServer(version: "1.3.0")
        let first = try XCTUnwrap(server.relayConfig(forPeer: peer.id))
        // 拨回 10 天前发的：签发超过一周。
        var aging = try XCTUnwrap(identity.peer(id: peer.id))
        aging.relayGrant = try first.renewed(by: root, now: Date() - 10 * 86_400)
        try identity.trust(aging)
        let renewed = try XCTUnwrap(server.relayConfig(forPeer: peer.id))
        XCTAssertEqual(renewed.key, first.key)
        XCTAssertEqual(TimeInterval(try XCTUnwrap(renewed.expires)),
                       Date().timeIntervalSince1970 + RemoteRelayConfig.certificateLifetime, accuracy: 5)
        XCTAssertEqual(identity.peer(id: peer.id)?.relayGrant, renewed, "续过的记下来，吊销按新的到期时间")
        XCTAssertEqual(server.relayConfig(forPeer: peer.id), renewed, "刚续过的不再续")

        // 1.2.x 时代发的（没有到期时间）也续成新的。
        var legacy = try XCTUnwrap(identity.peer(id: peer.id))
        legacy.relayGrant?.expires = nil
        try identity.trust(legacy)
        XCTAssertNotNil(server.relayConfig(forPeer: peer.id)?.expires)
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
        let (server, identity, peer) = try makeServer(version: "1.3.0")
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
        XCTAssertEqual(server.relayRevocations.pending(relayID: root.relayID),
                       [.init(member: try XCTUnwrap(first.memberPublicKey), expires: first.expires)])
        XCTAssertNil(server.relayConfig(forPeer: peer.id), "忘记了就什么都不给")
    }

    func testOldRelayGetsTheSharedKeyAndUnknownGetsNothing() throws {
        let (old, _, oldPeer) = try makeServer(version: "1.1.1")
        XCTAssertEqual(old.relayConfig(forPeer: oldPeer.id), root, "老中继不认证书，照旧发成员密钥")
        let (noExpiry, _, noExpiryPeer) = try makeServer(version: "1.2.0")
        XCTAssertEqual(noExpiry.relayConfig(forPeer: noExpiryPeer.id), root,
                       "1.2.x 只认没有到期时间的证书：这一版不再发那种证书，照旧发成员密钥")
        let (unknown, _, unknownPeer) = try makeServer(version: nil)
        XCTAssertNil(unknown.relayConfig(forPeer: unknownPeer.id), "还不知道中继版本时不发，注册上再发")
    }

    /// 经中继来续：只续自己给这台设备记着的那张（公钥对得上、没过期、没被忘记），续了还是同一把钥匙。
    func testHostRenewsOnlyItsOwnLiveGrant() throws {
        let (server, identity, peer) = try makeServer(version: "1.3.0")
        let first = try XCTUnwrap(server.relayConfig(forPeer: peer.id))
        let member = try XCTUnwrap(first.memberPublicKey)
        var aging = try XCTUnwrap(identity.peer(id: peer.id))
        aging.relayGrant = try first.renewed(by: root, now: Date() - 10 * 86_400)
        try identity.trust(aging)

        let renewed = try XCTUnwrap(server.renewRelayGrant(peerID: peer.id, member: member))
        XCTAssertEqual(renewed.key, first.key)
        XCTAssertGreaterThan(try XCTUnwrap(renewed.expires), try XCTUnwrap(aging.relayGrant?.expires))
        XCTAssertNil(server.renewRelayGrant(peerID: peer.id, member: try XCTUnwrap(try root.certificate(for: UUID())
            .memberPublicKey)), "别的钥匙不给续")
        XCTAssertNil(server.renewRelayGrant(peerID: UUID(), member: member), "不认识的设备")

        var expired = try XCTUnwrap(identity.peer(id: peer.id))
        expired.relayGrant = try first.renewed(by: root, now: Date() - 400 * 86_400)
        try identity.trust(expired)
        XCTAssertNil(server.renewRelayGrant(peerID: peer.id, member: member), "过期的不续：同网连一次或重新扫码")

        server.revoke(peer.id)
        XCTAssertNil(server.renewRelayGrant(peerID: peer.id, member: member), "忘记（吊销）后不能续")
    }

    /// 续期信令：只回认识、勾选过公网接入的设备；重放、别的种类、不认识的一律不理。
    func testRenewalSignalGate() throws {
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let phoneID = UUID()
        let phone = RemotePeer(id: phoneID, name: "手机", publicKey: phoneKey.publicKey.rawRepresentation, pairedAt: .now)
        var allowed = true
        var responder = RemoteSignalResponder(localKey: macKey, localID: UUID(),
                                              recognize: { $0 == phoneID ? phone : nil }, isAllowed: { _ in allowed })
        let shared = try RemoteSignalBox.sharedKey(local: phoneKey, remotePublicKey: macKey.publicKey.rawRepresentation)
        let now = Date().timeIntervalSince1970
        func box(_ kind: RemoteSignalBody.Kind, member: String? = "pk", session: String) throws -> String {
            var body = RemoteSignalBody(kind: kind, deviceID: phoneID, sentAt: now, nonce: RemoteSignalBody.newNonce())
            body.member = member
            return try RemoteSignalBox.seal(body, key: shared, session: session, direction: .phoneToMac)
        }
        let sealed = try box(.renewCertificate, session: "s1")
        XCTAssertEqual(responder.receiveRenewal(session: "s1", from: phoneID.uuidString, box: sealed, now: now)?.member, "pk")
        XCTAssertNil(responder.receiveRenewal(session: "s1", from: phoneID.uuidString, box: sealed, now: now), "重放")
        XCTAssertNil(responder.receiveRenewal(session: "s2", from: phoneID.uuidString,
                                              box: try box(.renewCertificate, member: nil, session: "s2"), now: now))
        XCTAssertNil(responder.receiveRenewal(session: "s3", from: phoneID.uuidString,
                                              box: try box(.relayProbe, session: "s3"), now: now))
        XCTAssertNil(responder.receiveRenewal(session: "s4", from: UUID().uuidString,
                                              box: try box(.renewCertificate, session: "s4"), now: now), "不认识")
        allowed = false
        XCTAssertNil(responder.receiveRenewal(session: "s5", from: phoneID.uuidString,
                                              box: try box(.renewCertificate, session: "s5"), now: now), "没勾选公网接入")
        // 连接请求的入口不吃续期信令（也不占它的防重放）。
        allowed = true
        let renewal = try box(.renewCertificate, session: "s6")
        XCTAssertNil(responder.respond(session: "s6", from: phoneID.uuidString, box: renewal, now: now))
        XCTAssertNotNil(responder.receiveRenewal(session: "s6", from: phoneID.uuidString, box: renewal, now: now))
    }

    func testUnusedInvitationCertificateIsRevokedWhenReplaced() throws {
        let (server, _, _) = try makeServer(version: "1.3.0")
        // 没有中继注册：邀请不带中继，也就没有要吊销的。
        XCTAssertNil(try server.makePairingInvitation().relay)
        server.cancelPairingInvitation()
        XCTAssertEqual(server.relayRevocations.pending(relayID: root.relayID), [])
    }
}
