import CryptoKit
import Foundation

/// 远控握手的密钥派生。
///
/// 两端各有一把长期密钥（static，配对时互相记住）和每条连接新生成的临时密钥（ephemeral）。
/// 会话密钥 = HKDF(ee ‖ es ‖ se，盐 = SHA256(握手记录))：
/// - `ee` 给前向保密：长期密钥日后泄露也解不开录下来的旧流量；
/// - `es` / `se` 把双方的长期密钥绑进去：只有持有对应长期私钥的一方才算得出同一把密钥，
///   所以「已配对」的连接不需要再额外签名，第一帧密文能解开就证明了对方身份（相当于 Noise KK）。
///
/// 配对时还没互相记住长期公钥，靠**核对码**防中间人：它同样从握手记录派生，中间人替换了
/// 任何一方的公钥，两端屏幕上的 6 位数字就对不上。与局域网同步那套「6 位配对码当盐」不同，
/// 这里的 6 位数不参与密钥派生，抓到握手包也无从离线穷举。
nonisolated enum RemoteKeySchedule {
    enum Role: Sendable {
        /// 发起连接的一方（手机）。
        case initiator
        /// 接受连接的一方（Mac）。
        case responder
    }

    static func derive(
        role: Role,
        localStatic: Curve25519.KeyAgreement.PrivateKey,
        localEphemeral: Curve25519.KeyAgreement.PrivateKey,
        remoteHello: RemoteHello,
        transcript: Data
    ) throws -> RemoteSessionKeys {
        let remoteEphemeral: Curve25519.KeyAgreement.PublicKey
        let remoteStatic: Curve25519.KeyAgreement.PublicKey
        do {
            remoteEphemeral = try .init(rawRepresentation: remoteHello.ephemeralKey)
            remoteStatic = try .init(rawRepresentation: remoteHello.staticKey)
        } catch {
            throw RemoteProtocolError.handshakeFailed("对端公钥无效")
        }
        let ee = try agree(localEphemeral, remoteEphemeral)
        // es 恒为「发起方临时 × 响应方长期」，se 恒为「发起方长期 × 响应方临时」，两端各自用
        // 自己手里的那一半算出同一个值。
        let es: Data
        let se: Data
        switch role {
        case .initiator:
            es = try agree(localEphemeral, remoteStatic)
            se = try agree(localStatic, remoteEphemeral)
        case .responder:
            es = try agree(localStatic, remoteEphemeral)
            se = try agree(localEphemeral, remoteStatic)
        }
        let material = SymmetricKey(data: ee + es + se)
        let salt = Data(SHA256.hash(data: transcript))
        func key(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt,
                                   info: Data("uTerm remote v1 \(label)".utf8), outputByteCount: 32)
        }
        let initiatorToResponder = key("i2r")
        let responderToInitiator = key("r2i")
        let codeBytes = key("verification").withUnsafeBytes { Array($0.prefix(4)) }
        let codeValue = codeBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        return RemoteSessionKeys(
            send: role == .initiator ? initiatorToResponder : responderToInitiator,
            receive: role == .initiator ? responderToInitiator : initiatorToResponder,
            verificationCode: String(format: "%06u", codeValue)
        )
    }

    private static func agree(_ privateKey: Curve25519.KeyAgreement.PrivateKey,
                              _ publicKey: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let bytes = secret.withUnsafeBytes { Data($0) }
        // 小阶点会让共享秘密退化成全 0，任何人都算得出来。
        guard bytes.contains(where: { $0 != 0 }) else {
            throw RemoteProtocolError.handshakeFailed("对端公钥无效")
        }
        return bytes
    }
}

nonisolated struct RemoteSessionKeys: Sendable {
    let send: SymmetricKey
    let receive: SymmetricKey
    /// 6 位核对码，两端屏幕上显示的应当相同。
    let verificationCode: String
}

/// 单方向的帧加密：ChaChaPoly，nonce = 4 字节 0 + 8 字节大端帧序号。
///
/// 序号两端各自计数、不上线：丢帧、重放、乱序都会让 nonce 对不上而校验失败，连接随即断开。
/// TCP 保证有序且不丢，所以正常情况下不会误伤。每帧只多 16 字节 tag。
nonisolated struct RemoteCipher: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nextNonce())
        return box.ciphertext + box.tag
    }

    mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw RemoteProtocolError.decryptionFailed }
        do {
            let split = sealed.endIndex - 16
            let box = try ChaChaPoly.SealedBox(nonce: nextNonce(), ciphertext: sealed[sealed.startIndex..<split],
                                               tag: sealed[split...])
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw RemoteProtocolError.decryptionFailed
        }
    }

    private mutating func nextNonce() throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 {
            bytes[4 + i] = UInt8(truncatingIfNeeded: counter >> (56 - 8 * UInt64(i)))
        }
        counter &+= 1
        return try ChaChaPoly.Nonce(data: bytes)
    }
}
