import XCTest
@testable import uTerm

/// holder 协议冻结之后要和各版本的 App 共存：解码不能因为字段不全崩溃，不认识的帧要能切出来再忽略。
final class HolderProtocolTests: XCTestCase {

    func test_frames_split_across_arbitrary_reads() throws {
        let frames = [HolderFrame(.input, payload: [1, 2, 3]), HolderFrame(.terminate), HolderFrame(.output, payload: Array(repeating: 7, count: 5000))]
        let bytes = frames.flatMap { $0.encoded() }
        var reader = HolderFrameReader()
        var decoded: [HolderFrame] = []
        var cursor = 0
        while cursor < bytes.count {
            let end = min(cursor + 3, bytes.count)
            bytes[cursor..<end].withUnsafeBytes { reader.append($0) }
            cursor = end
            while let frame = try reader.next() { decoded.append(frame) }
        }
        XCTAssertEqual(decoded, frames)
    }

    func test_unknown_frame_kind_is_read_and_exposed_as_nil() throws {
        var reader = HolderFrameReader()
        let unknown = HolderFrame(kindRaw: 250, payload: [9, 9])
        let known = HolderFrame(.redraw)
        (unknown.encoded() + known.encoded()).withUnsafeBytes { reader.append($0) }
        let first = try XCTUnwrap(reader.next())
        XCTAssertNil(first.kind)
        XCTAssertEqual(try reader.next()?.kind, .redraw)
    }

    func test_oversized_frame_is_rejected_before_allocating() {
        var reader = HolderFrameReader()
        var writer = HolderByteWriter()
        writer.u32(UInt32(HolderProtocol.maxFrameBytes + 1))
        writer.bytes.withUnsafeBytes { reader.append($0) }
        XCTAssertThrowsError(try reader.next())
    }

    func test_truncated_payloads_decode_to_nil_instead_of_crashing() {
        let hello = HolderHelloReply(version: 1, shellPID: 42, createdAt: 7, cols: 80, rows: 24, exitStatus: 3, attributes: [1, 2]).encoded()
        XCTAssertEqual(HolderHelloReply(decoding: hello)?.exitStatus, 3)
        XCTAssertEqual(HolderHelloReply(decoding: hello)?.attributes, [1, 2])
        for length in 0..<(hello.count - 2) {
            XCTAssertNil(HolderHelloReply(decoding: Array(hello[0..<length])), "长度 \(length)")
        }
        let checkpoint = HolderCheckpoint(offset: 9, cols: 80, rows: 24, hasGap: true, blob: [5]).encoded()
        XCTAssertEqual(HolderCheckpoint(decoding: checkpoint)?.blob, [5])
        XCTAssertEqual(HolderCheckpoint(decoding: checkpoint)?.hasGap, true)
        XCTAssertNil(HolderCheckpoint(decoding: Array(checkpoint[0..<5])))
    }

    func test_byte_queue_keeps_order_across_compaction() {
        var queue = HolderByteQueue()
        var expected: [UInt8] = []
        for round in 0..<200 {
            let chunk = (0..<97).map { UInt8(truncatingIfNeeded: $0 &+ round) }
            queue.append(chunk)
            expected += chunk
            let taken = queue.withReadable { Array($0.prefix(61)) }
            XCTAssertEqual(taken, Array(expected.prefix(61)))
            queue.consume(61)
            expected.removeFirst(61)
        }
        XCTAssertEqual(queue.count, expected.count)
        XCTAssertEqual(queue.withReadable { Array($0) }, expected)
    }

    // MARK: - 环形缓冲

    private func append(_ log: inout HolderOutputLog, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { log.append($0) }
    }

