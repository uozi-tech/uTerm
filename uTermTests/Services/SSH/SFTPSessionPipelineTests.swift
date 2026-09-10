import NIOCore
import XCTest
@testable import uTerm

/// SFTP 流水线读写（`SFTPPipeline`）的行为闸。
///
/// 被测的是**并发形状**，不是网络：`RecordingFile` 是一个可注入的假文件，
/// 记录每个请求的 offset / 长度、峰值在途数、以及是否被取消。真实的
/// `Citadel.SFTPFile` 只能靠一条活着的 SSH 通道拿到，单测造不出来 —— 这也是
/// `SFTPPipelineFile` 这层协议存在的理由。
final class SFTPSessionPipelineTests: XCTestCase {

    // MARK: - 夹具

    /// 假文件：内存 blob + 请求账本 + 可注入的延迟 / 失败 / 短读。
    private actor RecordingFile: SFTPPipelineFile {
        private(set) var writes: [(offset: UInt64, bytes: Int)] = []
        private(set) var reads: [(offset: UInt64, length: UInt32)] = []
        private(set) var peakInFlight = 0
        private(set) var cancelledRequests = 0
        private var inFlight = 0
        private var storage: [UInt8] = []

        /// 每个请求在应答前先睡这么久，好让「在途窗口」真的挤满。
        var latency: Duration = .milliseconds(2)
        /// 这些 offset 的写请求抛错。
        var failingWriteOffsets: Set<UInt64> = []
        /// 文件的逻辑大小；读超过它就短（EOF）。nil = 用 `storage.count`。
        var eofAt: Int?
        /// 单次读最多给这么多字节（模拟服务端短读），nil = 给满。
        var shortReadCap: Int?
        /// 落在这个区间里的读一律回空 —— 模拟服务端在文件中间凭空谎报 EOF。
        var blackHole: Range<UInt64>?
        /// 这些 offset 的**第一次**读只给 100 字节，之后正常（一次性短读）。
        var shortReadOnceOffsets: Set<UInt64> = []

        init(contents: [UInt8] = []) { self.storage = contents }

        func setLatency(_ value: Duration) { latency = value }
        func setFailingWriteOffsets(_ value: Set<UInt64>) { failingWriteOffsets = value }
        func setShortReadCap(_ value: Int?) { shortReadCap = value }
        func setBlackHole(_ value: Range<UInt64>?) { blackHole = value }
        func setShortReadOnceOffsets(_ value: Set<UInt64>) { shortReadOnceOffsets = value }

        func bytes() -> [UInt8] { storage }

        private func enter() {
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
        }

        private func leave() { inFlight -= 1 }

        func writeChunk(_ data: ByteBuffer, at offset: UInt64) async throws {
            enter()
            defer { leave() }
            // 失败在 sleep **之前**判：这样失败的那片立刻返回，其余仍在途，
            // 「取消其余」才是确定性的而不是靠赛跑。
            if failingWriteOffsets.contains(offset) {
                throw NSError(domain: "RecordingFile", code: 13, userInfo: [
                    NSLocalizedDescriptionKey: "write denied @ \(offset)"
                ])
            }
            do {
                try await Task.sleep(for: latency)
            } catch {
                cancelledRequests += 1
                throw error
            }
            writes.append((offset, data.readableBytes))
            let start = Int(offset)
            let end = start + data.readableBytes
            if storage.count < end { storage.append(contentsOf: [UInt8](repeating: 0, count: end - storage.count)) }
            storage.replaceSubrange(start..<end, with: data.readableBytesView)
        }

        func readChunk(from offset: UInt64, length: UInt32) async throws -> ByteBuffer {
            enter()
            defer { leave() }
            do {
                try await Task.sleep(for: latency)
            } catch {
                cancelledRequests += 1
                throw error
            }
            reads.append((offset, length))
            if let blackHole, blackHole.contains(offset) { return ByteBuffer() }
            let limit = eofAt ?? storage.count
            let start = min(Int(offset), limit)
            var want = min(Int(length), limit - start)
            if let shortReadCap { want = min(want, shortReadCap) }
            if shortReadOnceOffsets.contains(offset) {
                shortReadOnceOffsets.remove(offset)
                want = min(want, 100)
            }
            guard want > 0 else { return ByteBuffer() }
            var buffer = ByteBuffer()
            buffer.writeBytes(storage[start..<(start + want)])
            return buffer
        }
    }

