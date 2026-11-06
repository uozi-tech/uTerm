import CryptoKit
import Foundation

// 跨公网连接前，手机和 Mac 经中继交换的信令。中继只转发，看不懂也改不了：
// 密钥由两端长期密钥的 X25519 派生，只有互相认识的两台设备算得出来。

/// 信令内容。
nonisolated struct RemoteSignalBody: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// 手机：我想连你。
        case offer
        /// Mac：可以。
        case answer
        /// Mac：认识你，但没有允许你经公网接入。
        case denied
        /// 手机：打洞诊断，`ice` 是我的候选地址。
        case iceProbe
        /// Mac：打洞诊断的回复，`ice` 是我的候选地址。
        case iceProbeAnswer
        /// 手机：中继诊断。Mac 经中继回拨后，把收到的字节原样弹回。
        case relayProbe
        /// Mac：中继诊断的回复，可以拨了。
        case relayProbeAnswer
    }

    var kind: Kind
    var deviceID: UUID
    /// 发送时间（Unix 秒），和 `nonce` 一起防重放。
    var sentAt: TimeInterval
    /// 32 字节随机数。两端各出一个，派生本次会话的握手密钥。
    var nonce: Data
    /// ICE 描述（ufrag、密码、候选地址）。里面有 IP 地址，所以只放在密封的信令里。
    /// `offer` / `answer` 上是可选的：没有就走中继，旧版本的对端自然落到这条路上。
    var ice: String?

    static func newNonce() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }
}

/// 公网路径上包住明文握手帧的密钥，中继因此看不到设备名和公钥。
nonisolated struct RemoteHandshakeKeys: Sendable {
    let send: SymmetricKey
    let receive: SymmetricKey
}

nonisolated enum RemoteSignalDirection: String, Sendable {
    case phoneToMac = "i2r"
    case macToPhone = "r2i"
}

nonisolated enum RemoteSignalError: Error, Equatable {
    case invalidKey
    case malformed
    /// 解不开：对方不是它声称的设备，或内容被改过，或这条信令本来属于别的会话、别的方向。
    case undecryptable
}

nonisolated enum RemoteSignalBox {
    /// 两台设备共有的信令主密钥。
    static func sharedKey(local: Curve25519.KeyAgreement.PrivateKey, remotePublicKey: Data) throws -> SymmetricKey {
        guard let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey),
              let secret = try? local.sharedSecretFromKeyAgreement(with: remote) else {
            throw RemoteSignalError.invalidKey
        }
        let bytes = secret.withUnsafeBytes { Data($0) }
        // 小阶点会让共享秘密退化成全 0，任何人都算得出来。
        guard bytes.contains(where: { $0 != 0 }) else { throw RemoteSignalError.invalidKey }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes),
                                      salt: Data("uterm-signal-v1".utf8),
                                      info: Data("shared".utf8), outputByteCount: 32)
    }

    static func seal(_ body: RemoteSignalBody, key: SymmetricKey, session: String,
                     direction: RemoteSignalDirection) throws -> String {
        let plain = try JSONEncoder().encode(body)
        let sealed = try ChaChaPoly.seal(plain, using: key, authenticating: additionalData(session, direction))
        return sealed.combined.base64EncodedString()
    }

    static func open(_ box: String, key: SymmetricKey, session: String,
                     direction: RemoteSignalDirection) throws -> RemoteSignalBody {
        guard let data = Data(base64Encoded: box), let sealed = try? ChaChaPoly.SealedBox(combined: data) else {
            throw RemoteSignalError.malformed
        }
        guard let plain = try? ChaChaPoly.open(sealed, using: key, authenticating: additionalData(session, direction)) else {
            throw RemoteSignalError.undecryptable
        }
        guard let body = try? JSONDecoder().decode(RemoteSignalBody.self, from: plain) else {
            throw RemoteSignalError.malformed
        }
        return body
    }

    /// 绑定会话和方向：一条信令不能被搬到别的会话，也不能被原样反射回发送方。
    private static func additionalData(_ session: String, _ direction: RemoteSignalDirection) -> Data {
        Data("uterm-signal-v1\n\(direction.rawValue)\n\(session)".utf8)
    }

    /// 本次会话的握手密钥，从两端的随机数派生。
    static func handshakeKeys(sharedKey: SymmetricKey, phoneNonce: Data, macNonce: Data, session: String,
                              role: RemoteKeySchedule.Role) -> RemoteHandshakeKeys {
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: sharedKey, salt: phoneNonce + macNonce,
                                   info: Data("uterm-session-v1 \(session) \(label)".utf8), outputByteCount: 32)
        }
        let i2r = derive("i2r"), r2i = derive("r2i")
        return role == .initiator ? RemoteHandshakeKeys(send: i2r, receive: r2i)
                                  : RemoteHandshakeKeys(send: r2i, receive: i2r)
    }

    /// 本次会话直连用的密钥。
    static func directKeys(sharedKey: SymmetricKey, phoneNonce: Data, macNonce: Data, session: String,
                           role: RemoteKeySchedule.Role) -> RemoteDirectKeys {
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: sharedKey, salt: phoneNonce + macNonce,
                                   info: Data("uterm-direct-v1 \(session) \(label)".utf8), outputByteCount: 32)
        }
        func pair(_ name: String) -> RemoteDatagramKeys {
            let i2r = derive("\(name)-i2r"), r2i = derive("\(name)-r2i")
            return role == .initiator ? RemoteDatagramKeys(send: i2r, receive: r2i)
                                      : RemoteDatagramKeys(send: r2i, receive: i2r)
        }
        return RemoteDirectKeys(datagram: pair("datagram"), check: pair("check"))
    }
}

