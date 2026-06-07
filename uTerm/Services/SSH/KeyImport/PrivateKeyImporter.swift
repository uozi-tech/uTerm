import Foundation
import Crypto
@preconcurrency import Citadel

/// 私钥导入编排器：把任意受支持格式的私钥文本解析为 `ParsedPrivateKey`。
nonisolated enum PrivateKeyImporter {

    static func resolve(pem rawText: String, passphrase: String?) throws -> ParsedPrivateKey {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label = firstPEMLabel(in: text) else {
            throw PrivateKeyImportError.malformedPEM(reason: "未找到 -----BEGIN ...----- 标记")
        }

        switch label {
        case "OPENSSH PRIVATE KEY":
            return try resolveOpenSSH(text: text, passphrase: passphrase)
        case "DSA PRIVATE KEY":
            throw PrivateKeyImportError.dsaUnsupported
        case "RSA PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY", "ENCRYPTED PRIVATE KEY":
            return try resolvePEM(text: text, passphrase: passphrase)
        default:
            throw PrivateKeyImportError.unsupportedFormat(label: label)
        }
    }

    /// OpenSSH 容器：RSA / Ed25519 交给 Citadel；ECDSA 由 OpenSSHECDSADecoder 处理。
    private static func resolveOpenSSH(text: String, passphrase: String?) throws -> ParsedPrivateKey {
        let decryptionKey = passphrase?.data(using: .utf8)
        let keyType: SSHKeyType
        do {
            keyType = try SSHKeyDetection.detectPrivateKeyType(from: text)
        } catch {
            throw PrivateKeyImportError.malformedKey(reason: "无法识别 OpenSSH 私钥类型")
        }
        switch keyType {
        case .rsa:
            do {
                return .legacyOpenSSHRSA(try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryptionKey))
            } catch { throw mapCitadelKeyError(error) }
        case .ed25519:
            do {
                return .ed25519(try Curve25519.Signing.PrivateKey(
                    sshEd25519: text, decryptionKey: decryptionKey))
            } catch { throw mapCitadelKeyError(error) }
        default:
            switch keyType {
            case .ecdsaP256, .ecdsaP384, .ecdsaP521:
                return try OpenSSHECDSADecoder.decode(openSSHText: text)
            default:
                throw PrivateKeyImportError.unsupportedFormat(label: "OPENSSH \(keyType)")
            }
        }
    }

    /// PEM 信封：解析 -> 解密 -> DER 解码。
    private static func resolvePEM(text: String, passphrase: String?) throws -> ParsedPrivateKey {
        let doc = try PEMDocument.parse(text)
        let der = try PEMDecryptor.decryptedDER(from: doc, passphrase: passphrase)
        // PKCS#8 加密解密后是 PrivateKeyInfo，归一化标签为 "PRIVATE KEY"。
        let label = (doc.label == "ENCRYPTED PRIVATE KEY") ? "PRIVATE KEY" : doc.label
        return try DERKeyDecoder.decode(der: der, label: label)
    }

    /// Citadel 解析私钥抛错时映射到本模块错误（口令相关给出更准确的提示）。
    private static func mapCitadelKeyError(_ error: Error) -> PrivateKeyImportError {
        let text = (error.localizedDescription + "\(error)").lowercased()
        if text.contains("missingdecryptionkey") {
            return .encryptedKeyNeedsPassphrase
        }
        if text.contains("passphrase") || text.contains("decrypt") || text.contains("bcrypt") {
            return .incorrectPassphrase
        }
        return .malformedKey(reason: error.localizedDescription)
    }

    /// 取首个 `-----BEGIN <label>-----` 中的 label。
    private static func firstPEMLabel(in text: String) -> String? {
        guard let begin = text.range(of: "-----BEGIN ") else { return nil }
        let rest = text[begin.upperBound...]
        guard let end = rest.range(of: "-----") else { return nil }
        return String(rest[..<end.lowerBound])
    }
}
