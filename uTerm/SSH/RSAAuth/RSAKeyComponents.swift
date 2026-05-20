import Foundation

/// RSA 私钥的核心分量（无符号大端字节串）。足以构造 `_RSA.Signing.PrivateKey` 与
/// SSH `ssh-rsa` 公钥 blob —— 无需 dP/dQ/qInv。
nonisolated struct RSAKeyComponents {
    let modulus: [UInt8]          // n
    let publicExponent: [UInt8]   // e
    let privateExponent: [UInt8]  // d
    let prime1: [UInt8]           // p
    let prime2: [UInt8]           // q

    /// 从 PKCS#1 `RSAPrivateKey` DER（SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }）
    /// 抽取分量。复用 `DERKeyDecoder` 的 ASN.1 助手。
    static func fromPKCS1DER(_ der: [UInt8]) throws -> RSAKeyComponents {
        let root = try DERKeyDecoder.parse(der)
        let fields = try DERKeyDecoder.children(root)
        guard fields.count >= 9 else {
            throw PrivateKeyImportError.malformedKey(reason: "PKCS#1 RSA：字段不足（需 9）")
        }
        return RSAKeyComponents(
            modulus:         try DERKeyDecoder.integerMagnitude(fields[1]),
            publicExponent:  try DERKeyDecoder.integerMagnitude(fields[2]),
            privateExponent: try DERKeyDecoder.integerMagnitude(fields[3]),
            prime1:          try DERKeyDecoder.integerMagnitude(fields[4]),
            prime2:          try DERKeyDecoder.integerMagnitude(fields[5]))
    }
}
