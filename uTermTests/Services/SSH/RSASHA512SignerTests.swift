import XCTest
@testable import uTerm

final class RSASHA512SignerTests: XCTestCase {
    private func components() throws -> RSAKeyComponents {
        try RSAKeyComponents.fromPKCS1DER(PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der)
    }

    func testSignThenVerifyRoundTrips() throws {
        let signer = try RSASHA512Signer(components: components())
        let message = Array("uterm-rsa-sha512".utf8)
        let sig = try signer.sign(message)
        XCTAssertFalse(sig.isEmpty)
        // 用同一对公钥分量验签 —— 自洽证明签名正确。
        let comps = try components()
        XCTAssertTrue(RSASHA512Signer.isValidSignature(
            sig, for: message, modulus: comps.modulus, publicExponent: comps.publicExponent))
    }

    func testWrongMessageFailsVerification() throws {
        let signer = try RSASHA512Signer(components: components())
        let sig = try signer.sign(Array("message-A".utf8))
        let comps = try components()
        XCTAssertFalse(RSASHA512Signer.isValidSignature(
            sig, for: Array("message-B".utf8), modulus: comps.modulus, publicExponent: comps.publicExponent))
    }
}
