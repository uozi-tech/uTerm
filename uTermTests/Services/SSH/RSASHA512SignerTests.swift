import XCTest
@testable import uTerm
@testable import USSHKit

/// 用私钥签、用分量重建的公钥验（迁移前是 `RSASHA512Signer`）。
final class RSASHA512SignerTests: XCTestCase {
    private func components() throws -> SSHRSAPrivateKeyComponents {
        try RSAKeyMaterial.componentsFromPKCS1DER(PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der)
    }

    func testSignThenVerifyRoundTrips() throws {
        let comps = try components()
        let key = try RSAKeyMaterial.makeKey(comps)
        let message = Array("uterm-rsa-sha512".utf8)
        let sig = try key.signature(for: message, algorithm: .rsaSHA2_512)
        XCTAssertFalse(sig.bytes.isEmpty)
        // 用同一对公钥分量验签 —— 自洽证明签名正确。
        let publicKey = try SSHRSAPublicKey(modulus: comps.modulus, publicExponent: comps.publicExponent)
        XCTAssertTrue(publicKey.isValidSignature(sig, for: message, algorithm: .rsaSHA2_512))
    }

    func testWrongMessageFailsVerification() throws {
        let comps = try components()
        let key = try RSAKeyMaterial.makeKey(comps)
        let sig = try key.signature(for: Array("message-A".utf8), algorithm: .rsaSHA2_512)
        let publicKey = try SSHRSAPublicKey(modulus: comps.modulus, publicExponent: comps.publicExponent)
        XCTAssertFalse(publicKey.isValidSignature(sig, for: Array("message-B".utf8), algorithm: .rsaSHA2_512))
    }
}
