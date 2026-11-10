import XCTest
@testable import uTerm

/// `TerminalSession` 怎么把后端输出喂进终端。原来这里核的是 SwiftTerm 路径上的节拍（`TerminalFlushPacing`：主线程上
/// 每 16 ms 喂一拍，预算 32 KiB 起、有积压就翻倍到 512 KiB）和 4 MB 的输出缓冲（`TerminalOutputBuffer`，满了丢最旧的）。
/// 这两样随 SwiftTerm 一起删了：现在是共享的 `TerminalOutputPump`——入站任务不在主线程上，按 64 KiB 切片，每片
/// 喂影子终端 → tap（镜像、检查点）→ surface；surface 解析不过来时停取后端的输出（背压），**不丢字节**。
/// 泵本身的单测在 `TerminalOutputPumpTests`，这里验 `TerminalSession` 真的按它喂。
/// 每片喂多少从镜像订阅者看：tap 的 `didFeed` 紧跟在影子终端 `feed` 后面，一片一次。
@MainActor
final class TerminalFlushWiringTests: XCTestCase {

    private final class Batches: @unchecked Sendable {
        private let lock = NSLock()
        private var subscriber: TerminalMirrorTap.Subscriber?
        private var batches: [Data] = []
        private var extraSnapshots = 0

        func attach(_ subscriber: TerminalMirrorTap.Subscriber) {
            while subscriber.take(maxBytes: 1 << 30) != nil {}   // 订阅时那份快照不算喂入。
            lock.lock()
            self.subscriber = subscriber
            lock.unlock()
        }

        func collect() {
            lock.lock()
            defer { lock.unlock() }
            while let chunk = subscriber?.take(maxBytes: 1 << 30) {
                switch chunk {
                case .output(let data): batches.append(data)
                case .snapshot: extraSnapshots += 1
                }
            }
        }

