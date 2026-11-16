import CryptoKit
import Foundation

// CPace（draft-irtf-cfrg-cpace-21，套件 CPACE-X25519-SHA512）：平衡 PAKE。两端各自从同一个口令
// （新设备上显示的一次性 6 位码）派生同一个生成元，做一次 X25519 交换；口令不对的一方算不出同一把
// ISK，而且抓到双方消息的人也无从离线穷举口令——每猜一次都得真的跟一端跑一轮协议。
//
// CryptoKit 没有 PAKE，也不给任意点上的标量乘法接口，但 X25519 本身只认 u 坐标：把派生出的生成元
// 当成「对端公钥」交给 `Curve25519.KeyAgreement` 就是 draft 要的 `X25519(y, g)`（标量按 RFC 7748
// 钳位、u 坐标清最高位，都由 CryptoKit 做，`CPaceTests` 用 draft 的向量核过）。CryptoKit 缺的只是
// hash-to-curve 那一步（Elligator2 映到 Curve25519 的 u 坐标），所以这里手写了够用的模 2^255−19
// 域运算。
//
// 协议层（谁先发、码几次失败作废、ISK 之后怎么交换长期公钥）不在这里，见
// docs/remote-device-group-design.md §3、§7。

/// CPace 失败的原因。协议层只需要区分「对端消息格式不对」和「这一轮作废」，两者都应当终止这次加入。
nonisolated enum CPaceError: Error, Equatable, Sendable {
    /// 对端发来的公开分量不是 32 字节。
    case malformedShare
    /// `scalar_mult_vfy` 得到中性元（对端发了小阶点或 0）：draft 要求必须中止。
    case invalidShare
}

