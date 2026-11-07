import CryptoKit
import XCTest
@testable import uTerm

/// 信令的安全规则。这些决定公网上谁能碰到这台 Mac，每条都单独验。
final class RemoteSignalingTests: XCTestCase {

    private let phoneKey = Curve25519.KeyAgreement.PrivateKey()
    private let macKey = Curve25519.KeyAgreement.PrivateKey()
    private let phoneID = UUID()
    private let macID = UUID()
    private let now: TimeInterval = 1_800_000_000

    private var phonePeer: RemotePeer {
        RemotePeer(id: phoneID, name: "手机", publicKey: phoneKey.publicKey.rawRepresentation, pairedAt: Date())
    }

    private func shared() throws -> SymmetricKey {
        try RemoteSignalBox.sharedKey(local: phoneKey, remotePublicKey: macKey.publicKey.rawRepresentation)
    }

    private func offer(session: String = "s", at time: TimeInterval? = nil, nonce: Data = RemoteSignalBody.newNonce(),
                       deviceID: UUID? = nil, kind: RemoteSignalBody.Kind = .offer) throws -> (String, RemoteSignalBody) {
        let body = RemoteSignalBody(kind: kind, deviceID: deviceID ?? phoneID, sentAt: time ?? now, nonce: nonce)
        return (try RemoteSignalBox.seal(body, key: try shared(), session: session, direction: .phoneToMac), body)
    }

    private func responder(known: Bool = true, allowed: Bool = true) -> RemoteSignalResponder {
        let peer = phonePeer
        return RemoteSignalResponder(localKey: macKey, localID: macID,
                                     recognize: { known && $0 == peer.id ? peer : nil },
                                     isAllowed: { _ in allowed })
    }

    // MARK: - 密封

    func test_both_sides_derive_the_same_key_and_round_trip() throws {
        let macSide = try RemoteSignalBox.sharedKey(local: macKey, remotePublicKey: phoneKey.publicKey.rawRepresentation)
        let (box, body) = try offer()
        XCTAssertEqual(try RemoteSignalBox.open(box, key: macSide, session: "s", direction: .phoneToMac), body)
    }

    func test_a_third_device_cannot_open_or_forge_a_box() throws {
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        let wrong = try RemoteSignalBox.sharedKey(local: stranger, remotePublicKey: macKey.publicKey.rawRepresentation)
        let (box, _) = try offer()
        XCTAssertThrowsError(try RemoteSignalBox.open(box, key: wrong, session: "s", direction: .phoneToMac))
    }

    func test_box_is_bound_to_session_and_direction() throws {
        let key = try shared()
        let (box, _) = try offer(session: "s")
        XCTAssertThrowsError(try RemoteSignalBox.open(box, key: key, session: "other", direction: .phoneToMac),
                             "不能搬到别的会话")
        XCTAssertThrowsError(try RemoteSignalBox.open(box, key: key, session: "s", direction: .macToPhone),
                             "不能原样反射回发送方")
    }

    func test_tampered_or_garbage_box_is_rejected() throws {
        let key = try shared()
        let (box, _) = try offer()
        var bytes = try XCTUnwrap(Data(base64Encoded: box))
        bytes[bytes.startIndex + 15] ^= 1
        XCTAssertEqual(try? RemoteSignalBox.open(bytes.base64EncodedString(), key: key, session: "s", direction: .phoneToMac), nil)
        XCTAssertThrowsError(try RemoteSignalBox.open("不是 base64", key: key, session: "s", direction: .phoneToMac))
    }

    func test_low_order_public_key_is_rejected() {
        XCTAssertThrowsError(try RemoteSignalBox.sharedKey(local: phoneKey, remotePublicKey: Data(count: 32)))
    }

