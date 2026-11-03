import CryptoKit
import XCTest
@testable import uTerm

final class RemoteCryptoTests: XCTestCase {

    private typealias Key = Curve25519.KeyAgreement.PrivateKey

    private struct Side {
        let staticKey = Key()
        let ephemeral = Key()
        let id = UUID()

        func hello(advertising publicStatic: Data? = nil) -> RemoteHello {
            RemoteHello(version: RemoteConstants.protocolVersion, deviceID: id, deviceName: "dev",
                        ephemeralKey: ephemeral.publicKey.rawRepresentation,
                        staticKey: publicStatic ?? staticKey.publicKey.rawRepresentation)
        }
    }

    private func handshake(_ phone: Side, _ mac: Side,
                           phoneHello: RemoteHello? = nil) throws -> (phone: RemoteSessionKeys, mac: RemoteSessionKeys) {
        let ph = phoneHello ?? phone.hello()
        let mh = mac.hello()
        let transcript = try JSONEncoder().encode(ph) + JSONEncoder().encode(mh)
        let phoneKeys = try RemoteKeySchedule.derive(role: .initiator, localStatic: phone.staticKey,
                                                     localEphemeral: phone.ephemeral, remoteHello: mh,
                                                     transcript: transcript)
        let macKeys = try RemoteKeySchedule.derive(role: .responder, localStatic: mac.staticKey,
                                                   localEphemeral: mac.ephemeral, remoteHello: ph,
                                                   transcript: transcript)
        return (phoneKeys, macKeys)
    }

    func test_both_sides_derive_matching_keys_and_code() throws {
        let (phone, mac) = try handshake(Side(), Side())
        XCTAssertEqual(phone.verificationCode, mac.verificationCode)
        XCTAssertEqual(phone.verificationCode.count, 6)

        var phoneSend = RemoteCipher(key: phone.send)
        var macReceive = RemoteCipher(key: mac.receive)
        var macSend = RemoteCipher(key: mac.send)
        var phoneReceive = RemoteCipher(key: phone.receive)
        for i in 0..<5 {
            let up = Data("key \(i)".utf8)
            XCTAssertEqual(try macReceive.open(try phoneSend.seal(up)), up)
            let down = Data(repeating: UInt8(i), count: 40_000)
            XCTAssertEqual(try phoneReceive.open(try macSend.seal(down)), down)
        }
        // 两个方向的密钥不同：拿发送密钥解不开对方发来的帧。
        var wrongDirection = RemoteCipher(key: phone.send)
        var other = RemoteCipher(key: mac.send)
        XCTAssertThrowsError(try wrongDirection.open(try other.seal(Data("x".utf8))))
    }

    /// 冒用别人的长期公钥（手里没有对应私钥）：算出的会话密钥对不上，第一帧就解不开。
    func test_impersonating_a_static_key_without_its_private_key_fails() throws {
        let victim = Side()
        let attacker = Side()
        let mac = Side()
        let forged = attacker.hello(advertising: victim.staticKey.publicKey.rawRepresentation)
        let (attackerKeys, macKeys) = try handshake(attacker, mac, phoneHello: forged)
        var send = RemoteCipher(key: attackerKeys.send)
        var receive = RemoteCipher(key: macKeys.receive)
        XCTAssertThrowsError(try receive.open(try send.seal(Data("ls\n".utf8))))
    }

    /// 中间人分别与两端握手：两端屏幕上的核对码不同，用户一核对就能识破。
    func test_man_in_the_middle_yields_different_codes() throws {
        let (phoneSideKeys, _) = try handshake(Side(), Side())
        let (_, macSideKeys) = try handshake(Side(), Side())
        XCTAssertNotEqual(phoneSideKeys.verificationCode, macSideKeys.verificationCode)
    }

    func test_replayed_reordered_or_tampered_frames_fail() throws {
        let (phone, mac) = try handshake(Side(), Side())
        var send = RemoteCipher(key: phone.send)
        let first = try send.seal(Data("one".utf8))
        let second = try send.seal(Data("two".utf8))

        var reorder = RemoteCipher(key: mac.receive)
        XCTAssertThrowsError(try reorder.open(second), "乱序")

        var replay = RemoteCipher(key: mac.receive)
        XCTAssertNoThrow(try replay.open(first))
        XCTAssertThrowsError(try replay.open(first), "重放")

        var tamper = RemoteCipher(key: mac.receive)
        var flipped = first
        flipped[flipped.startIndex] ^= 0x01
        XCTAssertThrowsError(try tamper.open(flipped), "篡改")
    }

    func test_rejects_low_order_public_key() {
        let mac = Side()
        let bad = RemoteHello(version: 1, deviceID: UUID(), deviceName: "x",
                              ephemeralKey: Data(repeating: 0, count: 32), staticKey: Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try RemoteKeySchedule.derive(role: .responder, localStatic: mac.staticKey,
                                                          localEphemeral: mac.ephemeral, remoteHello: bad,
                                                          transcript: Data()))
    }

    func test_identity_store_persists_key_and_peers() throws {
        let storage = RemoteMemoryStorage()
        let store = RemoteIdentityStore(storage: storage)
        let key = try store.localIdentity()
        XCTAssertEqual(try RemoteIdentityStore(storage: storage).localIdentity().rawRepresentation,
                       key.rawRepresentation)

        let peer = RemotePeer(id: UUID(), name: "iPhone", publicKey: Data(repeating: 1, count: 32), pairedAt: Date())
        try store.trust(peer)
        try store.trust(RemotePeer(id: peer.id, name: "iPhone 改名", publicKey: peer.publicKey, pairedAt: peer.pairedAt))
        XCTAssertEqual(store.trustedPeers().count, 1)
        XCTAssertEqual(store.peer(id: peer.id)?.name, "iPhone 改名")
        try store.revoke(id: peer.id)
        XCTAssertNil(RemoteIdentityStore(storage: storage).peer(id: peer.id))
    }
}
