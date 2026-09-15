import XCTest
@testable import uTerm

/// 长度前缀分帧。
///
/// v1 用的是换行分帧，正确性依赖「JSON 编码里不会出现裸 0x0A」这个隐含前提——
/// 换个编码器或加个字段就可能踩空。这些用例钉住新分帧对半包、粘包和非法长度的处理。
final class LANSyncFramingTests: XCTestCase {
    private func payload(_ text: String) -> Data { Data(text.utf8) }

    func testFramePrefixesBigEndianLength() throws {
        let framed = try LANSyncTransport.frame(payload("hello"))

        XCTAssertEqual(Array(framed.prefix(4)), [0, 0, 0, 5])
        XCTAssertEqual(framed.count, 9)
    }

    func testRoundTripsASingleFrame() throws {
        var buffer = LANSyncFrameBuffer()
        try buffer.append(try LANSyncTransport.frame(payload("hello")))

        XCTAssertEqual(try buffer.nextFrame(), payload("hello"))
        XCTAssertNil(try buffer.nextFrame())
    }

    /// 粘包：一次 receive 里到了好几帧，要能依次全切出来。
    func testReadsMultipleFramesArrivingInOnePacket() throws {
        var packet = Data()
        for text in ["header", "chunk-1", "chunk-2"] {
            packet.append(try LANSyncTransport.frame(payload(text)))
        }
        var buffer = LANSyncFrameBuffer()
        try buffer.append(packet)

        XCTAssertEqual(try buffer.nextFrame(), payload("header"))
        XCTAssertEqual(try buffer.nextFrame(), payload("chunk-1"))
        XCTAssertEqual(try buffer.nextFrame(), payload("chunk-2"))
        XCTAssertNil(try buffer.nextFrame())
    }

    /// 半包：逐字节喂进去，凑齐前不得产出，凑齐后必须完整。
    func testWaitsForAPartialFrameToCompleteByteByByte() throws {
        let framed = try LANSyncTransport.frame(payload("hello"))
        var buffer = LANSyncFrameBuffer()

        for byte in framed.dropLast() {
            try buffer.append(Data([byte]))
            XCTAssertNil(try buffer.nextFrame(), "帧还没收齐就产出了")
        }
        try buffer.append(Data([framed.last!]))
        XCTAssertEqual(try buffer.nextFrame(), payload("hello"))
    }

    /// 负载里带裸换行也必须完好——这正是换行分帧做不到的。
    func testCarriesPayloadsContainingNewlines() throws {
        let body = payload("line-1\nline-2\n")
        var buffer = LANSyncFrameBuffer()
        try buffer.append(try LANSyncTransport.frame(body))

        XCTAssertEqual(try buffer.nextFrame(), body)
    }

    func testRejectsAFrameLargerThanTheCap() throws {
        var header = Data([0xFF, 0xFF, 0xFF, 0xFF])   // 长度前缀远超上限
        header.append(Data(repeating: 0x41, count: 16))
        var buffer = LANSyncFrameBuffer()
        try buffer.append(header)

        XCTAssertThrowsError(try buffer.nextFrame()) { error in
            guard case LANSyncTransportError.frameTooLarge = error else {
                return XCTFail("应为 frameTooLarge，实际 \(error)")
            }
        }
    }

    func testRejectsAZeroLengthFrame() throws {
        var buffer = LANSyncFrameBuffer()
        try buffer.append(Data([0, 0, 0, 0]))

        XCTAssertThrowsError(try buffer.nextFrame())
    }

    func testSendingAnOversizedPayloadIsRefusedUpFront() {
        let tooBig = Data(repeating: 0x41, count: LANSyncConstants.maxFrameBytes + 1)

        XCTAssertThrowsError(try LANSyncTransport.frame(tooBig)) { error in
            guard case LANSyncTransportError.frameTooLarge = error else {
                return XCTFail("应为 frameTooLarge，实际 \(error)")
            }
        }
    }

    /// 总量上限是防对端无限发的那道闸，不是单帧上限。
    func testStopsAcceptingBytesPastTheTransferCap() {
        var buffer = LANSyncFrameBuffer()
        let block = Data(repeating: 0x41, count: 1024 * 1024)
        XCTAssertThrowsError(try {
            for _ in 0...(LANSyncConstants.maxTotalBytes / block.count) {
                try buffer.append(block)
            }
        }()) { error in
            guard case LANSyncTransportError.transferTooLarge = error else {
                return XCTFail("应为 transferTooLarge，实际 \(error)")
            }
        }
    }
}
