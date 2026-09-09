import XCTest
@testable import uTerm

/// `BoundedExec` 的两条命脉：**永不返回的 body 也能按时超时返回**（Citadel 的 exec
/// 不可取消，结构化并发在这里救不了场），以及**晚到的结果被闸门丢弃**（不崩、不泄漏）。
final class BoundedExecTests: XCTestCase {

    func testCompletedValuePassesThrough() async {
        let outcome = await BoundedExec.run(timeout: .seconds(5)) { 42 }
        guard case .completed(let value) = outcome else {
            return XCTFail("应为 completed，实际 \(outcome)")
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(outcome.value, 42)
        XCTAssertFalse(outcome.timedOut)
        XCTAssertNil(outcome.errorText)
    }

    func testThrownErrorIsBoxedWithReadableText() async {
        struct Boom: LocalizedError { var errorDescription: String? { "炸了" } }
        let outcome = await BoundedExec.run(timeout: .seconds(5)) { () throws -> Int in throw Boom() }
        guard case .failed(let failure) = outcome else {
            return XCTFail("应为 failed，实际 \(outcome)")
        }
        XCTAssertTrue(failure.underlying is Boom)
        XCTAssertEqual(outcome.errorText, "炸了")
        XCTAssertNil(outcome.value)
    }

    /// 永不返回的 body：超时必须**立刻**返回，而不是等 body（那正是 `tail -f` 挂死任务组的形态）。
    func testNeverReturningBodyTimesOut() async {
        let start = Date()
        let outcome = await BoundedExec.run(timeout: .milliseconds(120)) {
            try? await Task.sleep(for: .seconds(600))
            return 1
        }
        XCTAssertTrue(outcome.timedOut, "应为 timedOut，实际 \(outcome)")
        XCTAssertNil(outcome.value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "超时后不该继续等 body")
    }

    /// 晚到的结果：`deliver` 被闸门吞掉，不 resume 第二次续体（那会崩），也不留悬挂 Task。
    func testLateResultAfterTimeoutIsDiscardedWithoutCrashing() async {
        let finished = expectation(description: "body 在超时之后自然跑完")
        let outcome = await BoundedExec.run(timeout: .milliseconds(50)) {
            try? await Task.sleep(for: .milliseconds(300))
            finished.fulfill()
            return "late"
        }
        XCTAssertTrue(outcome.timedOut)
        await fulfillment(of: [finished], timeout: 5)
        // 再多等一会儿，让那条晚到的 deliver 真正跑过一遍闸门。
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// body 赢的时候定时器要被取消，不能让它把结果覆盖成超时。
    func testFastBodyWinsOverTimer() async {
        for _ in 0..<20 {
            let outcome = await BoundedExec.run(timeout: .milliseconds(500)) { "ok" }
            XCTAssertEqual(outcome.value, "ok")
        }
    }
}
