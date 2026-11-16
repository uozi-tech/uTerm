import CryptoKit
import Foundation

// 设备组里的 Mac（docs/remote-device-group-design.md §7.2）：名册里的 `host` 与 `grant` 两种记录，
// 以及 `grant` 里只有对象组员打得开的中继包。
//
// - `host.<Mac>.<签名者>`：一台 Mac 的公开信息，由配对过它的组员签。只用来显示「组里有哪些 Mac、本机还没通的是
//   哪几台」，不凭它连接。
// - `grant.<组员>.<Mac>.<签名者>`：这台 Mac 对这台组员的开通结果，由去问的组员签。结果本身谁都能读（组里的设备
//   靠它知道「已经有人问过了」），只有中继配置（Mac 发给那台组员的成员证书，含私钥）封给那台组员。
//
// 两种记录都只认「我认的组员」签的（`RemoteGroupMembership.Signers`），签名本身在解码时验。

/// 一台 Mac 的公开信息：`host` 与 `grant` 里带的那一份。
nonisolated struct RemoteGroupHostInfo: Codable, Equatable, Hashable, Sendable {
    /// Mac 的远控设备 ID（握手里报的 `deviceID`）。
    var id: UUID
    var name: String
    /// Mac 的远控长期公钥（X25519 原始 32 字节）。
    var publicKey: Data
    var model: String?
    /// `RemoteDevicePlatform` 的原始值。
    var platform: String?

    var hasValidKey: Bool { publicKey.count == RemoteGroupFormat.keyLength }
}

nonisolated extension RemoteGroupCanonical {
    mutating func append(_ host: RemoteGroupHostInfo) {
        append(host.id)
        append(host.name)
        append(host.publicKey)
        appendOptional(host.model)
        appendOptional(host.platform)
    }

    /// 先记有没有（一个字节），有再记内容：nil 与空数据分得开。
    mutating func appendOptional(_ data: Data?) {
        guard let data else { return append(Data([0])) }
        append(Data([1]))
        append(data)
    }

    /// nil / false / true 各不相同。
    mutating func appendOptional(_ flag: Bool?) {
        guard let flag else { return append(Data([0])) }
        append(Data([1]))
        append(Data([flag ? 1 : 0]))
    }
}

/// 「我配对过这台 Mac」：组的 Mac 目录里的一项。
nonisolated struct RemoteGroupHost: Codable, Equatable, Sendable {
    static let label = "uTerm device-group host v1"

    var host: RemoteGroupHostInfo
    var signer: UUID
    var signerKey: Data
    /// 签名的时间：取「现在」与签名者自己进组时间里晚的那个（同 `RemoteGroupAdmit.signedAt`）。
    var signedAt: RemoteGroupTime
    var signature: Data

    var account: String { Self.account(host: host.id, signer: signer) }

    static func account(host: UUID, signer: UUID) -> String {
        "host.\(host.uuidString).\(signer.uuidString)"
    }

    /// 签名覆盖除签名之外的每个字段。
    var signedBytes: Data {
        var canonical = RemoteGroupCanonical(label: Self.label)
        canonical.append(host)
        canonical.append(signer)
        canonical.append(signerKey)
        canonical.append(signedAt)
        return canonical.bytes
    }

    static func make(host: RemoteGroupHostInfo, signer: RemoteGroupDevice, signedAt: RemoteGroupTime,
                     key: Curve25519.Signing.PrivateKey) throws -> RemoteGroupHost {
        var record = RemoteGroupHost(host: host, signer: signer.id, signerKey: signer.signingKey, signedAt: signedAt,
                                     signature: Data())
        record.signature = try key.signature(for: record.signedBytes)
        return record
    }

    var hasValidSignature: Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signerKey) else { return false }
        return key.isValidSignature(signature, for: signedBytes)
    }
}

