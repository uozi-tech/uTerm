import CryptoKit
import Foundation

// 设备组快通道的中继信箱线路（docs/remote-device-group-design.md §7.4「中继信箱」，落地见 §17）。
//
// 中继只会把 `client` 的信令（`signal`）转给 `host`，`host` 在同一个 `session` 上回；`box` 对它是不透明的字符串。
// 所以每台设备以 `host` 身份注册一个**信箱**（`RemoteGroupMailbox`），别的设备以 `client` 身份往信箱里投，一个
// `session` 就是一条线路（`RemoteGroupRelaySession`）。拨的一方叫 C（client），信箱的主人叫 M（mailbox）。
//
// 握手（`box` 是下面 `RemoteGroupRelayBox` 的二进制再 base64）：
// 1. C → M：hello（链路号、随机数、C 的远控公钥、C 以为的 M 的远控公钥）。信令外层的 `from` 是 C 的设备 ID。
//    M 只认**钥匙串名册**里有 `device.<from>`、公钥就是 hello 里那把的设备，而且 C 以为的 M 的公钥必须是本机的；
//    否则一个字都不回。
// 2. M → C：reply（同一个链路号、M 的随机数），紧接着 M 的证明帧。
// 3. 会话密钥 = HKDF-SHA256(X25519(本机远控私钥, 对方公钥), salt = 两个随机数, info = 标签、方向、
//    SHA-256(抄本))，抄本含 session、两端设备 ID、hello 与 reply 的原字节。共享秘密全 0 的拒掉。
// 4. 之后每帧 ChaChaPoly（`RemoteGroupLANCipher`，随机数是每个方向自己的帧序号）：重放、乱序、丢帧、被改都解不开，
//    直接断开。各方向第 0 帧是证明帧（抄本摘要）：C 核对过 M 的才回自己的；M 核对过 C 的才收业务帧。
// 5. 中继一帧最长 64 KiB（整条 JSON），同步层一条消息最大 48 KiB、base64 之后放不进。所以一条消息切成每片 30 KiB
//    明文的几片，前面的片标「还有」，收齐了才交出去：对同步层仍是一帧进一帧出。
//
// 信箱重连后，C 还在旧链路号上发的密封帧 M 不认识：M 回一个不加密的 reset（只带链路号），C 收到就断开重拨。
// 能往这个 session 里写的只有中继和信箱本身（session 归拨号的那条连接，见 relay/PROTOCOL.md），它们本来就能掐断。

/// 设备组的中继信箱：每台设备在默认中继上以「主机」身份注册的 ID 与钥匙。
nonisolated enum RemoteGroupMailbox {
    static let label = "uterm-group-mailbox-v1"
    /// 本机信箱主机钥匙在 `RemoteSecretStorage` 里的 account（和远控身份同一个 service，只存本机）。
    /// 和远控的 `relayHostKey` 分开：那把绑着这台 Mac 的远控主机 ID。
    static let hostKeyAccount = "groupMailboxKey"

    /// 信箱的主机 ID：SHA-256(标签 ‖ 设备 ID 的 16 字节) 取前 16 字节，版本位记成 8（RFC 9562 自定义）。
    /// 不用设备 ID 本身：Mac 的被控端已经拿设备 ID 注册着远控的主机，同一个 ID 再注册会互相顶掉。
    /// 设备 ID 是随机的 v4，版本位不同，两者永远不相等。每台设备都能从名册里别人的设备 ID 算出别人的信箱。
    static func hostID(for device: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(label.utf8) + RemoteGroupFormat.uuidBytes(device)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    /// 本机信箱的主机钥匙（P-256）；第一次调用时生成并保存。
    static func hostKey(storage: any RemoteSecretStorage = RemoteLocalState.secrets) throws -> P256.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let data = try storage.load(hostKeyAccount), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        try storage.save(key.rawRepresentation, account: hostKeyAccount)
        return key
    }

    private static let lock = NSLock()
}

/// C 的 hello。
nonisolated struct RemoteGroupRelayHello: Equatable, Sendable {
    /// 这一次握手的链路号（C 出的随机数）：密封帧和 reset 都带着它，信箱据此认出过时的帧。
    var linkID: Data
    var nonce: Data
    /// C 的远控公钥。
    var clientKey: Data
    /// C 从名册里拿来的 M 的远控公钥。
    var ownerKey: Data
}

