import XCTest
import NIOCore
@testable import uTerm
@testable import USSHKit

/// RSA 公钥 blob（`string "ssh-rsa" ‖ mpint e ‖ mpint n`）与验签。
final class RSASHA512PublicKeyTests: XCTestCase {
    func testKeyTypeIsSSHRSA() {
        // 公钥类型名是 ssh-rsa；rsa-sha2-512 是签名算法名（RFC 8332）。
        XCTAssertEqual(SSHRSAPublicKey.keyType, "ssh-rsa")
    }

    func testBlobIsMPIntEThenN() throws {
        let comps = try RSAKeyMaterial.componentsFromPKCS1DER(PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der)
        let pub = try SSHRSAPublicKey(modulus: comps.modulus, publicExponent: comps.publicExponent)
        var buffer = ByteBuffer(bytes: pub.sshBlob)
        func readString() -> [UInt8]? {
            guard let length = buffer.readInteger(as: UInt32.self) else { return nil }
            return buffer.readBytes(length: Int(length))
        }
        XCTAssertEqual(readString(), Array("ssh-rsa".utf8))
        // mpint：高位为 1 时补一个 0x00。
        let e = try XCTUnwrap(readString())
        XCTAssertEqual(Array(e.drop { $0 == 0 }), Array(comps.publicExponent.drop { $0 == 0 }))
        let n = try XCTUnwrap(readString())
        XCTAssertEqual(n.first, 0x00, "模数高位为 1，mpint 要补 0x00")
        XCTAssertEqual(Array(n.dropFirst()), Array(comps.modulus.drop { $0 == 0 }))
        XCTAssertEqual(buffer.readableBytes, 0)
        XCTAssertEqual(try SSHRSAPublicKey(sshBlob: pub.sshBlob), pub)
    }

    func testValidatesRealSignature() throws {
        let comps = try RSAKeyMaterial.componentsFromPKCS1DER(PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der)
        let key = try RSAKeyMaterial.makeKey(comps)
        let message = Array("verify-me".utf8)
        let sig = try SSHRSASignature(sshBlob: key.signature(for: message, algorithm: .rsaSHA2_512).sshBlob)
        let pub = try SSHRSAPublicKey(modulus: comps.modulus, publicExponent: comps.publicExponent)
        XCTAssertTrue(pub.isValidSignature(sig, for: message, algorithm: .rsaSHA2_512))
    }
}
