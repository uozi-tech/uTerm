import XCTest
@testable import uTerm

final class RemoteProtocolTests: XCTestCase {

    func test_message_round_trips_kind_channel_and_raw_payload() throws {
        let payload = Data([0x1b, 0x5b, 0x33, 0x31, 0x6d, 0x00, 0xff])
        let message = RemoteMessage(.output, channel: 0x01020304, payload: payload)
        let decoded = try RemoteMessage(decoding: message.encoded())
        XCTAssertEqual(decoded, message)
        XCTAssertEqual(message.encoded().count, RemoteMessage.headerSize + payload.count)
    }

    func test_message_with_empty_payload_and_slice_input() throws {
        let encoded = RemoteMessage(.ping).encoded()
        // 从更大的 Data 里切出来的切片，startIndex 不为 0。
        let sliced = (Data([9, 9]) + encoded).dropFirst(2)
        XCTAssertEqual(try RemoteMessage(decoding: Data(sliced)), RemoteMessage(.ping))
        XCTAssertEqual(try RemoteMessage(decoding: sliced), RemoteMessage(.ping))
    }

    func test_message_rejects_short_and_unknown() {
        XCTAssertThrowsError(try RemoteMessage(decoding: Data([1, 0, 0])))
        XCTAssertThrowsError(try RemoteMessage(decoding: Data([200, 0, 0, 0, 0])))
    }

    func test_grid_size_round_trips_and_rejects_zero() throws {
        let size = RemoteGridSize(cols: 300, rows: 72)
        XCTAssertEqual(try RemoteGridSize(decoding: size.encoded()), size)
        XCTAssertThrowsError(try RemoteGridSize(decoding: RemoteGridSize(cols: 0, rows: 10).encoded()))
        XCTAssertThrowsError(try RemoteGridSize(decoding: Data([1, 2, 3])))
    }

    func test_frame_buffer_handles_partial_and_coalesced_frames() throws {
        var buffer = RemoteFrameBuffer()
        let a = try RemoteFrameBuffer.frame(Data("hello".utf8))
        let b = try RemoteFrameBuffer.frame(Data(repeating: 7, count: 70_000))
        // 逐字节喂：直到最后一个字节之前都不该吐出第二帧。
        var out: [Data] = []
        for byte in a + b {
            buffer.append(Data([byte]))
            while let frame = try buffer.nextFrame() { out.append(frame) }
        }
        XCTAssertEqual(out, [Data("hello".utf8), Data(repeating: 7, count: 70_000)])
        XCTAssertEqual(buffer.bufferedBytes, 0)

        // 一次喂多帧。
        buffer.append(a + a + a)
        var count = 0
        while try buffer.nextFrame() != nil { count += 1 }
        XCTAssertEqual(count, 3)
    }

    func test_frame_buffer_compacts_without_losing_bytes() throws {
        var buffer = RemoteFrameBuffer()
        var expected: [Data] = []
        var got: [Data] = []
        for i in 0..<2_000 {
            let payload = Data(repeating: UInt8(i % 251), count: 1 + i % 977)
            expected.append(payload)
            let framed = try RemoteFrameBuffer.frame(payload)
            // 每次只喂半帧多一点，让缓冲里长期留着残帧，反复触发压缩路径。
            let cut = framed.count / 2 + 1
            buffer.append(framed.prefix(cut))
            while let f = try buffer.nextFrame() { got.append(f) }
            buffer.append(framed.dropFirst(cut))
            while let f = try buffer.nextFrame() { got.append(f) }
        }
        XCTAssertEqual(got, expected)
    }

    func test_frame_buffer_rejects_oversized_and_zero_length() {
        var buffer = RemoteFrameBuffer()
        let length = UInt32(RemoteConstants.maxFrameBytes + 1)
        buffer.append(Data([UInt8(length >> 24), UInt8((length >> 16) & 0xff),
                            UInt8((length >> 8) & 0xff), UInt8(length & 0xff)]))
        XCTAssertThrowsError(try buffer.nextFrame())

        var zero = RemoteFrameBuffer()
        zero.append(Data([0, 0, 0, 0]))
        XCTAssertThrowsError(try zero.nextFrame())
        XCTAssertThrowsError(try RemoteFrameBuffer.frame(Data()))
    }
}
