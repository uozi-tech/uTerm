import CryptoKit
import Foundation
@preconcurrency import Network
import XCTest
@testable import uTerm

/// 快通道的局域网线路：真的 `NWListener` + `NWConnection` 走回环（端点直接给，不经 Bonjour）。握手成功后收发；
/// 名册里没有的、公钥对不上的、没有私钥的、抄本被改的、重放旧帧的、超长帧的都连不上或被断开，也塞不进记录。
@MainActor
final class RemoteGroupLANLinkTests: XCTestCase {
    /// 一台设备：自己的「钥匙串」（放好名册里的 `device`）、叠加层、快通道（只监听、不广播不浏览）。
    private final class Side {
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let device: RemoteGroupDevice
        let keychain = LaggingKeychain()
        let overlay: RemoteGroupOverlayStorage
        let channel: RemoteGroupFastChannel

        init(_ name: String) {
            device = FastSyncFixtures.device(name, identity: identity)
            overlay = RemoteGroupOverlayStorage(base: keychain)
            channel = RemoteGroupFastChannel(local: device, identityKey: identity, overlay: overlay,
                                             advertises: false, browses: false) { _ in }
        }

        var joins: [RemoteGroupJoin] { RemoteGroupRoster(storage: overlay).load().joins }
    }

    private func side(_ name: String) -> Side {
        let side = Side(name)
        let channel = side.channel
        addTeardownBlock { channel.stop() }
        side.channel.start()
        return side
    }

    private func port(of side: Side) -> UInt16 {
        awaitFast("监听好") { side.channel.lan.port != nil }
        return side.channel.lan.port ?? 0
    }

