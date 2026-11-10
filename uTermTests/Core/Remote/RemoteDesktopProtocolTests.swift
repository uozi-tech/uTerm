import XCTest
@testable import uTerm

/// 远程桌面消息体的编解码：每种消息往返一致，坏数据抛错而不是崩，握手能力字段前后兼容。
final class RemoteDesktopProtocolTests: XCTestCase {

    func test_frame_round_trip_keyframe_and_delta() throws {
        let key = RemoteDesktopFrame(flags: [.keyframe], codec: .hevc, sequence: 0xDEAD_BEEF, captureNanos: 0x0123_4567_89AB_CDEF,
                                     width: 2464, height: 1600, parameterSets: [Data([0x40, 1, 2]), Data([0x42, 3]), Data([0x44])],
                                     data: Data(repeating: 0xAB, count: 300))
        let decodedKey = try RemoteDesktopFrame(decoding: key.encoded())
        XCTAssertEqual(decodedKey, key)
        XCTAssertTrue(decodedKey.isKeyframe)
        XCTAssertEqual(key.encoded().count, RemoteDesktopFrame.headerSize + 1 + (2 + 3) + (2 + 2) + (2 + 1) + 300)

        let delta = RemoteDesktopFrame(flags: [.refine], codec: .h264, sequence: 2, captureNanos: 99, width: 1920, height: 1080,
                                       parameterSets: [], data: Data([0, 0, 0, 1, 0x41]))
        let decodedDelta = try RemoteDesktopFrame(decoding: delta.encoded())
        XCTAssertEqual(decodedDelta, delta)
        XCTAssertFalse(decodedDelta.isKeyframe)
        XCTAssertTrue(decodedDelta.flags.contains(.refine))
        // 非关键帧不带参数集：帧头之后直接是码流。
        XCTAssertEqual(delta.encoded().count, RemoteDesktopFrame.headerSize + 5)
    }

    func test_frame_rejects_truncated_or_bogus_payloads() {
        let frame = RemoteDesktopFrame(flags: [.keyframe], codec: .hevc, sequence: 1, captureNanos: 1, width: 8, height: 8,
                                       parameterSets: [Data([1, 2, 3])], data: Data([9]))
        let bytes = frame.encoded()
        for cut in [0, 5, RemoteDesktopFrame.headerSize, RemoteDesktopFrame.headerSize + 2, bytes.count - 1] {
            XCTAssertThrowsError(try RemoteDesktopFrame(decoding: bytes.prefix(cut)), "截到 \(cut) 字节应报错")
        }
        var badCodec = bytes
        badCodec[badCodec.startIndex + 1] = 9
        XCTAssertThrowsError(try RemoteDesktopFrame(decoding: badCodec))
        // 关键帧声称 0 个参数集：解码端没法建格式描述，按坏消息处理。
        var noSets = Data(bytes.prefix(RemoteDesktopFrame.headerSize))
        noSets.append(0)
        noSets.append(1)
        XCTAssertThrowsError(try RemoteDesktopFrame(decoding: noSets))
    }

    func test_frame_decodes_from_sliced_data() throws {
        // 消息负载是 `Data` 切片（startIndex ≠ 0），读取必须按切片的索引来。
        let frame = RemoteDesktopFrame(flags: [], codec: .hevc, sequence: 5, captureNanos: 6, width: 10, height: 12,
                                       parameterSets: [], data: Data([1, 2, 3]))
        let wrapped = Data([0xFF, 0xFF]) + frame.encoded()
        XCTAssertEqual(try RemoteDesktopFrame(decoding: wrapped.dropFirst(2)), frame)
    }

    func test_ack_cursor_round_trip() throws {
        let ack = RemoteDesktopAck(sequence: 77, captureNanos: UInt64.max - 3, decodeMicros: 2_345, failed: true)
        XCTAssertEqual(try RemoteDesktopAck(decoding: ack.encoded()), ack)
        XCTAssertEqual(ack.encoded().count, 17)
        XCTAssertThrowsError(try RemoteDesktopAck(decoding: ack.encoded().prefix(16)))

        let cursor = RemoteDesktopCursor(x: 0.25, y: 0.875, visible: false)
        XCTAssertEqual(try RemoteDesktopCursor(decoding: cursor.encoded()), cursor)
    }

    func test_every_input_kind_round_trips() throws {
        let inputs: [RemoteDesktopInput] = [
            .move(x: 0.123, y: 0.987),
            .button(.left, down: true, clickCount: 2, x: 0.5, y: 0.5, modifiers: [.command, .shift]),
            .button(.right, down: false, clickCount: 1, x: 1, y: 0, modifiers: []),
            .button(.other, down: true, clickCount: 1, x: 0, y: 1, modifiers: [.option, .control, .function, .capsLock]),
            .scroll(dx: -12.5, dy: 300.25, phase: .began),
            .scroll(dx: 0, dy: -1, phase: .momentumEnded),
            .key(code: RemoteKeyMap.Key.left, down: true, modifiers: [.command]),
            .key(code: 0x00, down: false, modifiers: []),
            .text("你好 uTerm ✓ 🧑‍💻"),
        ]
        for input in inputs {
            XCTAssertEqual(try RemoteDesktopInput(decoding: input.encoded()), input, "\(input)")
        }
        XCTAssertThrowsError(try RemoteDesktopInput(decoding: Data([99])))
        XCTAssertThrowsError(try RemoteDesktopInput(decoding: Data([5])), "空文字不算输入")
        XCTAssertThrowsError(try RemoteDesktopInput(decoding: Data([3, 0, 0, 0, 0, 0, 0, 0, 0, 42])), "未知滚动阶段")
        XCTAssertThrowsError(try RemoteDesktopInput(decoding: Data([2, 7])), "未知按键 / 截断")
    }