/// draft §6–§8 的原语，名字与 draft 一一对应，方便对照向量。
nonisolated enum CPace {
    /// G_X25519.DSI。
    static let dsi = Data("CPace255".utf8)
    /// SHA-512 的输入块长（H.s_in_bytes），决定生成元字符串里补零的长度。
    static let hashBlockSize = 128
    /// G_X25519.field_size_bytes：标量、公开分量、K 都是这么长。
    static let fieldSize = 32

    // MARK: 字符串编码（draft §6.3、附录 A.1–A.3）

    /// LEB128 长度前缀 + 原串。
    static func prependLength(_ data: Data) -> Data {
        var length = data.count
        var encoded = Data()
        repeat {
            let low = UInt8(length & 0x7f)
            length >>= 7
            encoded.append(length == 0 ? low : low | 0x80)
        } while length != 0
        return encoded + data
    }

    /// 每段都带长度前缀再拼起来：前缀无歧义，拼接结果不会被换个切法解释成别的输入。
    static func lvCat(_ parts: Data...) -> Data {
        parts.reduce(into: Data()) { $0 += prependLength($1) }
    }

    /// draft 附录 A.3.1：逐字节比，前缀相同时长的大。
    static func lexicographicallyLarger(_ lhs: Data, _ rhs: Data) -> Bool {
        for (a, b) in zip(lhs, rhs) where a != b {
            return a > b
        }
        return lhs.count > rhs.count
    }

    /// 有序拼接：大的在前，前面加 `oc`。两端不论各自是谁都拼出同一个串（对称模式用）。
    static func orderedConcat(_ lhs: Data, _ rhs: Data) -> Data {
        lexicographicallyLarger(lhs, rhs) ? Data("oc".utf8) + lhs + rhs : Data("oc".utf8) + rhs + lhs
    }

    /// 发起方 / 响应方模式的记录：A（发起方）的消息在前。
    static func transcriptIR(ya: Data, ada: Data, yb: Data, adb: Data) -> Data {
        lvCat(ya, ada) + lvCat(yb, adb)
    }

    /// 没有固定先后的记录（两端同时发）。
    static func transcriptOC(ya: Data, ada: Data, yb: Data, adb: Data) -> Data {
        orderedConcat(lvCat(ya, ada), lvCat(yb, adb))
    }

    // MARK: 生成元（draft §8.1、§8.2）

    /// `lv_cat(DSI, PRS, zero_bytes(len_zpad), CI, sid)`：补零让 DSI 与口令正好填满第一个哈希块，
    /// 口令短时要哈希的字节数与口令长短无关（也给侧信道多添一点难度）。
    static func generatorString(dsi: Data, prs: Data, ci: Data, sid: Data, blockSize: Int) -> Data {
        let padding = max(0, blockSize - 1 - prependLength(prs).count - prependLength(dsi).count)
        return lvCat(dsi, prs, Data(count: padding), ci, sid)
    }

    /// 生成元字符串的哈希截成 32 字节，按 RFC 7748 `decodeUCoordinate` 清掉第 255 位
    /// 得到域元素，再用 Elligator2 映成曲线上的 u 坐标。
    static func calculateGenerator(prs: Data, ci: Data, sid: Data) -> Data {
        let string = generatorString(dsi: dsi, prs: prs, ci: ci, sid: sid, blockSize: hashBlockSize)
        let hash = Data(SHA512.hash(data: string).prefix(fieldSize))
        return Data(Elligator2.mapToCurve(Field25519(littleEndian: hash)).bytes)
    }

    // MARK: 标量与标量乘（draft §8.2）

    /// 32 字节均匀随机。钳位交给 X25519 自己做（draft §10.7 说明这样采样对 Curve25519 无损）。
    static func sampleScalar() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    /// G_X25519.I：中性元的编码，32 字节 0。
    static let neutralElement = Data(count: fieldSize)

    /// `scalar_mult`：`X25519(scalar, point)`，结果是中性元时返回 `neutralElement`。
    ///
    /// CryptoKit 收下任意 32 字节当私钥和公钥（不钳位、不校验点），乘之前按 RFC 7748 钳位标量、
    /// 清 u 的第 255 位、把 ≥ p 的 u 按模 p 处理。结果是全 0 时它**不返回 0，而是抛**
    /// `CryptoKitError.underlyingCoreCryptoError(error: -7)`（macOS 27 / Xcode 27 实测，
    /// `CPaceTests.test_cryptokit_throws_instead_of_returning_zero_on_low_order_point`）——
    /// 那一步本来也只会因为这个失败（两个 key 的长度在这之前已经核过），所以这里把它还原成 draft
    /// 的语义：返回中性元，由 `scalarMultVerified` 判。哪天 CryptoKit 改成直接返回 0 也一样成立。
    static func scalarMult(_ scalar: Data, _ point: Data) throws -> Data {
        guard scalar.count == fieldSize, point.count == fieldSize,
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: point)
        else { throw CPaceError.malformedShare }
        guard let secret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else {
            return neutralElement
        }
        return secret.withUnsafeBytes { Data($0) }
    }

    /// `scalar_mult_vfy`：结果是中性元（全 0）就中止。Curve25519 曲线与扭曲线上的小阶点，乘上钳位后
    /// （8 的倍数）的标量都落到 0，所以只查这一条就把它们全挡住了。
    static func scalarMultVerified(_ scalar: Data, _ point: Data) throws -> Data {
        let product = try scalarMult(scalar, point)
        // 不提前退出：不想让比较的耗时随 K 的内容变。
        let accumulated = product.reduce(UInt8(0)) { $0 | $1 }
        guard accumulated != 0 else { throw CPaceError.invalidShare }
        return product
    }

    // MARK: 会话密钥（draft §7.2、§10.4、§10.6）

    /// `ISK = H(lv_cat(DSI ‖ "_ISK", sid, K) ‖ transcript)`，64 字节。
    static func intermediateSessionKey(sid: Data, k: Data, transcript: Data) -> Data {
        Data(SHA512.hash(data: lvCat(dsi + Data("_ISK".utf8), sid, k) + transcript))
    }

    /// 调用方没有 sid 时，跑完之后两端都能算出的公开会话标识（draft §10.6）。
    static func sessionIDOutput(transcript: Data) -> Data {
        Data(SHA512.hash(data: Data("CPaceSidOutput".utf8) + transcript))
    }

    /// 显式确认用的 MAC 密钥 `H(b"CPaceMac" ‖ sid ‖ ISK)`（draft §10.4）。
    static func macKey(sid: Data, isk: Data) -> SymmetricKey {
        SymmetricKey(data: SHA512.hash(data: Data("CPaceMac".utf8) + sid + isk))
    }

    /// 一方的确认标签：对自己发出去的那条消息 `lv_cat(Y, AD)` 做 HMAC-SHA512。
    /// 两个方向的消息本来就不同，标签天然分开，不必再加方向标签。
    static func confirmationTag(macKey: SymmetricKey, share: Data, associatedData: Data) -> Data {
        Data(HMAC<SHA512>.authenticationCode(for: lvCat(share, associatedData), using: macKey))
    }
}

