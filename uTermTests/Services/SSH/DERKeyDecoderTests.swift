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

    /// RSA 关键往返：rsaOpenSSH / rsaPKCS1 / rsaPKCS8 是**同一把密钥**的三种封装
    /// （见 Fixtures/generate.sh），三条路解出的分量必须一致。
    func testRSARoundTripOpenSSHvsPKCS1() throws {
        let fromOpenSSH = try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaOpenSSH, passphrase: nil)
        guard case .rsa(let compsOpenSSH) = fromOpenSSH else {
            return XCTFail("OpenSSH RSA 应为 .rsa（rsa-sha2-512），得 \(fromOpenSSH)")
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
        XCTAssertEqual(compsPKCS1.publicKey, compsPKCS8.publicKey,
                       "同一密钥的 PKCS#1 与 PKCS#8 公钥（n、e）应相等")
        XCTAssertEqual(compsOpenSSH.publicKey, compsPKCS1.publicKey,
                       "同一密钥的 OpenSSH 容器与 PKCS#1 公钥应相等")
        // 私钥部分（d、p、q）不外露：PKCS#1 v1.5 签名是确定的，同一把私钥对同一段数据签出来逐字节相同。
        // p/q 只存在于 OpenSSH 私钥段，读错位（n,e,d,iqmp,p,q）会在这里暴露（构造时就会核对失败）。
        let message = Array("same-key".utf8)
        XCTAssertEqual(try compsOpenSSH.signature(for: message, algorithm: .rsaSHA2_512),
                       try compsPKCS1.signature(for: message, algorithm: .rsaSHA2_512))
        XCTAssertEqual(try compsPKCS8.signature(for: message, algorithm: .rsaSHA2_512),
                       try compsPKCS1.signature(for: message, algorithm: .rsaSHA2_512))
    }
}
