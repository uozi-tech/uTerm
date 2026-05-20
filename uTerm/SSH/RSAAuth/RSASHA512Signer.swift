import Foundation
import Crypto
import _CryptoExtras

/// RSA-SHA512 签名引擎，基于 swift-crypto 的 `_RSA.Signing`。
/// 对数据先做 SHA-512、再以 PKCS#1 v1.5 填充签名 —— 即 SSH `rsa-sha2-512` 的签名体。
nonisolated struct RSASHA512Signer {
    private let privateKey: _RSA.Signing.PrivateKey

    init(components: RSAKeyComponents) throws {
        do {
            self.privateKey = try _RSA.Signing.PrivateKey(
                n: components.modulus,
                e: components.publicExponent,
                d: components.privateExponent,
                p: components.prime1,
                q: components.prime2)
        } catch {
            throw PrivateKeyImportError.malformedKey(
                reason: "RSA 私钥构造失败：\(error.localizedDescription)")
        }
    }

    /// 对 `data` 做 SHA-512 + PKCS#1v1.5 签名，返回原始 RSA 签名字节。
    func sign<D: DataProtocol>(_ data: D) throws -> [UInt8] {
        let digest = SHA512.hash(data: Data(data))
        // PKCS#1 v1.5 是 SSH rsa-sha2-* 规定的填充方式（RFC 8332）；_CryptoExtras
        // 把它命名为 "insecure" 只是为了劝退能用 PSS 的调用方，对 SSH 而言是正确选择。
        let signature = try privateKey.signature(for: digest, padding: .insecurePKCS1v1_5)
        return [UInt8](signature.rawRepresentation)
    }

    /// 用公钥分量验证 `rsa-sha2-512` 签名。
    static func isValidSignature<D: DataProtocol>(
        _ signature: [UInt8], for data: D, modulus: [UInt8], publicExponent: [UInt8]
    ) -> Bool {
        guard let publicKey = try? _RSA.Signing.PublicKey(
            n: modulus, e: publicExponent) else { return false }
        let digest = SHA512.hash(data: Data(data))
        let rsaSig = _RSA.Signing.RSASignature(rawRepresentation: Data(signature))
        return publicKey.isValidSignature(rsaSig, for: digest, padding: .insecurePKCS1v1_5)
    }
}
