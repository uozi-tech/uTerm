import Foundation
import SwiftASN1

/// PEM 私钥解密：传统 DEK-Info 与 PKCS#8 PBES2。
nonisolated enum PEMDecryptor {

    /// 返回明文 DER。未加密则原样返回 `doc.der`。
    static func decryptedDER(from doc: PEMDocument, passphrase: String?) throws -> [UInt8] {
        let procType = doc.headers["Proc-Type"]?.uppercased() ?? ""
        let isLegacyEncrypted = procType.contains("ENCRYPTED")
        let isPBES2 = doc.label == "ENCRYPTED PRIVATE KEY"

        if !isLegacyEncrypted && !isPBES2 {
            return doc.der
        }
        guard let passphrase, !passphrase.isEmpty else {
            throw PrivateKeyImportError.encryptedKeyNeedsPassphrase
        }
        let password = [UInt8](passphrase.utf8)

        if isLegacyEncrypted {
            return try decryptLegacy(doc: doc, password: password)
        } else {
            return try decryptPBES2(der: doc.der, password: password)
        }
    }

    // MARK: - 传统 DEK-Info

    private static func decryptLegacy(doc: PEMDocument, password: [UInt8]) throws -> [UInt8] {
        guard let dekInfo = doc.headers["DEK-Info"] else {
            throw PrivateKeyImportError.malformedKey(reason: "缺少 DEK-Info 头")
        }
        let parts = dekInfo.split(separator: ",")
        guard parts.count == 2 else {
            throw PrivateKeyImportError.malformedKey(reason: "DEK-Info 格式错误")
        }
        let cipherName = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
        let iv = try hexBytes(String(parts[1]).trimmingCharacters(in: .whitespaces))

        let (cipher, keyLen) = try legacyCipher(cipherName)
        let salt = Array(iv.prefix(8))
        let key = KeyImportCrypto.evpBytesToKey(
            password: password, salt: salt, keyLength: keyLen)
        let raw = try KeyImportCrypto.cbcCrypt(
            cipher, encrypt: false, key: key, iv: iv, input: doc.der)
        return try KeyImportCrypto.stripPKCS7(raw, blockSize: cipher.blockSize)
    }

    private static func legacyCipher(_ name: String)
        throws -> (KeyImportCrypto.BlockCipher, Int) {
        switch name {
        case "AES-128-CBC": return (.aes, 16)
        case "AES-192-CBC": return (.aes, 24)
        case "AES-256-CBC": return (.aes, 32)
        case "DES-EDE3-CBC": return (.tripleDES, 24)
        case "DES-CBC": return (.des, 8)
        default: throw PrivateKeyImportError.unsupportedCipher(name: name)
        }
    }

    // MARK: - PKCS#8 PBES2

    /// EncryptedPrivateKeyInfo ::= SEQUENCE { encryptionAlgorithm AlgorithmIdentifier,
    ///                                        encryptedData OCTET STRING }
    private static func decryptPBES2(der: [UInt8], password: [UInt8]) throws -> [UInt8] {
        let root = try DERKeyDecoder.parse(der)
        let top = try DERKeyDecoder.children(root)
        guard top.count == 2 else {
            throw PrivateKeyImportError.malformedKey(reason: "EncryptedPrivateKeyInfo 字段数错误")
        }
        let algFields = try DERKeyDecoder.children(top[0])
        guard let algOID = algFields.first,
              try DERKeyDecoder.oidString(algOID) == "1.2.840.113549.1.5.13" else {
            throw PrivateKeyImportError.unsupportedKDF(name: "非 PBES2（不支持 PBES1）")
        }
        guard algFields.count >= 2 else {
            throw PrivateKeyImportError.malformedKey(reason: "PBES2：缺少参数")
        }
        // PBES2-params ::= SEQUENCE { keyDerivationFunc AID, encryptionScheme AID }
        let pbes2 = try DERKeyDecoder.children(algFields[1])
        guard pbes2.count == 2 else {
            throw PrivateKeyImportError.malformedKey(reason: "PBES2-params 字段数错误")
        }
        let (salt, iterations, prf, keyLenHint) = try parsePBKDF2(pbes2[0])
        let (cipher, keyLen, iv) = try parseEncScheme(pbes2[1])
        // keyLength 一律取自 encryptionScheme 指定的密码（keyLen），不信任 PBKDF2-params
        // 里的可选 keyLength 提示——它不可信且会被直接用于分配缓冲。
        // 若提示存在，仅校验其与密码所需长度一致，不一致则视为结构损坏。
        if let hint = keyLenHint, hint != keyLen {
            throw PrivateKeyImportError.malformedKey(reason: "PBKDF2 密钥长度与加密算法不符")
        }
        let key = try KeyImportCrypto.pbkdf2(
            password: password, salt: salt, iterations: iterations,
            keyLength: keyLen, prf: prf)
        let encrypted = try DERKeyDecoder.primitiveBytes(top[1])
        let raw = try KeyImportCrypto.cbcCrypt(
            cipher, encrypt: false, key: key, iv: iv, input: encrypted)
        return try KeyImportCrypto.stripPKCS7(raw, blockSize: cipher.blockSize)
    }

    /// keyDerivationFunc AID = SEQUENCE { OID(pbkdf2), PBKDF2-params }
    /// PBKDF2-params ::= SEQUENCE { salt OCTET STRING, iterationCount INT,
    ///                              keyLength INT OPTIONAL, prf AID OPTIONAL }
    private static func parsePBKDF2(_ node: ASN1Node)
        throws -> (salt: [UInt8], iterations: Int, prf: KeyImportCrypto.PRF, keyLen: Int?) {
        let kdf = try DERKeyDecoder.children(node)
        guard let kdfOID = kdf.first,
              try DERKeyDecoder.oidString(kdfOID) == "1.2.840.113549.1.5.12",
              kdf.count >= 2 else {
            throw PrivateKeyImportError.unsupportedKDF(name: "非 PBKDF2")
        }
        let params = try DERKeyDecoder.children(kdf[1])
        guard params.count >= 2 else {
            throw PrivateKeyImportError.malformedKey(reason: "PBKDF2-params 字段不足")
        }
        let salt = try DERKeyDecoder.primitiveBytes(params[0])
        let iterations = try intValue(params[1])
        // 迭代次数来自不可信 DER，仅受 4 字节宽度约束（最高约 4.29 亿）。
        // 不设上限会让构造的密钥强制执行多分钟级 HMAC，造成 CPU DoS / 界面卡死。
        guard iterations >= 1, iterations <= KeyImportCrypto.maxPBKDF2Iterations else {
            throw PrivateKeyImportError.malformedKey(reason: "PBKDF2 迭代次数超出允许范围")
        }
        var keyLen: Int?
        var prf: KeyImportCrypto.PRF = .sha1            // 默认 hmacWithSHA1
        for extra in params.dropFirst(2) {
            if case .primitive = extra.content,
               let n = try? intValue(extra) {
                keyLen = n
            } else if case .constructed = extra.content,
                      let oidNode = try? DERKeyDecoder.children(extra).first {
                prf = try prfFromOID(DERKeyDecoder.oidString(oidNode))
            }
        }
        return (salt, iterations, prf, keyLen)
    }

    private static func prfFromOID(_ oid: String) throws -> KeyImportCrypto.PRF {
        switch oid {
        case "1.2.840.113549.2.7":  return .sha1
        case "1.2.840.113549.2.8":  return .sha224
        case "1.2.840.113549.2.9":  return .sha256
        case "1.2.840.113549.2.10": return .sha384
        case "1.2.840.113549.2.11": return .sha512
        default: throw PrivateKeyImportError.unsupportedKDF(name: "PRF \(oid)")
        }
    }

    /// encryptionScheme AID = SEQUENCE { OID(cipher), IV OCTET STRING }
    private static func parseEncScheme(_ node: ASN1Node)
        throws -> (KeyImportCrypto.BlockCipher, Int, [UInt8]) {
        let enc = try DERKeyDecoder.children(node)
        guard let cipherOID = enc.first, enc.count >= 2 else {
            throw PrivateKeyImportError.malformedKey(reason: "encryptionScheme 字段不足")
        }
        let iv = try DERKeyDecoder.primitiveBytes(enc[1])
        switch try DERKeyDecoder.oidString(cipherOID) {
        case "2.16.840.1.101.3.4.1.2":  return (.aes, 16, iv)   // aes-128-CBC
        case "2.16.840.1.101.3.4.1.22": return (.aes, 24, iv)   // aes-192-CBC
        case "2.16.840.1.101.3.4.1.42": return (.aes, 32, iv)   // aes-256-CBC
        case "1.2.840.113549.3.7":      return (.tripleDES, 24, iv)  // des-EDE3-CBC
        case "1.3.14.3.2.7":            return (.des, 8, iv)    // des-CBC
        case let other:
            throw PrivateKeyImportError.unsupportedCipher(name: other)
        }
    }

    // MARK: - 工具

    private static func intValue(_ node: ASN1Node) throws -> Int {
        let bytes = try DERKeyDecoder.integerMagnitude(node)
        guard bytes.count <= 4 else {
            throw PrivateKeyImportError.malformedKey(reason: "整数过大")
        }
        return bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func hexBytes(_ hex: String) throws -> [UInt8] {
        guard hex.count % 2 == 0 else {
            throw PrivateKeyImportError.malformedKey(reason: "IV 十六进制长度为奇")
        }
        var result: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else {
                throw PrivateKeyImportError.malformedKey(reason: "IV 含非十六进制字符")
            }
            result.append(byte)
            idx = next
        }
        return result
    }
}
