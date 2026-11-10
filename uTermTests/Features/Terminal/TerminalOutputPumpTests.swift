import XCTest
@testable import uTerm

/// 两端共用的输出泵（`TerminalOutputPump`）：后端输出 → 影子终端 → tap → surface。
/// surface 用假的（`TerminalSurfaceSink`），不建窗口；真的 surface 那一侧在 `GhosttyMacHostTests`。
///
/// 迁移前这个文件核的是 SwiftTerm 时代的泵（主线程按节拍从 4 MiB 缓冲取字节喂视图、缓冲满了丢最旧的）。那套节拍、
/// 缓冲与丢弃都没有了：现在解析不在主线程上，背压靠闸门，surface 不吃字节时靠影子的回放补齐。同一个文件改成核新泵的
/// 同一批性质：字节一个不少、顺序不乱、换连接后旧字节作废、对端跟不上时不无限堆积。
final class TerminalOutputPumpTests: XCTestCase {

    /// 假的 surface：记下收到的东西；积压回调由测试手动拨。
    private final class FakeSurface: TerminalSurfaceSink, @unchecked Sendable {
        enum Entry: Equatable {
            case live(Data)
            case replay(Data)
        }

        private let lock = NSLock()
        private var log: [Entry] = []
        private var pending = 0
        private var backlogHandler: (@Sendable (Bool) -> Void)?

        var entries: [Entry] { lock.withLock { log } }
        var liveBytes: Data { entries.reduce(into: Data()) { if case .live(let data) = $1 { $0.append(data) } } }
        var replays: [Data] { entries.compactMap { if case .replay(let data) = $0 { return data } else { return nil } } }

        /// 当作还有这么多字节没解析（下一次 `discardPendingOutput` 会报这个数）。
        func setPending(_ bytes: Int) { lock.withLock { pending = bytes } }
        func setBacklogged(_ backlogged: Bool) { lock.withLock { backlogHandler }?(backlogged) }

        func receive(_ data: Data) { lock.withLock { log.append(.live(data)) } }
        func receiveReplay(_ data: Data) { lock.withLock { log.append(.replay(data)) } }
        func discardPendingOutput() -> Int {
            lock.withLock {
                defer { pending = 0 }
                return pending
            }
        }
        func setOutputBacklogHandler(highWater: Int, lowWater: Int, _ handler: (@Sendable (Bool) -> Void)?) {
            lock.withLock { backlogHandler = handler }
        }
    }