    func test_control_messages_json_round_trip() throws {
        let request = RemoteDesktopStartRequest(requestID: UUID(), maxWidth: 2622, maxHeight: 1206, codec: .h264, displayID: 3)
        XCTAssertEqual(try RemoteJSON.decode(RemoteDesktopStartRequest.self, from: RemoteJSON.encode(request)), request)

        let info = RemoteDesktopInfo(requestID: UUID(), displayID: 1, displayWidth: 1512, displayHeight: 982,
                                     streamWidth: 1856, streamHeight: 1206, codec: .hevc, canControl: false,
                                     controlNote: "只能查看")
        XCTAssertEqual(try RemoteJSON.decode(RemoteDesktopInfo.self, from: RemoteJSON.encode(info)), info)
        let rejected = RemoteDesktopInfo(requestID: UUID(), failure: .screenPermission, message: "没授权")
        XCTAssertEqual(try RemoteJSON.decode(RemoteDesktopInfo.self, from: RemoteJSON.encode(rejected)), rejected)
        for paused in [true, false] {
            let pause = RemoteDesktopPauseRequest(paused: paused)
            XCTAssertEqual(try RemoteJSON.decode(RemoteDesktopPauseRequest.self, from: RemoteJSON.encode(pause)), pause)
        }
    }

    func test_message_kinds_keep_their_wire_values() {
        // 线上编号一旦发布就不能改：老版本按编号认消息。
        XCTAssertEqual(RemoteMessage.Kind.desktopStart.rawValue, 10)
        XCTAssertEqual(RemoteMessage.Kind.desktopStop.rawValue, 11)
        XCTAssertEqual(RemoteMessage.Kind.desktopInput.rawValue, 12)
        XCTAssertEqual(RemoteMessage.Kind.desktopAck.rawValue, 13)
        XCTAssertEqual(RemoteMessage.Kind.desktopKeyframe.rawValue, 14)
        XCTAssertEqual(RemoteMessage.Kind.desktopPaste.rawValue, 15)
        XCTAssertEqual(RemoteMessage.Kind.desktopStarted.rawValue, 25)
        XCTAssertEqual(RemoteMessage.Kind.desktopFrame.rawValue, 26)
        XCTAssertEqual(RemoteMessage.Kind.desktopCursor.rawValue, 27)
        XCTAssertEqual(RemoteMessage.Kind.desktopPause.rawValue, 44)
        XCTAssertEqual(RemoteFeature.desktopPause, "desktop-pause")
        XCTAssertEqual(RemoteVideoCodec(wireValue: RemoteVideoCodec.hevc.wireValue), .hevc)
        XCTAssertEqual(RemoteVideoCodec(wireValue: RemoteVideoCodec.h264.wireValue), .h264)
    }

    func test_paste_round_trips_and_rejects_empty_or_oversized() throws {
        let image = Data(repeating: 0xAB, count: 300_000)
        for content in [RemoteDesktopPaste.text("你好 hello"), .png(image), .jpeg(image)] {
            XCTAssertEqual(try RemoteDesktopPaste(decoding: content.encoded()), content)
        }
        XCTAssertThrowsError(try RemoteDesktopPaste(decoding: Data([1])), "空文字")
        XCTAssertThrowsError(try RemoteDesktopPaste(decoding: Data([9, 1, 2])), "未知类型")
        let huge = RemoteDesktopPaste.png(Data(count: RemoteDesktopPaste.maxContentBytes + 1)).encoded()
        XCTAssertThrowsError(try RemoteDesktopPaste(decoding: huge), "超过一帧能装的上限")
        // 上限之内的整条消息（加密前）放得进一帧。
        let largest = RemoteMessage(.desktopPaste, channel: 1,
                                    payload: RemoteDesktopPaste.png(Data(count: RemoteDesktopPaste.maxContentBytes)).encoded())
        XCTAssertLessThan(largest.encoded().count + 16, RemoteConstants.maxFrameBytes)
    }

    /// 能力字段不升协议版本：P1 的握手消息（没有 features）照样解得开，新消息给 P1 解也不出错。
    func test_hello_features_are_backward_compatible() throws {
        struct P1Hello: Codable, Equatable {
            var version: Int
            var deviceID: UUID
            var deviceName: String
            var ephemeralKey: Data
            var staticKey: Data
        }
        let old = P1Hello(version: 1, deviceID: UUID(), deviceName: "老 Mac", ephemeralKey: Data([1]), staticKey: Data([2]))
        let decodedOld = try JSONDecoder().decode(RemoteHello.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decodedOld.features)
        XCTAssertFalse(decodedOld.supports(RemoteFeature.desktop))

        let new = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: UUID(), deviceName: "新 Mac",
                              ephemeralKey: Data([3]), staticKey: Data([4]), features: RemoteConstants.localFeatures)
        let asOld = try JSONDecoder().decode(P1Hello.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(asOld.deviceName, "新 Mac")
        XCTAssertTrue(try JSONDecoder().decode(RemoteHello.self, from: JSONEncoder().encode(new)).supports(RemoteFeature.desktop))
        XCTAssertEqual(RemoteConstants.protocolVersion, 1, "加能力不升版本号")
    }
}
