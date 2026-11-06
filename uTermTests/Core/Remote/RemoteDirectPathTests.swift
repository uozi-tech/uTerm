import CryptoKit
import XCTest
@testable import uTerm

/// 选路：连接请求的门禁、直连密钥、路径确认，以及真实 libjuice 上的一次完整直连。
final class RemoteDirectPathTests: XCTestCase {

    private struct Device {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let id = UUID()
        var peer: RemotePeer { RemotePeer(id: id, name: "设备", publicKey: key.publicKey.rawRepresentation, pairedAt: Date()) }
    }

    private let sampleDescription = "a=ice-ufrag:abcd\r\na=ice-pwd:efgh\r\na=candidate:1 1 UDP 2122317823 192.168.1.2 49160 typ host\r\n"

    private func responder(mac: Device, phone: Device, allowed: Bool) -> RemoteSignalResponder {
        let known = phone.peer
        return RemoteSignalResponder(localKey: mac.key, localID: mac.id,
                                     recognize: { $0 == known.id ? known : nil }, isAllowed: { _ in allowed })
    }

    private func offer(from phone: Device, to mac: Device, ice: String?, at now: TimeInterval) throws -> (box: String, nonce: Data) {
        let shared = try RemoteSignalBox.sharedKey(local: phone.key, remotePublicKey: mac.peer.publicKey)
        let body = RemoteSignalBody(kind: .offer, deviceID: phone.id, sentAt: now, nonce: RemoteSignalBody.newNonce(), ice: ice)
        return (try RemoteSignalBox.seal(body, key: shared, session: "s", direction: .phoneToMac), body.nonce)
    }

    private func open(_ box: String, phone: Device, mac: Device) throws -> RemoteSignalBody {
        let shared = try RemoteSignalBox.sharedKey(local: phone.key, remotePublicKey: mac.peer.publicKey)
        return try RemoteSignalBox.open(box, key: shared, session: "s", direction: .macToPhone)
    }

    // MARK: - 门禁

    func test_offer_with_addresses_asks_for_a_direct_attempt() throws {
        let mac = Device(), phone = Device()
        var gate = responder(mac: mac, phone: phone, allowed: true)
        let sent = try offer(from: phone, to: mac, ice: sampleDescription, at: 100)
        guard case .direct(let direct) = gate.receiveOffer(session: "s", from: phone.id.uuidString, box: sent.box, now: 100,
                                                           acceptsDirect: true) else {
            return XCTFail("应该试直连")
        }
        XCTAssertEqual(direct.remoteDescription, sampleDescription)
        let reply = try open(try XCTUnwrap(direct.sealedReply(ice: "mac-addresses", session: "s")), phone: phone, mac: mac)
        XCTAssertEqual(reply.kind, .answer)
        XCTAssertEqual(reply.ice, "mac-addresses")
        XCTAssertNotNil(gate.claim(session: "s", now: 100), "打不通时手机要能走中继")
    }

    /// 旧版本的手机不带地址，走原来的路。
    func test_offer_without_addresses_gets_a_relay_answer() throws {
        let mac = Device(), phone = Device()
        var gate = responder(mac: mac, phone: phone, allowed: true)
        let sent = try offer(from: phone, to: mac, ice: nil, at: 100)
        guard case .reply(let box) = gate.receiveOffer(session: "s", from: phone.id.uuidString, box: sent.box, now: 100,
                                                       acceptsDirect: true) else {
            return XCTFail("应该直接回复")
        }
        let reply = try open(box, phone: phone, mac: mac)
        XCTAssertEqual(reply.kind, .answer)
        XCTAssertNil(reply.ice)
    }

    func test_at_capacity_answers_without_addresses() throws {
        let mac = Device(), phone = Device()
        var gate = responder(mac: mac, phone: phone, allowed: true)
        let sent = try offer(from: phone, to: mac, ice: sampleDescription, at: 100)
        guard case .reply(let box) = gate.receiveOffer(session: "s", from: phone.id.uuidString, box: sent.box, now: 100,
                                                       acceptsDirect: false) else {
            return XCTFail("打洞尝试满了也不能拒绝连接")
        }
        XCTAssertNil(try open(box, phone: phone, mac: mac).ice)
    }

