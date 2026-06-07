import XCTest
@testable import uTerm

final class KeyImportCryptoTests: XCTestCase {

    /// RFC 6070：P="password", S="salt", c=1, dkLen=20, PRF=HMAC-SHA1
    /// -> 0c60c80f961f0e71f3a9b524af6012062fe037a6
    func testPBKDF2SHA1KnownVector() {
        let dk = KeyImportCrypto.pbkdf2(
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
}
