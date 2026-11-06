import XCTest
import SwiftTerm
@testable import uTerm

/// 两端共用的输出泵（`TerminalOutputPump`）：字节按序喂进终端、每拍回调、代次隔离、视图晚到、释放。
/// 节拍算法本身在 `TerminalFlushPacingTests`，mac 会话的接线在 `TerminalFlushWiringTests`。
@MainActor
final class TerminalOutputPumpTests: XCTestCase {

    private let kb = 1024
    /// 1ms 一拍、预算不随耗时缩：跑得快，批大小不取决于这台机器解析得多快。
    private lazy var fast = TerminalFlushPacing(intervalMs: 1, baseBytes: 32 * kb, maxBytes: 32 * kb, targetMs: 1_000_000)

    private final class Fed {
        var batches: [[UInt8]] = []
        var all: [UInt8] { batches.flatMap { $0 } }
    }

    private func makePump(pacing: TerminalFlushPacing? = nil, view: SwiftTerm.TerminalView?) -> (TerminalOutputPump, Fed) {
        let pump = TerminalOutputPump(pacing: pacing ?? fast)
        pump.terminalView = view
        let fed = Fed()
        pump.onFed = { fed.batches.append(Array($0)) }
        return (pump, fed)
    }

    /// 泵只弱引用视图（视图归拥有者），测试要自己留住它。
    private var views: [SwiftTerm.TerminalView] = []

    private func makeView() -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        views.append(view)
        return view
    }

    override func tearDown() {
        views.removeAll()
        super.tearDown()
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func screenText(_ view: SwiftTerm.TerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    func testFeedsStreamBytesIntoTheViewInOrder() async {
        let view = makeView()
        let (pump, fed) = makePump(view: view)
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        pump.start(stream)

        continuation.yield(Data("hello ".utf8))
        continuation.yield(Data("world".utf8))
        await waitUntil { fed.all.count == 11 }

        XCTAssertEqual(String(decoding: fed.all, as: UTF8.self), "hello world")
        XCTAssertTrue(screenText(view).contains("hello world"))
        continuation.finish()
    }

    /// 积压时一拍不超过预算，拼起来一个字节不丢、不错序。
    func testBacklogIsSplitIntoBudgetSizedBeatsWithoutLoss() async {
        let (pump, fed) = makePump(view: makeView())
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let payload = (0..<(200 * kb)).map { UInt8(truncatingIfNeeded: $0 % 94 + 32) }
        continuation.yield(Data(payload))
        pump.start(stream)

        await waitUntil { fed.all.count == payload.count }

        XCTAssertEqual(fed.all, payload)
        XCTAssertEqual(fed.batches.map(\.count).max(), 32 * kb)
        continuation.finish()
    }

    /// iOS：视图晚于建连才挂上。字节留在缓冲里，挂上后照样喂进去。
    func testBytesWaitUntilAViewIsAttached() async throws {
        let (pump, fed) = makePump(view: nil)
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        pump.start(stream)
        continuation.yield(Data("early".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(fed.batches.isEmpty)

        let view = makeView()
        pump.terminalView = view
        await waitUntil { fed.all.count == 5 }

        XCTAssertEqual(String(decoding: fed.all, as: UTF8.self), "early")
        XCTAssertTrue(screenText(view).contains("early"))
        continuation.finish()
    }

    /// 换连接（`reset`）后上一条连接的积压与后续字节都不再喂进来。
    func testResetDropsTheOldConnectionsBytes() async throws {
        let slow = TerminalFlushPacing(intervalMs: 40, baseBytes: 32 * kb, maxBytes: 32 * kb, targetMs: 8)
        let (pump, fed) = makePump(pacing: slow, view: makeView())
        let (old, oldContinuation) = AsyncStream.makeStream(of: Data.self)
        pump.start(old)
        oldContinuation.yield(Data(repeating: UInt8(ascii: "a"), count: 1024 * kb))
        await waitUntil { !fed.batches.isEmpty }
        XCTAssertTrue(pump.isRunning)

        pump.reset()
        XCTAssertFalse(pump.isRunning)
        let afterReset = fed.all.count
        XCTAssertLessThan(afterReset, 1024 * kb, "积压要还没喂完才有意义")
        oldContinuation.yield(Data("OLD".utf8))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fed.all.count, afterReset)

        let (new, newContinuation) = AsyncStream.makeStream(of: Data.self)
        pump.start(new)
        newContinuation.yield(Data("NEW".utf8))
        await waitUntil { fed.all.count == afterReset + 3 }
        XCTAssertEqual(fed.batches.last.map { String(decoding: $0, as: UTF8.self) }, "NEW")
        oldContinuation.finish()
        newContinuation.finish()
    }

    /// 换档马上生效：下一拍按新档的预算喂。
    func testPacingChangeAppliesFromTheNextBeat() async {
        let small = TerminalFlushPacing(intervalMs: 20, baseBytes: 32 * kb, maxBytes: 32 * kb, targetMs: 1_000_000)
        let (pump, fed) = makePump(pacing: small, view: makeView())
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        continuation.yield(Data(repeating: UInt8(ascii: "b"), count: 1024 * kb))
        pump.start(stream)
        await waitUntil { !fed.batches.isEmpty }

        pump.pacing = TerminalFlushPacing(intervalMs: 1, baseBytes: 128 * kb, maxBytes: 128 * kb, targetMs: 1_000_000)
        await waitUntil { fed.all.count == 1024 * kb }

        XCTAssertEqual(fed.batches.first?.count, 32 * kb)
        XCTAssertEqual(fed.batches.map(\.count).max(), 128 * kb)
        continuation.finish()
    }

    func testRestartFlushLoopDoesNothingWhenNotRunning() {
        let (pump, _) = makePump(view: makeView())
        pump.restartFlushLoop()
        XCTAssertFalse(pump.isRunning)
    }

    /// 两拍之间循环不强持泵：拥有者放手后泵就释放，挂起的循环随之退出。
    func testPumpIsReleasedWhileItsLoopIsIdle() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        weak var released: TerminalOutputPump?
        do {
            let (pump, fed) = makePump(view: makeView())
            pump.start(stream)
            continuation.yield(Data("x".utf8))
            await waitUntil { fed.all.count == 1 }
            released = pump
        }
        await waitUntil { released == nil }
        XCTAssertNil(released)
        continuation.finish()
    }
}
