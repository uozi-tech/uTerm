import CryptoKit
import Foundation
@preconcurrency import Network

// 设备组快通道的局域网线路（docs/remote-device-group-design.md §7.4「谁能进快通道」「密封」，落地见 §16）：
// 一条 TCP 连接，4 字节大端长度前缀分帧。
//
// 握手（发起方 I = 设备 ID 小的那台，见 `RemoteGroupLANService`；接受方 R）：
// 1. I → R：明文 hello（版本、设备 ID、远控公钥、32 字节随机数）；R → I：同样一份。
// 2. 两边都只认**钥匙串名册**里有 `device.<id>`、而且记录里的远控公钥就是 hello 里那把的设备（叠加层收到的
//    `device` 不算）；I 还要求 R 就是它要连的那台。
// 3. 会话密钥 = HKDF-SHA256(X25519(本机远控私钥, 对方公钥), salt = 两个随机数, info = 标签、方向、两端设备 ID、
//    握手抄本的摘要)，两个方向各一把。共享秘密全 0 的拒掉。
// 4. 之后每帧 ChaChaPoly，随机数是每个方向自己的帧序号（不随帧发送）：重放、乱序、丢帧、被改都解不开，直接断开。
//    第一帧是证明帧（抄本摘要）：I 先发，R 核对过才回自己的；两边都核对过才收业务帧。

/// 握手与逐帧加密（纯函数，测试也拿它来造坏对端）。
nonisolated enum RemoteGroupLANHandshake {
    static let version = 1
    static let nonceLength = 32
    /// 握手完成之前一帧最多多大（hello、证明帧都很小）。
    static let maxHandshakeFrame = 4 * 1024
    /// 握手之后一帧最多多大。
    static let maxFrame = 256 * 1024
    static let timeout: TimeInterval = 10

    struct Hello: Codable, Equatable, Sendable {
        var v: Int
        var id: UUID
        /// 远控公钥（X25519 原始 32 字节）。
        var key: Data
        var nonce: Data
    }

    /// 帧里明文的第一个字节。
    enum FrameType: UInt8 {
        case data = 1
        case proof = 2
        case ping = 3
    }

    static func newNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceLength, &bytes)
        return Data(bytes)
    }

    static func hello(_ device: RemoteGroupDevice, nonce: Data) throws -> Data {
        try JSONEncoder().encode(Hello(v: version, id: device.id, key: device.publicKey, nonce: nonce))
    }

    static func parseHello(_ data: Data) -> Hello? {
        guard let hello = try? JSONDecoder().decode(Hello.self, from: data), hello.v == version,
              hello.key.count == RemoteGroupFormat.keyLength, hello.nonce.count == nonceLength else { return nil }
        return hello
    }

    /// 钥匙串名册里这台设备的条目，并且公钥就是 hello 里报的那把。名册里同一个 ID 有几条（钥匙串圈里的人能写）时
    /// 只要有一条对得上：对得上的那把公钥，对方得拿着私钥才过得了证明帧。
    static func trustedEntry(for hello: Hello, in trusted: [RemoteGroupDevice]) -> RemoteGroupDevice? {
        trusted.first { $0.id == hello.id && $0.publicKey == hello.key && $0.hasValidKeys }
    }

    struct Keys {
        let send: SymmetricKey
        let receive: SymmetricKey
        /// 证明帧的内容。
        let proof: Data
    }

    /// `transcript` = 发起方的 hello 字节 ‖ 接受方的 hello 字节（线上的原样）。
    static func keys(identityKey: Curve25519.KeyAgreement.PrivateKey, peerKey: Data, initiator: Hello, responder: Hello,
                     transcript: Data, isInitiator: Bool) throws -> Keys {
        guard let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey),
              let secret = try? identityKey.sharedSecretFromKeyAgreement(with: remote) else {
            throw RemoteGroupLANError.handshake("对端公钥无效")
        }
        let bytes = secret.withUnsafeBytes { Data($0) }
        // 小阶点会让共享秘密退化成全 0，任何人都算得出来。
        guard bytes.contains(where: { $0 != 0 }) else { throw RemoteGroupLANError.handshake("共享秘密无效") }
        let digest = Data(SHA256.hash(data: transcript))
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: initiator.nonce + responder.nonce,
                                   info: Data("uTerm device-group lan v1 \(label) \(initiator.id.uuidString) \(responder.id.uuidString)".utf8) + digest,
                                   outputByteCount: 32)
        }
        let i2r = derive("i2r"), r2i = derive("r2i")
        let proof = Data(SHA256.hash(data: Data("uTerm device-group lan proof v1".utf8) + digest))
        return isInitiator ? Keys(send: i2r, receive: r2i, proof: proof) : Keys(send: r2i, receive: i2r, proof: proof)
    }

    /// 一帧：4 字节大端长度 + 内容。
    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }
}