    private func endpoint(_ side: Side) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port(of: side))!)
    }

    private var t0: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    // MARK: - 正常

    func test_two_listed_devices_connect_and_sync_records_over_loopback() throws {
        let mac = side("Mac"), phone = side("iPhone")
        for side in [mac, phone] {
            try side.keychain.put(.device(mac.device))
            try side.keychain.put(.device(phone.device))
        }
        phone.channel.lan.connect(to: endpoint(mac), peer: mac.device.id)
        awaitFast("握手成功") {
            mac.channel.sync.connectedPeers == [phone.device.id] && phone.channel.sync.connectedPeers == [mac.device.id]
        }
        let join = FastSyncFixtures.join(phone.device, at: t0)
        try phone.overlay.save(join.encoded(), account: join.account)
        awaitFast("经局域网送到") { !mac.joins.isEmpty }
        let fromMac = FastSyncFixtures.join(mac.device, at: t0)
        try mac.overlay.save(fromMac.encoded(), account: fromMac.account)
        awaitFast("反方向") { phone.joins.contains { $0.device.id == mac.device.id } }
        XCTAssertFalse(mac.keychain.loadAll().compactMap(RemoteGroupRecord.decode).contains { $0.account == join.account },
                       "收到的只进叠加层，不写钥匙串")
    }

    func test_a_device_listed_later_can_connect_on_retry() throws {
        let mac = side("Mac"), phone = side("iPhone")
        try phone.keychain.put(.device(mac.device))
        try mac.keychain.put(.device(mac.device))
        phone.channel.lan.connect(to: endpoint(mac), peer: mac.device.id)
        idleFast(0.5)
        XCTAssertTrue(mac.channel.sync.connectedPeers.isEmpty, "Mac 的钥匙串里还没有 iPhone 的 device")
        try mac.keychain.put(.device(phone.device))
        phone.channel.lan.connect(to: endpoint(mac), peer: mac.device.id)
        awaitFast("记录到了就连得上") { mac.channel.sync.connectedPeers == [phone.device.id] }
    }

    func test_the_initiator_refuses_a_responder_that_is_not_the_expected_device() throws {
        let mac = side("Mac"), phone = side("iPhone")
        let other = FastSyncFixtures.device("别的")
        for side in [mac, phone] {
            try side.keychain.put(.device(mac.device))
            try side.keychain.put(.device(phone.device))
            try side.keychain.put(.device(other))
        }
        phone.channel.lan.connect(to: endpoint(mac), peer: other.id)
        idleFast(0.5)
        XCTAssertTrue(phone.channel.sync.connectedPeers.isEmpty)
        XCTAssertTrue(mac.channel.sync.connectedPeers.isEmpty)
    }

    // MARK: - 对抗

    /// 名册里没有它（叠加层收到过它的 `device` 也不算）：hello 之后就断开，塞的 join 进不了名册。
    func test_a_device_missing_from_the_keychain_roster_is_refused_even_if_the_overlay_has_its_entry() async throws {
        let mac = side("Mac")
        try mac.keychain.put(.device(mac.device))
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let stranger = FastSyncFixtures.device("Stranger", identity: identity)
        mac.overlay.ingest(records: [try RemoteGroupRecord.device(stranger).encoded()], tombstones: [], from: nil)
        XCTAssertTrue(RemoteGroupRoster(storage: mac.overlay).load().devices.contains { $0.id == stranger.id })

        let client = try await RawLANClient.connect(port: port(of: mac))
        client.send(try RemoteGroupLANHandshake.hello(stranger, nonce: RemoteGroupLANHandshake.newNonce()))
        client.send(try RemoteGroupSyncMessage.records([FastSyncFixtures.data(FastSyncFixtures.join(stranger, at: t0))]).encoded())
        let reply = await client.read()
        XCTAssertEqual(reply, .closed, "不回 hello，直接断开")
        XCTAssertTrue(mac.joins.isEmpty)
        XCTAssertTrue(mac.channel.sync.connectedPeers.isEmpty)
    }

    func test_a_hello_whose_key_differs_from_the_roster_entry_is_refused() async throws {
        let mac = side("Mac")
        let phone = FastSyncFixtures.device("iPhone")
        try mac.keychain.put(.device(mac.device))
        try mac.keychain.put(.device(phone))
        var forged = phone
        forged.publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let client = try await RawLANClient.connect(port: port(of: mac))
        client.send(try RemoteGroupLANHandshake.hello(forged, nonce: RemoteGroupLANHandshake.newNonce()))
        let reply = await client.read()
        XCTAssertEqual(reply, .closed)
    }

    /// 报了名册里那台的 ID 和公钥，可是没有它的私钥：证明帧对不上，断开；之后的业务帧解不开，进不了名册。
    func test_claiming_a_listed_key_without_its_private_key_fails_the_proof() async throws {
        let mac = side("Mac")
        let phone = FastSyncFixtures.device("iPhone")
        try mac.keychain.put(.device(mac.device))
        try mac.keychain.put(.device(phone))
        let client = try await RawLANClient.connect(port: port(of: mac))
        var session = try await client.handshake(as: phone, identity: Curve25519.KeyAgreement.PrivateKey(), expecting: mac.device)
        let reply = await client.read()
        XCTAssertEqual(reply, .closed, "接受方不回证明帧")
        client.send(try session.seal(.data, try RemoteGroupSyncMessage.records([FastSyncFixtures.data(FastSyncFixtures.join(phone, at: t0))]).encoded()))
        idleFast()
        XCTAssertTrue(mac.joins.isEmpty)
    }

    func test_a_tampered_transcript_fails_the_proof() async throws {
        let mac = side("Mac")
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let phone = FastSyncFixtures.device("iPhone", identity: identity)
        try mac.keychain.put(.device(mac.device))
        try mac.keychain.put(.device(phone))
        let client = try await RawLANClient.connect(port: port(of: mac))
        _ = try await client.handshake(as: phone, identity: identity, expecting: mac.device, tamper: true)
        let reply = await client.read()
        XCTAssertEqual(reply, .closed)
        XCTAssertTrue(mac.channel.sync.connectedPeers.isEmpty)
    }

    func test_replayed_frames_are_refused_within_and_across_sessions() async throws {
        let mac = side("Mac")
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let phone = FastSyncFixtures.device("iPhone", identity: identity)
        try mac.keychain.put(.device(mac.device))
        try mac.keychain.put(.device(phone))

        // 第一次：正常握手，发一条带 join 的 records，Mac 收下。
        let first = try await RawLANClient.connect(port: port(of: mac))
        var session = try await first.handshake(as: phone, identity: identity, expecting: mac.device)
        let proof = try XCTUnwrap(first.sentPayloads.last)
        guard case .frame(let macProof) = await first.read() else { return XCTFail("应当收到接受方的证明帧") }
        _ = try session.open(macProof)
        let join = FastSyncFixtures.join(phone, at: t0)
        let frame = try session.seal(.data, try RemoteGroupSyncMessage.records([FastSyncFixtures.data(join)]).encoded())
        first.send(frame)
        awaitFast("认证过的对端发的照收") { !mac.joins.isEmpty }
        // 同一帧再发一次：序号对不上，解不开，断开。
        first.send(frame)
        let afterReplay = await first.readSkippingFrames()
        XCTAssertEqual(afterReplay, .closed)

        // 第二次：hello 交换之后把上一次的证明帧原样发过去：随机数换了，密钥不同。
        let second = try await RawLANClient.connect(port: port(of: mac))
        second.send(try RemoteGroupLANHandshake.hello(phone, nonce: RemoteGroupLANHandshake.newNonce()))
        guard case .frame = await second.read() else { return XCTFail("应当收到 hello") }
        second.send(proof)
        let afterOldProof = await second.read()
        XCTAssertEqual(afterOldProof, .closed)
    }

    func test_oversized_frames_are_refused_before_and_after_the_handshake() async throws {
        let mac = side("Mac")
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let phone = FastSyncFixtures.device("iPhone", identity: identity)
        try mac.keychain.put(.device(mac.device))
        try mac.keychain.put(.device(phone))

        let early = try await RawLANClient.connect(port: port(of: mac))
        early.send(Data(repeating: 0x7B, count: RemoteGroupLANHandshake.maxHandshakeFrame + 1))
        let earlyReply = await early.read()
        XCTAssertEqual(earlyReply, .closed, "握手之前一帧最多 4 KiB")

        let late = try await RawLANClient.connect(port: port(of: mac))
        _ = try await late.handshake(as: phone, identity: identity, expecting: mac.device)
        guard case .frame = await late.read() else { return XCTFail("应当收到接受方的证明帧") }
        var length = UInt32(RemoteGroupLANHandshake.maxFrame + 1).bigEndian
        late.sendRaw(Data(bytes: &length, count: 4) + Data(count: 1024))
        let lateReply = await late.readSkippingFrames()
        XCTAssertEqual(lateReply, .closed, "握手之后一帧最多 256 KiB")
        XCTAssertTrue(mac.joins.isEmpty)
    }

    func test_cipher_rejects_reordered_and_tampered_frames() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = RemoteGroupLANCipher(key: key), receiver = RemoteGroupLANCipher(key: key)
        let first = try sender.seal(Data("one".utf8)), second = try sender.seal(Data("two".utf8))
        XCTAssertThrowsError(try receiver.open(second), "乱序")
        XCTAssertEqual(try receiver.open(first), Data("one".utf8))
        var tampered = second
        tampered[0] ^= 1
        XCTAssertThrowsError(try receiver.open(tampered))
        XCTAssertEqual(try receiver.open(second), Data("two".utf8))
        XCTAssertThrowsError(try receiver.open(second), "重放")
    }

    func test_low_order_peer_keys_are_refused() throws {
        let hello = RemoteGroupLANHandshake.Hello(v: 1, id: UUID(), key: Data(count: 32), nonce: Data(count: 32))
        XCTAssertThrowsError(try RemoteGroupLANHandshake.keys(identityKey: .init(), peerKey: Data(count: 32), initiator: hello,
                                                              responder: hello, transcript: Data(), isInitiator: true))
    }
}

