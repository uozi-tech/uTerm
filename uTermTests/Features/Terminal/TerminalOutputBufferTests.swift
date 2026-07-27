import XCTest
@testable import uTerm

final class TerminalOutputBufferTests: XCTestCase {
    func testAppendThenDrainReturnsData() {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        buf.append(Data("hello".utf8), generation: 1)
        let out = buf.drain(maxBytes: 1024, generation: 1)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello")
    }

    func testDrainRespectsMaxBytes() {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        buf.append(Data("0123456789".utf8), generation: 1)
        let first = buf.drain(maxBytes: 4, generation: 1)
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "0123")
        let rest = buf.drain(maxBytes: 1024, generation: 1)
        XCTAssertEqual(String(decoding: rest, as: UTF8.self), "456789")
    }

    func testHighFrequencySmallChunksCoalesceIntoBoundedFlushes() {
        let buf = TerminalOutputBuffer(capacityBytes: 128 * 1024)
        for _ in 0..<50_000 {
            buf.append(Data([0x41]), generation: 1)
        }

        let firstFrame = buf.drain(maxBytes: 32 * 1024, generation: 1)
        let secondFrame = buf.drain(maxBytes: 32 * 1024, generation: 1)

        XCTAssertEqual(firstFrame.count, 32 * 1024)
        XCTAssertEqual(secondFrame.count, 50_000 - 32 * 1024)
        XCTAssertTrue(buf.drain(maxBytes: 32 * 1024, generation: 1).isEmpty)
    }

    func testStaleGenerationChunksAreDropped() {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        buf.append(Data("old".utf8), generation: 1)
        buf.append(Data("new".utf8), generation: 2)
        let out = buf.drain(maxBytes: 1024, generation: 2)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "new")
    }

    func testOverflowDropsOldestChunks() {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        buf.append(Data(repeating: 0x41, count: 1024), generation: 1) // 占满
        buf.append(Data(repeating: 0x42, count: 512), generation: 1)  // 触发丢弃
        let out = buf.drain(maxBytes: 4096, generation: 1)
        XCTAssertLessThanOrEqual(out.count, 1024)
        XCTAssertTrue(out.contains(0x42))
    }

    func testClearEmptiesBuffer() {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        buf.append(Data("x".utf8), generation: 1)
        buf.clear()
        XCTAssertTrue(buf.drain(maxBytes: 1024, generation: 1).isEmpty)
    }

    /// Flush 循环用这个挂起原语把空闲时的 CPU 占用降到 0，又能在
    /// `append()` 发生后立即恢复 —— 取代过去 100ms 的轮询间隔。
    /// 调用时若已有缓冲字节，立即返回，避免 drain/wait 之间的丢信号竞态。
    func testWaitForDataReturnsImmediatelyWhenBuffered() async {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        buf.append(Data("x".utf8), generation: 1)
        let start = Date()
        await buf.waitForData()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "已有数据时应立即返回")
    }

    /// `append()` 必须唤醒挂起的等待者，这是修复输入卡顿的核心机制。
    func testWaitForDataResumesAfterAppend() async {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        let expectResumed = expectation(description: "waiter resumed after append")
        Task {
            await buf.waitForData()
            expectResumed.fulfill()
        }
        // 让等待者先进入挂起态。
        try? await Task.sleep(for: .milliseconds(20))
        buf.append(Data("y".utf8), generation: 1)
        await fulfillment(of: [expectResumed], timeout: 0.2)
    }

    /// `clear()` 也要唤醒等待者，这样 `resetFeedAndResizeState()` 在取消
    /// flush task 时不会留下永远挂起的等待。
    func testClearResumesPendingWaiters() async {
        let buf = TerminalOutputBuffer(capacityBytes: 1024)
        let expectResumed = expectation(description: "waiter resumed on clear")
        Task {
            await buf.waitForData()
            expectResumed.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(20))
        buf.clear()
        await fulfillment(of: [expectResumed], timeout: 0.2)
    }
}