    /// Mac 的公网地址只给勾选过的设备。
    func test_unticked_device_gets_no_addresses() throws {
        let mac = Device(), phone = Device()
        var gate = responder(mac: mac, phone: phone, allowed: false)
        let sent = try offer(from: phone, to: mac, ice: sampleDescription, at: 100)
        guard case .reply(let box) = gate.receiveOffer(session: "s", from: phone.id.uuidString, box: sent.box, now: 100,
                                                       acceptsDirect: true) else {
            return XCTFail("应该拒绝")
        }
        let reply = try open(box, phone: phone, mac: mac)
        XCTAssertEqual(reply.kind, .denied)
        XCTAssertNil(reply.ice)
    }

    func test_replay_and_strangers_get_nothing() throws {
        let mac = Device(), phone = Device(), stranger = Device()
        var gate = responder(mac: mac, phone: phone, allowed: true)
        let sent = try offer(from: phone, to: mac, ice: sampleDescription, at: 100)
        func isIgnored(_ decision: RemoteSignalResponder.OfferDecision) -> Bool {
            if case .ignore = decision { return true }
            return false
        }
        XCTAssertFalse(isIgnored(gate.receiveOffer(session: "s", from: phone.id.uuidString, box: sent.box, now: 100, acceptsDirect: true)))
        XCTAssertTrue(isIgnored(gate.receiveOffer(session: "s", from: phone.id.uuidString, box: sent.box, now: 101, acceptsDirect: true)), "重放")
        let forged = try offer(from: stranger, to: mac, ice: sampleDescription, at: 100)
        XCTAssertTrue(isIgnored(gate.receiveOffer(session: "s", from: stranger.id.uuidString, box: forged.box, now: 100, acceptsDirect: true)))
    }

    func test_body_without_ice_from_an_old_peer_still_decodes() throws {
        let json = #"{"kind":"answer","deviceID":"\#(UUID().uuidString)","sentAt":1,"nonce":"AAAA"}"#
        XCTAssertNil(try JSONDecoder().decode(RemoteSignalBody.self, from: Data(json.utf8)).ice)
    }

    // MARK: - 密钥

