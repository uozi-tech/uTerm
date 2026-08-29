import XCTest
@testable import uTerm
@testable import USSHKit

final class DERKeyDecoderTests: XCTestCase {

    /// 从 PEM 文本取 DER 字节的小助手。
    private func der(of pem: String) throws -> [UInt8] {
        try PEMDocument.parse(pem).der
    }

    func testDecodesPKCS1RSA() throws {
        let key = try DERKeyDecoder.decode(
            der: der(of: KeyImportFixtures.rsaPKCS1), label: "RSA PRIVATE KEY")
        guard case .rsa = key else { return XCTFail("应为 rsa") }
    }

    func testDecodesSEC1ECDSA() throws {
        for (pem, name) in [(KeyImportFixtures.ecP256SEC1, "P256"),
                            (KeyImportFixtures.ecP384SEC1, "P384"),
                            (KeyImportFixtures.ecP521SEC1, "P521")] {
            let key = try DERKeyDecoder.decode(der: der(of: pem), label: "EC PRIVATE KEY")
            switch (name, key) {
            case ("P256", .p256), ("P384", .p384), ("P521", .p521): break
            default: XCTFail("\(name) 解析结果类型不符：\(key)")
            }
        }
    }

    /// 命名曲线 SEC1（含 namedCurve OID）：验证 DERKeyDecoder 能通过 OID 识别 P-256。
    func testDecodesNamedCurveSEC1EC() throws {
        let key = try DERKeyDecoder.decode(
            der: der(of: KeyImportFixtures.ecP256SEC1Named), label: "EC PRIVATE KEY")
        guard case .p256 = key else { return XCTFail("应为 p256，得 \(key)") }
    }

    func testDecodesPKCS8RSA() throws {
        let key = try DERKeyDecoder.decode(der: der(of: KeyImportFixtures.rsaPKCS8),
                                           label: "PRIVATE KEY")
        guard case .rsa = key else { return XCTFail("应为 rsa") }
    }

    func testDecodesPKCS8Ed25519() throws {
        let key = try DERKeyDecoder.decode(der: der(of: KeyImportFixtures.ed25519PKCS8),
                                           label: "PRIVATE KEY")
        guard case .ed25519 = key else { return XCTFail("应为 ed25519") }
    }

    func testDecodesPKCS8EC() throws {
        let key = try DERKeyDecoder.decode(der: der(of: KeyImportFixtures.ecP256PKCS8),
                                           label: "PRIVATE KEY")
        guard case .p256 = key else { return XCTFail("应为 p256") }
    }

    func testDSAThrowsUnsupported() throws {
        // DSA 走 PKCS#8/传统 PEM 标签均应被拒。dsaPEM 标签为 "DSA PRIVATE KEY"。
        XCTAssertThrowsError(try DERKeyDecoder.decode(
            der: der(of: KeyImportFixtures.dsaPEM), label: "DSA PRIVATE KEY")) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .dsaUnsupported)
        }
    }

    /// RSA 关键往返：rsaPKCS1 与 rsaPKCS8 是同一密钥的两种 PEM 封装，
    /// 解析后 RSAKeyComponents.modulus 应相等。
    /// OpenSSH RSA 走 .legacyOpenSSHRSA，PEM RSA 走 .rsa(RSAKeyComponents)。
    func testRSARoundTripOpenSSHvsPKCS1() throws {
        let fromOpenSSH = try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaOpenSSH, passphrase: nil)
        guard case .legacyOpenSSHRSA = fromOpenSSH else {
            return XCTFail("OpenSSH RSA 应为 .legacyOpenSSHRSA，得 \(fromOpenSSH)")
        }
        let fromPKCS1 = try DERKeyDecoder.decode(
            der: der(of: KeyImportFixtures.rsaPKCS1), label: "RSA PRIVATE KEY")
        let fromPKCS8 = try DERKeyDecoder.decode(
            der: der(of: KeyImportFixtures.rsaPKCS8), label: "PRIVATE KEY")
        guard case .rsa(let compsPKCS1) = fromPKCS1 else {
            return XCTFail("PKCS#1 RSA 应为 .rsa，得 \(fromPKCS1)")
        }
        guard case .rsa(let compsPKCS8) = fromPKCS8 else {
            return XCTFail("PKCS#8 RSA 应为 .rsa，得 \(fromPKCS8)")
        }
        XCTAssertEqual(compsPKCS1.modulus, compsPKCS8.modulus,
                       "同一密钥的 PKCS#1 与 PKCS#8 模数应相等")
    }
}
