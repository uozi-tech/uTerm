import Foundation
import Crypto

/// 把一段已被 `PrivateKeyImporter` 校验通过的私钥文本，提炼成密钥库要展示的
/// 元数据（类型 / 位数 / 公钥串 / 指纹）。
///
/// 取公钥的两条路径：
///  - **OpenSSH 容器**（`-----BEGIN OPENSSH PRIVATE KEY-----`）：公钥 blob 以明文
///    嵌在文件里，直接抽出来即可——对任何算法（含加口令的）都成立，无需私钥分量。
///  - **PEM**：无内嵌公钥，从 `ParsedPrivateKey` 反推（ed25519 用公钥原始字节，
///    RSA 用 `RSAKeyComponents` 的 e/n）。
///
/// 密钥库模型只表达 ed25519 / rsa（对齐设计稿）；其余算法（ecdsa 等）抛
/// `unsupportedAlgorithm`，由调用方提示用户。
nonisolated enum KeyImportInspector {

    struct Material {
        let type: SSHKeyKind
        let bits: Int
        let publicKey: String
        let fingerprint: String
    }

    enum InspectError: Error { case unsupportedAlgorithm, malformed }

    static func inspect(rawText: String, parsed: ParsedPrivateKey, comment: String) throws -> Material {
        if let blob = openSSHEmbeddedPublicBlob(rawText) {
            return try material(fromBlob: blob, comment: comment)
        }
        // PEM：从解析结果反推。
        switch parsed {
        case .ed25519(let key):
            let blob = SSHPublicMaterial.ed25519Blob(pub: [UInt8](key.publicKey.rawRepresentation))
            return material(type: .ed25519, bits: 256, blob: blob, comment: comment)
        case .rsa(let comps):
            let blob = SSHPublicMaterial.rsaBlob(e: comps.publicExponent, n: comps.modulus)
            return material(type: .rsa, bits: comps.modulus.count * 8, blob: blob, comment: comment)
        case .legacyOpenSSHRSA, .p256, .p384, .p521:
            // 这些要么应已走 OpenSSH 内嵌路径，要么是密钥库不建模的算法。
            throw InspectError.unsupportedAlgorithm
        }
    }

    // MARK: - 私有

    private static func material(type: SSHKeyKind, bits: Int, blob: [UInt8], comment: String) -> Material {
        Material(
            type: type, bits: bits,
            publicKey: SSHPublicMaterial.publicKeyLine(prefix: type == .rsa ? "ssh-rsa" : "ssh-ed25519",
                                                       blob: blob, comment: comment),
            fingerprint: SSHPublicMaterial.fingerprint(of: blob))
    }

    /// 从公钥 blob 的算法标识判定类型与位数。
    private static func material(fromBlob blob: [UInt8], comment: String) throws -> Material {
        var reader = SSHWireReader(blob)
        let algo = String(decoding: (try? reader.readString()) ?? [], as: UTF8.self)
        switch algo {
        case "ssh-ed25519":
            return material(type: .ed25519, bits: 256, blob: blob, comment: comment)
        case "ssh-rsa":
            _ = try? reader.readMPInt()                 // e
            let n = (try? reader.readMPInt()) ?? []     // n（已去前导零的幅值）
            return material(type: .rsa, bits: max(n.count * 8, 0), blob: blob, comment: comment)
        default:
            throw InspectError.unsupportedAlgorithm
        }
    }

    /// 解析 `openssh-key-v1` 容器，抽出明文公钥 blob。失败（非 OpenSSH 格式）返回 nil。
    private static func openSSHEmbeddedPublicBlob(_ text: String) -> [UInt8]? {
        guard text.contains("OPENSSH PRIVATE KEY") else { return nil }
        let b64 = text
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: b64) else { return nil }
        let bytes = [UInt8](data)
        let magic = Array("openssh-key-v1\0".utf8)
        guard bytes.count > magic.count, Array(bytes[0..<magic.count]) == magic else { return nil }
        var reader = SSHWireReader(Array(bytes[magic.count...]))
        do {
            _ = try reader.readString()   // ciphername
            _ = try reader.readString()   // kdfname
            _ = try reader.readString()   // kdfoptions
            _ = try reader.readUInt32()   // num keys
            return try reader.readString() // 第一把公钥 blob
        } catch {
            return nil
        }
    }
}
