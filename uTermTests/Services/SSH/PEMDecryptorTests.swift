import XCTest
@testable import uTerm
@testable import USSHKit

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

    // MARK: - 安全：不可信 PBES2 参数

    /// 过大的 PBKDF2 迭代次数必须在派生密钥前被拒，避免多分钟级 CPU DoS。
    /// 构造一个 iterationCount 超过上限的 PBES2 EncryptedPrivateKeyInfo，
    /// 直接走 decryptedDER；应立即抛出结构损坏而非卡在 PBKDF2。
    func testOversizedIterationCountRejected() {
        // 迭代次数 0x7FFFFFFF = 2,147,483,647，远超 10,000,000 上限，但仍 ≤4 字节。
        let der = Self.makePBES2DER(iterations: 0x7FFF_FFFF)
        let document = PEMDocument(
            label: "ENCRYPTED PRIVATE KEY", headers: [:], der: der)
        XCTAssertThrowsError(try PEMDecryptor.decryptedDER(
            from: document, passphrase: "whatever")) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedKey(reason: ""))
        }
    }

    /// 恰好超出上限一位（上限 + 1）同样应被拒，验证边界为闭区间上界。
    func testIterationJustAboveCeilingRejected() {
        let der = Self.makePBES2DER(iterations: KeyImportCrypto.maxPBKDF2Iterations + 1)
        let document = PEMDocument(
            label: "ENCRYPTED PRIVATE KEY", headers: [:], der: der)
        XCTAssertThrowsError(try PEMDecryptor.decryptedDER(
            from: document, passphrase: "whatever")) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedKey(reason: ""))
        }
    }

    /// 合理迭代次数（远低于上限）的同结构密钥应越过迭代检查，进入实际解密；
    /// 因密文为占位、口令任意，最终以口令错误失败，证明并非被迭代上限拦下。
    /// 用小迭代次数（1000）以保证测试快速。
    func testReasonableIterationPassesIterationCheck() {
        let der = Self.makePBES2DER(iterations: 1000)
        let document = PEMDocument(
            label: "ENCRYPTED PRIVATE KEY", headers: [:], der: der)
        XCTAssertThrowsError(try PEMDecryptor.decryptedDER(
            from: document, passphrase: "whatever")) {
            // 应走到 PKCS#7 校验阶段失败（口令错误），而非被迭代上限拦下。
            XCTAssertEqual($0 as? PrivateKeyImportError, .incorrectPassphrase,
                           "合理迭代次数不应被迭代检查拦下")
        }
    }

    // MARK: - DER 构造辅助（仅测试用）

    /// 构造最小可解析的 PBES2（PBKDF2 + AES-256-CBC）EncryptedPrivateKeyInfo DER。
    private static func makePBES2DER(iterations: Int) -> [UInt8] {
        // 短长度编码辅助：本测试所有元素长度均 < 128，使用单字节长度。
        func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            precondition(content.count < 0x80, "测试夹具仅支持短长度")
            return [tag, UInt8(content.count)] + content
        }
        func seq(_ content: [UInt8]) -> [UInt8] { tlv(0x30, content) }
        func octet(_ content: [UInt8]) -> [UInt8] { tlv(0x04, content) }
        // OID 内容字节（已是 DER body，仅需加 06 标签）。
        func oid(_ body: [UInt8]) -> [UInt8] { tlv(0x06, body) }
        // 把 ≤4 字节的非负整数编码为 DER INTEGER（必要时补 0x00 避免符号位）。
        func integer(_ value: Int) -> [UInt8] {
            var bytes: [UInt8] = []
            var v = value
            if v == 0 { bytes = [0] }
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
            return tlv(0x02, bytes)
        }

        // OID body 字节（点分 → DER 已知编码）。
        let oidPBES2: [UInt8]  = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D] // 1.2.840.113549.1.5.13
        let oidPBKDF2: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C] // 1.2.840.113549.1.5.12
        let oidAES256: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A] // 2.16.840.1.101.3.4.1.42

        let salt = octet(Array(repeating: 0x00, count: 8))
        let pbkdf2Params = seq(salt + integer(iterations))
        let kdf = seq(oid(oidPBKDF2) + pbkdf2Params)

        let iv = octet(Array(repeating: 0x00, count: 16))           // AES 块大小，IV 长度合法
        let encScheme = seq(oid(oidAES256) + iv)

        let pbes2Params = seq(kdf + encScheme)
        let alg = seq(oid(oidPBES2) + pbes2Params)

        // encryptedData：16 字节占位（整块，长度合法），口令错误时才会触发 PKCS#7 失败。
        let encrypted = octet(Array(repeating: 0x00, count: 16))
        return seq(alg + encrypted)
    }
}