/// 一台 Mac 对一台组员的开通结果，由去问的组员签。
nonisolated struct RemoteGroupHostGrant: Codable, Equatable, Sendable {
    static let label = "uTerm device-group grant v1"

    /// 对象组员：ID 与两把钥匙。Mac 记下的就是这个 ID 与这把 X25519 公钥。
    var deviceID: UUID
    var publicKey: Data
    var signingKey: Data
    var host: RemoteGroupHostInfo
    /// `RemoteVouchResult.Outcome` 的原始值，另加 `RemoteGroupGrant.unsupported`（Mac 版本太旧，没问）。
    var outcome: String
    var reason: String?
    var internetAccess: Bool?
    /// 封给对象组员的中继配置（`RemoteGroupRelaySeal`）。Mac 没发、担保者也没给这台 Mac 单独记中继时为 nil。
    var relay: Data?
    var signer: UUID
    var signerKey: Data
    var signedAt: RemoteGroupTime
    var signature: Data

    var account: String { Self.account(device: deviceID, host: host.id, signer: signer) }

    static func account(device: UUID, host: UUID, signer: UUID) -> String {
        "grant.\(device.uuidString).\(host.uuidString).\(signer.uuidString)"
    }

    var signedBytes: Data {
        var canonical = RemoteGroupCanonical(label: Self.label)
        canonical.append(deviceID)
        canonical.append(publicKey)
        canonical.append(signingKey)
        canonical.append(host)
        canonical.append(outcome)
        canonical.appendOptional(reason)
        canonical.appendOptional(internetAccess)
        canonical.appendOptional(relay)
        canonical.append(signer)
        canonical.append(signerKey)
        canonical.append(signedAt)
        return canonical.bytes
    }

    static func make(device: RemoteGroupDevice, host: RemoteGroupHostInfo, outcome: String, reason: String?,
                     internetAccess: Bool?, relay: Data?, signer: RemoteGroupDevice, signedAt: RemoteGroupTime,
                     key: Curve25519.Signing.PrivateKey) throws -> RemoteGroupHostGrant {
        var grant = RemoteGroupHostGrant(deviceID: device.id, publicKey: device.publicKey, signingKey: device.signingKey,
                                         host: host, outcome: outcome, reason: reason, internetAccess: internetAccess,
                                         relay: relay, signer: signer.id, signerKey: signer.signingKey, signedAt: signedAt,
                                         signature: Data())
        grant.signature = try key.signature(for: grant.signedBytes)
        return grant
    }

    var hasValidSignature: Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signerKey) else { return false }
        return key.isValidSignature(signature, for: signedBytes)
    }

    /// 对象就是这台设备（ID 与两把钥匙都对得上）。
    func isFor(_ device: RemoteGroupDevice) -> Bool {
        deviceID == device.id && publicKey == device.publicKey && signingKey == device.signingKey
    }

    /// 结果是针对这台 Mac 此刻的身份的（Mac 重装过、换了钥匙，旧结果就不算）。
    func isAbout(_ host: UUID, key: Data) -> Bool {
        self.host.id == host && self.host.publicKey == key
    }

    var isUsable: Bool { plain(relay: nil).isUsable }
    /// 有定论：Mac 记下了、早就认识、明确拒绝。不允许、版本太旧过一阵再问。
    var isFinal: Bool { plain(relay: nil).isFinal }

    /// 交给 `RemoteGroupHostAccess.adopt` 的明文。中继包由收的一方自己打开。
    func plain(relay: RemoteRelayConfig?) -> RemoteGroupGrant {
        RemoteGroupGrant(hostID: host.id, hostName: host.name, hostKey: host.publicKey, hostModel: host.model,
                         hostPlatform: host.platform, outcome: outcome, reason: reason, internetAccess: internetAccess,
                         relay: relay)
    }
}

/// `grant` 里的中继包：X25519(签名者的远控私钥, 对象组员的远控公钥) 经 HKDF 派生的钥匙，ChaChaPoly。
/// 只有这两台算得出来；附加数据绑定用途、两台设备和 Mac 的 ID，一个包搬不到别的记录上。
nonisolated enum RemoteGroupRelaySeal {
    static let label = "uTerm device-group grant relay v1"

    /// 两台设备之间的钥匙。对方公钥不合法、或协商出全 0（小阶点）时抛错。
    static func key(local: Curve25519.KeyAgreement.PrivateKey, remote: Data) throws -> SymmetricKey {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote)
        let secret = try local.sharedSecretFromKeyAgreement(with: publicKey)
        let bytes = secret.withUnsafeBytes { Data($0) }
        guard bytes.contains(where: { $0 != 0 }) else { throw RemoteSignalError.invalidKey }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: Data(label.utf8),
                                      info: Data("relay".utf8), outputByteCount: 32)
    }

    static func additionalData(signer: UUID, target: UUID, host: UUID) -> Data {
        var canonical = RemoteGroupCanonical(label: label)
        canonical.append(signer)
        canonical.append(target)
        canonical.append(host)
        return canonical.bytes
    }

    static func seal(_ relay: RemoteRelayConfig, key: SymmetricKey, signer: UUID, target: UUID,
                     host: UUID) throws -> Data {
        let plain = try JSONEncoder().encode(relay)
        return try ChaChaPoly.seal(plain, using: key,
                                   authenticating: additionalData(signer: signer, target: target, host: host)).combined
    }

    /// 打不开（不是封给本机的、被改过、绑的不是这几台）返回 nil。
    static func open(_ box: Data, key: SymmetricKey, signer: UUID, target: UUID, host: UUID) -> RemoteRelayConfig? {
        guard let sealed = try? ChaChaPoly.SealedBox(combined: box),
              let plain = try? ChaChaPoly.open(sealed, using: key,
                                               authenticating: additionalData(signer: signer, target: target, host: host))
        else { return nil }
        return try? JSONDecoder().decode(RemoteRelayConfig.self, from: plain)
    }
}
