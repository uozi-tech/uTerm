import XCTest
import NIOCore
@testable import uTerm

final class RSASHA512PublicKeyTests: XCTestCase {
    func testPrefixIsRSASHA2512() {
        // fork 的 userauth 算法名取自 publicKeyPrefix，必须是 rsa-sha2-512。
        XCTAssertEqual(RSASHA512PublicKey.publicKeyPrefix, "rsa-sha2-512")
    }

    func testWriteIsMPIntEThenN() {
        // e=0x010001（高位 0，不补零）, n=0x8000（高位 1，需补 0x00）。
        let pub = RSASHA512PublicKey(modulus: [0x80, 0x00], publicExponent: [0x01, 0x00, 0x01])
        var buffer = ByteBuffer()
        _ = pub.write(to: &buffer)
        XCTAssertEqual([UInt8](buffer.readableBytesView),
                       [0,0,0,3, 0x01,0x00,0x01,   // mpint e
                        0,0,0,3, 0x00,0x80,0x00])  // mpint n（补 0x00）
    }

    func testValidatesRealSignature() throws {
        let comps = try RSAKeyComponents.fromPKCS1DER(
            PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der)
        let signer = try RSASHA512Signer(components: comps)
        let message = Array("verify-me".utf8)
        let sig = RSASHA512Signature(rawRepresentation: Data(try signer.sign(message)))
        let pub = RSASHA512PublicKey(modulus: comps.modulus, publicExponent: comps.publicExponent)
        XCTAssertTrue(pub.isValidSignature(sig, for: message))
    }
}
