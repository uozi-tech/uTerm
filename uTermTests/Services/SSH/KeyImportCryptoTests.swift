import XCTest
@testable import uTerm
@testable import USSHKit

final class KeyImportCryptoTests: XCTestCase {

    /// RFC 6070：P="password", S="salt", c=1, dkLen=20, PRF=HMAC-SHA1
    /// -> 0c60c80f961f0e71f3a9b524af6012062fe037a6
    func testPBKDF2SHA1KnownVector() throws {
        let dk = try KeyImportCrypto.pbkdf2(
            password: Array("password".utf8), salt: Array("salt".utf8),
            iterations: 1, keyLength: 20, prf: .sha1)
        XCTAssertEqual(dk.map { String(format: "%02x", $0) }.joined(),
                       "0c60c80f961f0e71f3a9b524af6012062fe037a6")
    }

    /// EVP_BytesToKey(MD5) 已知答案测试 — 16 字节密钥（单块路径）。
    /// password = "abc"（0x61 0x62 0x63），salt = 8×0x01。
    /// D1 = MD5(password || salt) = b012a08089e2a1b55ef91d0e6b92a8e1
    /// 算法：python3 -c "import hashlib; d1=hashlib.md5(b'abc'+b'\x01'*8).digest(); print(d1.hex())"
    func testEVPBytesToKeyKnownAnswer16() {
        let password = Array("abc".utf8)
        let salt: [UInt8] = Array(repeating: 0x01, count: 8)
        let key = KeyImportCrypto.evpBytesToKey(password: password, salt: salt, keyLength: 16)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "b012a08089e2a1b55ef91d0e6b92a8e1")
    }

    /// EVP_BytesToKey(MD5) 已知答案测试 — 32 字节密钥（双块链式路径）。
    /// D1 = b012a08089e2a1b55ef91d0e6b92a8e1
    /// D2 = MD5(D1 || password || salt) = d5637891d905e56d52d78d106aea78e7
    /// 验证 MD5 链式循环需要迭代两轮（keyLength > 16）。
    func testEVPBytesToKeyKnownAnswer32() {
        let password = Array("abc".utf8)
        let salt: [UInt8] = Array(repeating: 0x01, count: 8)
        let key = KeyImportCrypto.evpBytesToKey(password: password, salt: salt, keyLength: 32)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "b012a08089e2a1b55ef91d0e6b92a8e1d5637891d905e56d52d78d106aea78e7")
    }

    /// AES-CBC：自加密后解密应还原（用 CryptoKit/已知值不便，这里做 round-trip）。
    func testAESCBCRoundTrip() throws {
        let key: [UInt8] = Array(0..<32)
        let iv: [UInt8] = Array(repeating: 0x09, count: 16)
        let plaintext: [UInt8] = Array("0123456789ABCDEF".utf8)   // 16 字节，整块
        let ct = try KeyImportCrypto.cbcCrypt(.aes, encrypt: true,
                                              key: key, iv: iv, input: plaintext)
        let pt = try KeyImportCrypto.cbcCrypt(.aes, encrypt: false,
                                              key: key, iv: iv, input: ct)
        XCTAssertEqual(pt, plaintext)
    }

    // MARK: - 安全：不可信输入校验

    /// 短 IV（小于块大小）必须抛错而非把短缓冲交给 CCCrypt 触发堆越界读。
    func testShortIVThrowsInsteadOfCrashing() {
        let key: [UInt8] = Array(0..<32)
        let shortIV: [UInt8] = [0x01]                              // 1 字节，远小于 AES 块（16）
        let input: [UInt8] = Array(repeating: 0, count: 16)
        XCTAssertThrowsError(try KeyImportCrypto.cbcCrypt(
            .aes, encrypt: false, key: key, iv: shortIV, input: input)) {
            XCTAssertEqual($0 as? PrivateKeyImportError,
                           .malformedKey(reason: "IV 长度与块大小不符"))
        }
    }

    /// 过长 IV 同样应被拒（CCCrypt 只读块大小字节，多余字节静默忽略会掩盖结构错误）。
    func testOverlongIVThrows() {
        let key: [UInt8] = Array(0..<32)
        let longIV: [UInt8] = Array(repeating: 0x09, count: 32)    // 32 字节，长于 AES 块
        let input: [UInt8] = Array(repeating: 0, count: 16)
        XCTAssertThrowsError(try KeyImportCrypto.cbcCrypt(
            .aes, encrypt: false, key: key, iv: longIV, input: input)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedKey(reason: ""))
        }
    }

    /// 3DES/DES 的块大小为 8，短 IV 同样应被拒。
    func testShortIVThrowsForTripleDES() {
        let key: [UInt8] = Array(0..<24)
        let shortIV: [UInt8] = [0x01]                              // 1 字节，小于 8
        let input: [UInt8] = Array(repeating: 0, count: 8)
        XCTAssertThrowsError(try KeyImportCrypto.cbcCrypt(
            .tripleDES, encrypt: false, key: key, iv: shortIV, input: input)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedKey(reason: ""))
        }
    }

    /// 超大派生密钥长度必须在分配缓冲前被拒，避免 ~4GB 内存分配。
    func testOversizedKeyLengthRejected() {
        let bigLen = Int(UInt32.max)                               // ~4.29e9，攻击者可控
        XCTAssertGreaterThan(bigLen, KeyImportCrypto.maxDerivedKeyLength)
        XCTAssertThrowsError(try KeyImportCrypto.pbkdf2(
            password: Array("pw".utf8), salt: Array("salt".utf8),
            iterations: 1, keyLength: bigLen, prf: .sha1)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedKey(reason: ""))
        }
    }

    /// keyLength 为 0 也应被拒（非法长度）。
    func testZeroKeyLengthRejected() {
        XCTAssertThrowsError(try KeyImportCrypto.pbkdf2(
            password: Array("pw".utf8), salt: Array("salt".utf8),
            iterations: 1, keyLength: 0, prf: .sha1)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedKey(reason: ""))
        }
    }

    /// 恰好等于上限的派生长度应放行（边界正向用例）。
    func testKeyLengthAtMaxAllowed() throws {
        let dk = try KeyImportCrypto.pbkdf2(
            password: Array("pw".utf8), salt: Array("salt".utf8),
            iterations: 1, keyLength: KeyImportCrypto.maxDerivedKeyLength, prf: .sha1)
        XCTAssertEqual(dk.count, KeyImportCrypto.maxDerivedKeyLength)
    }

    /// 迭代次数上限为正且足够大，覆盖正常密钥的迭代区间。
    func testPBKDF2IterationCeilingIsSane() {
        XCTAssertGreaterThan(KeyImportCrypto.maxPBKDF2Iterations, 1_000_000)
        XCTAssertLessThan(KeyImportCrypto.maxPBKDF2Iterations, Int(UInt32.max))
    }
}