nonisolated enum RemoteGroupLANError: Error, Equatable, LocalizedError {
    case handshake(String)
    case frame(String)
    case timeout
    case closed

    var errorDescription: String? {
        switch self {
        case .handshake(let reason): return "快通道握手失败：\(reason)"
        case .frame(let reason): return "快通道帧无效：\(reason)"
        case .timeout: return "快通道超时"
        case .closed: return "快通道已断开"
        }
    }
}

/// 一个方向的逐帧加解密：随机数 = 4 字节 0 + 8 字节大端帧序号，序号两边各自数，不随帧发送。
nonisolated struct RemoteGroupLANCipher {
    private let key: SymmetricKey
    private(set) var counter: UInt64 = 0
    private static let associatedData = Data("uTerm device-group lan frame v1".utf8)

    init(key: SymmetricKey) {
        self.key = key
    }

    private func nonce() throws -> ChaChaPoly.Nonce {
        var big = counter.bigEndian
        return try ChaChaPoly.Nonce(data: Data(count: 4) + Data(bytes: &big, count: 8))
    }

    /// 密文 ‖ 16 字节标签。
    mutating func seal(_ plain: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce(), authenticating: Self.associatedData)
        counter += 1
        // 拷成从 0 起的 Data：`box.ciphertext` 是 combined 的切片，下标不从 0 开始。
        return Data(box.ciphertext) + Data(box.tag)
    }

    mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw RemoteGroupLANError.frame("太短") }
        let box = try ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        guard let plain = try? ChaChaPoly.open(box, using: key, authenticating: Self.associatedData) else {
            throw RemoteGroupLANError.frame("解不开（被改、重放或乱序）")
        }
        counter += 1
        return plain
    }
}

/// 收字节、切帧。长度为 0 或超过上限时抛错（连接应立即断开）。
nonisolated struct RemoteGroupLANFrameReader {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next(limit: Int) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = buffer[start..<(start + 4)].reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= limit else { throw RemoteGroupLANError.frame("长度 \(length) 不在 1…\(limit)") }
        guard buffer.count >= 4 + length else { return nil }
        let frame = Data(buffer[(start + 4)..<(start + 4 + length)])
        buffer = Data(buffer[(start + 4 + length)...])
        return frame
    }
}

