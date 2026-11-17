import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 中继信箱的一条线路（§7.4「中继信箱」，落地见 §17）：信箱 ID、`box` 编解码、握手与密封、分片与重组，
/// 以及重放、乱序、被改、session / 方向被换、名册外、公钥不对都不通。两条 `RemoteGroupRelaySession` 之间用一根
/// 内存管子连（不经中继），管子可以截下、重放、改帧。
@MainActor
final class RemoteGroupRelayLinkTests: XCTestCase {
    /// 一台设备的身份。
    private struct Party {
        let identity: Curve25519.KeyAgreement.PrivateKey
        let device: RemoteGroupDevice

        init(_ name: String, identity: Curve25519.KeyAgreement.PrivateKey = .init(), id: UUID = UUID()) {
            self.identity = identity
            device = FastSyncFixtures.device(name, id: id, identity: identity)
        }
    }

    /// 截帧时要记住的东西（改写闭包在管子的队列上跑，不能抓测试里的 var）。
    private final class Held: @unchecked Sendable {
        var box: Data?
    }

    /// 一根管子：C 拨 M 的信箱。M 收到 hello 才用 `accept` 建；`rewriteToMailbox` / `rewriteToClient` 可以改写要送的帧。
    /// 所有状态都在 `queue` 上（测试用 `read` 读写）。
    private final class Pipe: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.relay-pipe")
        let session: String
        let clientParty: Party
        let mailboxParty: Party
        /// C 在 hello 里报的身份（默认就是它自己；冒充者报别人的）。
        let announced: RemoteGroupDevice
        var mailboxTrusts: [RemoteGroupDevice]
        private(set) var client: RemoteGroupRelaySession!
        var mailbox: RemoteGroupRelaySession?
        /// 两个方向上经过的 `box`（原样）。
        var sentToMailbox: [Data] = []
        var sentToClient: [Data] = []
        /// 改写：返回 nil 表示照送；返回数组就送这几帧（空数组 = 丢掉）。
        var rewriteToMailbox: (@Sendable (Data, Int) -> [Data]?)?
        var rewriteToClient: (@Sendable (Data, Int) -> [Data]?)?
        var events: [String] = []
        var clientFrames: [Data] = []
        var mailboxFrames: [Data] = []
        var clientEnded: Error?
        var mailboxEnded: Error?
        var mailboxRefused = false
        /// C 握好手之后先不 activate，等 `releaseClient()`。
        private let holdsClient: Bool
        private var heldClient: RemoteGroupRelaySession?

        init(client: Party, mailbox: Party, dialing target: RemoteGroupDevice? = nil, announcing: RemoteGroupDevice? = nil,
             session: String = "s-1", timing: RemoteGroupRelaySession.Timing = .standard, holdsClient: Bool = false) {
            self.session = session
            clientParty = client
            mailboxParty = mailbox
            announced = announcing ?? client.device
            mailboxTrusts = [client.device]
            self.holdsClient = holdsClient
            self.client = RemoteGroupRelaySession(
                dialing: target ?? mailbox.device, session: session, local: announced, identityKey: client.identity,
                queue: queue, timing: timing, emit: { [unowned self] box in self.carryToMailbox(box) })
        }

        func start() {
            queue.sync {
                client.start(onEstablished: { [unowned self] link in
                    events.append("client established")
                    if holdsClient { heldClient = link } else { activateClient(link) }
                }, onEnded: { [unowned self] _, _, error in clientEnded = error })
            }
        }

        func releaseClient() {
            queue.async { [self] in
                guard let link = heldClient else { return }
                heldClient = nil
                activateClient(link)
            }
        }

        private func activateClient(_ link: RemoteGroupRelaySession) {
            link.activate(onFrame: { [unowned self] frame in queue.async { self.clientFrames.append(frame) } },
                          onClose: { [unowned self] in queue.async { self.events.append("client closed") } })
        }

        private func carryToMailbox(_ box: Data) {
            let index = sentToMailbox.count
            sentToMailbox.append(box)
            let frames = rewriteToMailbox?(box, index) ?? [box]
            for frame in frames { queue.async { self.deliverToMailbox(frame) } }
        }

