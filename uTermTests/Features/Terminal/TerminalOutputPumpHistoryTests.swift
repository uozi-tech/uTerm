import Foundation
import Synchronization
import XCTest
@testable import uTerm

/// 输出泵的三样和「接回留在别处的会话」有关的输出项：历史字节（`.history`）、同步点（`.afterFed`）、
/// 本机会话还原检查点（`.snapshot`）。
final class TerminalOutputPumpHistoryTests: XCTestCase {
    /// 能被 `@Sendable` 闭包带着走的记录本（`Mutex` 自己不可拷贝，闭包捕获不了）。
    private final class Log<Value: Sendable>: Sendable {
        private let collected = Mutex<[Value]>([])
        var values: [Value] { collected.withLock { $0 } }
        func append(_ value: Value) { collected.withLock { $0.append(value) } }
    }

    private static let deviceAttributesQuery = Data("\u{1B}[c".utf8)

    private func makeTerminal(cols: Int = 80, rows: Int = 24)
        -> (shadow: ShadowTerminal, surface: RecordingTerminalSurface, pump: TerminalOutputPump) {
        let shadow = ShadowTerminal(cols: UInt16(cols), rows: UInt16(rows),
                                    options: TerminalScrollbackLimits(lines: 1000).shadowOptions)
        let surface = RecordingTerminalSurface()
        return (shadow, surface, TerminalOutputPump(shadow: shadow, surface: surface))
    }

    private func wait(_ what: String, timeout: Duration = .seconds(5), until done: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            guard ContinuousClock.now < deadline else {
                XCTFail("等不到：\(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 历史里的查询不答（当时的程序早就不等了，回答会打进现在这个程序的输入）；实时的照答。内容两种都进影子。
    func testHistoryIsParsedButItsQueriesAreNotAnswered() async {
        let (shadow, _, pump) = makeTerminal()
        let replies = Log<Data>()
        shadow.setReplyHandler { reply in replies.append(reply) }
        let (items, feed) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.reset()
        pump.start(items)

        feed.yield(.history(Self.deviceAttributesQuery + Data("past".utf8)))
        await wait("历史进影子") { shadow.viewportText().contains("past") }
        XCTAssertTrue(replies.values.isEmpty, "历史里的查询不该有应答")

        feed.yield(.bytes(Self.deviceAttributesQuery + Data(" live".utf8)))
        await wait("实时字节进影子") { shadow.viewportText().contains("past live") }
        await wait("实时查询有应答") { !replies.values.isEmpty }
        pump.reset()
    }

    /// surface 在吃字节时，历史也交给它，但走不产生应答的那个入口。
    func testHistoryReachesAFeedingSurfaceAsReplay() async {
        let (shadow, surface, pump) = makeTerminal()
        let (items, feed) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.reset()
        pump.setSurfaceFeeding(true)
        pump.start(items)
        // 开闸时影子是空的，没有可回放的；之后的字节直接交给 surface。
        feed.yield(.bytes(Data("live".utf8)))
        await wait("实时字节到 surface") { surface.liveBytes == Data("live".utf8) }
        let replaysBefore = surface.replays.count

        feed.yield(.history(Data("past".utf8)))
        await wait("历史进影子") { shadow.viewportText().contains("livepast") }
        XCTAssertEqual(surface.liveBytes, Data("live".utf8), "历史不走会产生应答的入口")
        XCTAssertEqual(surface.replays.dropFirst(replaysBefore).reduce(into: Data()) { $0.append($1) },
                       Data("past".utf8))
        pump.reset()
    }

    /// 同步点被调的那一刻，影子正好解析到排在它前面的字节为止。
    func testSyncPointRunsExactlyBetweenTheBytesAroundIt() async {
        let (shadow, _, pump) = makeTerminal()
        let (items, feed) = AsyncStream<TerminalOutputItem>.makeStream()
        let seen = Log<String>()
        feed.yield(.bytes(Data("one".utf8)))
        feed.yield(.afterFed { seen.append(shadow.viewportText().trimmingCharacters(in: .whitespacesAndNewlines)) })
        feed.yield(.history(Data(" two".utf8)))
        feed.yield(.afterFed { seen.append(shadow.viewportText().trimmingCharacters(in: .whitespacesAndNewlines)) })
        feed.yield(.bytes(Data(" three".utf8)))
        pump.reset()
        pump.start(items)

        await wait("全部进影子") { shadow.viewportText().contains("one two three") }
        XCTAssertEqual(seen.values, ["one", "one two"])
        pump.reset()
    }

    /// 换了连接之后，上一条连接留下的同步点不再执行。
    func testSyncPointFromAnOldConnectionIsDropped() async {
        let (shadow, _, pump) = makeTerminal()
        let ran = Log<Bool>()
        let (stale, staleFeed) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.reset()
        pump.start(stale)
        pump.reset()
        staleFeed.yield(.afterFed { ran.append(true) })

        let (items, feed) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.start(items)
        feed.yield(.bytes(Data("new".utf8)))
        await wait("新连接的字节进影子") { shadow.viewportText().contains("new") }
        XCTAssertTrue(ran.values.isEmpty)
        pump.reset()
    }

    /// 本机会话（影子跟本地网格走）还原检查点：内容回来了，网格还是本地的，不是存检查点时的。
    func testRestoringACheckpointKeepsTheLocalGrid() async throws {
        let saved = makeTerminal(cols: 100, rows: 30)
        saved.shadow.feed(Data("from the checkpoint".utf8))
        let checkpoint = try XCTUnwrap(saved.pump.performWhileFeedingPaused {
            saved.pump.makeCheckpoint(scrollbackLines: 500, programStatus: nil)
        })
        XCTAssertEqual(checkpoint.cols, 100)
        XCTAssertEqual(checkpoint.rows, 30)
        let snapshot = try XCTUnwrap(TerminalCheckpointBlob.decode(checkpoint.blob))

        let (shadow, _, pump) = makeTerminal()
        shadow.resize(cols: 60, rows: 20)
        let (items, feed) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.reset()
        pump.start(items)
        feed.yield(.snapshot(snapshot))
        feed.yield(.history(Data(" and after".utf8)))

        await wait("检查点和之后的历史进影子") { shadow.viewportText().contains("from the checkpoint and after") }
        XCTAssertEqual(shadow.size.cols, 60)
        XCTAssertEqual(shadow.size.rows, 20)
        pump.reset()
    }

    /// 还没有本地网格的影子（标签从没露出过）还原检查点：先用检查点的网格，等本地的报上来。
    func testRestoringACheckpointBeforeAnyLocalGridUsesTheCheckpointGrid() async throws {
        let saved = makeTerminal(cols: 100, rows: 30)
        saved.shadow.feed(Data("hello".utf8))
        let snapshot = try saved.shadow.snapshot()

        let (shadow, _, pump) = makeTerminal()
        let (items, feed) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.reset()
        pump.start(items)
        feed.yield(.snapshot(snapshot))
        await wait("检查点进影子") { shadow.viewportText().contains("hello") }
        XCTAssertEqual(shadow.size.cols, 100)
        XCTAssertEqual(shadow.size.rows, 30)
        pump.reset()
    }
}
