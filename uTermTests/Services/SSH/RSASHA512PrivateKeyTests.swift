import XCTest
@testable import uTerm

final class RSASHA512PrivateKeyTests: XCTestCase {
    private func components() throws -> RSAKeyComponents {
        try RSAKeyComponents.fromPKCS1DER(PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der)
    }

    func testKeyPrefix() {
        XCTAssertEqual(RSASHA512PrivateKey.keyPrefix, "rsa-sha2-512")
    }

    func testSignatureVerifiesAgainstPublicKey() throws {
        let key = try RSASHA512PrivateKey(components: components())
        let message = Array("payload".utf8)
        let sig = try key.signature(for: message)
        XCTAssertEqual(type(of: sig).signaturePrefix, "rsa-sha2-512")
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: message))
    }
}