/// 信令 `box` 里装的东西（二进制，第一个字节是种类）。
nonisolated enum RemoteGroupRelayBox: Equatable, Sendable {
    case hello(RemoteGroupRelayHello)
    case reply(linkID: Data, nonce: Data)
    /// 密文 ‖ 16 字节标签。
    case sealed(linkID: Data, body: Data)
    /// 信箱不认识这个链路号（信箱重连过）：C 断开重拨。不加密。
    case reset(linkID: Data)

    static let version: UInt8 = 1
    static let linkIDLength = 8
    static let nonceLength = 32

    private enum Tag: UInt8 {
        case hello = 1, reply, sealed, reset
    }

    var linkID: Data {
        switch self {
        case .hello(let hello): return hello.linkID
        case .reply(let linkID, _), .sealed(let linkID, _), .reset(let linkID): return linkID
        }
    }

    func encoded() -> Data {
        switch self {
        case .hello(let hello):
            return Data([Tag.hello.rawValue, Self.version]) + hello.linkID + hello.nonce + hello.clientKey + hello.ownerKey
        case .reply(let linkID, let nonce):
            return Data([Tag.reply.rawValue, Self.version]) + linkID + nonce
        case .sealed(let linkID, let body):
            return Data([Tag.sealed.rawValue]) + linkID + body
        case .reset(let linkID):
            return Data([Tag.reset.rawValue]) + linkID
        }
    }

    /// 长度不对、种类或版本不认识的返回 nil。
    static func decode(_ data: Data) -> RemoteGroupRelayBox? {
        let bytes = Data(data)
        guard let first = bytes.first, let tag = Tag(rawValue: first) else { return nil }
        let keyLength = RemoteGroupFormat.keyLength
        func slice(_ start: Int, _ count: Int) -> Data { Data(bytes[start..<(start + count)]) }
        switch tag {
        case .hello:
            guard bytes.count == 2 + linkIDLength + nonceLength + 2 * keyLength, bytes[1] == version else { return nil }
            return .hello(RemoteGroupRelayHello(linkID: slice(2, linkIDLength), nonce: slice(2 + linkIDLength, nonceLength),
                                                clientKey: slice(2 + linkIDLength + nonceLength, keyLength),
                                                ownerKey: slice(2 + linkIDLength + nonceLength + keyLength, keyLength)))
        case .reply:
            guard bytes.count == 2 + linkIDLength + nonceLength, bytes[1] == version else { return nil }
            return .reply(linkID: slice(2, linkIDLength), nonce: slice(2 + linkIDLength, nonceLength))
        case .sealed:
            guard bytes.count >= 1 + linkIDLength + 16 + 1 else { return nil }
            return .sealed(linkID: slice(1, linkIDLength), body: Data(bytes[(1 + linkIDLength)...]))
        case .reset:
            guard bytes.count == 1 + linkIDLength else { return nil }
            return .reset(linkID: slice(1, linkIDLength))
        }
    }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

/// 握手的密钥、证明与分片（纯函数，测试也拿它来造坏对端）。
nonisolated enum RemoteGroupRelayHandshake {
    /// 每片明文多大：base64 之后加上信令的 JSON 外壳约 42 KiB，离中继一帧 64 KiB 留足余量。
    static let fragmentSize = 30 * 1024
    /// 一条消息收齐之后最多多大（和局域网一帧的上限相同）。
    static let maxMessage = 256 * 1024
    static let frameAssociatedData = Data("uTerm device-group relay frame v1".utf8)

    /// 密封帧里明文的第一个字节。
    enum FrameType: UInt8 {
        /// 一条消息的最后一片（或唯一的一片）。
        case data = 1
        case proof = 2
        case ping = 3
        /// 一条消息的一片，后面还有。
        case more = 4
        /// 正常关闭：对端不用等超时。
        case bye = 5
    }

    struct Keys {
        let send: SymmetricKey
        let receive: SymmetricKey
        /// 证明帧的内容。
        let proof: Data
    }

    /// 抄本：标签 ‖ session（2 字节长度 + UTF-8）‖ C 的设备 ID ‖ M 的设备 ID ‖ hello 原字节 ‖ reply 原字节。
    static func transcript(session: String, client: UUID, owner: UUID, hello: Data, reply: Data) -> Data {
        let sessionBytes = Data(session.utf8)
        var length = UInt16(clamping: sessionBytes.count).bigEndian
        return Data("uTerm device-group relay v1".utf8) + Data(bytes: &length, count: 2) + sessionBytes
            + RemoteGroupFormat.uuidBytes(client) + RemoteGroupFormat.uuidBytes(owner) + hello + reply
    }

    static func keys(identityKey: Curve25519.KeyAgreement.PrivateKey, peerKey: Data, clientNonce: Data, mailboxNonce: Data,
                     transcript: Data, isClient: Bool) throws -> Keys {
        guard let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey),
              let secret = try? identityKey.sharedSecretFromKeyAgreement(with: remote) else {
            throw RemoteGroupRelayLinkError.handshake(String(localized: "对端公钥无效"))
        }
        let bytes = secret.withUnsafeBytes { Data($0) }
        // 小阶点会让共享秘密退化成全 0，任何人都算得出来。
        guard bytes.contains(where: { $0 != 0 }) else { throw RemoteGroupRelayLinkError.handshake(String(localized: "共享秘密无效")) }
        let digest = Data(SHA256.hash(data: transcript))
        func derive(_ direction: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: clientNonce + mailboxNonce,
                                   info: Data("uterm-group-sync-v1 relay \(direction)".utf8) + digest, outputByteCount: 32)
        }
        let c2m = derive("c2m"), m2c = derive("m2c")
        let proof = Data(SHA256.hash(data: Data("uTerm device-group relay proof v1".utf8) + digest))
        return isClient ? Keys(send: c2m, receive: m2c, proof: proof) : Keys(send: m2c, receive: c2m, proof: proof)
    }

    /// 把一条消息切成片：(内容, 后面还有)。空消息也是一片。
    static func fragments(_ message: Data, size: Int = fragmentSize) -> [(chunk: Data, more: Bool)] {
        guard !message.isEmpty else { return [(Data(), false)] }
        let bytes = Data(message)
        return stride(from: 0, to: bytes.count, by: size).map { start in
            let end = min(bytes.count, start + size)
            return (Data(bytes[start..<end]), end < bytes.count)
        }
    }
}