// MARK: - 测试用的「坏对端」

/// 直接说线上协议的客户端：照 `RemoteGroupLANHandshake` 做握手，想改哪一步改哪一步。
private final class RawLANClient: @unchecked Sendable {
    enum Read: Equatable {
        case frame(Data)
        case closed
        case timeout
    }

    struct Session {
        var send: RemoteGroupLANCipher
        var receive: RemoteGroupLANCipher

        mutating func seal(_ type: RemoteGroupLANHandshake.FrameType, _ body: Data) throws -> Data {
            try send.seal(Data([type.rawValue]) + body)
        }

        @discardableResult
        mutating func open(_ frame: Data) throws -> Data {
            try receive.open(frame)
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.raw-lan-client")
    private let lock = NSLock()
    private var reader = RemoteGroupLANFrameReader()
    private var isClosed = false
    private(set) var sentPayloads: [Data] = []

    private init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    static func connect(port: UInt16) async throws -> RawLANClient {
        let client = RawLANClient(port: port)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            client.connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error), .waiting(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            client.connection.start(queue: client.queue)
        }
        return client
    }

    func send(_ payload: Data) {
        lock.withLock { sentPayloads.append(payload) }
        sendRaw(RemoteGroupLANHandshake.frame(payload))
    }

    func sendRaw(_ bytes: Data) {
        connection.send(content: bytes, completion: .contentProcessed { _ in })
    }