// MARK: - 高层接口

/// 一端的一次 CPace。用法：两端各建一个会话、互发 `publicShare` 与 `associatedData`，
/// 收到对方的那一份后 `finish`，再互发 `CPaceKeys.localConfirmation`，各自 `verifyPeerConfirmation`。
/// 确认通过之前 ISK 不能用来做任何对外可见的事：口令错的一方此时与正确的一方算出的是两把无关的钥匙。
nonisolated struct CPaceSession: Sendable {
    enum Role: Sendable {
        /// 发起方（draft 里的 A）：记录里自己的消息在前。
        case initiator
        /// 响应方（B）。
        case responder
        /// 没有固定先后，记录用有序拼接。两端的 `associatedData` 必须互不相同（draft §10.1.1）。
        case symmetric
    }

    let role: Role
    let sessionID: Data
    /// 自己这一端的 AD，随 `publicShare` 一起明文发给对方。
    let associatedData: Data
    /// 发给对方的 Y = X25519(y, g)。
    let publicShare: Data
    private let scalar: Data

    /// - Parameters:
    ///   - password: 口令（PRS）。
    ///   - channelIdentifier: CI：两端事先都知道、要绑进生成元的上下文（协议名与版本、双方身份），
    ///     不上线路；任何一位对不上就等于口令不对。
    ///   - sessionID: sid：这一轮独有的值，两端必须一致（可以明文传）。
    ///   - associatedData: 自己的 AD，明文随消息发出，进记录。
    init(role: Role, password: Data, channelIdentifier: Data, sessionID: Data,
         associatedData: Data = Data()) throws {
        try self.init(role: role, password: password, channelIdentifier: channelIdentifier,
                      sessionID: sessionID, associatedData: associatedData, scalar: CPace.sampleScalar())
    }

    /// 测试用：指定标量，好对 draft 的向量。
    init(role: Role, password: Data, channelIdentifier: Data, sessionID: Data,
         associatedData: Data, scalar: Data) throws {
        self.role = role
        self.sessionID = sessionID
        self.associatedData = associatedData
        self.scalar = scalar
        let generator = CPace.calculateGenerator(prs: password, ci: channelIdentifier, sid: sessionID)
        // draft 里 scalar_mult 不检查结果；自己的 Y 是 0 只可能是哈希恰好落在小阶点上（可忽略），
        // 真碰上了也该中止而不是发个 0 出去。
        publicShare = try CPace.scalarMultVerified(scalar, generator)
    }

    /// 收到对方的 Y 与 AD 后得出 ISK。对方发来小阶点、0 或长度不对都抛错，这一轮作废。
    func finish(peerShare: Data, peerAssociatedData: Data) throws -> CPaceKeys {
        guard peerShare.count == CPace.fieldSize else { throw CPaceError.malformedShare }
        let k = try CPace.scalarMultVerified(scalar, peerShare)
        let transcript: Data
        switch role {
        case .initiator:
            transcript = CPace.transcriptIR(ya: publicShare, ada: associatedData,
                                            yb: peerShare, adb: peerAssociatedData)
        case .responder:
            transcript = CPace.transcriptIR(ya: peerShare, ada: peerAssociatedData,
                                            yb: publicShare, adb: associatedData)
        case .symmetric:
            transcript = CPace.transcriptOC(ya: publicShare, ada: associatedData,
                                            yb: peerShare, adb: peerAssociatedData)
        }
        let isk = CPace.intermediateSessionKey(sid: sessionID, k: k, transcript: transcript)
        let macKey = CPace.macKey(sid: sessionID, isk: isk)
        return CPaceKeys(
            isk: isk,
            localConfirmation: CPace.confirmationTag(macKey: macKey, share: publicShare,
                                                     associatedData: associatedData),
            expectedPeerConfirmation: CPace.confirmationTag(macKey: macKey, share: peerShare,
                                                            associatedData: peerAssociatedData)
        )
    }
}

