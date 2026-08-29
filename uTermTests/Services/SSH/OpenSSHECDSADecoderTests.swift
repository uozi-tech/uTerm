import XCTest
@testable import uTerm
@testable import USSHKit

final class OpenSSHECDSADecoderTests: XCTestCase {

    func testDecodesOpenSSHECDSA() throws {
        for (pem, expected) in [(KeyImportFixtures.ecP256OpenSSH, "p256"),
                                (KeyImportFixtures.ecP384OpenSSH, "p384"),
                                (KeyImportFixtures.ecP521OpenSSH, "p521")] {
            let key = try OpenSSHECDSADecoder.decode(openSSHText: pem)
            switch (expected, key) {
            case ("p256", .p256), ("p384", .p384), ("p521", .p521): break
            default: XCTFail("\(expected) 类型不符：\(key)")
            }
        }
    }

    func testEncryptedOpenSSHECDSARejected() {
        // ecP256OpenSSHEnc 是加密的 ECDSA OpenSSH 密钥，ciphername 非 "none"。
        XCTAssertThrowsError(try OpenSSHECDSADecoder.decode(openSSHText: KeyImportFixtures.ecP256OpenSSHEnc)) {
            guard case PrivateKeyImportError.unsupportedFormat = $0 else {
                return XCTFail("应抛 unsupportedFormat，实际 \($0)")
            }
        }
    }
}