    private func makeShadow(cols: UInt16 = 40, rows: UInt16 = 6) -> ShadowTerminal {
        ShadowTerminal(cols: cols, rows: rows, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
    }

    private func makePump() -> (TerminalOutputPump, ShadowTerminal, FakeSurface) {
        let shadow = makeShadow()
        let surface = FakeSurface()
        return (TerminalOutputPump(shadow: shadow, surface: surface), shadow, surface)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// 把影子读到的画面和「把 surface 收到的东西按顺序喂进另一个终端」比：两边应当一样。
    private func screen(replaying entries: [FakeSurface.Entry]) -> String {
        let terminal = makeShadow()
        for entry in entries {
            switch entry {
            case .live(let data), .replay(let data): terminal.feed(data)
            }
        }
        return terminal.viewportText()
    }

    // MARK: 分流

    /// surface 还没建：输出只进影子，surface 一个字节都不收；影子替它答查询。
    func testBeforeTheSurfaceExistsOutputOnlyReachesTheShadow() {
        let (pump, shadow, surface) = makePump()
        let replies = LockedBox<[Data]>([])
        shadow.setReplyHandler { data in replies.mutate { $0.append(data) } }

        pump.route(Data("hello\r\n\u{1B}[c".utf8))

        XCTAssertEqual(shadow.recentLines(1).lines, ["hello"])
        XCTAssertTrue(surface.entries.isEmpty)
        XCTAssertEqual(replies.value.count, 1, "surface 不在，DA 由影子答")
        XCTAssertEqual(pump.currentStats.shadowOnlyBytes, 10)
    }

    /// surface 建好：先收一份影子的回放，再收实时字节；之后查询由 surface 答，影子闭嘴。
    func testSurfaceGetsAReplayThenLiveBytes() {
        let (pump, shadow, surface) = makePump()
        let replies = LockedBox<[Data]>([])
        shadow.setReplyHandler { data in replies.mutate { $0.append(data) } }
        pump.route(Data("before\r\n".utf8))

        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        pump.route(Data("after\u{1B}[c".utf8))

        XCTAssertEqual(surface.replays.count, 1)
        XCTAssertEqual(surface.liveBytes, Data("after\u{1B}[c".utf8))
        XCTAssertEqual(screen(replaying: surface.entries), shadow.viewportText())
        XCTAssertTrue(replies.value.isEmpty, "surface 在吃字节：影子不答")
        XCTAssertTrue(pump.isFeedingSurface)
    }

    /// 影子是空的（新开的标签）：surface 建好时不回放。
    func testEmptyShadowIsNotReplayed() {
        let (pump, _, surface) = makePump()
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        pump.route(Data("first".utf8))
        XCTAssertEqual(surface.entries, [.live(Data("first".utf8))])
        XCTAssertEqual(pump.currentStats.replays, 0)
    }

    /// surface 停喂再恢复：中间的输出靠回放补齐，它队列里没解析的旧字节丢掉；中间没来过输出就不回放。
    func testSurfaceThatFellBehindIsReplayedOnResume() {
        let (pump, shadow, surface) = makePump()
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        pump.route(Data("one\r\n".utf8))

        surface.setPending(123)
        pump.setSurfaceFeeding(false)
        pump.route(Data("two\r\n".utf8))
        XCTAssertEqual(surface.liveBytes, Data("one\r\n".utf8), "停喂期间 surface 不收字节")
        XCTAssertEqual(pump.currentStats.droppedSurfaceBytes, 123)

        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        pump.route(Data("three".utf8))
        XCTAssertEqual(surface.replays.count, 1)
        // 回放开头自带复位，所以从回放那一项起重放就是 surface 现在的样子。
        let fromReplay = Array(surface.entries.drop { if case .replay = $0 { return false } else { return true } })
        XCTAssertEqual(screen(replaying: fromReplay), shadow.viewportText())

        pump.setSurfaceFeeding(false)
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        XCTAssertEqual(surface.replays.count, 1, "停喂期间没来过输出：不回放")
    }

    /// tap 看到的字节 = 影子吃进去的字节，顺序相同；调到 tap 时影子已经解析到这一片为止。
    func testTapSeesEveryByteInOrderAfterTheShadowParsedIt() {
        let (pump, shadow, _) = makePump()
        let tapped = LockedBox<Data>(Data())
        let cursors = LockedBox<[Int]>([])
        pump.onFed = { bytes in
            tapped.mutate { $0.append(bytes) }
            cursors.mutate { $0.append(shadow.cursor.x) }
        }
        pump.route(Data("ab".utf8))
        pump.route(Data("cde".utf8))
        XCTAssertEqual(tapped.value, Data("abcde".utf8))
        XCTAssertEqual(cursors.value, [2, 5])
    }

    /// 不经泵改了影子（从检查点还原）：`markSurfaceStale` 让在吃字节的 surface 当场重新对齐。
    func testMarkSurfaceStaleReplaysIntoALiveSurface() throws {
        let (pump, shadow, surface) = makePump()
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        let source = makeShadow()
        source.feed(Data("restored history\r\n$ ".utf8))
        try shadow.restore(snapshot: source.snapshot())

        pump.markSurfaceStale()

        XCTAssertEqual(surface.replays.count, 1)
        XCTAssertEqual(screen(replaying: surface.entries), source.viewportText())
    }

    // MARK: 整屏快照（远控镜像的接收端）

    /// 收到二进制快照：影子换成快照里的终端，surface 收一份回放；之后的字节接着它。
    func testSnapshotItemRestoresTheShadowAndReplaysIntoTheSurface() async throws {
        let (pump, shadow, surface) = makePump()
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        let mac = makeShadow(cols: 30, rows: 5)
        mac.feed(Data("mac line 1\r\nmac line 2\r\n".utf8))
        let (stream, continuation) = AsyncStream<TerminalOutputItem>.makeStream()

        pump.start(stream)
        continuation.yield(.bytes(Data("stale local bytes".utf8)))
        continuation.yield(.snapshot(try mac.snapshot()))
        continuation.yield(.bytes(Data("live".utf8)))
        mac.feed(Data("live".utf8))

        let arrived = await waitUntil { shadow.recentLines(1).lines == ["live"] }
        XCTAssertTrue(arrived)
        XCTAssertEqual(shadow.viewportText(), mac.viewportText())
        XCTAssertEqual(shadow.size.cols, 30)
        XCTAssertEqual(surface.replays.count, 1)
        let fromReplay = Array(surface.entries.drop { if case .replay = $0 { return false } else { return true } })
        let mirror = makeShadow(cols: 30, rows: 5)
        for case .replay(let data) in fromReplay.prefix(1) { mirror.feed(data) }
        for case .live(let data) in fromReplay.dropFirst() { mirror.feed(data) }
        XCTAssertEqual(mirror.viewportText(), mac.viewportText())
        pump.reset()
    }

    /// 解不开的快照丢掉，影子原样不动。
    func testGarbageSnapshotIsRejected() {
        let (pump, shadow, surface) = makePump()
        pump.route(Data("keep".utf8))
        pump.applySnapshot(Data("not a snapshot".utf8))
        XCTAssertEqual(shadow.recentLines(1).lines, ["keep"])
        XCTAssertEqual(pump.currentStats.rejectedSnapshots, 1)
        XCTAssertTrue(surface.entries.isEmpty)
    }

    // MARK: 入站、代次、背压

    /// 一条流泵到底：字节一个不少、顺序不乱；大块切片后拼起来还是原样。
    func testStreamIsPumpedCompletelyAndInOrder() async {
        let (pump, shadow, surface) = makePump()
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        var expected = Data()
        let big = Data((0..<(TerminalOutputPump.sliceBytes * 2 + 100)).map { UInt8(ascii: "a") + UInt8($0 % 26) })

        pump.start(stream)
        for chunk in [Data("x1\r\n".utf8), big, Data("\r\nend".utf8)] {
            expected.append(chunk)
            continuation.yield(chunk)
        }

        let done = await waitUntil { surface.liveBytes.count == expected.count }
        XCTAssertTrue(done)
        XCTAssertEqual(surface.liveBytes, expected)
        XCTAssertEqual(shadow.recentLines(1).lines, ["end"])
        XCTAssertEqual(shadow.totalFedBytes, expected.count)
        pump.reset()
    }

    /// `reset()` 之后，上一条连接的流里再来字节也不进终端。
    func testResetDiscardsThePreviousConnectionsOutput() async {
        let (pump, shadow, _) = makePump()
        let (old, oldContinuation) = AsyncStream<Data>.makeStream()
        pump.start(old)
        oldContinuation.yield(Data("old".utf8))
        let fed = await waitUntil { shadow.totalFedBytes == 3 }
        XCTAssertTrue(fed)

        let generation = pump.generation
        pump.reset()
        XCTAssertEqual(pump.generation, generation + 1)
        XCTAssertFalse(pump.isRunning)
        oldContinuation.yield(Data("stale".utf8))

        let (new, newContinuation) = AsyncStream<Data>.makeStream()
        pump.start(new)
        newContinuation.yield(Data("!".utf8))
        let arrived = await waitUntil { shadow.totalFedBytes >= 4 }
        XCTAssertTrue(arrived)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(shadow.totalFedBytes, 4, "旧连接的字节不该进来")
        XCTAssertEqual(shadow.recentLines(1).lines, ["old!"])
        pump.reset()
    }

    /// surface 积压到高水位：入站停下不再取后端的输出；落回低水位后继续，字节不丢。
    func testBacklogPausesIngressUntilTheSurfaceCatchesUp() async {
        let (pump, shadow, surface) = makePump()
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        pump.start(stream)

        surface.setBacklogged(true)
        continuation.yield(Data("held".utf8))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(shadow.totalFedBytes, 0, "积压期间不取输出")
        XCTAssertEqual(pump.currentStats.backpressureWaits, 1)

        surface.setBacklogged(false)
        let resumed = await waitUntil { shadow.totalFedBytes == 4 }
        XCTAssertTrue(resumed)
        XCTAssertEqual(surface.liveBytes, Data("held".utf8))
        pump.reset()
    }

    /// surface 不吃字节时不看它的积压（它这时不会消，等它就把入站卡死了——iOS 后台原来的病）。
    func testBacklogIsIgnoredWhileOnlyTheShadowIsFed() async {
        let (pump, shadow, surface) = makePump()
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        surface.setBacklogged(true)
        pump.setSurfaceFeeding(false)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        pump.start(stream)
        continuation.yield(Data("background".utf8))
        let fed = await waitUntil { shadow.totalFedBytes == 10 }
        XCTAssertTrue(fed)
        pump.reset()
    }

    /// 挂在闸门上的入站任务在 `reset()` 时放掉，不留一个永远醒不来的任务。
    func testResetReleasesAnIngressParkedAtTheGate() async {
        let (pump, shadow, surface) = makePump()
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        let finished = LockedBox(false)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        continuation.onTermination = { _ in finished.mutate { $0 = true } }
        pump.start(stream)
        surface.setBacklogged(true)
        continuation.yield(Data("parked".utf8))
        try? await Task.sleep(for: .milliseconds(50))

        pump.reset()
        continuation.finish()

        let released = await waitUntil { finished.value }
        XCTAssertTrue(released)
        XCTAssertEqual(shadow.totalFedBytes, 0, "换了连接：挂着的那一片不要了")
    }
}

/// 测试里跨线程攒结果用的小盒子。
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}