        var all: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return batches
        }
        /// 订阅之后又被改发快照的次数（积压超限才会；这些用例里不该发生）。
        var resyncs: Int { lock.withLock { extraSnapshots } }
        var sizes: [Int] { all.map(\.count) }
        var total: Int { sizes.reduce(0, +) }
        var joined: Data { all.reduce(into: Data()) { $0.append($1) } }
    }

    private let kb = 1024

    private func record(_ session: TerminalSession) -> Batches {
        let batches = Batches()
        let subscriber = session.mirrorTap.subscribe(id: UUID(), limit: 64 * 1024 * 1024) { batches.collect() }
        batches.attach(subscriber)
        return batches
    }

    /// 可打印、带换行，内容按位置变化，错序能看出来。
    private func payload(bytes: Int) -> Data {
        var data = Data(capacity: bytes)
        var line = 0
        while data.count < bytes {
            data.append(contentsOf: "\(line) ".utf8)
            data.append(contentsOf: repeatElement(UInt8(ascii: "x"), count: 60))
            data.append(contentsOf: "\r\n".utf8)
            line += 1
        }
        return data.prefix(bytes)
    }

    private func waitFor(_ batches: Batches, total: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while batches.total < total, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(batches.total, total, file: file, line: line)
    }

    /// 原来核「会话默认用桌面节拍」。节拍没有了；对应的默认状态是：会话一建好泵就在，surface 还没建所以不喂它，
    /// 字节只进影子终端，查询由影子终端答。
    func testSessionStartsWithThePumpFeedingOnlyTheShadow() async throws {
        let session = TerminalSession()
        defer { session.dispose() }
        XCTAssertFalse(session.outputPump.isFeedingSurface, "surface 还没建：泵不喂它")
        XCTAssertFalse(session.outputPump.isRunning, "还没连接：没有入站任务")
        let backend = MockBackend()
        await session.connect(using: backend)
        XCTAssertTrue(session.outputPump.isRunning)

        await backend.emitOutput(Data("hello\u{1b}[6n".utf8))
        let deadline = Date().addingTimeInterval(3)
        var written: [Data] = []
        while written.isEmpty, Date() < deadline {
            written = await backend.writtenData
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.shadow.recentLines(1).lines, ["hello"])
        XCTAssertEqual(written, [Data("\u{1b}[1;6R".utf8)], "surface 不吃字节时由影子终端答查询")
        XCTAssertEqual(session.outputPump.currentStats.shadowOnlyBytes, 9)
        await session.close()
    }

    /// 原来核「有积压时预算一路翻倍到上限」。现在没有预算：大块输出按 `sliceBytes` 切片，每片之间看一次闸门，
    /// 不等节拍，一口气喂完。分片不能丢字节也不能错序。
    func testLargeOutputIsFedInSlicesWithoutWaitingForATick() async throws {
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let batches = record(session)
        let output = payload(bytes: 1600 * kb)

        let started = ContinuousClock.now
        await backend.emitOutput(output)
        try await waitFor(batches, total: output.count)
        let elapsed = ContinuousClock.now - started

        XCTAssertEqual(batches.sizes.max(), TerminalOutputPump.sliceBytes, "每片不超过 sliceBytes")
        XCTAssertEqual(batches.sizes.count, (output.count + TerminalOutputPump.sliceBytes - 1) / TerminalOutputPump.sliceBytes)
        XCTAssertEqual(batches.joined, output, "分片不能丢字节也不能错序")
        XCTAssertEqual(batches.resyncs, 0)
        // 旧节拍下 1.6 MB 至少要 7 拍（约 110 ms）；现在只受解析速度限制。上限放得很宽，只防「又被按拍子喂」。
        XCTAssertLessThan(elapsed, .seconds(5))
        XCTAssertEqual(session.shadow.totalFedBytes, output.count)
        await session.close()
    }

    /// 原来核「解析跟不上时预算停在下限，不把主线程全占了」。预算的概念没有了：喂字节不在主线程上，画面跟不上时
    /// 是入站任务停取（背压），由 `TerminalOutputPumpTests` 的背压用例核。
    func testSlowFeedStaysAtBaseBudget() throws {
        throw XCTSkip("TerminalFlushPacing 的预算随 SwiftTerm 删除；对应物是输出泵的背压，见 TerminalOutputPumpTests")
    }

    /// 入站任务不在主线程上：主线程被占着的时候输出照样进影子终端（旧实现在主线程上按拍喂，主线程一卡就停）。
    func testOutputIsParsedWhileTheMainThreadIsBusy() async throws {
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let output = payload(bytes: 400 * kb)
        await backend.emitOutput(output)

        // 占住主线程，不让出：这期间只能靠后台的入站任务喂。
        blockMainThread(upTo: 5) { session.shadow.totalFedBytes >= output.count }
        XCTAssertEqual(session.shadow.totalFedBytes, output.count, "主线程忙的时候输出也要喂完")
        await session.close()
    }

    /// 同步地等（不让出主线程）。
    private func blockMainThread(upTo seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { usleep(5_000) }
    }

    /// 没有积压时一批只有几百字节，一次喂完。
    func testSmallOutputIsFedInOneBatch() async throws {
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let batches = record(session)

        await backend.emitOutput(Data("hello\r\n".utf8))
        try await waitFor(batches, total: 7)

        XCTAssertEqual(batches.sizes, [7])
        await session.close()
    }

    /// 关掉之后旧连接的输出作废：还在路上的、关掉之后才到的，都不能进终端，重连后也不能混进新连接的输出里。
    func testClosingDropsBacklogAndItNeverReachesTheNextConnection() async throws {
        let session = TerminalSession()
        let oldBackend = MockBackend()
        await session.connect(using: oldBackend)
        let batches = record(session)
        await oldBackend.emitOutput(payload(bytes: 256 * kb))
        try await waitFor(batches, total: 256 * kb)

        // 换连接：代次 +1，旧入站任务停掉。`detach` 不关后端，旧后端之后吐的东西还会进它的输出流。
        session.detach()
        let afterClose = batches.total
        await oldBackend.emitOutput(Data("STALE".utf8))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(batches.total, afterClose, "旧连接的输出不能再进终端")

        let newBackend = MockBackend()
        await session.connect(using: newBackend)
        await newBackend.emitOutput(Data("NEW".utf8))
        try await waitFor(batches, total: afterClose + 3)
        XCTAssertEqual(batches.all.last, Data("NEW".utf8))
        await oldBackend.emitOutput(Data("STALE".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(batches.total, afterClose + 3)
        XCTAssertFalse(session.shadow.viewportText().contains("STALE"))
        await session.close()
    }

    // MARK: - 原来的 4 MB 缓冲

    /// 原来核「缓冲满了丢最旧的，留最新的 4 MB」。`TerminalOutputBuffer` 删了，现在不丢：来多少喂多少
    /// （surface 跟不上靠背压，不靠丢）。6 个 1 MB 的块全部按序进终端。
    func testOutputBufferKeepsTheNewestChunksInOrder() async throws {
        let mb = 1024 * 1024
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let batches = record(session)
        var expected = Data()
        for index in 0..<6 {
            let chunk = Data(repeating: UInt8(ascii: "a") + UInt8(index), count: mb)
            expected.append(chunk)
            await backend.emitOutput(chunk)
        }

        try await waitFor(batches, total: 6 * mb)

        XCTAssertEqual(batches.joined, expected, "一个字节不丢、顺序不变（旧实现只留最新的 4 MB）")
        XCTAssertEqual(batches.resyncs, 0)
        await session.close()
    }

    /// 原来核「比缓冲还大的一块只留它的尾巴」。现在整块都进终端。
    func testOversizedChunkKeepsItsTail() async throws {
        let mb = 1024 * 1024
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let batches = record(session)
        var chunk = Data(repeating: UInt8(ascii: "A"), count: mb)
        chunk.append(Data(repeating: UInt8(ascii: "B"), count: 4 * mb))

        await backend.emitOutput(chunk)
        try await waitFor(batches, total: 5 * mb)

        XCTAssertEqual(batches.joined, chunk, "开头那 1 MB 也在（旧实现会丢掉它）")
        XCTAssertEqual(batches.sizes.max(), TerminalOutputPump.sliceBytes)
        await session.close()
    }
}
