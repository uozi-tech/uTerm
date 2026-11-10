import XCTest
@testable import uTerm

/// 原来核的是 `TerminalOutputBuffer`：旧引擎那条路径上，后端输出先进一个有上限的缓冲（满了丢最旧的），主线程的
/// flush 循环按拍从里面取。这个类型随旧引擎一起删了。现在后端输出由共享的 `TerminalOutputPump` 直接分流
/// （影子终端 → tap → surface），中间没有会丢字节的缓冲；画面解析不过来时停取后端的输出（背压）。
///
/// 这里逐条换成泵上的对应性质（用假的 surface，不建窗口）；纯属缓冲内部机制、泵上已有同名性质用例的，保留用例、
/// 标跳过并指到 `TerminalOutputPumpTests` 里的那一条。
final class TerminalOutputBufferTests: XCTestCase {

    private func makePump() -> (TerminalOutputPump, ShadowTerminal, RecordingTerminalSurface) {
        let shadow = ShadowTerminal(cols: 80, rows: 24, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        let surface = RecordingTerminalSurface()
        let pump = TerminalOutputPump(shadow: shadow, surface: surface)
        pump.setSurfaceFeeding(true)
        pump.waitForCatchUp()
        return (pump, shadow, surface)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// 进去什么、出来什么。
    func testAppendThenDrainReturnsData() async {
        let (pump, shadow, surface) = makePump()
        let (stream, continuation) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.start(stream)
        continuation.yield(.bytes(Data("hello".utf8)))
        let arrived = await waitUntil { surface.liveBytes.count == 5 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(String(decoding: surface.liveBytes, as: UTF8.self), "hello")
        XCTAssertEqual(shadow.recentLines(1).lines, ["hello"])
        pump.reset()
    }

    /// 原来：`drain(maxBytes:)` 一次最多取这么多。现在：大块按 `sliceBytes` 切，每片不超过它，拼起来还是原样。
    func testDrainRespectsMaxBytes() async {
        let (pump, _, surface) = makePump()
        let (stream, continuation) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.start(stream)
        let big = Data((0..<(TerminalOutputPump.sliceBytes * 3 + 10)).map { UInt8(ascii: "0") + UInt8($0 % 10) })
        continuation.yield(.bytes(big))
        let arrived = await waitUntil { surface.liveBytes.count == big.count }
        XCTAssertTrue(arrived)
        XCTAssertEqual(surface.pieces.map(\.count),
                       [TerminalOutputPump.sliceBytes, TerminalOutputPump.sliceBytes, TerminalOutputPump.sliceBytes, 10])
        XCTAssertEqual(surface.liveBytes, big)
        pump.reset()
    }

    /// 高频的小块（一次一个字节，5 万次）：一个不少、顺序不变。
    func testHighFrequencySmallChunksCoalesceIntoBoundedFlushes() async {
        let (pump, shadow, surface) = makePump()
        let (stream, continuation) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.start(stream)
        var expected = Data()
        for index in 0..<50_000 {
            let byte = UInt8(ascii: "A") + UInt8(index % 26)
            expected.append(byte)
            continuation.yield(.bytes(Data([byte])))
        }
        let arrived = await waitUntil(20) { shadow.totalFedBytes == 50_000 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(surface.liveBytes, expected)
        XCTAssertLessThanOrEqual(surface.pieces.map(\.count).max() ?? 0, TerminalOutputPump.sliceBytes)
        pump.reset()
    }

    /// 上一条连接的输出作废。
    func testStaleGenerationChunksAreDropped() async {
        let (pump, shadow, surface) = makePump()
        let (old, oldContinuation) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.start(old)
        pump.reset()
        oldContinuation.yield(.bytes(Data("old".utf8)))
        let (new, newContinuation) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.start(new)
        newContinuation.yield(.bytes(Data("new".utf8)))
        let arrived = await waitUntil { shadow.totalFedBytes >= 3 }
        XCTAssertTrue(arrived)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(String(decoding: surface.liveBytes, as: UTF8.self), "new")
        pump.reset()
    }

    /// 原来：缓冲满了丢最旧的。现在不丢：画面解析不过来（积压到高水位）时入站停下，等它消化了再继续，
    /// 这期间到的每一块之后都按原来的顺序进终端。
    func testOverflowDropsOldestChunks() async {
        let (pump, shadow, surface) = makePump()
        let (stream, continuation) = AsyncStream<TerminalOutputItem>.makeStream()
        pump.start(stream)
        surface.setBacklogged(true)
        var expected = Data()
        for value in [UInt8(0x41), 0x42, 0x43] {
            let chunk = Data(repeating: value, count: 1024)
            expected.append(chunk)
            continuation.yield(.bytes(chunk))
        }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(shadow.totalFedBytes, 0, "积压期间不取输出")

        surface.setBacklogged(false)
        let arrived = await waitUntil { surface.liveBytes.count == expected.count }
        XCTAssertTrue(arrived)
        XCTAssertEqual(surface.liveBytes, expected, "最旧的那一块也在")
        pump.reset()
    }

    func testClearEmptiesBuffer() throws {
        throw XCTSkip("没有缓冲可清了；换连接时作废旧输出见上面的 testStaleGenerationChunksAreDropped 与 TerminalOutputPumpTests.testResetDiscardsThePreviousConnectionsOutput")
    }

    func testWaitForDataReturnsImmediatelyWhenBuffered() throws {
        throw XCTSkip("flush 循环的挂起原语随 TerminalOutputBuffer 删除；入站任务直接 for await 后端的流，没有轮询也没有等待原语")
    }

    func testWaitForDataResumesAfterAppend() throws {
        throw XCTSkip("同上；「停下之后能被叫醒」现在是闸门放行，见 testOverflowDropsOldestChunks 与 TerminalOutputPumpTests.testBacklogPausesIngressUntilTheSurfaceCatchesUp")
    }

    func testClearResumesPendingWaiters() throws {
        throw XCTSkip("同上；「换连接时不留永远挂起的等待」见 TerminalOutputPumpTests.testResetReleasesAnIngressParkedAtTheGate")
    }
}
