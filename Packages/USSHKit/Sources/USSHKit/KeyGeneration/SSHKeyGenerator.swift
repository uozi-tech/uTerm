import Foundation
import Crypto
import Security

/// 进程内生成 SSH 密钥。app 开了 sandbox（仅 `files.user-selected.read-only`），
/// 不能 `exec ssh-keygen`，故全部用纯 Swift 完成：
///  - **ed25519**：`Curve25519.Signing.PrivateKey`（swift-crypto）→ 手写 **未加密**
///    `openssh-key-v1` 私钥容器；
///  - **rsa**：`SecKeyCreateRandomKey` → PKCS#1 DER → `BEGIN RSA PRIVATE KEY` PEM。
///  - **ecdsa**：`P256/P384/P521.Signing.PrivateKey` → 手写 **未加密**
///    `openssh-key-v1` 私钥容器。
///
/// 生成的私钥不加口令（靠钟匙串加密），公钥串与 `SHA256:` 指纹自算。产物文本可被
/// `PrivateKeyImporter.resolve(pem:passphrase:)` 原样回读，连接路径无需特判。
public nonisolated enum SSHKeyGenerator {

    public struct GeneratedKey: Sendable {
        public let privateKeyText: String   // OpenSSH 或 PEM，明文
        public let publicKey: String        // `ssh-... AAAA... comment`
        public let fingerprint: String      // `SHA256:...`
    }

    public enum GenerationError: Error {
        case rsaGenerationFailed(String)
        case rsaExportFailed
        case unsupportedKeyType(SSHPrivateKeyKind)
    }

    // MARK: - ed25519

    public static func generateEd25519(comment: String) -> GeneratedKey {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = [UInt8](priv.publicKey.rawRepresentation)   // 32
        let seed = [UInt8](priv.rawRepresentation)            // 32

        let pubBlob = SSHPublicMaterial.ed25519Blob(pub: pub)
        let text = openSSHPrivateKey(pubBlob: pubBlob, pub: pub, seed: seed, comment: comment)
        return GeneratedKey(
            privateKeyText: text,
            publicKey: SSHPublicMaterial.publicKeyLine(prefix: "ssh-ed25519", blob: pubBlob, comment: comment),
            fingerprint: SSHPublicMaterial.fingerprint(of: pubBlob))
    }

    // MARK: - rsa

    public static func generateRSA(bits: Int, comment: String) throws -> GeneratedKey {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
        ]
        var error: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            let msg = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "未知错误"
            throw GenerationError.rsaGenerationFailed(msg)
        }
        // 私钥外部表示 = PKCS#1 `RSAPrivateKey` DER。
        guard let derCF = SecKeyCopyExternalRepresentation(privKey, &error) else {
            throw GenerationError.rsaExportFailed
        }
        let der = [UInt8](derCF as Data)

        let pem = pemWrap(der: der, label: "RSA PRIVATE KEY")
        let comps = try RSAKeyComponents.fromPKCS1DER(der)
        let pubBlob = SSHPublicMaterial.rsaBlob(e: comps.publicExponent, n: comps.modulus)
        return GeneratedKey(
            privateKeyText: pem,
            publicKey: SSHPublicMaterial.publicKeyLine(prefix: "ssh-rsa", blob: pubBlob, comment: comment),
            fingerprint: SSHPublicMaterial.fingerprint(of: pubBlob))
    }

    // MARK: - ecdsa

    public static func generateECDSA(type: SSHPrivateKeyKind, comment: String) throws -> GeneratedKey {
        switch type {
        case .ecdsaP256:
            let priv = P256.Signing.PrivateKey()
            return ecdsaKey(
                algorithm: "ecdsa-sha2-nistp256",
                curve: "nistp256",
                publicKey: [UInt8](priv.publicKey.x963Representation),
                scalar: [UInt8](priv.rawRepresentation),
                comment: comment)
        case .ecdsaP384:
            let priv = P384.Signing.PrivateKey()
            return ecdsaKey(
                algorithm: "ecdsa-sha2-nistp384",
                curve: "nistp384",
                publicKey: [UInt8](priv.publicKey.x963Representation),
                scalar: [UInt8](priv.rawRepresentation),
                comment: comment)
        case .ecdsaP521:
            let priv = P521.Signing.PrivateKey()
            return ecdsaKey(
                algorithm: "ecdsa-sha2-nistp521",
                curve: "nistp521",
                publicKey: [UInt8](priv.publicKey.x963Representation),
                scalar: [UInt8](priv.rawRepresentation),
                comment: comment)
        default:
            throw GenerationError.unsupportedKeyType(type)
        }
    }

    private static func ecdsaKey(algorithm: String, curve: String, publicKey: [UInt8],
                                 scalar: [UInt8], comment: String) -> GeneratedKey {
        let pubBlob = SSHPublicMaterial.ecdsaBlob(
            algorithm: algorithm, curve: curve, publicKey: publicKey)
        let text = openSSHECDSAPrivateKey(
            algorithm: algorithm, curve: curve, pubBlob: pubBlob,
            publicKey: publicKey, scalar: scalar, comment: comment)
        return GeneratedKey(
            privateKeyText: text,
            publicKey: SSHPublicMaterial.publicKeyLine(prefix: algorithm, blob: pubBlob, comment: comment),
            fingerprint: SSHPublicMaterial.fingerprint(of: pubBlob))
    }

    // MARK: - OpenSSH 未加密私钥容器

    /// 序列化 `openssh-key-v1`（cipher=none / kdf=none，单密钥）。
    private static func openSSHPrivateKey(pubBlob: [UInt8], pub: [UInt8],
                                          seed: [UInt8], comment: String) -> String {
        var inner = SSHWireWriter()
        // check1 == check2（未加密时只是占位防误用，取固定值即可）。
        let check: UInt32 = 0x756F_7A69   // "uozi"
        inner.writeUInt32(check)
        inner.writeUInt32(check)
        inner.writeString("ssh-ed25519")
        inner.writeString(pub)            // 公钥 32
        inner.writeString(seed + pub)     // 私钥 64 = seed || pub
        inner.writeString(comment.trimmingCharacters(in: .whitespacesAndNewlines))
        // padding 1,2,3,... 到 8 字节块对齐。
        var pad: UInt8 = 1
        while inner.bytes.count % 8 != 0 {
            inner.writeRawBytes([pad]); pad += 1
        }

        return openSSHPrivateKeyContainer(pubBlob: pubBlob, privateSection: inner.bytes)
    }

    /// 序列化 OpenSSH ECDSA 私钥段：algorithm, curve name, Q(point), d(scalar), comment。
    private static func openSSHECDSAPrivateKey(algorithm: String, curve: String,
                                               pubBlob: [UInt8], publicKey: [UInt8],
                                               scalar: [UInt8], comment: String) -> String {
        var inner = SSHWireWriter()
        let check: UInt32 = 0x756F_7A69
        inner.writeUInt32(check)
        inner.writeUInt32(check)
        inner.writeString(algorithm)
        inner.writeString(curve)
        inner.writeString(publicKey)
        inner.writeMPInt(scalar)
        inner.writeString(comment.trimmingCharacters(in: .whitespacesAndNewlines))
        var pad: UInt8 = 1
        while inner.bytes.count % 8 != 0 {
            inner.writeRawBytes([pad]); pad += 1
        }
        return openSSHPrivateKeyContainer(pubBlob: pubBlob, privateSection: inner.bytes)
    }

    private static func openSSHPrivateKeyContainer(pubBlob: [UInt8], privateSection: [UInt8]) -> String {
        var w = SSHWireWriter()
        w.writeRawBytes(Array("openssh-key-v1\0".utf8))
        w.writeString("none")             // ciphername
        w.writeString("none")             // kdfname
        w.writeString([])                 // kdfoptions（空）
        w.writeUInt32(1)                  // 密钥数
        w.writeString(pubBlob)            // 公钥 blob
        w.writeString(privateSection)     // 私钥段

        let b64 = Data(w.bytes).base64EncodedString()
        return pemBody(base64: b64, label: "OPENSSH PRIVATE KEY", lineWidth: 70)
    }

    // MARK: - PEM 包装

    /// 标准 PEM（DER → base64 → 64 列），用于 RSA。
    private static func pemWrap(der: [UInt8], label: String) -> String {
        pemBody(base64: Data(der).base64EncodedString(), label: label, lineWidth: 64)
    }

    private static func pemBody(base64: String, label: String, lineWidth: Int) -> String {
        let chars = Array(base64)
        var lines: [String] = []
        var i = 0
        while i < chars.count {
            let end = min(i + lineWidth, chars.count)
            lines.append(String(chars[i..<end]))
            i = end
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }
}