    /// 下一帧；对端断开返回 `.closed`。
    func read(timeout: TimeInterval = 3) async -> Read {
        if let frame = lock.withLock({ try? reader.next(limit: 1 << 20) }) { return .frame(frame) }
        if lock.withLock({ isClosed }) { return .closed }
        let chunk: Read = await withCheckedContinuation { continuation in
            let once = Once()
            queue.asyncAfter(deadline: .now() + timeout) { once.run { continuation.resume(returning: .timeout) } }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty { self.lock.withLock { self.reader.append(data) } }
                if error != nil || isComplete {
                    self.lock.withLock { self.isClosed = true }
                }
                once.run { continuation.resume(returning: .frame(Data())) }
            }
        }
        if chunk == .timeout { return .timeout }
        return await read(timeout: timeout)
    }

    /// 读到断开为止（中间的探活帧、业务帧都跳过）。
    func readSkippingFrames(timeout: TimeInterval = 3) async -> Read {
        while true {
            let next = await read(timeout: timeout)
            if case .frame = next { continue }
            return next
        }
    }

    /// 当发起方握手：发 hello、收 hello、算密钥、发证明帧。`identity` 不是 `device` 那把公钥的私钥时，证明帧对方解不开；
    /// `tamper` 把抄本改一个字节再算。返回会话（还没读接受方的证明帧）。
    func handshake(as device: RemoteGroupDevice, identity: Curve25519.KeyAgreement.PrivateKey,
                   expecting peer: RemoteGroupDevice, tamper: Bool = false) async throws -> Session {
        let mine = try RemoteGroupLANHandshake.hello(device, nonce: RemoteGroupLANHandshake.newNonce())
        send(mine)
        guard case .frame(let theirs) = await read() else { throw RemoteGroupLANError.closed }
        let localHello = try XCTUnwrap(RemoteGroupLANHandshake.parseHello(mine))
        let remoteHello = try XCTUnwrap(RemoteGroupLANHandshake.parseHello(theirs))
        XCTAssertEqual(remoteHello.id, peer.id)
        var transcript = mine + theirs
        if tamper { transcript[transcript.count - 3] ^= 1 }
        let keys = try RemoteGroupLANHandshake.keys(identityKey: identity, peerKey: remoteHello.key, initiator: localHello,
                                                    responder: remoteHello, transcript: transcript, isInitiator: true)
        var session = Session(send: RemoteGroupLANCipher(key: keys.send), receive: RemoteGroupLANCipher(key: keys.receive))
        send(try session.seal(.proof, keys.proof))
        return session
    }
}

/// 只跑一次（续体只能 resume 一次）。
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