    private func payload(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    }

    private func buffer(_ bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        return buffer
    }

    // MARK: - 写

    /// 切片必须**恰好**覆盖整段、不重叠、每片不超过 32 000 B（swift-nio-ssh #99 的上限）。
    func testWriteSlicesCoverTheWholeRangeWithoutOverlap() async throws {
        let bytes = payload(100_000)
        let file = RecordingFile()
        await file.setLatency(.zero)

        try await SFTPPipeline.write(file, data: buffer(bytes), at: 0, inFlight: 8)

        let writes = await file.writes.sorted { $0.offset < $1.offset }
        XCTAssertEqual(writes.count, 4, "100 000 B / 32 000 B = 4 片")
        XCTAssertEqual(writes.map(\.bytes), [32_000, 32_000, 32_000, 4_000])
        var expected: UInt64 = 0
        for write in writes {
            XCTAssertEqual(write.offset, expected, "切片必须首尾相接，不重叠也不留洞")
            XCTAssertLessThanOrEqual(write.bytes, SFTPPipeline.chunkSize)
            expected += UInt64(write.bytes)
        }
        XCTAssertEqual(expected, 100_000)
        let stored = await file.bytes()
        XCTAssertEqual(stored, bytes, "并发写完的内容要与源逐字节一致")
    }

    /// 起始 offset 非 0 时（分片续写），所有请求都从 base 起算。
    func testWriteHonoursTheBaseOffset() async throws {
        let bytes = payload(70_000)
        let file = RecordingFile(contents: [UInt8](repeating: 0, count: 1_000_000))
        await file.setLatency(.zero)

        try await SFTPPipeline.write(file, data: buffer(bytes), at: 500_000, inFlight: 4)

        let writes = await file.writes.sorted { $0.offset < $1.offset }
        XCTAssertEqual(writes.first?.offset, 500_000)
        XCTAssertEqual(writes.map(\.offset), [500_000, 532_000, 564_000])
        let stored = await file.bytes()
        XCTAssertEqual(Array(stored[500_000..<570_000]), bytes)
    }

    /// 在途请求数不得越过 `inFlight`，而且要真的用满（否则等于没并发）。
    func testWriteKeepsInFlightRequestsWithinTheWindow() async throws {
        let bytes = payload(32_000 * 40)
        let file = RecordingFile()
        await file.setLatency(.milliseconds(4))

        try await SFTPPipeline.write(file, data: buffer(bytes), at: 0, inFlight: 6)

        let peak = await file.peakInFlight
        XCTAssertLessThanOrEqual(peak, 6, "在途数越过窗口 = 内存与通道窗口都失控")
        XCTAssertGreaterThan(peak, 1, "峰值只有 1 说明退化回串行了")
    }

    func testWriteWithInFlightOneIsSerial() async throws {
        let bytes = payload(96_000)
        let file = RecordingFile()
        await file.setLatency(.milliseconds(1))

        try await SFTPPipeline.write(file, data: buffer(bytes), at: 0, inFlight: 1)

        let peak = await file.peakInFlight
        XCTAssertEqual(peak, 1)
        let writes = await file.writes
        XCTAssertEqual(writes.map(\.offset), [0, 32_000, 64_000], "串行时顺序也该是有序的")
    }

    /// 某一片失败：抛的是**原错误**，其余在途请求被取消，并且不会继续往下发新片。
    func testWriteFailurePropagatesOriginalErrorAndCancelsTheRest() async throws {
        let bytes = payload(32_000 * 40)
        let file = RecordingFile()
        await file.setLatency(.milliseconds(200))
        await file.setFailingWriteOffsets([32_000])

        do {
            try await SFTPPipeline.write(file, data: buffer(bytes), at: 0, inFlight: 4)
            XCTFail("有一片写失败，整体必须失败")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "RecordingFile", "错误要原样上抛，不能包一层")
            XCTAssertEqual(error.code, 13)
        }