    func test_log_returns_everything_while_under_capacity_and_grows_past_initial_storage() {
        var log = HolderOutputLog(capacity: 1024 * 1024)
        let bytes = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 % 251) }
        append(&log, Array(bytes[0..<70_000]))
        append(&log, Array(bytes[70_000...]))
        XCTAssertEqual(log.startOffset, 0)
        XCTAssertEqual(log.endOffset, 200_000)
        XCTAssertEqual(log.read(from: 0, maxBytes: 300_000), bytes)
        XCTAssertEqual(log.read(from: 199_999, maxBytes: 10), [bytes[199_999]])
        XCTAssertEqual(log.read(from: 200_000, maxBytes: 10), [])
    }

    func test_log_wraps_and_keeps_only_the_tail() {
        var log = HolderOutputLog(capacity: 1000)
        let bytes = (0..<3700).map { UInt8(truncatingIfNeeded: $0 % 253) }
        var cursor = 0
        // 块大小故意不整除容量，绕回发生在块中间。
        while cursor < bytes.count {
            let end = min(cursor + 317, bytes.count)
            append(&log, Array(bytes[cursor..<end]))
            cursor = end
        }
        XCTAssertEqual(log.startOffset, 2700)
        XCTAssertEqual(log.read(from: 2700, maxBytes: 5000), Array(bytes[2700...]))
        XCTAssertEqual(log.read(from: 3650, maxBytes: 10), Array(bytes[3650..<3660]))
        XCTAssertNil(log.read(from: 2699, maxBytes: 1), "已被覆盖")
        XCTAssertNil(log.read(from: 3701, maxBytes: 1), "还没写到")
    }

    func test_log_single_append_larger_than_capacity() {
        var log = HolderOutputLog(capacity: 1000)
        append(&log, [1, 2, 3])
        let huge = (0..<5000).map { UInt8(truncatingIfNeeded: $0 % 241) }
        append(&log, huge)
        XCTAssertEqual(log.endOffset, 5003)
        XCTAssertEqual(log.read(from: log.startOffset, maxBytes: 5000), Array(huge.suffix(1000)))
    }

    /// 洪水不能让内存跟着涨（iGhostVT 踩过 45 秒涨到 1.1 GB）：存储只到容量为止，而且一直读得出最新内容。
    func test_log_flood_stays_within_capacity() {
        let capacity = 16 * 1024 * 1024
        var log = HolderOutputLog(capacity: capacity)
        let chunk = [UInt8](repeating: 0x41, count: 1024 * 1024)
        for _ in 0..<128 { append(&log, chunk) }
        XCTAssertEqual(log.endOffset, 128 * 1024 * 1024)
        XCTAssertEqual(log.endOffset - log.startOffset, UInt64(capacity))
        XCTAssertEqual(log.read(from: log.startOffset, maxBytes: capacity)?.count, capacity)
    }

    // MARK: - 检查点的版本头
    //
    // 原来这里核的是 `TerminalOutputBuffer` 的丢弃计数（检查点要靠它算出终端看到了输出流的哪个位置）。新的输出泵不丢
    // 字节，那个缓冲和计数都删了；检查点这一侧现在要保证的是：只认同一个引擎版本存的快照。

    func test_checkpoint_blob_is_only_accepted_from_the_same_engine_version() throws {
        let terminal = ShadowTerminal(cols: 40, rows: 6, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        terminal.feed(Data("history\r\n$ ".utf8))
        let snapshot = try terminal.snapshot()

        let blob = TerminalCheckpointBlob.encode(snapshot: snapshot)
        XCTAssertEqual(TerminalCheckpointBlob.decode(blob), snapshot)
        XCTAssertNil(TerminalCheckpointBlob.decode(blob, engine: "ghostty-ffffffff+p0000/snapshot-9"), "别的引擎版本存的：丢弃")
        XCTAssertNil(TerminalCheckpointBlob.decode(Array("\u{1B}c\u{1B}[2Jold VT checkpoint".utf8)), "没有版本头的旧检查点：丢弃")
        XCTAssertNil(TerminalCheckpointBlob.decode([]))

        let restored = ShadowTerminal(cols: 80, rows: 24, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        try restored.restore(snapshot: XCTUnwrap(TerminalCheckpointBlob.decode(blob)))
        XCTAssertEqual(restored.recentLines(5).lines, ["history", "$"])
    }

    /// 只差渲染补丁的版本（`TerminalEngineVersion.sameSnapshotFormat`）存的快照照认：更新 App 之后旧终端照常接回。
    func test_checkpoint_blob_from_a_render_only_engine_change_is_accepted() throws {
        let terminal = ShadowTerminal(cols: 40, rows: 6, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        terminal.feed(Data("history\r\n$ ".utf8))
        let snapshot = try terminal.snapshot()
        for (old, new) in TerminalEngineVersion.sameSnapshotFormat {
            XCTAssertEqual(TerminalCheckpointBlob.decode(TerminalCheckpointBlob.encode(snapshot: snapshot, engine: old)), snapshot,
                           "\(old) 存的检查点")
            XCTAssertEqual(TerminalCheckpointBlob.decode(TerminalCheckpointBlob.encode(snapshot: snapshot), engine: new), snapshot,
                           "反过来：\(new) 存的给旧引擎读")
        }
    }

    /// 不带回放流时仍是第 2 版、逐字节和以前一样（同引擎的旧版本 App 照样读得懂）；带了是第 3 版，三段都能取回，
    /// 回放流不核引擎版本。
    func test_checkpoint_blob_carries_an_engine_independent_replay_stream() throws {
        let snapshot = Data("binary snapshot".utf8)
        let status = Data(#"{"records":[]}"#.utf8)
        let replay = Data("\u{1b}[2Jreplay".utf8)

        let plain = TerminalCheckpointBlob.encode(snapshot: snapshot, programStatus: status)
        let engine = Array(TerminalEngineVersion.current.utf8)
        XCTAssertEqual(plain, Array("uTermCP\u{2}".utf8) + [UInt8(engine.count)] + engine + [0, 0, 0, UInt8(status.count)]
                       + Array(status) + Array(snapshot), "不带回放流的格式不能变")
        XCTAssertNil(TerminalCheckpointBlob.decodeReplay(plain))

        let foreign = "ghostty-ffffffff+p0000/snapshot-9"
        let withReplay = TerminalCheckpointBlob.encode(snapshot: snapshot, programStatus: status, replay: replay, engine: foreign)
        XCTAssertEqual(Array(withReplay.prefix(8)), Array("uTermCP\u{3}".utf8))
        XCTAssertNil(TerminalCheckpointBlob.decode(withReplay), "快照仍然只认格式相同的引擎")
        XCTAssertEqual(TerminalCheckpointBlob.decode(withReplay, engine: foreign), snapshot)
        XCTAssertEqual(TerminalCheckpointBlob.decodeReplay(withReplay), replay)
        XCTAssertEqual(TerminalCheckpointBlob.decodeProgramStatus(withReplay), status)

        // 没有程序状态时两段长度前缀照样对齐。
        let noStatus = TerminalCheckpointBlob.encode(snapshot: snapshot, replay: replay)
        XCTAssertEqual(TerminalCheckpointBlob.decode(noStatus), snapshot)
        XCTAssertEqual(TerminalCheckpointBlob.decodeReplay(noStatus), replay)
        XCTAssertNil(TerminalCheckpointBlob.decodeProgramStatus(noStatus))

        // 截断在回放流里：整张不认，不拿半截当快照。
        let cut = Array(withReplay.prefix(withReplay.count - snapshot.count - 3))
        XCTAssertNil(TerminalCheckpointBlob.decode(cut, engine: foreign))
        XCTAssertNil(TerminalCheckpointBlob.decodeReplay(cut))
    }

    /// `localNetworkUnreachable` 是后加的可选字段：旧 `uterm-ssh` 发的失败没有它，新 App 照样解；反过来旧 App 忽略它。
    func test_bridge_failure_decodes_with_and_without_local_network_flag() throws {
        let old = Data(#"{"kind":"connect","message":"x"}"#.utf8)
        let decodedOld = try JSONDecoder().decode(SSHBridgeFailure.self, from: old)
        XCTAssertNil(decodedOld.localNetworkUnreachable)

        var failure = SSHBridgeFailure(kind: .connect, message: "路由不可达")
        failure.localNetworkUnreachable = true
        let roundTrip = try JSONDecoder().decode(SSHBridgeFailure.self, from: JSONEncoder().encode(failure))
        XCTAssertEqual(roundTrip.localNetworkUnreachable, true)
    }
}