/// 拒绝重放：时间差太大的不要，时限内同一个随机数只认一次。
nonisolated struct RemoteSignalReplayGuard {
    static let window: TimeInterval = 120

    private var seen: [Data: TimeInterval] = [:]

    mutating func accept(_ body: RemoteSignalBody, now: TimeInterval) -> Bool {
        guard abs(now - body.sentAt) <= Self.window, body.nonce.count == 32 else { return false }
        seen = seen.filter { now - $0.value <= Self.window * 2 }
        guard seen[body.nonce] == nil else { return false }
        seen[body.nonce] = now
        return true
    }
}

/// Mac 这边处理手机信令的决定。不碰网络，便于把每条安全规则单独测到。
nonisolated struct RemoteSignalResponder {
    /// 手机打完招呼、还没走中继接进来的会话。
    struct PendingSession: Sendable {
        let peer: RemotePeer
        let keys: RemoteHandshakeKeys
        let expiresAt: TimeInterval
    }

    static let sessionLifetime: TimeInterval = 30
    static let maxPendingSessions = 32

    let localKey: Curve25519.KeyAgreement.PrivateKey
    let localID: UUID
    /// 这个设备 ID 对应谁；不认识返回 nil。不认识的设备收不到任何回应。
    let recognize: (UUID) -> RemotePeer?
    /// 这台设备可以经公网接入吗。
    let isAllowed: (UUID) -> Bool

    private var replayGuard = RemoteSignalReplayGuard()
    private var pending: [String: PendingSession] = [:]
    /// 中继诊断的会话：中继回拨时弹回字节，不接进远控。会话 → 过期时刻。
    private var echoSessions: [String: TimeInterval] = [:]

    init(localKey: Curve25519.KeyAgreement.PrivateKey, localID: UUID, recognize: @escaping (UUID) -> RemotePeer?,
         isAllowed: @escaping (UUID) -> Bool) {
        self.localKey = localKey
        self.localID = localID
        self.recognize = recognize
        self.isAllowed = isAllowed
    }

    /// 手机想打洞直连，Mac 要先收集自己的地址才能回复。
    struct DirectOffer: Sendable {
        let peer: RemotePeer
        let handshakeKeys: RemoteHandshakeKeys
        let directKeys: RemoteDirectKeys
        let sharedKey: SymmetricKey
        let remoteDescription: String
        let reply: RemoteSignalBody

        /// 带上（或不带）自己的地址，封好回复。
        func sealedReply(ice: String?, session: String) -> String? {
            var body = reply
            body.ice = ice
            return try? RemoteSignalBox.seal(body, key: sharedKey, session: session, direction: .macToPhone)
        }
    }

    enum OfferDecision {
        /// 不认识、解不开或重放，或者根本不是连接请求：什么都不回。
        case ignore
        /// 现在就能回（没勾选公网接入，或者走中继）。
        case reply(String)
        /// 试试直连。中继那条路同样准备好了，手机打不通可以直接走中继。
        case direct(DirectOffer)
    }

    /// 处理连接请求。`acceptsDirect`：现在还能再开一个打洞尝试吗。
    mutating func receiveOffer(session: String, from: String?, box: String?, now: TimeInterval,
                               acceptsDirect: Bool) -> OfferDecision {
        guard let from, let deviceID = UUID(uuidString: from), let box, let peer = recognize(deviceID),
              let shared = try? RemoteSignalBox.sharedKey(local: localKey, remotePublicKey: peer.publicKey),
              let offer = try? RemoteSignalBox.open(box, key: shared, session: session, direction: .phoneToMac),
              offer.kind == .offer, offer.deviceID == deviceID, replayGuard.accept(offer, now: now) else {
            return .ignore
        }
        pending = pending.filter { $0.value.expiresAt > now }
        var reply = RemoteSignalBody(kind: .answer, deviceID: localID, sentAt: now, nonce: RemoteSignalBody.newNonce())
        guard isAllowed(deviceID) else {
            reply.kind = .denied
            let sealed = try? RemoteSignalBox.seal(reply, key: shared, session: session, direction: .macToPhone)
            return sealed.map(OfferDecision.reply) ?? .ignore
        }
        guard pending.count < Self.maxPendingSessions else { return .ignore }
        let keys = RemoteSignalBox.handshakeKeys(sharedKey: shared, phoneNonce: offer.nonce, macNonce: reply.nonce,
                                                 session: session, role: .responder)
        pending[session] = PendingSession(peer: peer, keys: keys, expiresAt: now + Self.sessionLifetime)
        if acceptsDirect, let description = offer.ice {
            let direct = RemoteSignalBox.directKeys(sharedKey: shared, phoneNonce: offer.nonce, macNonce: reply.nonce,
                                                    session: session, role: .responder)
            return .direct(DirectOffer(peer: peer, handshakeKeys: keys, directKeys: direct, sharedKey: shared,
                                       remoteDescription: description, reply: reply))
        }
        let sealed = try? RemoteSignalBox.seal(reply, key: shared, session: session, direction: .macToPhone)
        return sealed.map(OfferDecision.reply) ?? .ignore
    }

    /// 处理一条信令，返回要回给手机的密封内容。nil = 什么都不回。
    mutating func respond(session: String, from: String?, box: String?, now: TimeInterval) -> String? {
        guard case .reply(let sealed) = receiveOffer(session: session, from: from, box: box, now: now,
                                                     acceptsDirect: false) else { return nil }
        return sealed
    }

    /// 手机要做打洞诊断。
    struct ProbeRequest: Sendable {
        let peer: RemotePeer
        let sharedKey: SymmetricKey
        let remoteDescription: String
    }

    enum ProbeDecision {
        /// 不认识、解不开或重放：什么都不回。
        case ignore
        /// 认识，但没有勾选公网接入。附上要回给手机的密封内容。
        case denied(String)
        case accepted(ProbeRequest)
        /// 中继诊断：会话已登记，附上要回给手机的密封回复。
        case relayEcho(String)
    }

    /// 打洞诊断的门禁和正式连接一样：只回应认识的设备，候选地址（含 Mac 的公网 IP）只给勾选过的设备。
    mutating func receiveProbe(session: String, from: String?, box: String?, now: TimeInterval) -> ProbeDecision {
        guard let from, let deviceID = UUID(uuidString: from), let box, let peer = recognize(deviceID),
              let shared = try? RemoteSignalBox.sharedKey(local: localKey, remotePublicKey: peer.publicKey),
              let offer = try? RemoteSignalBox.open(box, key: shared, session: session, direction: .phoneToMac),
              offer.kind == .iceProbe || offer.kind == .relayProbe, offer.deviceID == deviceID,
              offer.kind == .relayProbe || offer.ice != nil, replayGuard.accept(offer, now: now) else {
            return .ignore
        }
        guard isAllowed(deviceID) else {
            let reply = RemoteSignalBody(kind: .denied, deviceID: localID, sentAt: now, nonce: RemoteSignalBody.newNonce())
            guard let sealed = try? RemoteSignalBox.seal(reply, key: shared, session: session, direction: .macToPhone) else {
                return .ignore
            }
            return .denied(sealed)
        }
        guard offer.kind == .iceProbe, let description = offer.ice else {
            echoSessions = echoSessions.filter { $0.value > now }
            guard echoSessions.count < Self.maxPendingSessions else { return .ignore }
            let reply = RemoteSignalBody(kind: .relayProbeAnswer, deviceID: localID, sentAt: now,
                                         nonce: RemoteSignalBody.newNonce())
            guard let sealed = try? RemoteSignalBox.seal(reply, key: shared, session: session, direction: .macToPhone) else {
                return .ignore
            }
            echoSessions[session] = now + Self.sessionLifetime
            return .relayEcho(sealed)
        }
        return .accepted(ProbeRequest(peer: peer, sharedKey: shared, remoteDescription: description))
    }

    /// 中继说手机为诊断接进来了。一个会话只能接一次。
    mutating func claimEcho(session: String, now: TimeInterval) -> Bool {
        guard let expiresAt = echoSessions.removeValue(forKey: session) else { return false }
        return expiresAt > now
    }

    /// 中继说手机接进来了。一个会话只能接一次。
    mutating func claim(session: String, now: TimeInterval) -> PendingSession? {
        guard let found = pending.removeValue(forKey: session), found.expiresAt > now else { return nil }
        return found
    }
}