        private func carryToClient(_ box: Data) {
            let index = sentToClient.count
            sentToClient.append(box)
            let frames = rewriteToClient?(box, index) ?? [box]
            for frame in frames { queue.async { self.deliverToClient(frame) } }
        }

        func deliverToClient(_ frame: Data) {
            guard let decoded = RemoteGroupRelayBox.decode(frame) else { return }
            client.receive(decoded)
        }

        /// 信箱收到一帧（在 queue 上调；测试也用它直接塞帧）。
        func deliverToMailbox(_ frame: Data) {
            guard let decoded = RemoteGroupRelayBox.decode(frame) else { return }
            if case .hello(let hello) = decoded {
                mailbox?.end(RemoteGroupRelayLinkError.replaced)
                mailbox = nil
                guard let link = RemoteGroupRelaySession.accept(
                    hello, from: announced.id, session: session, local: mailboxParty.device,
                    identityKey: mailboxParty.identity, trusted: mailboxTrusts, queue: queue,
                    emit: { [unowned self] box in self.carryToClient(box) }) else {
                    mailboxRefused = true
                    return
                }
                mailbox = link
                link.start(onEstablished: { [unowned self] link in
                    events.append("mailbox established")
                    link.activate(onFrame: { [unowned self] frame in queue.async { self.mailboxFrames.append(frame) } },
                                  onClose: { [unowned self] in queue.async { self.events.append("mailbox closed") } })
                }, onEnded: { [unowned self] _, _, error in mailboxEnded = error })
                return
            }
            guard let mailbox, decoded.linkID == mailbox.linkID else { return }
            mailbox.receive(decoded)
        }

