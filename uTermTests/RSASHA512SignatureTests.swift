import XCTest
import NIOCore
@testable import uTerm

final class RSASHA512SignatureTests: XCTestCase {
    func testPrefix() {
        XCTAssertEqual(RSASHA512Signature.signaturePrefix, "rsa-sha2-512")
    }

    func testWriteReadRoundTrip() throws {
        let raw: [UInt8] = Array(0..<40)
        let sig = RSASHA512Signature(rawRepresentation: Data(raw))
        var buffer = ByteBuffer()
        _ = sig.write(to: &buffer)
        let decoded = try RSASHA512Signature.read(from: &buffer)
        XCTAssertEqual([UInt8](decoded.rawRepresentation), raw)
    }

    func testWriteUsesSSHStringFraming() throws {
        let sig = RSASHA512Signature(rawRepresentation: Data([0xAA, 0xBB]))
        var buffer = ByteBuffer()
        _ = sig.write(to: &buffer)
        // SSH string：uint32 长度前缀 + 字节。
        XCTAssertEqual([UInt8](buffer.readableBytesView), [0, 0, 0, 2, 0xAA, 0xBB])
    }
}