/// 收片、拼回一条消息。超过上限抛错（线路应立即断开）。
nonisolated struct RemoteGroupRelayReassembler {
    let limit: Int
    private var buffer = Data()

    init(limit: Int = RemoteGroupRelayHandshake.maxMessage) {
        self.limit = limit
    }

    /// 还在拼的字节数。
    var pendingBytes: Int { buffer.count }

    /// 收一片：后面还有时返回 nil，最后一片返回整条消息。
    mutating func add(_ chunk: Data, more: Bool) throws -> Data? {
        guard buffer.count + chunk.count <= limit else {
            buffer = Data()
            throw RemoteGroupRelayLinkError.frame(String(localized: "消息超过 \(limit) 字节"))
        }
        buffer.append(chunk)
        guard !more else { return nil }
        defer { buffer = Data() }
        return buffer
    }
}

nonisolated enum RemoteGroupRelayLinkError: Error, Equatable, LocalizedError {
    case handshake(String)
    case frame(String)
    case timeout
    /// 本机关掉的。
    case closed
    /// 对端说它关了（`bye`）。
    case closedByPeer
    /// 信箱不认识这条链路（信箱重连过）。
    case reset
    /// 中继说对方的信箱不在线。
    case undeliverable
    /// 同一个 session 上又开始了一次握手，或者同一台对端留了另一条。
    case replaced

    var errorDescription: String? {
        switch self {
        case .handshake(let reason): return String(localized: "中继线路握手失败：\(reason)")
        case .frame(let reason): return String(localized: "中继线路帧无效：\(reason)")
        case .timeout: return String(localized: "中继线路超时")
        case .closed: return String(localized: "中继线路已关闭")
        case .closedByPeer: return String(localized: "对方关闭了中继线路")
        case .reset: return String(localized: "对方信箱重连过")
        case .undeliverable: return String(localized: "对方信箱不在线")
        case .replaced: return String(localized: "换成了另一条线路")
        }
    }
}