/// 一轮 CPace 的结果。K 不出这个类型（draft §10.3：泄露 K 等于给了离线穷举口令的机会）。
nonisolated struct CPaceKeys: Sendable {
    /// 中间会话密钥，64 字节。别直接当对称密钥用，经 `deriveKey` 派生。
    let isk: Data
    /// 发给对方的确认标签。
    let localConfirmation: Data
    fileprivate let expectedPeerConfirmation: Data

    /// 对方的确认标签对不对。错了说明口令、CI、sid 或双方看到的消息有一处不同，这一轮必须作废。
    func verifyPeerConfirmation(_ tag: Data) -> Bool {
        constantTimeEqual(tag, expectedPeerConfirmation)
    }

    /// 从 ISK 派生用途专属的对称密钥（HKDF-SHA512，info 区分用途）。
    func deriveKey(info: Data, outputByteCount: Int = 32) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: isk), info: info,
                               outputByteCount: outputByteCount)
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// MARK: - Elligator2（RFC 9380 §6.7.1，curve25519：J = 486662，K = 1，Z = 2）

nonisolated enum Elligator2 {
    static let j = Field25519(486_662)
    static let z = Field25519(2)

    /// 把任意域元素映成 Curve25519 上一点的 u 坐标（v 坐标 CPace 用不到，不算）。
    /// 照 RFC 9380 的直线写法，没有随输入走的分支：选哪个候选靠掩码。
    static func mapToCurve(_ r: Field25519) -> Field25519 {
        let one = Field25519(1)
        let minusJ = Field25519.zero - j
        // x1 = −J / (1 + Z·r²)；分母为 0（Curve25519 上不会发生：−1/Z 不是平方）时 inv0 给 0，退回 −J。
        let denominator = one + z * r.squared()
        var x1 = minusJ * denominator.inverted()
        x1 = Field25519.select(x1, minusJ, when: x1.isZero)
        // g(x1) = x1³ + J·x1² + x1
        let gx1 = x1 * (x1 * (x1 + j) + one)
        let x2 = Field25519.zero - x1 - j
        return Field25519.select(x2, x1, when: gx1.isSquare)
    }
}

// MARK: - 模 p = 2^255 − 19 的域运算

