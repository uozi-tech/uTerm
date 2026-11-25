import XCTest
@testable import uTerm

/// 退出状态之后：输出安静 `idle` 才结束，每块输出重新计时，最多等 `cap`。
final class RemoteExitDrainTests: XCTestCase {

    func testQuietOutputEndsAfterTheIdlePeriod() async throws {
        let drain = RemoteExitDrain(idle: .milliseconds(100), cap: .seconds(5))
        let started = ContinuousClock.now
        try await bounded("waitForQuiet 返回") { await drain.waitForQuiet(since: started) }
        let elapsed = ContinuousClock.now - started
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(100))
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testEveryChunkRestartsTheIdleTimer() async throws {
        let drain = RemoteExitDrain(idle: .milliseconds(200), cap: .seconds(5))
        let started = ContinuousClock.now
        let feeder = Task {
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(100))
                drain.noteChunk()
            }
        }
        try await bounded("waitForQuiet 返回") { await drain.waitForQuiet(since: started) }
        feeder.cancel()
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(700),
                                    "还在来输出时不该结束")
    }

    func testTheCapEndsEvenWhenOutputNeverStops() async throws {
        let drain = RemoteExitDrain(idle: .milliseconds(200), cap: .milliseconds(600))
        let started = ContinuousClock.now
        let feeder = Task {
            while !Task.isCancelled {
                drain.noteChunk()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        try await bounded("waitForQuiet 返回") { await drain.waitForQuiet(since: started) }
        feeder.cancel()
        let elapsed = ContinuousClock.now - started
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(600))
        XCTAssertLessThan(elapsed, .milliseconds(1500))
    }
}
