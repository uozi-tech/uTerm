import Foundation
import Crypto

/// 把一段已被 `PrivateKeyImporter` 校验通过的私钥文本，提炼成密钥库要展示的
/// 元数据（类型 / 位数 / 公钥串 / 指纹）。
///
/// 取公钥的两条路径：
///  - **OpenSSH 容器**（`-----BEGIN OPENSSH PRIVATE KEY-----`）：公钥 blob 以明文
///    嵌在文件里，直接抽出来即可——对任何算法（含加口令的）都成立，无需私钥分量。
///  - **PEM**：无内嵌公钥，从 `ParsedPrivateKey` 反推（ed25519 用公钥原始字节，
///    RSA 用 `RSAKeyComponents` 的 e/n，ECDSA 用 X9.63 公钥点）。
///
/// 密钥库模型表达 ed25519 / rsa / ecdsa；DSA 等旧算法抛 `unsupportedAlgorithm`，
/// 由调用方提示用户。
public nonisolated enum KeyImportInspector {

    public struct Material: Sendable {
        public let type: SSHPrivateKeyKind
        public let bits: Int
        public let publicKey: String
        public let fingerprint: String
    }

    public enum InspectError: Error { case unsupportedAlgorithm, malformed }

    public static func inspect(
        rawText: String,
        parsed key: SSHPrivateKey,
        comment: String
    ) throws -> Material {
        try inspectParsed(rawText: rawText, parsed: key.parsed, comment: comment)
    }

    static func inspect(
        rawText: String,
        parsed: ParsedPrivateKey,
        comment: String
    ) throws -> Material {
        try inspectParsed(rawText: rawText, parsed: parsed, comment: comment)
    }

    private static func inspectParsed(
        rawText: String,
        parsed: ParsedPrivateKey,
        comment: String
    ) throws -> Material {
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
        case .p256(let key):
            let blob = SSHPublicMaterial.ecdsaBlob(
                algorithm: "ecdsa-sha2-nistp256",
                curve: "nistp256",
                publicKey: [UInt8](key.publicKey.x963Representation))
            return material(type: .ecdsaP256, bits: 256, blob: blob, comment: comment)
        case .p384(let key):
            let blob = SSHPublicMaterial.ecdsaBlob(
                algorithm: "ecdsa-sha2-nistp384",
                curve: "nistp384",
                publicKey: [UInt8](key.publicKey.x963Representation))
            return material(type: .ecdsaP384, bits: 384, blob: blob, comment: comment)
        case .p521(let key):
            let blob = SSHPublicMaterial.ecdsaBlob(
                algorithm: "ecdsa-sha2-nistp521",
                curve: "nistp521",
                publicKey: [UInt8](key.publicKey.x963Representation))
            return material(type: .ecdsaP521, bits: 521, blob: blob, comment: comment)
        case .legacyOpenSSHRSA:
            // OpenSSH RSA 应已走容器内嵌公钥路径。
            throw InspectError.unsupportedAlgorithm
        }
    }

    // MARK: - 私有

    private static func material(type: SSHPrivateKeyKind, bits: Int, blob: [UInt8], comment: String) -> Material {
        Material(
            type: type, bits: bits,
            publicKey: SSHPublicMaterial.publicKeyLine(prefix: publicKeyPrefix(for: type),
                                                       blob: blob, comment: comment),
            fingerprint: SSHPublicMaterial.fingerprint(of: blob))
    }

    private static func publicKeyPrefix(for type: SSHPrivateKeyKind) -> String {
        switch type {
        case .ed25519:   return "ssh-ed25519"
        case .rsa:       return "ssh-rsa"
        case .ecdsaP256: return "ecdsa-sha2-nistp256"
        case .ecdsaP384: return "ecdsa-sha2-nistp384"
        case .ecdsaP521: return "ecdsa-sha2-nistp521"
        }
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
        case "ecdsa-sha2-nistp256":
            return try ecdsaMaterial(blob: blob, reader: &reader, expectedCurve: "nistp256",
                                     type: .ecdsaP256, bits: 256, comment: comment)
        case "ecdsa-sha2-nistp384":
            return try ecdsaMaterial(blob: blob, reader: &reader, expectedCurve: "nistp384",
                                     type: .ecdsaP384, bits: 384, comment: comment)
        case "ecdsa-sha2-nistp521":
            return try ecdsaMaterial(blob: blob, reader: &reader, expectedCurve: "nistp521",
                                     type: .ecdsaP521, bits: 521, comment: comment)
        default:
            throw InspectError.unsupportedAlgorithm
        }
    }

    private static func ecdsaMaterial(blob: [UInt8], reader: inout SSHWireReader,
                                      expectedCurve: String, type: SSHPrivateKeyKind,
                                      bits: Int, comment: String) throws -> Material {
        let curve = String(decoding: try reader.readString(), as: UTF8.self)
        guard curve == expectedCurve else { throw InspectError.malformed }
        _ = try reader.readString() // Q: SEC1/X9.63 public point
        return material(type: type, bits: bits, blob: blob, comment: comment)
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