/// 只为 Elligator2 准备的最小实现：16 个 16 位的肢（TweetNaCl 的 gf 表示），乘法后做两轮进位。
/// 求逆和判平方剩余都是按公开指数做的平方-乘，不随底数（秘密）走分支；正确与清晰优先，速度够用
/// （一次映射几百次乘法）。
nonisolated struct Field25519: Sendable {
    fileprivate var limbs: [Int64]

    static let zero = Field25519(0)

    /// 小整数常量。
    init(_ value: Int64) {
        precondition(value >= 0 && value < 1 << 32)
        limbs = [Int64](repeating: 0, count: 16)
        limbs[0] = value & 0xffff
        limbs[1] = value >> 16
    }

    /// RFC 7748 `decodeUCoordinate`：32 字节小端，忽略第 255 位。不要求小于 p，非规范值照常参与运算。
    init(littleEndian bytes: Data) {
        precondition(bytes.count == 32)
        let b = [UInt8](bytes)
        limbs = (0..<16).map { Int64(b[2 * $0]) | Int64(b[2 * $0 + 1]) << 8 }
        limbs[15] &= 0x7fff
    }

    private init(limbs: [Int64]) {
        self.limbs = limbs
    }

    /// 规范（< p）的 32 字节小端编码。
    var bytes: [UInt8] {
        var t = limbs
        Self.carry(&t)
        Self.carry(&t)
        Self.carry(&t)
        // 减两次 p，借位决定要不要留下差值。
        for _ in 0..<2 {
            var m = [Int64](repeating: 0, count: 16)
            m[0] = t[0] - 0xffed
            for i in 1..<15 {
                m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
                m[i - 1] &= 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
            let borrow = (m[15] >> 16) & 1
            m[14] &= 0xffff
            t = Self.select(Field25519(limbs: t), Field25519(limbs: m), when: 1 - borrow).limbs
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<16 {
            out[2 * i] = UInt8(t[i] & 0xff)
            out[2 * i + 1] = UInt8((t[i] >> 8) & 0xff)
        }
        return out
    }

    /// 1 表示是 0，否则 0。
    var isZero: Int64 {
        let accumulated = bytes.reduce(UInt8(0)) { $0 | $1 }
        return Int64((Int(accumulated) - 1) >> 8) & 1
    }

    /// 1 表示是平方剩余（含 0），否则 0。Legendre 符号 x^((p−1)/2) 只会是 0、1 或 −1。
    var isSquare: Int64 {
        let legendre = power(Self.halfPMinusOne)
        let minusOne = Field25519.zero - Field25519(1)
        return 1 - (legendre - minusOne).isZero
    }

    func squared() -> Field25519 { self * self }

    /// x^(p−2)；0 的「逆」是 0（RFC 9380 的 inv0）。
    func inverted() -> Field25519 { power(Self.pMinusTwo) }

    /// 平方-乘，指数是公开常量（小端字节）。
    func power(_ exponent: [UInt8]) -> Field25519 {
        var result = Field25519(1)
        for byte in exponent.reversed() {
            for bit in (0..<8).reversed() {
                result = result.squared()
                if (byte >> bit) & 1 == 1 {
                    result = result * self
                }
            }
        }
        return result
    }

    /// flag 为 1 取 b，为 0 取 a；按掩码选，不分支。
    static func select(_ a: Field25519, _ b: Field25519, when flag: Int64) -> Field25519 {
        let mask = -flag
        return Field25519(limbs: (0..<16).map { a.limbs[$0] ^ (mask & (a.limbs[$0] ^ b.limbs[$0])) })
    }

    static func + (lhs: Field25519, rhs: Field25519) -> Field25519 {
        var out = Field25519(limbs: (0..<16).map { lhs.limbs[$0] + rhs.limbs[$0] })
        carry(&out.limbs)
        return out
    }

    static func - (lhs: Field25519, rhs: Field25519) -> Field25519 {
        var out = Field25519(limbs: (0..<16).map { lhs.limbs[$0] - rhs.limbs[$0] })
        carry(&out.limbs)
        return out
    }

    static func * (lhs: Field25519, rhs: Field25519) -> Field25519 {
        var t = [Int64](repeating: 0, count: 31)
        for i in 0..<16 {
            for j in 0..<16 {
                t[i + j] += lhs.limbs[i] * rhs.limbs[j]
            }
        }
        // 2^256 ≡ 38 (mod p)：第 16 肢以上折回低位。
        for i in 0..<15 {
            t[i] += 38 * t[i + 16]
        }
        var out = Array(t[0..<16])
        carry(&out)
        carry(&out)
        return Field25519(limbs: out)
    }

    /// 每肢留 16 位，进位往上推，最高肢溢出的部分 ×38 折回第 0 肢。
    private static func carry(_ o: inout [Int64]) {
        for i in 0..<16 {
            o[i] += 1 << 16
            let c = o[i] >> 16
            if i < 15 {
                o[i + 1] += c - 1
            } else {
                o[0] += 38 * (c - 1)
            }
            o[i] -= c << 16
        }
    }

    /// p − 2 = 2^255 − 21。
    private static let pMinusTwo: [UInt8] = [0xeb] + [UInt8](repeating: 0xff, count: 30) + [0x7f]
    /// (p − 1) / 2 = 2^254 − 10。
    private static let halfPMinusOne: [UInt8] = [0xf6] + [UInt8](repeating: 0xff, count: 30) + [0x3f]
}

nonisolated extension Field25519: Equatable {
    static func == (lhs: Field25519, rhs: Field25519) -> Bool { lhs.bytes == rhs.bytes }
}
