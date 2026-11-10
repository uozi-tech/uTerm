import XCTest
@testable import uTerm

/// 两端共用的输出泵（`TerminalOutputPump`）：后端输出 → 影子终端 → tap → surface。
/// surface 用假的（`TerminalSurfaceSink`），不建窗口；真的 surface 那一侧在 `GhosttyMacHostTests`。
///
/// 迁移前这个文件核的是旧的泵（主线程按节拍从 4 MiB 缓冲取字节喂视图、缓冲满了丢最旧的）。那套节拍、
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
        private var grid: (cols: Int, rows: Int)?

        var entries: [Entry] { lock.withLock { log } }
        /// surface 的网格（主控端等网格对齐时读）；nil = 没有。
        func setGrid(cols: Int, rows: Int) { lock.withLock { grid = (cols, rows) } }
        var surfaceGridSize: (cols: Int, rows: Int)? { lock.withLock { grid } }
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
    private func screen(replaying entries: [FakeSurface.Entry], cols: UInt16 = 40, rows: UInt16 = 6) -> String {
        let terminal = makeShadow(cols: cols, rows: rows)
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

    // MARK: 主控端等网格对齐（`followsSnapshotGrid`）

    private func snapshot(cols: UInt16, rows: UInt16, text: String) throws -> Data {
        let mac = makeShadow(cols: cols, rows: rows)
        mac.feed(Data(text.utf8))
        return try mac.snapshot()
    }

    /// 快照是被控端的网格、本地 surface 是另一个网格：画面停着（不回放、实时字节不进 surface），
    /// 等来同网格的快照再回放；停着期间的字节都在影子里。
    func testMismatchedSnapshotHoldsTheSurfaceUntilAnAlignedOneArrives() throws {
        let (pump, shadow, surface) = makePump()
        pump.followsSnapshotGrid = true
        surface.setGrid(cols: 50, rows: 8)
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()

        pump.applySnapshot(try snapshot(cols: 30, rows: 5, text: "mac at 30x5"))
        XCTAssertTrue(pump.isHoldingForGrid)
        pump.route(Data("\r\nmore".utf8))
        XCTAssertTrue(surface.entries.isEmpty, "网格没对齐：不回放、不进实时字节")
        XCTAssertEqual(shadow.size.cols, 30, "影子跟着被控端的网格")

        let aligned = try snapshot(cols: 50, rows: 8, text: "mac at 50x8")
        pump.applySnapshot(aligned)
        XCTAssertFalse(pump.isHoldingForGrid)
        XCTAssertEqual(surface.replays.count, 1)
        pump.route(Data(" live".utf8))
        XCTAssertEqual(surface.liveBytes, Data(" live".utf8))
        XCTAssertEqual(screen(replaying: surface.entries, cols: 50, rows: 8), shadow.viewportText())
        XCTAssertEqual(pump.currentStats.gridHolds, 1)
    }

    /// 等不到同网格的快照（对端没钉成）：超时后照常回放，同样的错位不再停第二次。
    func testGridHoldTimesOutAndReplaysAnyway() async throws {
        let (pump, _, surface) = makePump()
        pump.followsSnapshotGrid = true
        surface.setGrid(cols: 50, rows: 8)
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        pump.applySnapshot(try snapshot(cols: 30, rows: 5, text: "never aligned"))
        XCTAssertTrue(pump.isHoldingForGrid)

        let released = await waitUntil(TerminalOutputPump.gridAlignmentTimeout + 2) { surface.replays.count == 1 }
        XCTAssertTrue(released, "超时后要回放")
        XCTAssertFalse(pump.isHoldingForGrid)
        XCTAssertEqual(pump.currentStats.gridHoldTimeouts, 1)
        pump.route(Data("x".utf8))
        XCTAssertEqual(surface.liveBytes, Data("x".utf8), "同样的错位不再停")
    }

    /// 本机会话（默认不跟快照网格）：网格不一样也照常回放（影子本来就跟着 surface）。
    func testLocalSessionsNeverHoldForGrid() throws {
        let (pump, _, surface) = makePump()
        surface.setGrid(cols: 50, rows: 8)
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        pump.applySnapshot(try snapshot(cols: 30, rows: 5, text: "local"))
        XCTAssertFalse(pump.isHoldingForGrid)
        XCTAssertEqual(surface.replays.count, 1)
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
        let (stream, continuation) = AsyncStream<TerminalOutputItem>.makeStream()
        var expected = Data()
        let big = Data((0..<(TerminalOutputPump.sliceBytes * 2 + 100)).map { UInt8(ascii: "a") + UInt8($0 % 26) })

        pump.start(stream)
        for chunk in [Data("x1\r\n".utf8), big, Data("\r\nend".utf8)] {
            expected.append(chunk)
            continuation.yield(.bytes(chunk))
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
        let (old, oldContinuation) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.start(old)
        oldContinuation.yield(.bytes(Data("old".utf8)))
        let fed = await waitUntil { shadow.totalFedBytes == 3 }
        XCTAssertTrue(fed)

        let generation = pump.generation
        pump.reset()
        XCTAssertEqual(pump.generation, generation + 1)
        XCTAssertFalse(pump.isRunning)
        oldContinuation.yield(.bytes(Data("stale".utf8)))

        let (new, newContinuation) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.start(new)
        newContinuation.yield(.bytes(Data("!".utf8)))
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
        let (stream, continuation) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.start(stream)

        surface.setBacklogged(true)
        continuation.yield(.bytes(Data("held".utf8)))
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
        let (stream, continuation) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.start(stream)
        continuation.yield(.bytes(Data("background".utf8)))
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
        let (stream, continuation) = AsyncStream<TerminalOutputItem>.makeStream()
        continuation.onTermination = { _ in finished.mutate { $0 = true } }
        pump.start(stream)
        surface.setBacklogged(true)
        continuation.yield(.bytes(Data("parked".utf8)))
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

// MARK: - 补尾巴、擦屏

/// 停喂 / 恢复时 surface 追影子：能补尾巴就补（视口、选区都留着），补不了才整屏回放；擦屏在 surface 解析到之后才交出去。
final class TerminalOutputPumpTailTests: XCTestCase {

    /// 假的 surface，带一个「还没解析」的队列：`receive` 进队列，`parse()` 才算解析完（标记在那之后调）。
    /// `takePendingOutputForCatchUp` 把队列原样交回，和 `InMemoryTerminalSession` 一样。
    private final class QueuedSurface: TerminalSurfaceSink, @unchecked Sendable {
        enum Entry: Equatable {
            case live(Data)
            case replay(Data)
        }

        private let lock = NSLock()
        private var parsed: [Entry] = []
        private var queue: [Entry] = []
        private var markers: [@Sendable () -> Void] = []
        private var grid: (cols: Int, rows: Int)?
        /// 下一次交回时假装夹着回放（交不全）。
        var nextTakeIsIncomplete = false

        var entries: [Entry] { lock.withLock { parsed } }
        var replays: [Data] { entries.compactMap { if case .replay(let data) = $0 { return data } else { return nil } } }
        func setGrid(cols: Int, rows: Int) { lock.withLock { grid = (cols, rows) } }
        var surfaceGridSize: (cols: Int, rows: Int)? { lock.withLock { grid } }

        func receive(_ data: Data) { lock.withLock { queue.append(.live(data)) } }
        func receiveReplay(_ data: Data) { lock.withLock { queue.append(.replay(data)) } }

        /// 把队列里的都解析掉，再调排着的标记。
        func parse() {
            let pending: [@Sendable () -> Void] = lock.withLock {
                parsed.append(contentsOf: queue)
                queue.removeAll()
                defer { markers.removeAll() }
                return markers
            }
            pending.forEach { $0() }
        }

        func discardPendingOutput() -> Int {
            lock.withLock {
                defer { queue.removeAll() }
                return queue.reduce(0) { if case .live(let d) = $1 { return $0 + d.count }; if case .replay(let d) = $1 { return $0 + d.count }; return $0 }
            }
        }

        func takePendingOutputForCatchUp() -> TerminalPendingWrites {
            lock.withLock {
                var bytes = Data()
                var complete = !nextTakeIsIncomplete
                nextTakeIsIncomplete = false
                for entry in queue {
                    switch entry {
                    case .live(let data): bytes.append(data)
                    case .replay: complete = false
                    }
                }
                queue.removeAll()
                return TerminalPendingWrites(bytes: bytes, complete: complete, droppedBytes: bytes.count)
            }
        }

        func afterPendingOutput(_ body: @escaping @Sendable () -> Void) {
            lock.withLock { markers.append(body) }
        }

        func setOutputBacklogHandler(highWater: Int, lowWater: Int, _ handler: (@Sendable (Bool) -> Void)?) {}
    }

    private func makePump() -> (TerminalOutputPump, ShadowTerminal, QueuedSurface) {
        let shadow = ShadowTerminal(cols: 40, rows: 6, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        let surface = QueuedSurface()
        let pump = TerminalOutputPump(shadow: shadow, surface: surface)
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        return (pump, shadow, surface)
    }

    /// surface 解析过的东西按顺序喂进另一个终端：应当和影子一样。
    private func screen(_ entries: [QueuedSurface.Entry]) -> String {
        let terminal = ShadowTerminal(cols: 40, rows: 6, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        for entry in entries {
            switch entry {
            case .live(let data), .replay(let data): terminal.feed(data)
            }
        }
        return terminal.viewportText()
    }

    /// 停喂时 surface 队列里没解析的字节和停喂期间的输出接成尾巴，恢复时原样补给它，不整屏回放。
    func testHiddenOutputIsAppendedAsATailInsteadOfAReplay() {
        let (pump, shadow, surface) = makePump()
        let caughtUp = LockedBox<[TerminalOutputPump.CatchUp]>([])
        pump.onSurfaceCaughtUp = { kind in caughtUp.mutate { $0.append(kind) } }
        pump.route(Data("one\r\n".utf8))
        surface.parse()
        pump.route(Data("queued\r\n".utf8))      // 交给了 surface、还没解析
        pump.setSurfaceFeeding(false)
        pump.route(Data("two\r\n".utf8))
        XCTAssertTrue(pump.surfaceNeedsCatchUp)

        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        surface.parse()
        XCTAssertEqual(pump.currentStats.replays, 0, "补得了尾巴就不整屏回放")
        XCTAssertEqual(pump.currentStats.tailCatchUps, 1)
        XCTAssertEqual(surface.replays, [Data("queued\r\ntwo\r\n".utf8)], "尾巴 = 队列里没解析的 + 停喂期间的，先后不变")
        XCTAssertEqual(screen(surface.entries), shadow.viewportText())
        XCTAssertEqual(caughtUp.value, [.tail])
        XCTAssertFalse(pump.surfaceNeedsCatchUp)
    }

    /// 停喂期间网格变了：同一串字节按不同网格解析结果不同，只能整屏回放。
    func testGridChangeWhileHiddenFallsBackToAReplay() {
        let (pump, shadow, surface) = makePump()
        let caughtUp = LockedBox<[TerminalOutputPump.CatchUp]>([])
        pump.onSurfaceCaughtUp = { kind in caughtUp.mutate { $0.append(kind) } }
        pump.route(Data("one\r\n".utf8))
        surface.parse()
        pump.setSurfaceFeeding(false)
        shadow.resize(cols: 30, rows: 6)
        pump.route(Data("two\r\n".utf8))
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        surface.parse()
        XCTAssertEqual(pump.currentStats.replays, 1)
        XCTAssertEqual(pump.currentStats.tailCatchUps, 0)
        XCTAssertEqual(caughtUp.value, [.replay])
    }

    /// 网格先变、后来又没来字节，恢复时网格对不上：同样整屏回放。
    func testGridChangeWithoutOutputIsCaughtAtResume() {
        let (pump, shadow, surface) = makePump()
        pump.route(Data("one\r\n".utf8))
        pump.setSurfaceFeeding(false)
        pump.route(Data("two\r\n".utf8))
        shadow.resize(cols: 30, rows: 6)
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        surface.parse()
        XCTAssertEqual(pump.currentStats.replays, 1)
        XCTAssertEqual(pump.currentStats.tailCatchUps, 0)
    }

    /// 停喂期间输出攒过了上限：整屏回放（代价和输出量无关），不留着几 MB 的尾巴。
    func testTailOverTheLimitFallsBackToAReplay() {
        let (pump, _, surface) = makePump()
        pump.setSurfaceFeeding(false)
        let line = Data(String(repeating: "x", count: 1023).appending("\n").utf8)
        for _ in 0..<(TerminalOutputPump.tailLimit / line.count + 2) { pump.route(line) }
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        surface.parse()
        XCTAssertEqual(pump.currentStats.replays, 1)
        XCTAssertEqual(pump.currentStats.tailCatchUps, 0)
    }

    /// surface 交回的不全（队列里夹着回放）、影子被不经过泵的方式改过：整屏回放。
    func testIncompleteOrStaleSurfaceFallsBackToAReplay() {
        let (pump, _, surface) = makePump()
        pump.route(Data("one\r\n".utf8))
        surface.nextTakeIsIncomplete = true
        pump.setSurfaceFeeding(false)
        pump.route(Data("two\r\n".utf8))
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        surface.parse()
        XCTAssertEqual(pump.currentStats.replays, 1)

        pump.setSurfaceFeeding(false)
        pump.route(Data("three\r\n".utf8))
        pump.markSurfaceStale()      // surface 被放掉了
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        surface.parse()
        XCTAssertEqual(pump.currentStats.replays, 2)
        XCTAssertEqual(pump.currentStats.tailCatchUps, 0)
    }

    /// 擦屏等 surface 解析到那一片之后才交出去；普通输出不报。
    func testEraseIsReportedAfterTheSurfaceParsedIt() {
        let (pump, _, surface) = makePump()
        let erases = LockedBox<[TerminalErase]>([])
        pump.onSurfaceErase = { erase in erases.mutate { $0.append(erase) } }
        pump.route(Data("plain output\r\n".utf8))
        pump.route(Data("\u{1B}[H\u{1B}[2J".utf8))
        XCTAssertEqual(erases.value, [], "surface 还没解析到")
        surface.parse()
        XCTAssertEqual(erases.value, [.screen])
        pump.route(Data("\u{1B}[2K".utf8))
        surface.parse()
        XCTAssertEqual(erases.value, [.screen, .inPlace])
    }

    /// 停喂期间来的擦屏（含停喂时还排在 surface 队列里的）：补完尾巴、surface 解析完之后再报，取最重的那一档。
    func testEraseWhileHiddenIsReportedAfterCatchingUp() {
        let (pump, _, surface) = makePump()
        let events = LockedBox<[String]>([])
        pump.onSurfaceErase = { erase in events.mutate { $0.append("erase \(erase)") } }
        pump.onSurfaceCaughtUp = { kind in events.mutate { $0.append("caught up \(kind)") } }
        pump.route(Data("\u{1B}[?1049h".utf8))   // 交给了 surface、还没解析
        pump.setSurfaceFeeding(false)
        pump.route(Data("\u{1B}[K".utf8))
        surface.parse()
        XCTAssertEqual(events.value, ["erase screen"], "排在停喂前的那个标记照常调（早一点，无害）")

        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        XCTAssertEqual(events.value, ["erase screen"], "补完、解析完之前不报")
        surface.parse()
        XCTAssertEqual(events.value, ["erase screen", "erase screen", "caught up tail"])
    }

    /// 整屏快照（远控镜像）换掉了影子：surface 回放之后报一次整屏擦除（选区一律清掉）。
    func testSnapshotReportsAScreenErase() throws {
        let (pump, _, surface) = makePump()
        let erases = LockedBox<[TerminalErase]>([])
        pump.onSurfaceErase = { erase in erases.mutate { $0.append(erase) } }
        let source = ShadowTerminal(cols: 40, rows: 6, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        source.feed(Data("mirrored".utf8))
        pump.applySnapshot(try source.snapshot())
        surface.parse()
        XCTAssertEqual(erases.value, [.screen])
    }
}
