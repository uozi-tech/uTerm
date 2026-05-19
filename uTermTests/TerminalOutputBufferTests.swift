import XCTest
@testable import uTerm

final class TerminalOutputBufferTests: XCTestCase {
    func testAppendThenDrainReturnsData() {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        buf.append(Data("hello".utf8), generation: 1)
        let out = buf.drain(maxBytes: 1024, generation: 1)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello")
    }

    func testDrainRespectsMaxBytes() {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        buf.append(Data("0123456789".utf8), generation: 1)
        let first = buf.drain(maxBytes: 4, generation: 1)
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "0123")
        let rest = buf.drain(maxBytes: 1024, generation: 1)
        XCTAssertEqual(String(decoding: rest, as: UTF8.self), "456789")
    }

    func testStaleGenerationChunksAreDropped() {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        buf.append(Data("old".utf8), generation: 1)
        buf.append(Data("new".utf8), generation: 2)
        let out = buf.drain(maxBytes: 1024, generation: 2)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "new")
    }

    func testOverflowDropsOldestChunks() {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        buf.append(Data(repeating: 0x41, count: 1024), generation: 1) // 占满
        buf.append(Data(repeating: 0x42, count: 512), generation: 1)  // 触发丢弃
        let out = buf.drain(maxBytes: 4096, generation: 1)
        XCTAssertLessThanOrEqual(out.count, 1024)
        XCTAssertTrue(out.contains(0x42))
    }

    func testClearEmptiesBuffer() {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        buf.append(Data("x".utf8), generation: 1)
        buf.clear()
        XCTAssertTrue(buf.drain(maxBytes: 1024, generation: 1).isEmpty)
    }
}