    func test_direct_keys_mirror_between_the_two_ends() {
        let shared = SymmetricKey(size: .bits256)
        let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)
        let phone = RemoteSignalBox.directKeys(sharedKey: shared, phoneNonce: a, macNonce: b, session: "s", role: .initiator)
        let mac = RemoteSignalBox.directKeys(sharedKey: shared, phoneNonce: a, macNonce: b, session: "s", role: .responder)
        func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
        XCTAssertEqual(bytes(phone.datagram.send), bytes(mac.datagram.receive))
        XCTAssertEqual(bytes(phone.datagram.receive), bytes(mac.datagram.send))
        XCTAssertEqual(bytes(phone.check.send), bytes(mac.check.receive))
        let distinct = Set([phone.datagram.send, phone.datagram.receive, phone.check.send, phone.check.receive].map(bytes))
        XCTAssertEqual(distinct.count, 4, "确认包和传输层的序号各算各的，密钥不能相同")
        let other = RemoteSignalBox.directKeys(sharedKey: shared, phoneNonce: a, macNonce: b, session: "t", role: .initiator)
        XCTAssertNotEqual(bytes(phone.datagram.send), bytes(other.datagram.send), "每个会话一把")
    }

    // MARK: - 真实 libjuice

    /// 两个 attempt 在本机打通。没有非回环网卡的机器跑不了。
    private func connectedPair() async throws -> (phone: RemoteDirectAttempt, mac: RemoteDirectAttempt) {
        let phone = try XCTUnwrap(RemoteDirectAttempt(stunHost: nil, stunPort: 0))
        let mac = try XCTUnwrap(RemoteDirectAttempt(stunHost: nil, stunPort: 0))
        XCTAssertTrue(phone.gather())
        await phone.waitForGathering(limit: .seconds(3))
        let offered = try XCTUnwrap(phone.localDescription())
        guard !RemoteICECandidateKind.all(inDescription: offered).isEmpty else {
            throw XCTSkip("这台机器没有非回环网卡，没有候选地址可打")
        }
        XCTAssertTrue(mac.setRemote(offered))
        XCTAssertTrue(mac.gather())
        await mac.waitForGathering(limit: .seconds(3))
        XCTAssertTrue(phone.setRemote(try XCTUnwrap(mac.localDescription())))
        let connected = await phone.waitForConnection(limit: .seconds(10))
        XCTAssertTrue(connected)
        return (phone, mac)
    }

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func add(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
        var all: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    private nonisolated static func pump(_ transport: RemoteP2PTransport, into inbox: Inbox) {
        transport.receive(maximumLength: 256 * 1024) { data, done, error in
            if let data { inbox.add(data) }
            if !done, error == nil { pump(transport, into: inbox) }
        }
    }

    private func keyPairs() -> (phone: RemoteDirectKeys, mac: RemoteDirectKeys) {
        let shared = SymmetricKey(size: .bits256)
        let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)
        return (RemoteSignalBox.directKeys(sharedKey: shared, phoneNonce: a, macNonce: b, session: "s", role: .initiator),
                RemoteSignalBox.directKeys(sharedKey: shared, phoneNonce: a, macNonce: b, session: "s", role: .responder))
    }

    func test_real_ice_verifies_the_path_and_carries_bytes() async throws {
        let (phone, mac) = try await connectedPair()
        let keys = keyPairs()
        async let hostChecked = mac.waitForCheck(keys: keys.mac.check, limit: .seconds(5))
        let verified = await phone.verify(keys: keys.phone.check, limit: .seconds(5))
        let checked = await hostChecked
        XCTAssertTrue(verified)
        XCTAssertTrue(checked)

        let phoneTransport = try XCTUnwrap(phone.makeTransport(keys: keys.phone.datagram))
        let macTransport = try XCTUnwrap(mac.makeTransport(keys: keys.mac.datagram))
        XCTAssertNil(mac.makeTransport(keys: keys.mac.datagram), "只能交出去一次")
        defer {
            phoneTransport.cancel()
            macTransport.cancel()
        }
        let queue = DispatchQueue(label: "test.direct")
        phoneTransport.start(queue: queue) { _ in }
        macTransport.start(queue: queue) { _ in }
        let inbox = Inbox()
        Self.pump(macTransport, into: inbox)
        let data = Data((0..<500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        phoneTransport.send(data) { _ in }
        let deadline = Date().addingTimeInterval(10)
        while inbox.all.count < data.count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(inbox.all, data)
    }

    /// 没有正确密钥的一方（别人打进这个端口，或者信令被调包）过不了确认。
    func test_wrong_keys_do_not_verify() async throws {
        let (phone, mac) = try await connectedPair()
        defer {
            phone.close()
            mac.close()
        }
        let hostKeys = keyPairs().mac.check, phoneKeys = keyPairs().phone.check
        async let hostChecked = mac.waitForCheck(keys: hostKeys, limit: .milliseconds(800))
        let verified = await phone.verify(keys: phoneKeys, limit: .milliseconds(800))
        let checked = await hostChecked
        XCTAssertFalse(verified)
        XCTAssertFalse(checked, "Mac 不能因为收到垃圾就把连接交给业务")
    }

    func test_connection_gives_up_quickly_on_unreachable_candidates() async throws {
        let phone = try XCTUnwrap(RemoteDirectAttempt(stunHost: nil, stunPort: 0))
        defer { phone.close() }
        XCTAssertTrue(phone.gather())
        await phone.waitForGathering(limit: .seconds(3))
        XCTAssertTrue(phone.setRemote(sampleDescription.replacingOccurrences(of: "192.168.1.2", with: "198.51.100.7")))
        let started = Date()
        let connected = await phone.waitForConnection(limit: .milliseconds(400))
        XCTAssertFalse(connected)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        let verified = await phone.verify(keys: keyPairs().phone.check, limit: .milliseconds(200))
        XCTAssertFalse(verified)
    }
}
