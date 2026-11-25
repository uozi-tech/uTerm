import XCTest
import NIOCore
@testable import uTerm
@testable import USSHKit

/// RSA 签名 blob 的线格式（`string 算法名 ‖ string 签名`，RFC 8332 §3）。
final class RSASHA512SignatureTests: XCTestCase {
    func testPrefix() {
        XCTAssertEqual(SSHRSASignatureAlgorithm(name: "rsa-sha2-512"), .rsaSHA2_512)
    }

    func testWriteReadRoundTrip() throws {
        let raw: [UInt8] = Array(0..<40)
        let sig = SSHRSASignature(algorithm: .rsaSHA2_512, bytes: raw)
        let decoded = try SSHRSASignature(sshBlob: sig.sshBlob)
        XCTAssertEqual(decoded.bytes, raw)
        XCTAssertEqual(decoded.algorithm, .rsaSHA2_512)
    }

    func testWriteUsesSSHStringFraming() throws {
        let sig = SSHRSASignature(algorithm: .rsaSHA2_512, bytes: [0xAA, 0xBB])
        // SSH string：uint32 长度前缀 + 字节；先是算法名，再是签名。
        let name = Array("rsa-sha2-512".utf8)
        XCTAssertEqual(sig.sshBlob, [0, 0, 0, UInt8(name.count)] + name + [0, 0, 0, 2, 0xAA, 0xBB])
    }
}