        let writes = await file.writes
        XCTAssertLessThan(writes.count, 40, "失败后不该把剩下的片全发完")
        let cancelled = await file.cancelledRequests
        XCTAssertGreaterThan(cancelled, 0, "在途的其余请求应被取消")
    }

    func testWriteOfEmptyDataSendsNothing() async throws {
        let file = RecordingFile()
        try await SFTPPipeline.write(file, data: ByteBuffer(), at: 0)
        let writes = await file.writes
        XCTAssertTrue(writes.isEmpty)
    }

    // MARK: - 读

    func testReadReassemblesSegmentsInOrder() async throws {
        let bytes = payload(100_000)
        let file = RecordingFile(contents: bytes)
        await file.setLatency(.zero)

        let result = try await SFTPPipeline.read(file, offset: 0, length: 100_000, inFlight: 8)

        XCTAssertEqual(Array(result.readableBytesView), bytes)
        let reads = await file.reads
        XCTAssertEqual(reads.count, 4)
        XCTAssertEqual(reads.map(\.length).sorted(), [4_000, 32_000, 32_000, 32_000])
    }

    func testReadHonoursOffsetAndLength() async throws {
        let bytes = payload(200_000)
        let file = RecordingFile(contents: bytes)
        await file.setLatency(.zero)

        let result = try await SFTPPipeline.read(file, offset: 40_000, length: 50_000, inFlight: 4)

        XCTAssertEqual(Array(result.readableBytesView), Array(bytes[40_000..<90_000]))
        let reads = await file.reads.sorted { $0.offset < $1.offset }
        XCTAssertEqual(reads.first?.offset, 40_000)
        XCTAssertEqual(reads.last.map { $0.offset + UInt64($0.length) }, 90_000)
    }

    /// 服务端只给一半就返回（SFTP 允许短读）：对剩下的区间补发，最终仍读满。
    func testReadResendsOnShortReads() async throws {
        let bytes = payload(64_000)
        let file = RecordingFile(contents: bytes)
        await file.setLatency(.zero)
        await file.setShortReadCap(1_000)   // 每次最多给 1 000 B

        let result = try await SFTPPipeline.read(file, offset: 0, length: 64_000, inFlight: 2)

        XCTAssertEqual(Array(result.readableBytesView), bytes, "短读必须补发到读满")
        let reads = await file.reads
        XCTAssertEqual(reads.count, 64, "64 000 B / 1 000 B = 64 个请求（每段各自补发）")
    }

    /// 到 EOF：返回的字节数少于请求的长度，而不是报错。
    func testReadStopsAtEOFAndReturnsShort() async throws {
        let bytes = payload(50_000)
        let file = RecordingFile(contents: bytes)
        await file.setLatency(.zero)

        let result = try await SFTPPipeline.read(file, offset: 0, length: 200_000, inFlight: 8)

        XCTAssertEqual(result.readableBytes, 50_000)
        XCTAssertEqual(Array(result.readableBytesView), bytes)
    }

    func testReadPastEOFReturnsEmpty() async throws {
        let file = RecordingFile(contents: payload(1_000))
        await file.setLatency(.zero)
        let result = try await SFTPPipeline.read(file, offset: 5_000, length: 32_000)
        XCTAssertEqual(result.readableBytes, 0)
    }

    func testReadKeepsInFlightRequestsWithinTheWindow() async throws {
        let file = RecordingFile(contents: payload(32_000 * 40))
        await file.setLatency(.milliseconds(4))

        _ = try await SFTPPipeline.read(file, offset: 0, length: 32_000 * 40, inFlight: 5)

        let peak = await file.peakInFlight
        XCTAssertLessThanOrEqual(peak, 5)
        XCTAssertGreaterThan(peak, 1)
    }

    func testReadOfZeroLengthSendsNothing() async throws {
        let file = RecordingFile(contents: payload(10))
        let result = try await SFTPPipeline.read(file, offset: 0, length: 0)
        XCTAssertEqual(result.readableBytes, 0)
        let reads = await file.reads
        XCTAssertTrue(reads.isEmpty)
    }

    // MARK: - 读：短读 / 空洞的完整性闸

    /// 一次性短读（服务端某一段先只给 100 B，其余下一次再给）必须在**同一 offset**
    /// 补发到读满，而不是把这段当成 EOF 把后面的数据全丢掉。
    func testReadResendsAfterASingleShortSegmentAndKeepsTheRest() async throws {
        let bytes = payload(96_000)
        let file = RecordingFile(contents: bytes)
        await file.setLatency(.zero)
        await file.setShortReadOnceOffsets([32_000])   // 第 1 段先只给 100 B

        let result = try await SFTPPipeline.read(
            file, offset: 0, length: 96_000, inFlight: 4, requireFullLength: true)

        XCTAssertEqual(Array(result.readableBytesView), bytes,
                       "一次短读之后的字节一个都不能少（12 MiB 变 116 KiB 就是这么来的）")
        let reads = await file.reads
        XCTAssertEqual(reads.count, 4, "3 段 + 短读那段补发一次")
    }

    /// 中间某段永远读到空（服务端异常 / 并发截断）：必须抛错，
    /// **绝不**把「空洞后面的数据」悄悄丢掉然后报成功。
    func testReadRefusesToSwallowAHoleInTheMiddle() async throws {
        let bytes = payload(128_000)
        let file = RecordingFile(contents: bytes)
        await file.setLatency(.zero)
        await file.setBlackHole(32_000..<64_000)   // 第 1 段恒空，第 2、3 段仍有数据

        do {
            _ = try await SFTPPipeline.read(file, offset: 0, length: 128_000, inFlight: 8)
            XCTFail("中间出现空洞时必须抛错，而不是回一段残缺数据")
        } catch let error as SFTPShortReadError {
            XCTAssertEqual(error.offset, 64_000, "报的是空洞之后那段的起点")
            XCTAssertEqual(error.expected, 0)
            XCTAssertGreaterThan(error.actual, 0)
        }
    }

    /// `requireFullLength`：调用方已经 stat 过，这些字节一定存在 —— 任何一段没读满
    /// 都是错误，不许当 EOF 收尾。
    func testReadWithRequireFullLengthRejectsAShortTail() async throws {
        let bytes = payload(50_000)
        let file = RecordingFile(contents: bytes)
        await file.setLatency(.zero)

        do {
            _ = try await SFTPPipeline.read(
                file, offset: 0, length: 100_000, inFlight: 4, requireFullLength: true)
            XCTFail("声明长度读不满必须抛错")
        } catch let error as SFTPShortReadError {
            XCTAssertEqual(error.offset, 32_000)
            XCTAssertEqual(error.expected, 32_000)
            XCTAssertEqual(error.actual, 18_000)
        }
    }

    /// 严格档在数据齐全时照常返回（别把闸门做成永远拦）。
    func testReadWithRequireFullLengthPassesWhenEverySegmentIsFull() async throws {
        let bytes = payload(100_000)
        let file = RecordingFile(contents: bytes)
        await file.setLatency(.zero)

        let result = try await SFTPPipeline.read(
            file, offset: 0, length: 100_000, inFlight: 8, requireFullLength: true)

        XCTAssertEqual(Array(result.readableBytesView), bytes)
    }

    /// EOF 之后的段都是空的 —— 这才是正常的文件到头，非严格档照常短返回。
    func testReadTreatsTrailingEmptySegmentsAsEOF() async throws {
        let bytes = payload(40_000)
        let file = RecordingFile(contents: bytes)
        await file.setLatency(.zero)

        let result = try await SFTPPipeline.read(file, offset: 0, length: 160_000, inFlight: 8)

        XCTAssertEqual(result.readableBytes, 40_000)
        XCTAssertEqual(Array(result.readableBytesView), bytes)
    }

    /// 外层任务被取消时，流水线要停下来（而不是把剩余分片发完）。
    func testWriteStopsWhenTheCallerIsCancelled() async throws {
        let file = RecordingFile()
        await file.setLatency(.milliseconds(20))
        let data = buffer(payload(32_000 * 60))

        let task = Task {
            try await SFTPPipeline.write(file, data: data, at: 0, inFlight: 4)
        }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        do {
            try await task.value
            XCTFail("取消后不该正常完成")
        } catch {
            // CancellationError 或被取消的 sleep 抛出的错误都算
        }
        let writes = await file.writes
        XCTAssertLessThan(writes.count, 60, "取消后不该把剩下的片全发完")
    }
}
