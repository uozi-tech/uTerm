// 【迁移中，暂未编译】这份用例还依赖 SwiftTerm 或已经删掉的 SwiftTerm 时代类型，等改写到 Ghostty + 影子终端
// （`ShadowTerminal`）上的同一条行为。改写完把这一对 `#if UTERM_LEGACY_SWIFTTERM_TESTS` / `#endif` 去掉。
// 清单与进度见 docs/ghostty-eval/migration-log.md「测试改写」。
#if UTERM_LEGACY_SWIFTTERM_TESTS
import XCTest
@testable import uTerm

/// `TerminalFlushPacing` 的算法单测在 `TerminalFlushPacingTests`，这里验 `TerminalSession` 真的按它喂。
/// 每拍喂多少从镜像订阅者看：`didFeed` 紧跟在 `terminalView.feed` 后面，一拍一次。
/// 不断言耗时；预算走向靠换 `targetMs` 固定下来，不取决于这台机器解析得多快。
@MainActor
final class TerminalFlushWiringTests: XCTestCase {

    private final class Batches: @unchecked Sendable {
        private let lock = NSLock()
        private var subscriber: TerminalMirrorTap.Subscriber?
        private var batches: [Data] = []

        func attach(_ subscriber: TerminalMirrorTap.Subscriber) {
            _ = subscriber.take(maxBytes: .max)   // 订阅时那份快照不算喂入。
            lock.lock()
            self.subscriber = subscriber
            lock.unlock()
        }

        func collect() {
            lock.lock()
            defer { lock.unlock() }
            if let data = subscriber?.take(maxBytes: .max) { batches.append(data) }
        }

        var all: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return batches
        }
        var sizes: [Int] { all.map(\.count) }
        var total: Int { sizes.reduce(0, +) }
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

    func testSessionUsesDesktopPacingByDefault() {
        XCTAssertEqual(TerminalSession().flushPacing, .desktop)
    }

    func testBacklogRampsBudgetUpToTheMaximum() async throws {
        let session = TerminalSession()
        session.flushPacing = TerminalFlushPacing(intervalMs: 1, baseBytes: 32 * kb, maxBytes: 512 * kb, targetMs: 1_000_000)
        let backend = MockBackend()
        await session.connect(using: backend)
        let batches = record(session)
        let output = payload(bytes: 1600 * kb)

        await backend.emitOutput(output)
        try await waitFor(batches, total: output.count)

        XCTAssertEqual(Array(batches.sizes.prefix(5)), [32, 64, 128, 256, 512].map { $0 * kb })
        XCTAssertEqual(batches.sizes.max(), 512 * kb, "预算封顶")
        XCTAssertEqual(batches.all.reduce(into: Data()) { $0.append($1) }, output, "分拍不能丢字节也不能错序")
        await session.close()
    }

    /// 解析跟不上（每拍都超过目标耗时）时不放大，不把主线程全占了。
    func testSlowFeedStaysAtBaseBudget() async throws {
        let session = TerminalSession()
        session.flushPacing = TerminalFlushPacing(intervalMs: 1, baseBytes: 32 * kb, maxBytes: 512 * kb, targetMs: 0)
        let backend = MockBackend()
        await session.connect(using: backend)
        let batches = record(session)
        let output = payload(bytes: 200 * kb)

        await backend.emitOutput(output)
        try await waitFor(batches, total: output.count)

        XCTAssertEqual(batches.sizes.max(), 32 * kb)
        await session.close()
    }

    func testRealDesktopPacingNeverExceedsItsMaximumAndKeepsOrder() async throws {
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let batches = record(session)
        let output = payload(bytes: 400 * kb)

        await backend.emitOutput(output)
        try await waitFor(batches, total: output.count)

        XCTAssertLessThanOrEqual(batches.sizes.max() ?? 0, TerminalFlushPacing.desktop.maxBytes)
        XCTAssertEqual(batches.sizes.first, TerminalFlushPacing.desktop.baseBytes, "第一拍从下限开始")
        XCTAssertEqual(batches.all.reduce(into: Data()) { $0.append($1) }, output)
        await session.close()
    }

    /// 没有积压时一拍只有几百字节，一次喂完，不等下一拍。
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

    /// 关掉之后积压作废，重连后也不能混进新连接的输出里。
    func testClosingDropsBacklogAndItNeverReachesTheNextConnection() async throws {
        let session = TerminalSession()
        session.flushPacing = TerminalFlushPacing(intervalMs: 40, baseBytes: 32 * kb, maxBytes: 32 * kb, targetMs: 8)
        let oldBackend = MockBackend()
        await session.connect(using: oldBackend)
        let batches = record(session)
        await oldBackend.emitOutput(payload(bytes: 1024 * kb))
        let deadline = ContinuousClock.now + .seconds(5)
        while batches.total == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThan(batches.total, 0)

        await session.close()
        let afterClose = batches.total
        XCTAssertLessThan(afterClose, 1024 * kb, "积压要还没喂完才有意义")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(batches.total, afterClose)

        let newBackend = MockBackend()
        await session.connect(using: newBackend)
        await newBackend.emitOutput(Data("NEW".utf8))
        try await waitFor(batches, total: afterClose + 3)
        XCTAssertEqual(batches.all.last, Data("NEW".utf8))
        await session.close()
    }

    // MARK: - 4MB 缓冲

    func testOutputBufferKeepsTheNewestChunksInOrder() {
        let mb = 1024 * 1024
        let buffer = TerminalOutputBuffer(capacityBytes: 4 * mb)
        for index in 0..<6 {
            buffer.append(Data(repeating: UInt8(index), count: mb), generation: 1)
        }

        let drained = buffer.drain(maxBytes: 16 * mb, generation: 1)

        XCTAssertEqual(drained.count, 4 * mb)
        XCTAssertEqual(drained.first, 2, "丢的是最旧的")
        XCTAssertEqual(drained.last, 5)
        XCTAssertTrue(buffer.drain(maxBytes: mb, generation: 1).isEmpty)
    }

    func testOversizedChunkKeepsItsTail() {
        let mb = 1024 * 1024
        let buffer = TerminalOutputBuffer(capacityBytes: 4 * mb)
        var chunk = Data(repeating: 0xAA, count: mb)
        chunk.append(Data(repeating: 0xBB, count: 4 * mb))

        buffer.append(chunk, generation: 1)
        let drained = buffer.drain(maxBytes: 16 * mb, generation: 1)

        XCTAssertEqual(drained.count, 4 * mb)
        XCTAssertFalse(drained.contains(0xAA))
    }
}
#endif
