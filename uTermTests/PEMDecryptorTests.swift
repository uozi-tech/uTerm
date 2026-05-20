import XCTest
@testable import uTerm

final class PEMDecryptorTests: XCTestCase {

    private func doc(_ pem: String) throws -> PEMDocument { try PEMDocument.parse(pem) }

    func testDecryptsLegacyPKCS1() throws {
        let der = try PEMDecryptor.decryptedDER(
            from: doc(KeyImportFixtures.rsaPKCS1Enc),
            passphrase: KeyImportFixtures.passphrase)
        // 解密结果应为可解析的 PKCS#1。
        _ = try DERKeyDecoder.decode(der: der, label: "RSA PRIVATE KEY")
    }

    func testDecryptsPBES2RSA() throws {
        let der = try PEMDecryptor.decryptedDER(
            from: doc(KeyImportFixtures.rsaPKCS8Enc),
            passphrase: KeyImportFixtures.passphrase)
        _ = try DERKeyDecoder.decode(der: der, label: "PRIVATE KEY")
    }

    func testDecryptsPBES2Ed25519() throws {
        let der = try PEMDecryptor.decryptedDER(
            from: doc(KeyImportFixtures.ed25519PKCS8Enc),
            passphrase: KeyImportFixtures.passphrase)
        _ = try DERKeyDecoder.decode(der: der, label: "PRIVATE KEY")
    }

    func testWrongPassphraseThrowsIncorrect() throws {
        XCTAssertThrowsError(try PEMDecryptor.decryptedDER(
            from: doc(KeyImportFixtures.rsaPKCS8Enc), passphrase: "wrong")) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .incorrectPassphrase)
        }
    }

    func testMissingPassphraseThrows() throws {
        XCTAssertThrowsError(try PEMDecryptor.decryptedDER(
            from: doc(KeyImportFixtures.rsaPKCS8Enc), passphrase: nil)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .encryptedKeyNeedsPassphrase)
        }
    }

    func testUnencryptedPassThrough() throws {
        let der = try PEMDecryptor.decryptedDER(
            from: doc(KeyImportFixtures.rsaPKCS1), passphrase: nil)
        XCTAssertEqual(der, try doc(KeyImportFixtures.rsaPKCS1).der)
    }

    func testDecryptsLegacySEC1EC() throws {
        let der = try PEMDecryptor.decryptedDER(
            from: doc(KeyImportFixtures.ecP256SEC1Enc),
            passphrase: KeyImportFixtures.passphrase)
        _ = try DERKeyDecoder.decode(der: der, label: "EC PRIVATE KEY")
    }
}