/// 局域网上的一条快通道连接：先握手，成功后就是一条 `RemoteGroupPeerLink`。状态都在自己的队列上。
nonisolated final class RemoteGroupLANConnection: RemoteGroupPeerLink, @unchecked Sendable {
    enum Role {
        /// 发起方，要连的是这台（Bonjour TXT 里报的设备 ID）。
        case initiator(expected: UUID)
        case responder
    }

    /// 空闲多久发一次探活帧、多久没收到任何东西就断开。
    static let pingInterval: TimeInterval = 15
    static let idleTimeout: TimeInterval = 45
    /// 交给同步层之前最多存几帧。
    private static let maxPendingFrames = 256

    let kind = RemoteGroupLinkKind.localNetwork
    let role: Role
    /// 对端在钥匙串名册里的条目：握手核对过 hello 之后才有，`onEstablished` 之后才交给别人用。
    var peer: RemoteGroupDevice {
        identityLock.withLock { peerDevice }!
    }
    /// 这条连接由哪台发起（两台同时互连时按它挑留下哪条）。
    var initiatorID: UUID? { identityLock.withLock { initiator } }

    /// `peer` / `initiatorID` 在任意线程上读（含 `onEstablished` 回调里，那时在本连接的队列上）。
    private let identityLock = NSLock()
    private var peerDevice: RemoteGroupDevice?
    private var initiator: UUID?
    private let connection: NWConnection
    private let local: RemoteGroupDevice
    private let identityKey: Curve25519.KeyAgreement.PrivateKey
    private let trusted: @Sendable () -> [RemoteGroupDevice]
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.group-lan")
    private var reader = RemoteGroupLANFrameReader()
    private var sendCipher: RemoteGroupLANCipher?
    private var receiveCipher: RemoteGroupLANCipher?
    private var localHello = Data()
    private var remoteHello: RemoteGroupLANHandshake.Hello?
    private var remoteHelloBytes = Data()
    private var keys: RemoteGroupLANHandshake.Keys?
    private var isEstablished = false
    private var isClosed = false
    private var onEstablished: (@Sendable (RemoteGroupLANConnection) -> Void)?
    private var onFailed: (@Sendable (Error) -> Void)?
    private var onFrame: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var pending: [Data] = []
    private var lastReceived = Date()
    private var lastSent = Date()
    private var timer: DispatchSourceTimer?

    init(connection: NWConnection, role: Role, local: RemoteGroupDevice,
         identityKey: Curve25519.KeyAgreement.PrivateKey, trusted: @escaping @Sendable () -> [RemoteGroupDevice]) {
        self.connection = connection
        self.role = role
        self.local = local
        self.identityKey = identityKey
        self.trusted = trusted
    }

    /// 开始握手。成功调 `onEstablished`（之后断开走 `activate` 给的 `onClose`），失败调 `onFailed`，只调其一、一次。
    func start(onEstablished: @escaping @Sendable (RemoteGroupLANConnection) -> Void,
               onFailed: @escaping @Sendable (Error) -> Void) {
        queue.async { [self] in
            self.onEstablished = onEstablished
            self.onFailed = onFailed
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.connectionReady()
                case .failed(let error): self.fail(error)
                case .waiting(let error) where !self.isEstablished: self.fail(error)
                case .cancelled: self.fail(RemoteGroupLANError.closed)
                default: break
                }
            }
            connection.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + RemoteGroupLANHandshake.timeout, repeating: 5)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    // MARK: - RemoteGroupPeerLink

    func activate(onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !isClosed else { return onClose() }
            self.onFrame = onFrame
            self.onClose = onClose
            let frames = pending
            pending = []
            for frame in frames { onFrame(frame) }
        }
    }

    func send(_ frame: Data) {
        queue.async { [self] in
            guard isEstablished, !isClosed else { return }
            sendSealed(.data, frame)
        }
    }

    func close() {
        queue.async { [self] in fail(RemoteGroupLANError.closed) }
    }

    // MARK: - 握手

    private func connectionReady() {
        guard !isClosed else { return }
        receive()
        if case .initiator = role {
            identityLock.withLock { initiator = local.id }
            sendHello()
        }
    }

    private func sendHello() {
        do {
            localHello = try RemoteGroupLANHandshake.hello(local, nonce: RemoteGroupLANHandshake.newNonce())
            write(localHello)
        } catch {
            fail(error)
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.reader.append(data)
                self.drain()
            }
            if let error { return self.fail(error) }
            if isComplete { return self.fail(RemoteGroupLANError.closed) }
            if !self.isClosed { self.receive() }
        }
    }

    private func drain() {
        do {
            while !isClosed,
                  let frame = try reader.next(limit: isEstablished ? RemoteGroupLANHandshake.maxFrame
                                                                   : RemoteGroupLANHandshake.maxHandshakeFrame) {
                lastReceived = Date()
                try handle(frame)
            }
        } catch {
            fail(error)
        }
    }

    private func handle(_ frame: Data) throws {
        guard let keys else { return try handleHello(frame) }
        guard var cipher = receiveCipher else { throw RemoteGroupLANError.closed }
        let plain = try cipher.open(frame)
        receiveCipher = cipher
        guard let type = plain.first.flatMap(RemoteGroupLANHandshake.FrameType.init(rawValue:)) else {
            throw RemoteGroupLANError.frame("类型不认识")
        }
        let body = Data(plain.dropFirst())
        if !isEstablished {
            // 第一帧必须是证明帧，内容对得上抄本。
            guard type == .proof, cipher.counter == 1, body == keys.proof else {
                throw RemoteGroupLANError.handshake("对端证明不了算得出会话密钥")
            }
            if case .responder = role { sendSealed(.proof, keys.proof) }
            establish()
            return
        }
        switch type {
        case .data:
            if let onFrame { onFrame(body) } else {
                guard pending.count < Self.maxPendingFrames else { throw RemoteGroupLANError.frame("积压太多") }
                pending.append(body)
            }
        case .ping:
            break
        case .proof:
            throw RemoteGroupLANError.frame("多余的证明帧")
        }
    }

    private func handleHello(_ frame: Data) throws {
        guard remoteHello == nil, let hello = RemoteGroupLANHandshake.parseHello(frame) else {
            throw RemoteGroupLANError.handshake("hello 无效")
        }
        guard hello.id != local.id else { throw RemoteGroupLANError.handshake("连到了自己") }
        if case .initiator(let expected) = role, hello.id != expected {
            throw RemoteGroupLANError.handshake("对端不是要连的那台")
        }
        guard let entry = RemoteGroupLANHandshake.trustedEntry(for: hello, in: trusted()) else {
            throw RemoteGroupLANError.handshake("对端不在钥匙串名册里，或公钥对不上")
        }
        remoteHello = hello
        remoteHelloBytes = frame
        if case .responder = role {
            identityLock.withLock { initiator = hello.id }
            sendHello()
        }
        guard let mine = RemoteGroupLANHandshake.parseHello(localHello) else { throw RemoteGroupLANError.closed }
        let isInitiator: Bool
        if case .initiator = role { isInitiator = true } else { isInitiator = false }
        let transcript = isInitiator ? localHello + remoteHelloBytes : remoteHelloBytes + localHello
        let keys = try RemoteGroupLANHandshake.keys(identityKey: identityKey, peerKey: entry.publicKey,
                                                    initiator: isInitiator ? mine : hello,
                                                    responder: isInitiator ? hello : mine,
                                                    transcript: transcript, isInitiator: isInitiator)
        self.keys = keys
        sendCipher = RemoteGroupLANCipher(key: keys.send)
        receiveCipher = RemoteGroupLANCipher(key: keys.receive)
        identityLock.withLock { peerDevice = entry }
        if isInitiator { sendSealed(.proof, keys.proof) }
    }

    private func establish() {
        isEstablished = true
        timer?.schedule(deadline: .now() + 5, repeating: 5)
        let callback = onEstablished
        onEstablished = nil
        onFailed = nil
        callback?(self)
    }

    // MARK: - 收发

    private func sendSealed(_ type: RemoteGroupLANHandshake.FrameType, _ body: Data) {
        guard var cipher = sendCipher else { return }
        do {
            let sealed = try cipher.seal(Data([type.rawValue]) + body)
            sendCipher = cipher
            guard sealed.count <= RemoteGroupLANHandshake.maxFrame else { return fail(RemoteGroupLANError.frame("要发的帧太大")) }
            write(sealed)
        } catch {
            fail(error)
        }
    }

    private func write(_ payload: Data) {
        lastSent = Date()
        connection.send(content: RemoteGroupLANHandshake.frame(payload), completion: .contentProcessed { [weak self] error in
            guard let error, let self else { return }
            self.queue.async { self.fail(error) }
        })
    }

    private func tick() {
        guard !isClosed else { return }
        guard isEstablished else { return fail(RemoteGroupLANError.timeout) }
        let now = Date()
        if now.timeIntervalSince(lastReceived) > Self.idleTimeout { return fail(RemoteGroupLANError.timeout) }
        if now.timeIntervalSince(lastSent) > Self.pingInterval { sendSealed(.ping, Data()) }
    }

    private func fail(_ error: Error) {
        guard !isClosed else { return }
        isClosed = true
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending = []
        if isEstablished {
            let callback = onClose
            onClose = nil
            onFrame = nil
            callback?()
        } else {
            let callback = onFailed
            onFailed = nil
            onEstablished = nil
            callback?(error)
        }
    }
}