    func test_handshake_keys_pair_up_and_depend_on_both_nonces() throws {
        let key = try shared()
        let a = RemoteSignalBody.newNonce(), b = RemoteSignalBody.newNonce()
        let phone = RemoteSignalBox.handshakeKeys(sharedKey: key, phoneNonce: a, macNonce: b, session: "s", role: .initiator)
        let mac = RemoteSignalBox.handshakeKeys(sharedKey: key, phoneNonce: a, macNonce: b, session: "s", role: .responder)
        XCTAssertEqual(phone.send, mac.receive)
        XCTAssertEqual(phone.receive, mac.send)
        XCTAssertNotEqual(phone.send, phone.receive)
        let other = RemoteSignalBox.handshakeKeys(sharedKey: key, phoneNonce: a, macNonce: RemoteSignalBody.newNonce(),
                                                  session: "s", role: .initiator)
        XCTAssertNotEqual(phone.send, other.send)
    }

    // MARK: - 防重放

    func test_replay_guard_rejects_repeats_and_stale_times() {
        var guardian = RemoteSignalReplayGuard()
        let nonce = RemoteSignalBody.newNonce()
        let body = RemoteSignalBody(kind: .offer, deviceID: phoneID, sentAt: now, nonce: nonce)
        XCTAssertTrue(guardian.accept(body, now: now))
        XCTAssertFalse(guardian.accept(body, now: now + 1), "同一随机数只认一次")
        var old = body
        old.nonce = RemoteSignalBody.newNonce()
        old.sentAt = now - 121
        XCTAssertFalse(guardian.accept(old, now: now), "太旧")
        old.sentAt = now + 121
        XCTAssertFalse(guardian.accept(old, now: now), "太新")
        old.sentAt = now
        old.nonce = Data(count: 4)
        XCTAssertFalse(guardian.accept(old, now: now), "随机数太短")
    }

    // MARK: - Mac 的决定

    func test_unknown_device_gets_no_answer_at_all() throws {
        var responder = responder(known: false)
        let (box, _) = try offer()
        XCTAssertNil(responder.respond(session: "s", from: phoneID.uuidString, box: box, now: now),
                     "不认识的设备不能探测到这台 Mac 在线")
        XCTAssertNil(responder.claim(session: "s", now: now))
    }

    func test_known_but_not_allowed_device_is_told_and_cannot_connect() throws {
        var responder = responder(allowed: false)
        let (box, _) = try offer()
        let reply = try XCTUnwrap(responder.respond(session: "s", from: phoneID.uuidString, box: box, now: now))
        let body = try RemoteSignalBox.open(reply, key: try shared(), session: "s", direction: .macToPhone)
        XCTAssertEqual(body.kind, .denied)
        XCTAssertNil(responder.claim(session: "s", now: now), "被拒的会话接不进来")
    }

    func test_allowed_device_gets_answer_and_matching_keys_once() throws {
        var responder = responder()
        let (box, sent) = try offer()
        let reply = try XCTUnwrap(responder.respond(session: "s", from: phoneID.uuidString, box: box, now: now))
        let body = try RemoteSignalBox.open(reply, key: try shared(), session: "s", direction: .macToPhone)
        XCTAssertEqual(body.kind, .answer)
        XCTAssertEqual(body.deviceID, macID)

        let pending = try XCTUnwrap(responder.claim(session: "s", now: now))
        XCTAssertEqual(pending.peer.id, phoneID)
        let phone = RemoteSignalBox.handshakeKeys(sharedKey: try shared(), phoneNonce: sent.nonce, macNonce: body.nonce,
                                                  session: "s", role: .initiator)
        XCTAssertEqual(phone.send, pending.keys.receive)
        XCTAssertNil(responder.claim(session: "s", now: now), "一个会话只能接一次")
    }

    func test_session_expires() throws {
        var responder = responder()
        let (box, _) = try offer()
        XCTAssertNotNil(responder.respond(session: "s", from: phoneID.uuidString, box: box, now: now))
        XCTAssertNil(responder.claim(session: "s", now: now + RemoteSignalResponder.sessionLifetime + 1))
    }

    func test_replayed_offer_gets_no_answer() throws {
        var responder = responder()
        let (box, _) = try offer()
        XCTAssertNotNil(responder.respond(session: "s", from: phoneID.uuidString, box: box, now: now))
        XCTAssertNil(responder.respond(session: "s", from: phoneID.uuidString, box: box, now: now + 1))
    }

