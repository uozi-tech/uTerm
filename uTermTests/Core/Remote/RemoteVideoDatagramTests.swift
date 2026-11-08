import XCTest
@testable import uTerm

/// 视频分片的丢包恢复：纯逻辑，时间由测试推进，结果完全确定。
final class RemoteVideoDatagramTests: XCTestCase {

    private func payload(_ bytes: Int, seed: UInt8 = 1) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31) &+ seed })
    }

    private func packets(_ data: Data, sequence: UInt32 = 1, fec: Int = 0, deadline: Int = 200, roundTrip: Int = 50) -> [Data] {
        RemoteVideoPacketizer.packets(payload: data, channel: 1, videoSequence: sequence, fecGroupSize: fec,
                                      deadlineMillis: deadline, roundTripMillis: roundTrip)
    }

    private let ms: UInt64 = 1_000_000

    func test_packets_fit_the_datagram_limit() {
        for packet in packets(payload(100_000), fec: 4) {
            XCTAssertLessThanOrEqual(packet.count + RemoteDatagramCipher.overhead, RemoteP2PTransport.datagramBytes)
        }
    }

    func test_all_packets_rebuild_the_frame_in_any_order() {
        let data = payload(10_000)
        var assembler = RemoteVideoReassembler()
        var frames: [Data] = []
        for packet in packets(data).reversed() {
            frames += assembler.receive(packet, now: 1000 * ms).frames
        }
        XCTAssertEqual(frames, [data])
    }

    func test_exact_multiple_of_the_fragment_size_works() {
        let data = payload(RemoteVideoPacketizer.fragmentBytes * 3)
        var assembler = RemoteVideoReassembler()
        var frames: [Data] = []
        for packet in packets(data, fec: 2) {
            frames += assembler.receive(packet, now: 1000 * ms).frames
        }
        XCTAssertEqual(frames, [data])
    }

    // MARK: - 纠错

    func test_one_missing_fragment_per_group_is_rebuilt_without_asking() {
        let data = payload(10_000)
        let all = packets(data, fec: 4)
        let count = RemoteVideoPacketizer.fragmentCount(totalBytes: data.count)
        // 每组丢一个数据分片。
        var assembler = RemoteVideoReassembler()
        var frames: [Data] = []
        for (index, packet) in all.enumerated() where index >= count || index % 4 != 0 {
            frames += assembler.receive(packet, now: 1000 * ms).frames
        }
        XCTAssertEqual(frames, [data])
        XCTAssertEqual(assembler.counters.recoveredByFEC, RemoteVideoPacketizer.parityCount(fragments: count, groupSize: 4))
        XCTAssertEqual(assembler.counters.nackedPackets, 0)
    }

    /// 短尾巴分片的长度要还原对，否则拼出来的帧多几个零，解码器才发现不对。
    func test_rebuilt_last_fragment_keeps_its_real_length() {
        let data = payload(RemoteVideoPacketizer.fragmentBytes * 2 + 7)
        let all = packets(data, fec: 3)
        var assembler = RemoteVideoReassembler()
        var frames: [Data] = []
        for (index, packet) in all.enumerated() where index != 2 {
            frames += assembler.receive(packet, now: 1000 * ms).frames
        }
        XCTAssertEqual(frames, [data])
    }

    func test_two_missing_in_one_group_need_a_retransmission() {
        let data = payload(10_000)
        let all = packets(data, fec: 4)
        var assembler = RemoteVideoReassembler()
        var delivered: [Data] = []
        for (index, packet) in all.enumerated() where index != 0 && index != 1 {
            delivered += assembler.receive(packet, now: 1000 * ms).frames
        }
        XCTAssertTrue(delivered.isEmpty)
        let output = assembler.tick(now: 1020 * ms)
        XCTAssertEqual(output.nacks.first?.indices, [0, 1])
        delivered += assembler.receive(all[0], now: 1060 * ms).frames
        XCTAssertEqual(delivered, [data], "补上一个，另一个由纠错分片算出来")
    }

    // MARK: - 重传请求

    func test_gap_is_only_asked_for_after_the_reorder_wait() {
        let all = packets(payload(5000))
        var assembler = RemoteVideoReassembler()
        _ = assembler.receive(all[0], now: 1000 * ms)
        _ = assembler.receive(all[2], now: 1001 * ms)
        XCTAssertTrue(assembler.tick(now: 1002 * ms).nacks.isEmpty, "可能只是乱序")
        XCTAssertEqual(assembler.tick(now: 1012 * ms).nacks.first?.indices?.contains(1), true)
    }

    func test_tail_loss_is_asked_for_once_the_stream_goes_quiet() {
        let all = packets(payload(5000), roundTrip: 40)
        var assembler = RemoteVideoReassembler()
        _ = assembler.receive(all[0], now: 1000 * ms)
        XCTAssertTrue(assembler.tick(now: 1005 * ms).nacks.isEmpty)
        let nacks = assembler.tick(now: 1020 * ms).nacks
        XCTAssertEqual(nacks.first?.indices, (1..<UInt16(all.count)).map { $0 })
    }

    /// 抖动大的链路上分片会晚到上百毫秒。头一次按 6 ms 判丢、要了重传，原来那份半个往返内就到了：乱序窗口
    /// 撑到那么大，之后同样的乱序不再去要重传（以前每片都要，重传挤掉新分片，2026-11-09 高延迟抖动直连 0 fps）。
    func test_reordering_widens_the_window_and_stops_spurious_requests() {
        var assembler = RemoteVideoReassembler()
        var requested: [[UInt16]] = []
        for frame in 1...2 {
            let all = packets(payload(11_000, seed: UInt8(frame)), sequence: UInt32(frame), deadline: 2000, roundTrip: 300)
            let start = UInt64(frame) * 1000 * ms
            // 第 3 片比第 4 片晚 100 ms。
            var schedule: [(UInt64, Data)] = all.indices.map { (start + UInt64($0) * 2 * ms, all[$0]) }
            schedule[3].0 = schedule[4].0 + 100 * ms
            schedule.sort { $0.0 < $1.0 }
            var now = start
            var next = 0
            while now < start + 400 * ms {
                while next < schedule.count, schedule[next].0 <= now {
                    _ = assembler.receive(schedule[next].1, now: now)
                    next += 1
                }
                requested.append(contentsOf: assembler.tick(now: now).nacks.compactMap(\.indices))
                now += 5 * ms
            }
            if frame == 1 { XCTAssertFalse(requested.isEmpty, "头一次只能按 6 ms 判") ; requested = [] }
        }
        XCTAssertEqual(requested, [], "窗口撑大以后同样的乱序不再要重传")
        XCTAssertGreaterThanOrEqual(assembler.reorderWindow, 100 * ms)
    }

    /// 关键帧（时限超过 5 s）在窄链路上一片片慢慢到，7 s 才到齐：不能在 5 s 时拦腰放弃，否则永远出不来画面。
    /// 刷新帧仍封顶 5 s。
    func test_keyframe_still_arriving_after_five_seconds_is_not_given_up() {
        for (deadline, expectDelivered) in [(5001, true), (5000, false)] {
            let data = payload(150_000)
            let all = packets(data, deadline: deadline, roundTrip: 300)
            var assembler = RemoteVideoReassembler()
            var frames: [Data] = []
            var lost: [UInt32] = []
            let step = 7000 * ms / UInt64(all.count)
            for (index, packet) in all.enumerated() {
                let now = 1000 * ms + UInt64(index) * step
                let output = assembler.receive(packet, now: now)
                frames += output.frames
                lost += output.lost
                lost += assembler.tick(now: now).lost
            }
            if expectDelivered {
                XCTAssertEqual(frames, [data], "关键帧")
                XCTAssertEqual(lost, [])
            } else {
                XCTAssertEqual(lost, [1], "刷新帧到 5 s 放弃")
            }
        }
    }

    func test_requests_are_not_repeated_within_a_round_trip() {
        let all = packets(payload(5000), roundTrip: 100)
        var assembler = RemoteVideoReassembler()
        _ = assembler.receive(all[0], now: 1000 * ms)
        XCTAssertFalse(assembler.tick(now: 1030 * ms).nacks.isEmpty)
        XCTAssertTrue(assembler.tick(now: 1060 * ms).nacks.isEmpty)
        XCTAssertFalse(assembler.tick(now: 1160 * ms).nacks.isEmpty, "一个往返还没来就再要一次")
    }

    func test_nack_round_trips() throws {
        let some = RemoteVideoNack(channel: 7, videoSequence: 9, indices: [1, 2, 3])
        XCTAssertEqual(try RemoteVideoNack(decoding: some.encoded()), some)
        let whole = RemoteVideoNack(channel: 7, videoSequence: 9, indices: nil)
        XCTAssertEqual(try RemoteVideoNack(decoding: whole.encoded()), whole)
    }

    // MARK: - 顺序与放弃

    func test_frames_are_delivered_strictly_in_order() {
        let first = payload(3000, seed: 1), second = payload(3000, seed: 2)
        var assembler = RemoteVideoReassembler()
        var frames: [Data] = []
        for packet in packets(second, sequence: 2) { frames += assembler.receive(packet, now: 1000 * ms).frames }
        XCTAssertTrue(frames.isEmpty, "第 1 帧还没到")
        for packet in packets(first, sequence: 1) { frames += assembler.receive(packet, now: 1010 * ms).frames }
        XCTAssertEqual(frames, [first, second])
    }

    func test_frame_past_its_deadline_is_given_up_and_the_next_one_flows() {
        let first = payload(3000, seed: 1), second = payload(3000, seed: 2)
        var assembler = RemoteVideoReassembler()
        let partial = packets(first, sequence: 1, deadline: 100)
        _ = assembler.receive(partial[0], now: 1000 * ms)
        for packet in packets(second, sequence: 2) { _ = assembler.receive(packet, now: 1010 * ms) }
        XCTAssertTrue(assembler.tick(now: 1050 * ms).lost.isEmpty)
        // 往返 50 ms：最后一片之后再等 140 ms。
        let output = assembler.tick(now: 1141 * ms)
        XCTAssertEqual(output.lost, [1])
        XCTAssertEqual(output.frames, [second])
        XCTAssertEqual(assembler.counters.lostFrames, 1)
    }

    /// 节奏刚被压下去时一帧会发得比预计慢。分片还在到就不算丢，否则降速会引发丢帧，丢帧又引发降速。
    func test_frame_that_is_still_arriving_is_not_given_up() {
        let data = payload(5000)
        let all = packets(data, deadline: 100)
        var assembler = RemoteVideoReassembler()
        var frames: [Data] = []
        for (position, packet) in all.enumerated() {
            let now = (1000 + UInt64(position) * 90) * ms
            frames += assembler.receive(packet, now: now).frames
            XCTAssertTrue(assembler.tick(now: now).lost.isEmpty)
        }
        XCTAssertEqual(frames, [data], "超过了原定的 100 ms，但一直在到")
    }

    func test_slow_frame_still_has_a_hard_limit() {
        let all = packets(payload(50_000), deadline: 100)
        var assembler = RemoteVideoReassembler()
        var lost: [UInt32] = []
        var now = 1000 * ms
        // 一直收到同一个重复的分片，不能靠它无限续命。
        while now < 3000 * ms {
            lost += assembler.receive(all[0], now: now).lost
            lost += assembler.tick(now: now).lost
            now += 50 * ms
        }
        XCTAssertEqual(lost, [1])
    }

    /// 窄链路上的大帧：分片一片片慢慢到，2.5 s 才到齐，计划时长也是这么长——不能在 1.5 s 时拦腰放弃。
    func test_large_slow_frame_is_not_cut_at_the_normal_limit() {
        let data = payload(200_000)
        let all = packets(data, deadline: 2600)
        var assembler = RemoteVideoReassembler()
        var frames: [Data] = []
        var lost: [UInt32] = []
        let step = 2500 * ms / UInt64(all.count)
        for (index, packet) in all.enumerated() {
            let now = 1000 * ms + UInt64(index) * step
            let output = assembler.receive(packet, now: now)
            frames += output.frames
            lost += output.lost
            lost += assembler.tick(now: now).lost
        }
        XCTAssertEqual(lost, [])
        XCTAssertEqual(frames, [data])
    }

    /// 整帧都没到：比它新的帧来了才知道，先要一次，到时限再放弃。
    func test_wholly_missing_frame_is_requested_then_given_up() {
        let third = payload(3000, seed: 3)
        var assembler = RemoteVideoReassembler()
        var frames: [Data] = []
        for packet in packets(third, sequence: 2, deadline: 100) { frames += assembler.receive(packet, now: 1000 * ms).frames }
        XCTAssertTrue(frames.isEmpty)
        let asking = assembler.tick(now: 1040 * ms)
        XCTAssertEqual(asking.nacks.first, RemoteVideoNack(channel: 1, videoSequence: 1, indices: nil))
        let output = assembler.tick(now: 1141 * ms)
        XCTAssertEqual(output.lost, [1])
        XCTAssertEqual(output.frames, [third])
    }

    func test_new_channel_starts_over_and_old_channel_is_ignored() {
        var assembler = RemoteVideoReassembler()
        let newer = RemoteVideoPacketizer.packets(payload: payload(100), channel: 5, videoSequence: 1, fecGroupSize: 0,
                                                  deadlineMillis: 100, roundTripMillis: 10)
        XCTAssertEqual(assembler.receive(newer[0], now: 1000 * ms).frames.count, 1)
        let older = RemoteVideoPacketizer.packets(payload: payload(100), channel: 4, videoSequence: 2, fecGroupSize: 0,
                                                  deadlineMillis: 100, roundTripMillis: 10)
        XCTAssertTrue(assembler.receive(older[0], now: 1001 * ms).frames.isEmpty)
        let again = RemoteVideoPacketizer.packets(payload: payload(100), channel: 6, videoSequence: 1, fecGroupSize: 0,
                                                  deadlineMillis: 100, roundTripMillis: 10)
        XCTAssertEqual(assembler.receive(again[0], now: 1002 * ms).frames.count, 1)
    }

    func test_garbage_and_lies_do_not_crash_or_allocate() {
        var assembler = RemoteVideoReassembler()
        XCTAssertTrue(assembler.receive(Data(), now: 0).frames.isEmpty)
        XCTAssertTrue(assembler.receive(Data(repeating: 0xFF, count: 40), now: 0).frames.isEmpty)
        // 声称 4 GB 的帧。
        var writer = RemoteByteWriter(capacity: 40)
        RemoteVideoPacketHeader(channel: 1, videoSequence: 1, totalBytes: .max, index: 0, fecGroupSize: 0,
                                deadlineMillis: 100, roundTripMillis: 10).write(to: &writer)
        XCTAssertTrue(assembler.receive(writer.data, now: 0).frames.isEmpty)
        XCTAssertFalse(assembler.hasWork)
    }

    // MARK: - 发送端

    func test_buffer_serves_retransmissions_and_forgets_acknowledged_frames() {
        var buffer = RemoteVideoSendBuffer()
        let sent = buffer.add(payload: payload(3000), sequence: 42, channel: 1, fecGroupSize: 0, deadlineMillis: 200,
                              roundTripMillis: 50, now: 1000 * ms)
        let nack = RemoteVideoNack(channel: 1, videoSequence: 1, indices: [1])
        XCTAssertEqual(buffer.packets(for: nack, now: 1010 * ms), [sent[1]])
        buffer.acknowledge(sequence: 42)
        XCTAssertTrue(buffer.packets(for: nack, now: 1020 * ms).isEmpty)
        XCTAssertTrue(buffer.isEmpty)
    }

    func test_buffer_maps_lost_frames_back_to_encoder_sequences() {
        var buffer = RemoteVideoSendBuffer()
        _ = buffer.add(payload: payload(100), sequence: 10, channel: 1, fecGroupSize: 0, deadlineMillis: 200,
                       roundTripMillis: 50, now: 0)
        _ = buffer.add(payload: payload(100), sequence: 12, channel: 1, fecGroupSize: 0, deadlineMillis: 200,
                       roundTripMillis: 50, now: 0)
        XCTAssertEqual(buffer.markLost(videoSequences: [2, 99]), [12], "视频序号没有空洞，编码序号有")
    }

    func test_buffer_probes_the_tail_until_the_deadline() {
        var buffer = RemoteVideoSendBuffer()
        let sent = buffer.add(payload: payload(3000), sequence: 1, channel: 1, fecGroupSize: 2, deadlineMillis: 500,
                              roundTripMillis: 50, now: 1000 * ms)
        XCTAssertTrue(buffer.probes(now: 1010 * ms, roundTripNanos: 50 * ms).isEmpty, "还没到一个往返")
        let probes = buffer.probes(now: 1070 * ms, roundTripNanos: 50 * ms)
        XCTAssertTrue(probes.contains(sent.last!))
        XCTAssertTrue(buffer.probes(now: 1600 * ms, roundTripNanos: 50 * ms).isEmpty, "过了时限不再探测")
    }

    func test_buffer_expires_frames_nobody_answered_for() {
        var buffer = RemoteVideoSendBuffer()
        _ = buffer.add(payload: payload(100), sequence: 7, channel: 1, fecGroupSize: 0, deadlineMillis: 100,
                       roundTripMillis: 50, now: 1000 * ms)
        XCTAssertTrue(buffer.expire(now: 1150 * ms, graceNanos: 100 * ms).isEmpty)
        XCTAssertEqual(buffer.expire(now: 1250 * ms, graceNanos: 100 * ms), [7])
        XCTAssertTrue(buffer.isEmpty)
    }

    /// 关键帧接收端会等到 `frameWaitCap`（最长 30 s）：发送端也留着它、不提前按丢失处理（否则再发一个一样大的
    /// 关键帧排在后面）。普通帧照旧。
    func test_buffer_keeps_keyframes_as_long_as_the_receiver_waits() {
        var buffer = RemoteVideoSendBuffer()
        _ = buffer.add(payload: payload(100), sequence: 7, channel: 1, fecGroupSize: 0, deadlineMillis: 8000,
                       roundTripMillis: 300, now: 0)
        _ = buffer.add(payload: payload(100), sequence: 8, channel: 1, fecGroupSize: 0, deadlineMillis: 100,
                       roundTripMillis: 300, now: 0)
        XCTAssertEqual(buffer.expire(now: 9000 * ms, graceNanos: 800 * ms), [8])
        _ = buffer.add(payload: payload(100), sequence: 9, channel: 1, fecGroupSize: 0, deadlineMillis: 100,
                       roundTripMillis: 300, now: 10_000 * ms)
        XCTAssertFalse(buffer.packets(for: RemoteVideoNack(channel: 1, videoSequence: 1, indices: [0]), now: 10_000 * ms)
            .isEmpty, "过了 6 s 还留着关键帧")
        XCTAssertEqual(buffer.expire(now: 12_900 * ms, graceNanos: 800 * ms), [7, 9])
    }

    func test_buffer_memory_is_bounded() {
        var buffer = RemoteVideoSendBuffer(limits: .init(maxFrames: 4, maxBytes: 1_000_000, maxAgeNanos: 1_000_000_000))
        for index in 0..<10 {
            _ = buffer.add(payload: payload(100), sequence: UInt32(index), channel: 1, fecGroupSize: 0, deadlineMillis: 100,
                           roundTripMillis: 50, now: 0)
        }
        XCTAssertTrue(buffer.packets(for: RemoteVideoNack(channel: 1, videoSequence: 1, indices: [0]), now: 0).isEmpty)
        XCTAssertFalse(buffer.packets(for: RemoteVideoNack(channel: 1, videoSequence: 10, indices: [0]), now: 0).isEmpty)
    }

    // MARK: - 闭环

    /// 发送端和接收端接起来，在确定的随机丢包下跑一长串帧，策略要真的把画面救回来。
    private func simulate(loss: Double, fec: Int, roundTripMillis: UInt64 = 60, frames: Int = 300,
                          frameBytes: Int = 8000) -> (delivered: Int, lost: Int, fecRecovered: Int, nacked: Int, overhead: Double) {
        var seed: UInt64 = 42
        func chance(_ probability: Double) -> Bool {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53) < probability
        }
        var buffer = RemoteVideoSendBuffer()
        var assembler = RemoteVideoReassembler()
        var inFlight: [(arrival: UInt64, packet: Data)] = []
        var nackFlight: [(arrival: UInt64, nack: RemoteVideoNack)] = []
        var delivered = 0, lost = 0, dataPackets = 0, allPackets = 0
        let oneWay = roundTripMillis * ms / 2
        var now: UInt64 = 1000 * ms
        let end = now + UInt64(frames) * 33 * ms + 1000 * ms
        var nextFrame = now
        var produced = 0
        let send = { (packet: Data, at: UInt64) in
            allPackets += 1
            if !chance(loss) { inFlight.append((at + oneWay, packet)) }
        }
        while now < end {
            if produced < frames, now >= nextFrame {
                produced += 1
                nextFrame += 33 * ms
                let deadline = RemoteLossPolicy.frameDeadlineMillis(frameBytes: frameBytes, roundTripNanos: roundTripMillis * ms,
                                                                    pacingRate: 1_000_000)
                let packets = buffer.add(payload: payload(frameBytes, seed: UInt8(truncatingIfNeeded: produced)),
                                         sequence: UInt32(produced), channel: 1, fecGroupSize: fec, deadlineMillis: deadline,
                                         roundTripMillis: Int(roundTripMillis), now: now)
                dataPackets += RemoteVideoPacketizer.fragmentCount(totalBytes: frameBytes)
                for packet in packets { send(packet, now) }
            }
            for item in nackFlight where item.arrival <= now {
                for packet in buffer.packets(for: item.nack, now: now) { send(packet, now) }
            }
            nackFlight.removeAll { $0.arrival <= now }
            var output = RemoteVideoReassembler.Output()
            let arrived = inFlight.filter { $0.arrival <= now }
            inFlight.removeAll { $0.arrival <= now }
            for item in arrived {
                let step = assembler.receive(item.packet, now: now)
                output.frames += step.frames
                output.lost += step.lost
                output.nacks += step.nacks
            }
            let tick = assembler.tick(now: now)
            output.frames += tick.frames
            output.lost += tick.lost
            output.nacks += tick.nacks
            delivered += output.frames.count
            lost += output.lost.count
            for nack in output.nacks where !chance(loss) { nackFlight.append((now + oneWay, nack)) }
            now += ms
        }
        return (delivered, lost, assembler.counters.recoveredByFEC, assembler.counters.nackedPackets,
                Double(allPackets) / Double(dataPackets) - 1)
    }

    func test_no_loss_costs_nothing() {
        let result = simulate(loss: 0, fec: 0)
        XCTAssertEqual(result.delivered, 300)
        XCTAssertEqual(result.lost, 0)
        XCTAssertEqual(result.nacked, 0)
        XCTAssertEqual(result.overhead, 0, accuracy: 0.001)
    }

    func test_one_percent_loss_loses_no_frames() {
        let result = simulate(loss: 0.01, fec: 16)
        print("[丢包模拟] 1%：交付 \(result.delivered)，放弃 \(result.lost)，纠错 \(result.fecRecovered)，请求 \(result.nacked)，开销 \(result.overhead)")
        XCTAssertEqual(result.lost, 0)
        XCTAssertEqual(result.delivered, 300)
        XCTAssertLessThan(result.overhead, 0.15)
    }

    func test_five_percent_loss_loses_almost_no_frames() {
        let result = simulate(loss: 0.05, fec: 5)
        print("[丢包模拟] 5%：交付 \(result.delivered)，放弃 \(result.lost)，纠错 \(result.fecRecovered)，请求 \(result.nacked)，开销 \(result.overhead)")
        XCTAssertLessThanOrEqual(result.lost, 1)
        XCTAssertGreaterThan(result.fecRecovered, result.nacked, "大部分靠纠错，不用等一个往返")
    }

    func test_twenty_percent_loss_still_delivers_most_frames() {
        let result = simulate(loss: 0.20, fec: 3)
        print("[丢包模拟] 20%：交付 \(result.delivered)，放弃 \(result.lost)，纠错 \(result.fecRecovered)，请求 \(result.nacked)，开销 \(result.overhead)")
        XCTAssertGreaterThan(result.delivered, 270)
    }

    func test_fec_avoids_waiting_for_a_round_trip() {
        let without = simulate(loss: 0.03, fec: 0)
        let with = simulate(loss: 0.03, fec: 8)
        XCTAssertLessThan(with.nacked, without.nacked / 2)
    }
}