/// 经中继信箱的一条快通道线路：先握手，成功后就是一条 `RemoteGroupPeerLink`。
///
/// 不自己开队列：所有状态都在构造时给的 `queue` 上（由 `RemoteGroupRelayService` 的队列统一驱动）。
/// `RemoteGroupPeerLink` 的几个方法可以在任意线程上调；其余的方法（`start`、`receive`、`tick`、`end`）必须在 `queue` 上调。
/// 发出去的 `box` 经 `emit`（在 `queue` 上调）交给拥有者包成信令发给中继。
nonisolated final class RemoteGroupRelaySession: RemoteGroupPeerLink, @unchecked Sendable {
    enum Role: Equatable, Sendable {
        /// 本机往对方的信箱拨。
        case client
        /// 对方拨进本机的信箱。
        case mailbox
    }

    struct Timing: Sendable {
        /// 握手多久不完就放弃。
        var handshake: TimeInterval = 10
        /// 多久没发过东西就发一个探活帧。
        var ping: TimeInterval = 30
        /// 多久什么都没收到就断开（对方下线、拨号那头的中继连接断了，中继都不会告诉信箱）。
        var idle: TimeInterval = 90

        static let standard = Timing()
    }

    /// 交给同步层之前最多存几帧。
    private static let maxPendingFrames = 256

    let kind = RemoteGroupLinkKind.relay
    let role: Role
    /// 对端在钥匙串名册里的条目（拨的一方：拿来拨的那条；信箱：核对过 hello 的那条）。
    let peer: RemoteGroupDevice
    let session: String
    let linkID: Data
    /// 这条线路是哪台拨的（两台互相拨通了两条时按它挑留下哪条）。
    let opener: UUID

    private let local: RemoteGroupDevice
    private let identityKey: Curve25519.KeyAgreement.PrivateKey
    private let queue: DispatchQueue
    private let timing: Timing
    private let emit: (Data) -> Void
    private let startedAt: Date
    private var hello: Data?
    private var nonce: Data
    private var keys: RemoteGroupRelayHandshake.Keys?
    private var sendCipher: RemoteGroupLANCipher?
    private var receiveCipher: RemoteGroupLANCipher?
    private var reassembler = RemoteGroupRelayReassembler()
    private(set) var isEstablished = false
    /// 握好手的时刻（去重时据此分「两边同时拨的竞争」和「旧的那条早就死了」）。
    private(set) var establishedAt: Date?
    private(set) var isEnded = false
    private var onEstablished: ((RemoteGroupRelaySession) -> Void)?
    private var onEnded: ((RemoteGroupRelaySession, _ wasEstablished: Bool, Error) -> Void)?
    private var onFrame: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var pending: [Data] = []
    private var lastReceived: Date
    private var lastSent: Date

    /// 拨的一方：往 `peer` 的信箱拨（`peer` 必须是钥匙串名册里的条目）。`start` 时发 hello。
    init(dialing peer: RemoteGroupDevice, session: String, local: RemoteGroupDevice,
         identityKey: Curve25519.KeyAgreement.PrivateKey, queue: DispatchQueue, timing: Timing = .standard,
         now: Date = Date(), emit: @escaping (Data) -> Void) {
        role = .client
        self.peer = peer
        self.session = session
        linkID = RemoteGroupRelayBox.random(RemoteGroupRelayBox.linkIDLength)
        opener = local.id
        self.local = local
        self.identityKey = identityKey
        self.queue = queue
        self.timing = timing
        self.emit = emit
        nonce = RemoteGroupRelayBox.random(RemoteGroupRelayBox.nonceLength)
        startedAt = now
        lastReceived = now
        lastSent = now
    }

    private init(accepting hello: RemoteGroupRelayHello, helloBytes: Data, from peer: RemoteGroupDevice, session: String,
                 local: RemoteGroupDevice, identityKey: Curve25519.KeyAgreement.PrivateKey, queue: DispatchQueue,
                 timing: Timing, now: Date, emit: @escaping (Data) -> Void) throws {
        role = .mailbox
        self.peer = peer
        self.session = session
        linkID = hello.linkID
        opener = peer.id
        self.local = local
        self.identityKey = identityKey
        self.queue = queue
        self.timing = timing
        self.emit = emit
        nonce = RemoteGroupRelayBox.random(RemoteGroupRelayBox.nonceLength)
        startedAt = now
        lastReceived = now
        lastSent = now
        let reply = RemoteGroupRelayBox.reply(linkID: hello.linkID, nonce: nonce).encoded()
        self.hello = reply
        let transcript = RemoteGroupRelayHandshake.transcript(session: session, client: peer.id, owner: local.id,
                                                              hello: helloBytes, reply: reply)
        try installKeys(RemoteGroupRelayHandshake.keys(identityKey: identityKey, peerKey: peer.publicKey,
                                                       clientNonce: hello.nonce, mailboxNonce: nonce,
                                                       transcript: transcript, isClient: false))
    }

    /// 信箱收到一个 hello：拨号的那台（`from`，信令外层的设备 ID）在钥匙串名册里、公钥就是 hello 里那把、它以为的本机
    /// 公钥也对，才建一条；否则返回 nil，什么都不回。`start` 时回 reply 与证明帧。
    static func accept(_ hello: RemoteGroupRelayHello, from: UUID, session: String, local: RemoteGroupDevice,
                       identityKey: Curve25519.KeyAgreement.PrivateKey, trusted: [RemoteGroupDevice], queue: DispatchQueue,
                       timing: Timing = .standard, now: Date = Date(),
                       emit: @escaping (Data) -> Void) -> RemoteGroupRelaySession? {
        guard from != local.id, hello.ownerKey == local.publicKey,
              let entry = trusted.first(where: { $0.id == from && $0.publicKey == hello.clientKey && $0.hasValidKeys })
        else { return nil }
        return try? RemoteGroupRelaySession(accepting: hello, helloBytes: RemoteGroupRelayBox.hello(hello).encoded(),
                                            from: entry, session: session, local: local, identityKey: identityKey,
                                            queue: queue, timing: timing, now: now, emit: emit)
    }

    // MARK: - 拥有者（在 queue 上调）

    /// 开始握手。成功调 `onEstablished`；无论成败，结束时调一次 `onEnded`（成功之后断开也是）。
    func start(onEstablished: @escaping (RemoteGroupRelaySession) -> Void,
               onEnded: @escaping (RemoteGroupRelaySession, _ wasEstablished: Bool, Error) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.onEstablished = onEstablished
        self.onEnded = onEnded
        switch role {
        case .client:
            let bytes = RemoteGroupRelayBox.hello(RemoteGroupRelayHello(
                linkID: linkID, nonce: nonce, clientKey: local.publicKey, ownerKey: peer.publicKey)).encoded()
            hello = bytes
            write(bytes)
        case .mailbox:
            if let hello { write(hello) }
            sendSealed(.proof, keys?.proof ?? Data())
        }
    }

    /// 这个 session 上收到的一个 `box`（链路号由拥有者先对过）。
    func receive(_ box: RemoteGroupRelayBox, now: Date = Date()) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isEnded, box.linkID == linkID else { return }
        lastReceived = now
        do {
            switch box {
            case .hello:
                throw RemoteGroupRelayLinkError.handshake(String(localized: "多余的 hello"))
            case .reply(_, let mailboxNonce):
                guard role == .client, keys == nil, let hello else { throw RemoteGroupRelayLinkError.handshake(String(localized: "多余的 reply")) }
                let transcript = RemoteGroupRelayHandshake.transcript(session: session, client: local.id, owner: peer.id,
                                                                      hello: hello, reply: box.encoded())
                try installKeys(RemoteGroupRelayHandshake.keys(identityKey: identityKey, peerKey: peer.publicKey,
                                                               clientNonce: nonce, mailboxNonce: mailboxNonce,
                                                               transcript: transcript, isClient: true))
            case .sealed(_, let body):
                try handleSealed(body)
            case .reset:
                guard role == .client else { return }
                throw RemoteGroupRelayLinkError.reset
            }
        } catch {
            end(error)
        }
    }

    /// 每秒一次：握手超时、空闲探活与断开。
    func tick(now: Date = Date()) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isEnded else { return }
        guard isEstablished else {
            if now.timeIntervalSince(startedAt) >= timing.handshake { end(RemoteGroupRelayLinkError.timeout) }
            return
        }
        if now.timeIntervalSince(lastReceived) >= timing.idle { return end(RemoteGroupRelayLinkError.timeout) }
        if now.timeIntervalSince(lastSent) >= timing.ping { sendSealed(.ping, Data(), now: now) }
    }

    /// 结束这条线路。已建立且是正常关闭（`.closed` / `.replaced`）时先告诉对端（`bye`）。
    func end(_ error: Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isEnded else { return }
        if isEstablished, let reason = error as? RemoteGroupRelayLinkError, reason == .closed || reason == .replaced {
            sendSealed(.bye, Data())
        }
        isEnded = true
        pending = []
        let wasEstablished = isEstablished
        let ended = onEnded, closed = onClose
        onEnded = nil
        onEstablished = nil
        onClose = nil
        onFrame = nil
        ended?(self, wasEstablished, error)
        if wasEstablished { closed?() }
    }

    // MARK: - RemoteGroupPeerLink

    func activate(onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !isEnded else { return onClose() }
            self.onFrame = onFrame
            self.onClose = onClose
            let frames = pending
            pending = []
            for frame in frames { onFrame(frame) }
        }
    }

    func send(_ frame: Data) {
        queue.async { [self] in
            guard isEstablished, !isEnded else { return }
            guard frame.count <= RemoteGroupRelayHandshake.maxMessage else {
                AppLogger.notice("设备组：要经中继发的一条消息太大（\(frame.count) 字节），丢掉", category: RemoteLog.category)
                return
            }
            for fragment in RemoteGroupRelayHandshake.fragments(frame) {
                sendSealed(fragment.more ? .more : .data, fragment.chunk)
            }
        }
    }

    func close() {
        queue.async { [self] in end(RemoteGroupRelayLinkError.closed) }
    }

    // MARK: - 收发

    private func installKeys(_ keys: RemoteGroupRelayHandshake.Keys) throws {
        self.keys = keys
        sendCipher = RemoteGroupLANCipher(key: keys.send, associatedData: RemoteGroupRelayHandshake.frameAssociatedData)
        receiveCipher = RemoteGroupLANCipher(key: keys.receive, associatedData: RemoteGroupRelayHandshake.frameAssociatedData)
    }

    private func handleSealed(_ body: Data) throws {
        guard let keys, var cipher = receiveCipher else { throw RemoteGroupRelayLinkError.handshake(String(localized: "还没有会话密钥")) }
        let plain: Data
        do {
            plain = try cipher.open(body)
        } catch {
            throw RemoteGroupRelayLinkError.frame(String(localized: "解不开（被改、重放或乱序）"))
        }
        receiveCipher = cipher
        guard let type = plain.first.flatMap(RemoteGroupRelayHandshake.FrameType.init(rawValue:)) else {
            throw RemoteGroupRelayLinkError.frame(String(localized: "类型不认识"))
        }
        let content = Data(plain.dropFirst())
        if !isEstablished {
            // 第一帧必须是证明帧，内容对得上抄本。
            guard type == .proof, cipher.counter == 1, content == keys.proof else {
                throw RemoteGroupRelayLinkError.handshake(String(localized: "对端证明不了算得出会话密钥"))
            }
            if role == .client { sendSealed(.proof, keys.proof) }
            return establish()
        }
        switch type {
        case .data, .more:
            guard let message = try reassembler.add(content, more: type == .more) else { return }
            if let onFrame { onFrame(message) } else {
                guard pending.count < Self.maxPendingFrames else { throw RemoteGroupRelayLinkError.frame(String(localized: "积压太多")) }
                pending.append(message)
            }
        case .ping:
            break
        case .bye:
            throw RemoteGroupRelayLinkError.closedByPeer
        case .proof:
            throw RemoteGroupRelayLinkError.frame(String(localized: "多余的证明帧"))
        }
    }

    private func establish() {
        isEstablished = true
        establishedAt = lastReceived
        let callback = onEstablished
        onEstablished = nil
        callback?(self)
    }

    private func sendSealed(_ type: RemoteGroupRelayHandshake.FrameType, _ content: Data, now: Date = Date()) {
        guard var cipher = sendCipher else { return }
        do {
            let sealed = try cipher.seal(Data([type.rawValue]) + content)
            sendCipher = cipher
            lastSent = now
            write(RemoteGroupRelayBox.sealed(linkID: linkID, body: sealed).encoded())
        } catch {
            end(error)
        }
    }

    private func write(_ box: Data) {
        emit(box)
    }
}
