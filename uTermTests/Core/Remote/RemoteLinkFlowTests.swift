import XCTest
@testable import uTerm

/// 链路层排队（调研 §17.5）的纯逻辑：分级、分片、通道内保序、闸门、端到端计量、收方回报节奏。
final class RemoteLinkFlowTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    private func drain(_ flow: inout RemoteLinkFlow, now: UInt64 = 0) -> [RemoteLinkFlow.Record] {
        var records: [RemoteLinkFlow.Record] = []
        while let record = flow.next() {
            flow.recordSent(bytes: record.message.payload.count + RemoteMessage.headerSize + 20, now: now)
            records.append(record)
        }
        return records
    }

    func test_urgent_messages_go_first() {
        var flow = RemoteLinkFlow()
        flow.enqueue(RemoteMessage(.desktopFrame, channel: 7, payload: Data(count: 1000)), token: 1)
        flow.enqueue(RemoteMessage(.desktopAudioFrame, channel: 7, payload: Data(count: 100)), token: 2)
        flow.enqueue(RemoteMessage(.desktopAck, channel: 7, payload: Data(count: 10)), token: 3)
        XCTAssertEqual(drain(&flow).map(\.token), [2, 3, 1])
    }

    /// `desktopStarted` 和光标同属紧急：光标不能越过它先到（手机靠它绑定通道，先到的光标会被丢掉）。
    func test_desktop_started_is_not_overtaken_by_cursor() {
        var flow = RemoteLinkFlow()
        flow.enqueue(RemoteMessage(.output, channel: 3, payload: Data(count: 300_000)), token: 1)
        flow.enqueue(RemoteMessage(.desktopStarted, channel: 9, payload: Data(count: 200)), token: 2)
        flow.enqueue(RemoteMessage(.desktopCursor, channel: 9, payload: Data(count: 20)), token: 3)
        let tokens = drain(&flow).compactMap(\.token)
        XCTAssertEqual(Array(tokens.prefix(2)), [2, 3])
    }

    func test_large_messages_are_fragmented_and_reassembled() throws {
        var flow = RemoteLinkFlow()
        let payload = Data((0..<100_000).map { UInt8($0 % 251) })
        flow.enqueue(RemoteMessage(.desktopFrame, channel: 9, payload: payload), token: 5)
        let records = drain(&flow)
        XCTAssertEqual(records.count, 7)
        XCTAssertTrue(records.allSatisfy { $0.message.kind == .linkFragment && $0.message.payload.count <= 16 * 1024 + 5 })
        XCTAssertEqual(records.map(\.token), [nil, nil, nil, nil, nil, nil, 5], "只有最后一片带完成")
        var receiver = RemoteLinkFlow()
        var rebuilt: [RemoteMessage] = []
        for record in records {
            if let message = try receiver.reassemble(record.message.payload) { rebuilt.append(message) }
        }
        XCTAssertEqual(rebuilt, [RemoteMessage(.desktopFrame, channel: 9, payload: payload)])
    }

    /// 视频分片期间，紧急消息和别的通道（终端）都能插进来；同一通道内照旧保序。
    func test_fragments_interleave_with_urgent_and_other_channels_but_keep_channel_order() throws {
        var flow = RemoteLinkFlow()
        flow.enqueue(RemoteMessage(.desktopFrame, channel: 9, payload: Data(count: 40_000)), token: 1)
        flow.enqueue(RemoteMessage(.desktopClipboard, channel: 9, payload: Data(count: 10)), token: 2)
        flow.enqueue(RemoteMessage(.output, channel: 3, payload: Data(count: 10)), token: 3)
        flow.enqueue(RemoteMessage(.closed, channel: 3, payload: Data()), token: 4)
        var order: [String] = []
        let first = try XCTUnwrap(flow.next())
        order.append(first.message.kind == .linkFragment ? "frag" : "\(first.message.kind)")
        flow.enqueue(RemoteMessage(.desktopAudioFrame, channel: 9, payload: Data(count: 50)), token: 5)
        while let record = flow.next() {
            order.append(record.message.kind == .linkFragment ? "frag\(record.token.map { "#\($0)" } ?? "")"
                         : "\(record.message.kind)")
        }
        // 第一片之后：声音先走；然后终端与视频轮转；视频通道里剪贴板排在整帧之后。
        XCTAssertEqual(order, ["frag", "desktopAudioFrame", "output", "frag", "closed", "frag#1", "desktopClipboard"])
    }

    /// 没有读数时预算 256 KB：超出后普通消息停住、紧急消息照发；对端报来收到之后放行。
    func test_gate_holds_bulk_until_peer_reports_receipt() {
        var flow = RemoteLinkFlow()
        for index in 0..<40 {
            flow.enqueue(RemoteMessage(.desktopFrame, channel: 9, payload: Data(count: 16_000)), token: index)
        }
        let first = drain(&flow)
        XCTAssertEqual(flow.budget, 256 * 1024)
        XCTAssertGreaterThanOrEqual(flow.inPipe, 256 * 1024)
        XCTAssertLessThan(flow.inPipe, 256 * 1024 + 17_000)
        XCTAssertLessThan(first.count, 40)
        flow.enqueue(RemoteMessage(.pong, payload: Data()), token: 99)
        XCTAssertEqual(drain(&flow).map(\.token), [99])
        flow.receiveAck(flow.sentBytes, now: 10 * ms)
        XCTAssertFalse(drain(&flow, now: 10 * ms).isEmpty)
    }

    /// 稳态：链路 1.25 MB/s（10 Mbps）、往返 100 ms。预算收敛到 速率 ×（往返 + 30 ms）× 1.25 附近。
    func test_budget_tracks_delivery_rate_and_min_round_trip() {
        var flow = RemoteLinkFlow()
        let rate = 1_250_000.0
        var now: UInt64 = 0
        var delivered: UInt64 = 0
        var inFlight: [(bytes: UInt64, sentAt: UInt64)] = []
        for _ in 0..<3_000 {
            for _ in 0..<4 { flow.enqueue(RemoteMessage(.desktopFrame, channel: 9, payload: Data(count: 4_000)), token: nil) }
            while let record = flow.next() {
                let bytes = record.message.payload.count + RemoteMessage.headerSize + 20
                flow.recordSent(bytes: bytes, now: now)
                inFlight.append((flow.sentBytes, now))
            }
            // 链路按 1.25 MB/s 往外送，送到的字节 50 ms 后被对端收到、再 50 ms 后报回来。
            now += 2 * ms
            let capacity = UInt64(rate * 0.002)
            delivered = min(flow.sentBytes, delivered + capacity)
            if let reported = inFlight.last(where: { $0.bytes <= delivered && now &- $0.sentAt >= 100 * ms }) {
                flow.receiveAck(reported.bytes, now: now)
                inFlight.removeAll { $0.bytes <= reported.bytes }
            }
        }
        let rtt = Double(flow.minimumRoundTripNanos ?? 0) / 1e6
        let measured = flow.deliveryRate ?? 0
        XCTAssertEqual(rtt, 100, accuracy: 15, "最小往返 \(rtt) ms")
        XCTAssertEqual(measured, rate, accuracy: rate * 0.15, "送达速率 \(measured)")
        let expected = rate * 0.13 * 1.25
        XCTAssertEqual(Double(flow.budget), expected, accuracy: expected * 0.25, "预算 \(flow.budget)")
    }

    func test_receiver_acks_every_16kb_or_after_20ms() {
        var flow = RemoteLinkFlow()
        XCTAssertEqual(flow.recordReceived(bytes: 1_000, now: 0), .at(20 * ms))
        XCTAssertEqual(flow.recordReceived(bytes: 1_000, now: 1 * ms), RemoteLinkFlow.AckDecision.none, "已经约过")
        XCTAssertEqual(flow.recordReceived(bytes: 15_000, now: 2 * ms), .now)
        XCTAssertEqual(flow.takeAck(), 17_000)
        XCTAssertNil(flow.takeAck(), "没有新收到的不回")
        XCTAssertEqual(flow.recordReceived(bytes: 10, now: 3 * ms), .at(23 * ms))
    }

    func test_reassembly_rejects_oversized_messages() {
        var flow = RemoteLinkFlow()
        let piece = RemoteLinkFragment(channel: 1, last: false, bytes: Data(count: 1_000_000))
        XCTAssertThrowsError(try {
            for _ in 0..<5 { _ = try flow.reassemble(piece.encoded()) }
        }())
    }

    func test_ack_and_fragment_wire_formats() throws {
        XCTAssertEqual(try RemoteLinkAck.decode(RemoteLinkAck.encode(123_456_789_012)), 123_456_789_012)
        let fragment = RemoteLinkFragment(channel: 42, last: true, bytes: Data([1, 2, 3]))
        XCTAssertEqual(try RemoteLinkFragment(decoding: fragment.encoded()), fragment)
        XCTAssertThrowsError(try RemoteLinkFragment(decoding: Data([1, 0, 0, 0, 42])))
    }
}
