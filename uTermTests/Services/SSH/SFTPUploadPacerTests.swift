import NIOCore
import XCTest
@testable import uTerm

/// 终端贴图 / 贴视频的上传节奏（`SFTPUploadPacer`）：和交互终端共用一条 SSH 连接时，上传不能把按键挤在后面。
///
/// 前几条用例是一条瓶颈链路的离散模拟（确定性，不睡、不碰网络）：链路按 `rate` 一字节一字节往外送，
/// 先来先走（同一条 TCP 上终端和 SFTP 就是这样），送完再过 `roundTrip` 收到确认。此刻按一个键要等多久
/// = 链路里还排着的字节 ÷ 速率。发送方的规则和 `SFTPPipeline` 的写循环一样：个数不过 64，
/// 有节奏时在途字节不过预算、片长取节奏给的。
final class SFTPUploadPacerTests: XCTestCase {

    private struct Outcome {
        /// 起步 2 s 之后，任一时刻按键要排的最长时间（秒）。
        var worstKeystrokeWait: Double
        /// 整段上传的平均速率（字节 / 秒）。
        var throughput: Double
        /// 传完用了多久（秒）。
        var duration: Double
    }

    private func simulate(bytes total: Int, rate: Double, roundTrip: Double, paced: Bool) -> Outcome {
        var pacer = paced ? SFTPUploadPacer() : nil
        let window = SFTPPipeline.defaultInFlight
        let tripNanos = UInt64(roundTrip * 1e9)
        var now: UInt64 = 0
        var linkFreeAt: UInt64 = 0
        var inFlight: [(bytes: Int, sentAt: UInt64, ackAt: UInt64)] = []
        var outstanding = 0
        var sent = 0
        var worst: UInt64 = 0
        while sent < total || !inFlight.isEmpty {
            while sent < total, inFlight.count < window,
                  inFlight.isEmpty || pacer?.allowsMore(outstanding: outstanding) != false {
                let length = min(pacer?.chunkLength ?? SFTPPipeline.chunkSize, total - sent)
                pacer?.willSend(at: now)
                let departs = max(now, linkFreeAt) + UInt64(Double(length) / rate * 1e9)
                linkFreeAt = departs
                inFlight.append((length, now, departs + tripNanos))
                outstanding += length
                sent += length
            }
            if now > 2_000_000_000 { worst = max(worst, linkFreeAt > now ? linkFreeAt - now : 0) }
            let next = inFlight.indices.min { inFlight[$0].ackAt < inFlight[$1].ackAt }!
            let ack = inFlight.remove(at: next)
            now = ack.ackAt
            outstanding -= ack.bytes
            pacer?.acknowledged(bytes: ack.bytes, sentAt: ack.sentAt, ackedAt: ack.ackAt)
        }
        return Outcome(worstKeystrokeWait: Double(worst) / 1e9, throughput: Double(total) / (Double(now) / 1e9),
                       duration: Double(now) / 1e9)
    }

    /// 回归：手机上行 1 Mbps、往返 80 ms，不按节奏时一次压 2 MiB，按键要排十几秒（「上传期间打不了字」）。
    func testUnpacedUploadBuriesKeystrokesOnASlowLink() {
        let outcome = simulate(bytes: 3_000_000, rate: 125_000, roundTrip: 0.08, paced: false)
        XCTAssertGreaterThan(outcome.worstKeystrokeWait, 10, "前提：固定 64 个请求在途时按键要等十几秒")
    }

    /// 同一条慢链路按节奏传：按键最多排几百毫秒，上传速率不掉。
    func testPacedUploadKeepsKeystrokesResponsiveOnASlowLink() {
        let outcome = simulate(bytes: 3_000_000, rate: 125_000, roundTrip: 0.08, paced: true)
        XCTAssertLessThan(outcome.worstKeystrokeWait, 0.3, "按键排在上传后面的时间要压到几百毫秒以内")
        XCTAssertGreaterThan(outcome.throughput, 125_000 * 0.9, "链路还得吃满，上传不能因此变慢")
    }

    /// 更慢的链路（160 kbps、往返 300 ms）：片要切小，否则光一片 32 KB 就要排 1.6 s。
    func testPacedUploadShrinksChunksOnAVerySlowLink() {
        let outcome = simulate(bytes: 400_000, rate: 20_000, roundTrip: 0.3, paced: true)
        XCTAssertLessThan(outcome.worstKeystrokeWait, 0.8)
        XCTAssertGreaterThan(outcome.throughput, 20_000 * 0.85)
    }

