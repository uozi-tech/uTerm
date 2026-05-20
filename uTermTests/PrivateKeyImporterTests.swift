import XCTest
import Crypto
@preconcurrency import Citadel
@testable import uTerm

final class PrivateKeyImporterTests: XCTestCase {

    func testOpenSSHEd25519Resolves() throws {
        let key = try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.ed25519OpenSSH, passphrase: nil)
        guard case .ed25519 = key else { return XCTFail("应为 ed25519，得 \(key)") }
    }

    func testOpenSSHRSAResolves() throws {
        let key = try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaOpenSSH, passphrase: nil)
        guard case .legacyOpenSSHRSA = key else { return XCTFail("应为 legacyOpenSSHRSA，得 \(key)") }
    }

    func testGarbageThrowsMalformed() {
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(pem: "not a key", passphrase: nil)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedPEM(reason: ""))
        }
    }

    func testResolvesUnencryptedPEMKeys() throws {
        let cases: [(String, String)] = [
            (KeyImportFixtures.rsaPKCS1, "rsa"),
            (KeyImportFixtures.rsaPKCS8, "rsa"),
            (KeyImportFixtures.ed25519PKCS8, "ed25519"),
            (KeyImportFixtures.ecP256SEC1, "p256"),
            (KeyImportFixtures.ecP384SEC1, "p384"),
            (KeyImportFixtures.ecP521SEC1, "p521"),
            (KeyImportFixtures.ecP256PKCS8, "p256"),
        ]
        for (pem, expected) in cases {
            let key = try PrivateKeyImporter.resolve(pem: pem, passphrase: nil)
            XCTAssertEqual(caseName(key), expected, "PEM 解析类型不符")
        }
    }

    func testDSAPEMRejected() {
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.dsaPEM, passphrase: nil)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .dsaUnsupported)
        }
    }

    func testResolvesOpenSSHECDSA() throws {
        for (pem, expected) in [(KeyImportFixtures.ecP256OpenSSH, "p256"),
                                (KeyImportFixtures.ecP384OpenSSH, "p384"),
                                (KeyImportFixtures.ecP521OpenSSH, "p521")] {
            let key = try PrivateKeyImporter.resolve(pem: pem, passphrase: nil)
            XCTAssertEqual(caseName(key), expected, "OpenSSH ECDSA 解析类型不符")
        }
    }

    func testResolvesEncryptedPEMKeys() throws {
        let pass = KeyImportFixtures.passphrase
        let cases: [(String, String)] = [
            (KeyImportFixtures.rsaPKCS1Enc, "rsa"),
            (KeyImportFixtures.rsaPKCS8Enc, "rsa"),
            (KeyImportFixtures.ed25519PKCS8Enc, "ed25519"),
            (KeyImportFixtures.ecP256SEC1Enc, "p256"),
        ]
        for (pem, expected) in cases {
            let key = try PrivateKeyImporter.resolve(pem: pem, passphrase: pass)
            XCTAssertEqual(caseName(key), expected)
        }
    }

    func testEncryptedPEMWrongPassphrase() {
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaPKCS8Enc, passphrase: "wrong")) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .incorrectPassphrase)
        }
    }

    func testEncryptedPEMMissingPassphrase() {
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaPKCS8Enc, passphrase: nil)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .encryptedKeyNeedsPassphrase)
        }
    }

    /// 加密 OpenSSH ECDSA 密钥应通过 SSHKeyDetection → OpenSSHECDSADecoder 路由，
    /// 并以 unsupportedFormat 拒绝（加密 OpenSSH 格式暂不支持解密）。
    func testEncryptedOpenSSHECDSARejectedViaImporter() {
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.ecP256OpenSSHEnc, passphrase: KeyImportFixtures.passphrase)) {
            guard case PrivateKeyImportError.unsupportedFormat = $0 else {
                return XCTFail("应抛 unsupportedFormat，实际 \($0)")
            }
        }
    }

    /// 取 ParsedPrivateKey 的 case 名，便于断言。
    private func caseName(_ key: ParsedPrivateKey) -> String {
        switch key {
        case .rsa: return "rsa"
        case .legacyOpenSSHRSA: return "rsa"
        case .ed25519: return "ed25519"
        case .p256: return "p256"; case .p384: return "p384"; case .p521: return "p521"
        }
    }
}