    func test_offer_claiming_another_device_inside_the_box_is_ignored() throws {
        var responder = responder()
        let (box, _) = try offer(deviceID: UUID())
        XCTAssertNil(responder.respond(session: "s", from: phoneID.uuidString, box: box, now: now))
    }

    func test_reflected_answer_is_not_treated_as_an_offer() throws {
        var responder = responder()
        let (box, _) = try offer(kind: .answer)
        XCTAssertNil(responder.respond(session: "s", from: phoneID.uuidString, box: box, now: now))
    }

    func test_malformed_sender_is_ignored() throws {
        var responder = responder()
        let (box, _) = try offer()
        XCTAssertNil(responder.respond(session: "s", from: nil, box: box, now: now))
        XCTAssertNil(responder.respond(session: "s", from: "不是 UUID", box: box, now: now))
        XCTAssertNil(responder.respond(session: "s", from: phoneID.uuidString, box: nil, now: now))
    }
}

/// 中继配置的导入。里面有成员私钥，坏数据一律拒绝。
final class RemoteRelayConfigTests: XCTestCase {

    private func sampleKey() -> String {
        P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
    }

    private func sample() -> RemoteRelayConfig {
        RemoteRelayConfig(name: "家里", host: "relay.example.com", port: 47310, relayID: "abc123", key: sampleKey())
    }

    func test_imports_the_json_uterm_relay_writes() throws {
        let key = sampleKey()
        let json = """
        {"format":"uterm-relay","version":1,"name":"home","host":"relay.test","port":47310,"relayID":"abc","key":"\(key)"}
        """
        let config = try XCTUnwrap(RemoteRelayConfig(importing: Data(json.utf8)))
        XCTAssertEqual(config.host, "relay.test")
        XCTAssertEqual(config.endpointDescription, "relay.test:47310")
        XCTAssertNotNil(config.memberKey)
    }

    func test_rejects_wrong_format_version_port_or_key() throws {
        func json(format: String = "uterm-relay", version: Int = 1, port: Int = 47310, key: String) -> Data {
            Data("""
            {"format":"\(format)","version":\(version),"name":"n","host":"h","port":\(port),"relayID":"i","key":"\(key)"}
            """.utf8)
        }
        let key = sampleKey()
        XCTAssertNotNil(RemoteRelayConfig(importing: json(key: key)))
        XCTAssertNil(RemoteRelayConfig(importing: json(format: "other", key: key)))
        XCTAssertNil(RemoteRelayConfig(importing: json(version: 2, key: key)))
        XCTAssertNil(RemoteRelayConfig(importing: json(port: 70000, key: key)))
        XCTAssertNil(RemoteRelayConfig(importing: json(key: "短")))
        XCTAssertNil(RemoteRelayConfig(importing: Data("不是 JSON".utf8)))
    }

    func test_qr_url_round_trips() throws {
        let config = sample()
        let url = try XCTUnwrap(config.url)
        XCTAssertEqual(RemoteRelayConfig(scanned: url.absoluteString), config)
    }

    func test_pairing_codes_and_relay_codes_do_not_mix() throws {
        let invitation = RemotePairingInvitation(macID: UUID(), macName: "m", macKey: Data(count: 32),
                                                 token: RemotePairingInvitation.newToken())
        XCTAssertNil(RemoteRelayConfig(scanned: invitation.url.absoluteString))
        XCTAssertNil(RemotePairingInvitation(scanned: try XCTUnwrap(sample().url).absoluteString))
    }

    func test_store_round_trips_and_clears() throws {
        let store = RemoteRelayConfigStore(storage: RemoteMemorySyncedStorage())
        XCTAssertNil(store.load())
        let config = sample()
        try store.save(config)
        XCTAssertEqual(store.load(), config)
        store.clear()
        XCTAssertNil(store.load())
    }
}

extension SymmetricKey {
    fileprivate static func == (lhs: SymmetricKey, rhs: SymmetricKey) -> Bool {
        lhs.withUnsafeBytes { Data($0) } == rhs.withUnsafeBytes { Data($0) }
    }
}