    /// 中等链路（8 Mbps、往返 150 ms）：不按节奏时按键也要等将近 2 s。
    func testPacedUploadOnAMediumLink() {
        let unpaced = simulate(bytes: 20_000_000, rate: 1_000_000, roundTrip: 0.15, paced: false)
        XCTAssertGreaterThan(unpaced.worstKeystrokeWait, 1.5)
        let outcome = simulate(bytes: 20_000_000, rate: 1_000_000, roundTrip: 0.15, paced: true)
        XCTAssertLessThan(outcome.worstKeystrokeWait, 0.4)
        XCTAssertGreaterThan(outcome.throughput, 1_000_000 * 0.85)
    }

    /// 快链路（50 MB/s、往返 20 ms）：预算要涨到吃满链路，不能为了按键把上传限慢。
    func testPacedUploadStillFillsAFastLink() {
        let outcome = simulate(bytes: 64 * 1_048_576, rate: 50_000_000, roundTrip: 0.02, paced: true)
        XCTAssertGreaterThan(outcome.throughput, 50_000_000 * 0.85)
        let unpaced = simulate(bytes: 64 * 1_048_576, rate: 50_000_000, roundTrip: 0.02, paced: false)
        XCTAssertLessThan(outcome.duration, unpaced.duration + 0.25, "只多起步那几个往返，不能明显变慢")
    }

    /// 先单独发一小片量往返，它确认之前不发第二片；之后片长不超过一个 SFTP 请求的上限。
    func testStartsWithASingleProbe() {
        var pacer = SFTPUploadPacer()
        XCTAssertEqual(pacer.chunkLength, SFTPUploadPacer.Config.standard.probeChunk)
        pacer.willSend(at: 0)
        XCTAssertFalse(pacer.allowsMore(outstanding: pacer.chunkLength), "量往返的那片在路上时不再发")
        pacer.acknowledged(bytes: 4096, sentAt: 0, ackedAt: 50_000_000)
        XCTAssertEqual(pacer.minimumRoundTripNanos.map { $0 <= 50_000_000 }, true)
        XCTAssertTrue(pacer.allowsMore(outstanding: 0))
        XCTAssertLessThanOrEqual(pacer.chunkLength, SFTPPipeline.chunkSize)
        XCTAssertFalse(pacer.allowsMore(outstanding: pacer.budget))
    }

    /// 每 10 s 停一下重新量往返：等在途清空，只发一小片。
    func testReprobesAfterTheInterval() {
        var pacer = SFTPUploadPacer()
        pacer.willSend(at: 0)
        pacer.acknowledged(bytes: 4096, sentAt: 0, ackedAt: 50_000_000)
        XCTAssertTrue(pacer.allowsMore(outstanding: 0))
        pacer.acknowledged(bytes: 8192, sentAt: 10_000_000_000, ackedAt: 10_060_000_000)
        XCTAssertFalse(pacer.allowsMore(outstanding: 0), "到点了：在途清空之前不发新片")
        XCTAssertEqual(pacer.chunkLength, SFTPUploadPacer.Config.standard.probeChunk)
    }

    // MARK: - 真的流水线

    private final class MemoryFile: SFTPPipelineFile, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UInt8] = []
        private var lengths: [Int] = []

        func writeChunk(_ data: ByteBuffer, at offset: UInt64) async throws {
            try await Task.sleep(for: .milliseconds(1))
            lock.withLock {
                lengths.append(data.readableBytes)
                let end = Int(offset) + data.readableBytes
                if storage.count < end { storage.append(contentsOf: [UInt8](repeating: 0, count: end - storage.count)) }
                storage.replaceSubrange(Int(offset)..<end, with: data.readableBytesView)
            }
        }

        func readChunk(from offset: UInt64, length: UInt32) async throws -> ByteBuffer { ByteBuffer() }

        var bytes: [UInt8] { lock.withLock { storage } }
        var chunkLengths: [Int] { lock.withLock { lengths } }
    }

    /// 按节奏写，内容照样一字不差、每片不超过 32 000 B，进度报到总数。
    func testPacedPipelineWritesEveryByte() async throws {
        let bytes = (0..<300_001).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        let file = MemoryFile()
        var last = 0
        try await SFTPPipeline.write(file, data: buffer, at: 0, paced: true) { written, _ in last = written }
        XCTAssertEqual(file.bytes, bytes)
        XCTAssertTrue(file.chunkLengths.allSatisfy { $0 > 0 && $0 <= SFTPPipeline.chunkSize })
        XCTAssertEqual(file.chunkLengths.reduce(0, +), bytes.count)
        XCTAssertEqual(last, bytes.count)
    }
}