        func read<T>(_ body: (Pipe) -> T) -> T { queue.sync { body(self) } }
    }

    private func established(_ pipe: Pipe) {
        awaitFast("两头握好手") { pipe.read { $0.events.contains("client established") && $0.events.contains("mailbox established") } }
    }

    private func sealedCount(_ boxes: [Data]) -> Int {
        boxes.filter { if case .sealed = RemoteGroupRelayBox.decode($0) { return true } else { return false } }.count
    }

    // MARK: - 信箱 ID 与钥匙

    func test_mailbox_id_is_stable_differs_from_the_device_id_and_does_not_collide() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(RemoteGroupMailbox.hostID(for: a), RemoteGroupMailbox.hostID(for: a), "同一台算出来一样")
        XCTAssertNotEqual(RemoteGroupMailbox.hostID(for: a), a, "不是设备 ID 本身（被控端拿设备 ID 注册着远控主机）")
        XCTAssertNotEqual(RemoteGroupMailbox.hostID(for: a), RemoteGroupMailbox.hostID(for: b))
        let ids = Set((0..<2000).map { _ in RemoteGroupMailbox.hostID(for: UUID()) })
        XCTAssertEqual(ids.count, 2000)
        // 版本位是 8：和随机的 v4 设备 ID 永远不同。
        let mailbox = RemoteGroupMailbox.hostID(for: a)
        XCTAssertEqual(mailbox.uuid.6 >> 4, 8)
        XCTAssertEqual(mailbox.uuid.8 >> 6, 2)
        XCTAssertEqual(Array(mailbox.uuidString)[14], "8")
        // 固定的向量：两端（Mac、iPhone）必须算出同一个，改了算法就是协议变更。
        let fixed = UUID(uuidString: "00112233-4455-4677-8899-AABBCCDDEEFF")!
        let expected = Array(SHA256.hash(data: Data("uterm-group-mailbox-v1".utf8) + RemoteGroupFormat.uuidBytes(fixed)).prefix(16))
        let got = withUnsafeBytes(of: RemoteGroupMailbox.hostID(for: fixed).uuid) { Array($0) }
        XCTAssertEqual(Array(got[0..<6]), Array(expected[0..<6]))
        XCTAssertEqual(got[6] & 0x0F, expected[6] & 0x0F)
        XCTAssertEqual(Array(got[9...]), Array(expected[9...]))
    }

    func test_mailbox_host_key_is_kept_and_separate_from_the_remote_host_key() throws {
        let storage = RemoteMemoryStorage()
        let first = try RemoteGroupMailbox.hostKey(storage: storage)
        XCTAssertEqual(try RemoteGroupMailbox.hostKey(storage: storage).rawRepresentation, first.rawRepresentation)
        XCTAssertNotNil(try storage.load(RemoteGroupMailbox.hostKeyAccount))
        let remote = try RemoteIdentityStore(role: .controllers, storage: storage).relayHostKey()
        XCTAssertNotEqual(remote.rawRepresentation, first.rawRepresentation, "不复用远控那把")
    }

    // MARK: - box

    func test_box_round_trips_and_rejects_garbage() {
        let link = RemoteGroupRelayBox.random(8), nonce = RemoteGroupRelayBox.random(32)
        let hello = RemoteGroupRelayHello(linkID: link, nonce: nonce, clientKey: Data(repeating: 1, count: 32),
                                          ownerKey: Data(repeating: 2, count: 32))
        let boxes: [RemoteGroupRelayBox] = [.hello(hello), .reply(linkID: link, nonce: nonce),
                                            .sealed(linkID: link, body: Data(repeating: 7, count: 40)), .reset(linkID: link)]
        for box in boxes {
            XCTAssertEqual(RemoteGroupRelayBox.decode(box.encoded()), box)
            XCTAssertNil(RemoteGroupRelayBox.decode(box.encoded() + Data([0])) .flatMap { $0 == box ? $0 : nil }, "多一个字节不是同一个")
        }
        XCTAssertNil(RemoteGroupRelayBox.decode(Data()))
        XCTAssertNil(RemoteGroupRelayBox.decode(Data([9, 1, 2, 3])), "种类不认识")
        var wrongVersion = RemoteGroupRelayBox.hello(hello).encoded()
        wrongVersion[1] = 2
        XCTAssertNil(RemoteGroupRelayBox.decode(wrongVersion), "版本不认识")
        XCTAssertNil(RemoteGroupRelayBox.decode(RemoteGroupRelayBox.hello(hello).encoded().dropLast()), "长度不对")
        XCTAssertNil(RemoteGroupRelayBox.decode(Data([3]) + link + Data(repeating: 0, count: 10)), "密文短于标签")
        XCTAssertNil(RemoteGroupRelayBox.decode(Data([4]) + link + Data([0])), "reset 多字节")
    }

    // MARK: - 握手

    func test_handshake_then_messages_both_ways_including_fragmented_ones() {
        let pipe = Pipe(client: Party("C"), mailbox: Party("M"))
        pipe.start()
        established(pipe)
        let small = Data("你好".utf8)
        let large = Data((0..<(100 * 1024)).map { UInt8($0 % 251) })
        pipe.client.send(small)
        pipe.client.send(large)
        pipe.mailbox?.send(large)
        pipe.mailbox?.send(Data())
        awaitFast("都到了") { pipe.read { $0.mailboxFrames.count == 2 && $0.clientFrames.count == 2 } }
        pipe.read { pipe in
            XCTAssertEqual(pipe.mailboxFrames, [small, large])
            XCTAssertEqual(pipe.clientFrames, [large, Data()])
            XCTAssertEqual(pipe.mailbox?.opener, pipe.clientParty.device.id)
            XCTAssertEqual(pipe.client.opener, pipe.clientParty.device.id)
            XCTAssertEqual(pipe.mailbox?.peer.id, pipe.clientParty.device.id)
            XCTAssertEqual(pipe.client.peer.id, pipe.mailboxParty.device.id)
            XCTAssertEqual(pipe.client.kind, .relay)
            // 每个 box 都塞得进中继的一帧：base64 加 JSON 外壳也不到 64 KiB。
            let biggest = (pipe.sentToMailbox + pipe.sentToClient).map { $0.base64EncodedString().utf8.count }.max() ?? 0
            XCTAssertLessThan(biggest + 300, 64 * 1024)
        }
    }

    func test_one_fragment_or_several_and_sizes_add_up() {
        XCTAssertEqual(RemoteGroupRelayHandshake.fragments(Data()).count, 1)
        let exact = Data(count: RemoteGroupRelayHandshake.fragmentSize)
        XCTAssertEqual(RemoteGroupRelayHandshake.fragments(exact).map(\.more), [false], "恰好一片")
        let three = Data(count: 2 * RemoteGroupRelayHandshake.fragmentSize + 1)
        XCTAssertEqual(RemoteGroupRelayHandshake.fragments(three).map(\.more), [true, true, false])
        XCTAssertEqual(RemoteGroupRelayHandshake.fragments(three).map(\.chunk.count).reduce(0, +), three.count)

        var reassembler = RemoteGroupRelayReassembler(limit: 100)
        XCTAssertEqual(try reassembler.add(Data([1]), more: false), Data([1]))
        XCTAssertNil(try reassembler.add(Data([1, 2]), more: true))
        XCTAssertNil(try reassembler.add(Data([3]), more: true))
        XCTAssertEqual(try reassembler.add(Data([4]), more: false), Data([1, 2, 3, 4]))
        XCTAssertEqual(reassembler.pendingBytes, 0)
        XCTAssertNil(try reassembler.add(Data(count: 60), more: true))
        XCTAssertThrowsError(try reassembler.add(Data(count: 41), more: false), "超长")
        XCTAssertEqual(reassembler.pendingBytes, 0, "超长之后清空")
    }

    func test_a_missing_or_reordered_fragment_ends_the_link_and_nothing_is_delivered() {
        for mode in ["drop", "swap"] {
            let pipe = Pipe(client: Party("C"), mailbox: Party("M"))
            pipe.start()
            established(pipe)
            let base = pipe.read { $0.sentToMailbox.count }
            let held = Held()
            let drops = mode == "drop"
            pipe.read { pipe in
                pipe.rewriteToMailbox = { box, index in
                    // 这条消息的三片是 base、base+1、base+2。
                    guard index == base || index == base + 1 else { return nil }
                    if drops { return index == base + 1 ? [] : nil }
                    if index == base { held.box = box; return [] }
                    return [box, held.box!]
                }
            }
            pipe.client.send(Data(count: 2 * RemoteGroupRelayHandshake.fragmentSize + 10))
            awaitFast("\(mode)：信箱那头断开") { pipe.read { $0.mailboxEnded != nil } }
            pipe.read { XCTAssertTrue($0.mailboxFrames.isEmpty, mode) }
        }
    }

    func test_mailbox_says_nothing_to_devices_outside_the_keychain_roster_or_with_the_wrong_keys() {
        let client = Party("C"), owner = Party("M")
        // 名册里没有它。
        let stranger = Pipe(client: client, mailbox: owner)
        stranger.mailboxTrusts = []
        stranger.start()
        idleFast()
        stranger.read { XCTAssertTrue($0.mailboxRefused); XCTAssertTrue($0.sentToClient.isEmpty, "一个字都不回") }

        // 名册里那条的公钥不是 hello 里那把。
        let wrongKey = Pipe(client: client, mailbox: owner)
        wrongKey.mailboxTrusts = [FastSyncFixtures.device("C", id: client.device.id)]
        wrongKey.start()
        idleFast()
        wrongKey.read { XCTAssertTrue($0.mailboxRefused); XCTAssertTrue($0.sentToClient.isEmpty) }

        // 拨号方拿的是信箱主人的旧公钥（或别人写的假条目）。
        var stale = owner.device
        stale.publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let staleOwner = Pipe(client: client, mailbox: owner, dialing: stale)
        staleOwner.start()
        idleFast()
        staleOwner.read { XCTAssertTrue($0.mailboxRefused); XCTAssertTrue($0.sentToClient.isEmpty) }
    }

    func test_someone_with_a_roster_id_and_public_key_but_not_the_private_key_never_gets_in() {
        let victim = Party("C"), owner = Party("M")
        // 冒充者报 victim 的设备 ID 和公钥，手里却是另一把私钥。
        let pipe = Pipe(client: Party("X"), mailbox: owner, announcing: victim.device)
        pipe.read { $0.mailboxTrusts = [victim.device] }
        pipe.start()
        awaitFast("冒充者算不出 M 的证明，自己先断") { pipe.read { $0.clientEnded != nil } }
        pipe.read { pipe in
            XCTAssertFalse(pipe.events.contains("mailbox established"))
            XCTAssertFalse(pipe.events.contains("client established"))
            XCTAssertNotNil(pipe.mailbox, "信箱照名册回了 reply（它分不出来），但证明帧过不了")
        }
        // 冒充者硬发一帧密文（随便哪把钥匙封的）也进不去。
        pipe.read { pipe in
            let junk = RemoteGroupRelayBox.sealed(linkID: pipe.mailbox!.linkID, body: Data(repeating: 9, count: 40))
            pipe.deliverToMailbox(junk.encoded())
        }
        awaitFast("信箱断开") { pipe.read { $0.mailboxEnded != nil } }
        pipe.read { XCTAssertFalse($0.events.contains("mailbox established")) }
    }

    func test_keys_are_bound_to_session_direction_and_both_device_ids() throws {
        let c = Party("C"), m = Party("M")
        let hello = RemoteGroupRelayBox.random(106), reply = RemoteGroupRelayBox.random(42)
        let nc = RemoteGroupRelayBox.random(32), nm = RemoteGroupRelayBox.random(32)
        func keys(session: String = "s", client: UUID? = nil, owner: UUID? = nil, isClient: Bool) throws -> RemoteGroupRelayHandshake.Keys {
            let transcript = RemoteGroupRelayHandshake.transcript(session: session, client: client ?? c.device.id,
                                                                  owner: owner ?? m.device.id, hello: hello, reply: reply)
            return try RemoteGroupRelayHandshake.keys(identityKey: isClient ? c.identity : m.identity,
                                                      peerKey: isClient ? m.device.publicKey : c.device.publicKey,
                                                      clientNonce: nc, mailboxNonce: nm, transcript: transcript,
                                                      isClient: isClient)
        }
        func opens(_ sender: SymmetricKey, _ receiver: SymmetricKey) -> Bool {
            var seal = RemoteGroupLANCipher(key: sender, associatedData: RemoteGroupRelayHandshake.frameAssociatedData)
            var open = RemoteGroupLANCipher(key: receiver, associatedData: RemoteGroupRelayHandshake.frameAssociatedData)
            guard let sealed = try? seal.seal(Data("x".utf8)) else { return false }
            return (try? open.open(sealed)) != nil
        }
        let clientSide = try keys(isClient: true), mailboxSide = try keys(isClient: false)
        XCTAssertTrue(opens(clientSide.send, mailboxSide.receive), "C → M")
        XCTAssertTrue(opens(mailboxSide.send, clientSide.receive), "M → C")
        XCTAssertEqual(clientSide.proof, mailboxSide.proof)
        XCTAssertFalse(opens(clientSide.send, clientSide.receive), "方向被换：自己发的自己收不了")
        XCTAssertFalse(opens(clientSide.send, try keys(session: "t", isClient: false).receive), "session 被换")
        XCTAssertFalse(opens(clientSide.send, try keys(client: UUID(), isClient: false).receive), "拨号方 ID 被换")
        XCTAssertFalse(opens(clientSide.send, try keys(owner: UUID(), isClient: false).receive), "信箱主人 ID 被换")
        // 也不能拿局域网那套的 AAD 解。
        var seal = RemoteGroupLANCipher(key: clientSide.send, associatedData: RemoteGroupRelayHandshake.frameAssociatedData)
        var lan = RemoteGroupLANCipher(key: mailboxSide.receive)
        XCTAssertThrowsError(try lan.open(try seal.seal(Data("x".utf8))))
        // 小阶点：共享秘密全 0，拒掉。
        let zero = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(try RemoteGroupRelayHandshake.keys(identityKey: c.identity, peerKey: zero, clientNonce: nc,
                                                                mailboxNonce: nm, transcript: Data(), isClient: true))
    }

    func test_replayed_reordered_or_tampered_frames_end_the_link() {
        for mode in ["replay", "reorder", "tamper"] {
            let pipe = Pipe(client: Party("C"), mailbox: Party("M"))
            pipe.start()
            established(pipe)
            pipe.client.send(Data("first".utf8))
            awaitFast("\(mode)：第一条到了") { pipe.read { $0.mailboxFrames.count == 1 } }
            let base = pipe.read { $0.sentToMailbox.count }
            let first = pipe.read { $0.sentToMailbox[base - 1] }
            let held = Held()
            let kind = mode
            pipe.read { pipe in
                pipe.rewriteToMailbox = { box, index in
                    switch kind {
                    case "replay":
                        return index == base ? [first] : nil
                    case "reorder":
                        if index == base { held.box = box; return [] }
                        if index == base + 1 { return [box, held.box!] }
                        return nil
                    default:
                        guard index == base else { return nil }
                        var bytes = box
                        bytes[bytes.count - 20] ^= 0x01
                        return [bytes]
                    }
                }
            }
            pipe.client.send(Data("second".utf8))
            pipe.client.send(Data("third".utf8))
            awaitFast("\(mode)：信箱那头断开") { pipe.read { $0.mailboxEnded != nil } }
            pipe.read { pipe in
                XCTAssertEqual(pipe.mailboxFrames, [Data("first".utf8)], mode)
                XCTAssertTrue(pipe.events.contains("mailbox closed"), "\(mode)：交给同步层的线路也收到断开")
            }
        }
    }

    func test_a_replayed_hello_from_an_earlier_handshake_gets_nowhere() {
        let pipe = Pipe(client: Party("C"), mailbox: Party("M"))
        pipe.start()
        established(pipe)
        // 把上一次的 hello 与 C 的证明帧原样再送一遍（录下流量的人能做到）。
        let (hello, proof) = pipe.read { ($0.sentToMailbox[0], $0.sentToMailbox[1]) }
        let before = pipe.read { $0.events.filter { $0 == "mailbox established" }.count }
        pipe.queue.async { pipe.deliverToMailbox(hello) }
        pipe.queue.async { pipe.deliverToMailbox(proof) }
        idleFast()
        pipe.read { pipe in
            XCTAssertEqual(pipe.events.filter { $0 == "mailbox established" }.count, before, "新的随机数下旧证明帧解不开")
            XCTAssertNotNil(pipe.mailboxEnded)
        }
    }

    func test_reset_for_this_link_ends_the_dialer_and_other_links_resets_are_ignored() {
        let pipe = Pipe(client: Party("C"), mailbox: Party("M"))
        pipe.start()
        established(pipe)
        pipe.read { $0.client.receive(.reset(linkID: RemoteGroupRelayBox.random(8))) }
        idleFast(0.1)
        pipe.read { XCTAssertNil($0.clientEnded, "别的链路号的 reset 不理") }
        pipe.read { $0.client.receive(.reset(linkID: $0.client.linkID)) }
        pipe.read { XCTAssertEqual($0.clientEnded as? RemoteGroupRelayLinkError, .reset) }
    }

    func test_handshake_timeout_idle_timeout_ping_and_bye() {
        // 握手不完：到时就断。
        let silent = Pipe(client: Party("C"), mailbox: Party("M"))
        silent.read { $0.rewriteToMailbox = { @Sendable _, _ in [] } }
        silent.start()
        silent.read { $0.client.tick(now: Date().addingTimeInterval(5)) }
        silent.read { XCTAssertNil($0.clientEnded) }
        silent.read { $0.client.tick(now: Date().addingTimeInterval(11)) }
        silent.read { XCTAssertEqual($0.clientEnded as? RemoteGroupRelayLinkError, .timeout) }

        // 建立之后：安静 30 秒发探活，90 秒什么都没收到就断。
        let pipe = Pipe(client: Party("C"), mailbox: Party("M"))
        pipe.start()
        established(pipe)
        let before = pipe.read { sealedCount($0.sentToMailbox) }
        pipe.read { $0.client.tick(now: Date().addingTimeInterval(31)) }
        pipe.read { XCTAssertEqual(sealedCount($0.sentToMailbox), before + 1, "发了一个探活帧") }
        idleFast(0.1)
        pipe.read { XCTAssertNil($0.mailboxEnded, "探活帧对端照收") }
        pipe.read { $0.mailbox?.tick(now: Date().addingTimeInterval(91)) }
        pipe.read { XCTAssertEqual($0.mailboxEnded as? RemoteGroupRelayLinkError, .timeout) }

        // 正常关闭：告诉对端，对端不用等超时。
        let polite = Pipe(client: Party("C"), mailbox: Party("M"))
        polite.start()
        established(polite)
        polite.client.close()
        awaitFast("对端收到 bye") { polite.read { $0.mailboxEnded != nil } }
        polite.read { pipe in
            XCTAssertEqual(pipe.mailboxEnded as? RemoteGroupRelayLinkError, .closedByPeer)
            XCTAssertEqual(pipe.clientEnded as? RemoteGroupRelayLinkError, .closed)
            XCTAssertTrue(pipe.events.contains("client closed") && pipe.events.contains("mailbox closed"))
        }
    }

    func test_frames_before_activate_are_kept_in_order() {
        let pipe = Pipe(client: Party("C"), mailbox: Party("M"), holdsClient: true)
        pipe.start()
        established(pipe)
        for index in 0..<5 { pipe.mailbox?.send(Data([UInt8(index)])) }
        idleFast(0.1)
        pipe.read { XCTAssertTrue($0.clientFrames.isEmpty) }
        pipe.releaseClient()
        awaitFast("activate 之后按序交出") { pipe.read { $0.clientFrames.count == 5 } }
        pipe.read { XCTAssertEqual($0.clientFrames, (0..<5).map { Data([UInt8($0)]) }) }
    }

    /// 本机拨出去、建成已久的那条，对方又拨进来：对方手里已经没有线路，换成新的（不论 ID 大小）；建成不久的仍按 ID 规则。
    func test_an_inbound_dial_replaces_an_old_outbound_link_but_not_a_fresh_one() throws {
        let c = Party("C"), m = Party("M")
        let mine = Pipe(client: c, mailbox: m)       // C 拨 M：C 手里的是 `client` 那头
        let theirs = Pipe(client: m, mailbox: c)     // M 拨 C：C 手里的是信箱那头
        mine.start()
        theirs.start()
        established(mine)
        established(theirs)
        let existing = mine.client!, candidate = try XCTUnwrap(theirs.read { $0.mailbox })
        let since = try XCTUnwrap(existing.establishedAt)
        let local = c.device.id, peer = m.device.id
        XCTAssertTrue(RemoteGroupRelayService.prefers(candidate, over: existing, local: local, peer: peer,
                                                      now: since.addingTimeInterval(6), raceWindow: 5),
                      "建成 6 秒的旧线路：换成对方新拨进来的")
        let byRule = RemoteGroupLANService.leads(peer, over: local)
        XCTAssertEqual(RemoteGroupRelayService.prefers(candidate, over: existing, local: local, peer: peer,
                                                       now: since.addingTimeInterval(1), raceWindow: 5), byRule,
                       "竞争窗口之内：按 ID 规则")
        // 反过来（本机新拨出的顶对方拨进来的旧线路）不适用：本机有活的线路就不会拨。
        XCTAssertEqual(RemoteGroupRelayService.prefers(existing, over: candidate, local: local, peer: peer,
                                                       now: since.addingTimeInterval(60), raceWindow: 5), !byRule)
    }

    func test_two_links_between_the_same_pair_keep_the_one_dialed_by_the_smaller_id() {
        let a = Party("A"), b = Party("B")
        let (small, large) = a.device.id.uuidString < b.device.id.uuidString ? (a, b) : (b, a)
        let queue = DispatchQueue(label: "test")
        func link(opener: Party, to target: Party) -> RemoteGroupRelaySession {
            RemoteGroupRelaySession(dialing: target.device, session: "x", local: opener.device, identityKey: opener.identity,
                                    queue: queue, emit: { _ in })
        }
        let bySmall = link(opener: small, to: large), byLarge = link(opener: large, to: small)
        for local in [small.device.id, large.device.id] {
            let peer = local == small.device.id ? large.device.id : small.device.id
            XCTAssertTrue(RemoteGroupRelayService.prefers(bySmall, over: byLarge, local: local, peer: peer))
            XCTAssertFalse(RemoteGroupRelayService.prefers(byLarge, over: bySmall, local: local, peer: peer))
        }
        XCTAssertTrue(RemoteGroupRelayService.prefers(link(opener: small, to: large), over: bySmall,
                                                      local: small.device.id, peer: large.device.id), "同一方拨的留新的")
    }
}

