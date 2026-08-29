import XCTest
@testable import uTerm
@testable import USSHKit

final class SSHWireFormatTests: XCTestCase {

    func testWriteString() {
        var w = SSHWireWriter()
        w.writeString([0xAA, 0xBB])
        XCTAssertEqual(w.bytes, [0, 0, 0, 2, 0xAA, 0xBB])
    }

    func testWriteUInt32() {
        var w = SSHWireWriter()
        w.writeUInt32(1)
        XCTAssertEqual(w.bytes, [0, 0, 0, 1])
    }

    func testMpintPrependsZeroWhenHighBitSet() {
        var w = SSHWireWriter()
        w.writeMPInt([0xFF, 0x01])           // 最高位为 1 -> 前补 0x00
        XCTAssertEqual(w.bytes, [0, 0, 0, 3, 0x00, 0xFF, 0x01])
    }

    func testMpintStripsLeadingZerosThenNoPrepend() {
        var w = SSHWireWriter()
        w.writeMPInt([0x00, 0x00, 0x7F, 0x10]) // 去前导零，最高位 0 -> 不补
        XCTAssertEqual(w.bytes, [0, 0, 0, 2, 0x7F, 0x10])
    }

    func testReaderRoundTrip() throws {
        var w = SSHWireWriter()
        w.writeString(Array("ssh-rsa".utf8))
        w.writeUInt32(7)
        var r = SSHWireReader(w.bytes)
        XCTAssertEqual(try r.readString(), Array("ssh-rsa".utf8))
        XCTAssertEqual(try r.readUInt32(), 7)
        XCTAssertTrue(r.isAtEnd)
    }

    func testReaderOverrunThrows() {
        var r = SSHWireReader([0, 0, 0, 9, 1, 2])
        XCTAssertThrowsError(try r.readString())
    }
}
