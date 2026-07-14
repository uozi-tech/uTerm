import Foundation
import Crypto

/// 由公钥 wire-format blob 派生展示用材料（公钥串 + `SHA256:` 指纹），
/// 以及组装各算法的公钥 blob。生成（`SSHKeyGenerator`）与导入
/// （`KeyImportInspector`）共用，保证两条路径产出格式一致。
nonisolated enum SSHPublicMaterial {

    static func ed25519Blob(pub: [UInt8]) -> [UInt8] {
        var w = SSHWireWriter()
        w.writeString("ssh-ed25519")
        w.writeString(pub)
        return w.bytes
    }

    static func rsaBlob(e: [UInt8], n: [UInt8]) -> [UInt8] {
        var w = SSHWireWriter()
        w.writeString("ssh-rsa")
        w.writeMPInt(e)
        w.writeMPInt(n)
        return w.bytes
    }

    static func ecdsaBlob(algorithm: String, curve: String, publicKey: [UInt8]) -> [UInt8] {
        var w = SSHWireWriter()
        w.writeString(algorithm)
        w.writeString(curve)
        w.writeString(publicKey)
        return w.bytes
    }

    /// `<prefix> <base64(blob)> <comment>`。
    static func publicKeyLine(prefix: String, blob: [UInt8], comment: String) -> String {
        let b64 = Data(blob).base64EncodedString()
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(prefix) \(b64)" : "\(prefix) \(b64) \(trimmed)"
    }

    /// `SHA256:<base64-no-padding(sha256(blob))>` —— 与 `ssh-keygen -lf` 一致。
    static func fingerprint(of blob: [UInt8]) -> String {
        let digest = SHA256.hash(data: Data(blob))
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }
}
