import XCTest
@testable import uTerm
@testable import USSHKit

/// RSA 私钥签 rsa-sha2-512（迁移前是 USSHKit 自己的 `RSASHA512PrivateKey`，现在是 USSHCore 的 `SSHRSAPrivateKey`）。
final class RSASHA512PrivateKeyTests: XCTestCase {
    private func key() throws -> SSHRSAPrivateKey {
        try RSAKeyMaterial.makeKey(RSAKeyMaterial.componentsFromPKCS1DER(
            PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der))
    }

    func testAlgorithmName() {
        XCTAssertEqual(SSHRSASignatureAlgorithm.rsaSHA2_512.name, "rsa-sha2-512")
    }

    func testSignatureVerifiesAgainstPublicKey() throws {
        let key = try key()
        let message = Array("payload".utf8)
        let sig = try key.signature(for: message, algorithm: .rsaSHA2_512)
        XCTAssertEqual(sig.algorithm, .rsaSHA2_512)
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: message, algorithm: .rsaSHA2_512))
        // 期望的算法对不上（降级到别的算法）直接判假。
        XCTAssertFalse(key.publicKey.isValidSignature(sig, for: message, algorithm: .rsaSHA2_256))
    }
}
