import Foundation
import SwiftData

/// 密钥算法类型。以 rawValue 持久化（同 `AuthMethod` 的 CloudKit 取舍）。
enum SSHKeyKind: String, CaseIterable, Sendable {
    case ed25519
    case rsa
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521

    /// 列表 / 详情里的算法标签，如 `ed25519` 或 `rsa 4096`。
    nonisolated func label(bits: Int) -> String {
        switch self {
        case .ed25519:  return "ed25519"
        case .rsa:      return "rsa \(bits)"
        case .ecdsaP256: return "ecdsa p256"
        case .ecdsaP384: return "ecdsa p384"
        case .ecdsaP521: return "ecdsa p521"
        }
    }
}

/// 密钥库里的一把 SSH 密钥。设计稿 `keys.jsx` 的 `KEYS_SEED` 模型在 SwiftData 里的落地。
///
/// 私钥**正文不入库** —— 它（以及导入密钥可能带的口令）按 `id` 存进 `KeychainStore`
/// （account = `id/privateKey`、`id/passphrase`），与 `ServerProfile` 的密钥存储同构。
/// 模型只保存可公开展示的元数据（指纹 / 公钥 / 注释 / 时间）。
///
/// CloudKit 约束：所有属性有默认值或可空，无 `@Attribute(.unique)`。
@Model
final class SSHKey {
    var id: UUID = UUID()
    var name: String = ""
    /// `SSHKeyKind` 的 rawValue，通过 `type` 计算属性读写。
    var typeRaw: String = SSHKeyKind.ed25519.rawValue
    /// 位数：ed25519 恒 256；rsa 为 2048 / 3072 / 4096；ecdsa 为曲线位数。
    var bits: Int = 256
    /// 公钥末尾注释（如 `sz@laptop`）。
    var comment: String = ""
    /// `SHA256:...` 指纹。
    var fingerprint: String = ""
    /// 完整 OpenSSH 公钥串（`ssh-ed25519 AAAA... comment`）。
    var publicKey: String = ""
    var createdAt: Date = Date()
    /// 最近一次被用于连接的时间。连接成功后由调用方赋值；从未用过为 nil。
    var lastUsedAt: Date?
    /// 导入的私钥是否自带口令（生成的密钥恒 false —— 明文存钟匙串）。
    var hasPassphrase: Bool = false

    init() {}

    var type: SSHKeyKind {
        get { SSHKeyKind(rawValue: typeRaw) ?? .ed25519 }
        set { typeRaw = newValue.rawValue }
    }

    /// 算法 + 位数标签，如 `ed25519` / `rsa 4096`。
    var typeLabel: String { type.label(bits: bits) }
}
