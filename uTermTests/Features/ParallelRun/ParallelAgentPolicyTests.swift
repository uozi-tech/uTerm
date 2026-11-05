import XCTest
@testable import uTerm

/// 并行执行 Agent 的公共规则：重试判定、退避重试、回喂裁剪、轮数提醒、提示词要点。
final class ParallelAgentPolicyTests: XCTestCase {

    // MARK: - isRetryable

    func testTransientErrorsAreRetryable() {
        for status in [408, 409, 425, 429, 500, 502, 503, 529] {
            XCTAssertTrue(ParallelAgentPolicy.isRetryable(LLMClientError.httpError(status: status, body: "")),
                          "HTTP \(status) 应当重试")
        }
        XCTAssertTrue(ParallelAgentPolicy.isRetryable(LLMClientError.streamIdleTimeout))
        XCTAssertTrue(ParallelAgentPolicy.isRetryable(LLMClientError.incompleteStream))
        XCTAssertTrue(ParallelAgentPolicy.isRetryable(LLMClientError.streamError("overloaded")))
        XCTAssertTrue(ParallelAgentPolicy.isRetryable(URLError(.networkConnectionLost)))
    }

    func testPermanentErrorsAreNotRetried() {
        for status in [400, 401, 403, 404] {
            XCTAssertFalse(ParallelAgentPolicy.isRetryable(LLMClientError.httpError(status: status, body: "")),
                           "HTTP \(status) 重试也是同样结果")
        }
        XCTAssertFalse(ParallelAgentPolicy.isRetryable(LLMClientError.outputLimitReached))
        XCTAssertFalse(ParallelAgentPolicy.isRetryable(CancellationError()))
    }

    // MARK: - withRetry

    func testWithRetryRecoversFromTransientFailures() async {
        let calls = Counter()
        let retries = Counter()
        let result = await ParallelAgentPolicy.withRetry(
            delay: { _ in .zero },
            onRetry: { n, _ in retries.record(n) }
        ) {
            let n = calls.next()
            if n < 3 { throw LLMClientError.httpError(status: 429, body: "rate limited") }
            return "ok"
        }
        XCTAssertEqual(try? result.get(), "ok")
        XCTAssertEqual(calls.value, 3, "前两次 429 之后第三次成功")
        XCTAssertEqual(retries.recorded, [1, 2])
    }

    func testWithRetryStopsImmediatelyOnPermanentError() async {
        let calls = Counter()
        let result: Result<String, Error> = await ParallelAgentPolicy.withRetry(delay: { _ in .zero }) {
            _ = calls.next()
            throw LLMClientError.httpError(status: 401, body: "bad key")
        }
        XCTAssertEqual(calls.value, 1, "401 不该重试")
        guard case .failure(let error) = result else { return XCTFail("应当失败") }
        XCTAssertEqual(error as? LLMClientError, .httpError(status: 401, body: "bad key"))
    }

    func testWithRetryGivesUpAfterAttempts() async {
        let calls = Counter()
        let result: Result<String, Error> = await ParallelAgentPolicy.withRetry(attempts: 4, delay: { _ in .zero }) {
            _ = calls.next()
            throw LLMClientError.httpError(status: 503, body: "")
        }
        XCTAssertEqual(calls.value, 4)
        XCTAssertThrowsError(try result.get())
    }

    func testRetryDelayGrowsAndIsBounded() {
        let first = ParallelAgentPolicy.retryDelay(afterAttempt: 1)
        let third = ParallelAgentPolicy.retryDelay(afterAttempt: 3)
        let later = ParallelAgentPolicy.retryDelay(afterAttempt: 9)
        XCTAssertGreaterThanOrEqual(first, .seconds(2))
        XCTAssertLessThanOrEqual(first, .seconds(3.5))
        XCTAssertGreaterThanOrEqual(third, .seconds(10))
        XCTAssertLessThanOrEqual(later, .seconds(11.5), "超出表长按最后一档")
    }

    // MARK: - clipForModel

    func testShortOutputIsUntouched() {
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ParallelAgentPolicy.clipForModel(text), text)
    }

    func testLongOutputKeepsHeadAndTail() {
        let lines = (1...1000).map { "line \($0)" }
        let clipped = ParallelAgentPolicy.clipForModel(lines.joined(separator: "\n"))
        XCTAssertTrue(clipped.hasPrefix("line 1\n"))
        XCTAssertTrue(clipped.hasSuffix("line 1000"), "错误多在最后几行，尾部必须保留")
        XCTAssertTrue(clipped.contains("中间省略 850 行"))
        XCTAssertFalse(clipped.contains("line 500\n"))
    }

    func testVeryWideOutputIsCappedByCharacters() {
        let wide = String(repeating: "x", count: 50_000) + "ERROR at end"
        let clipped = ParallelAgentPolicy.clipForModel(wide)
        XCTAssertLessThan(clipped.count, ParallelAgentPolicy.modelOutputMaxChars + 100)
        XCTAssertTrue(clipped.hasSuffix("ERROR at end"))
    }

    // MARK: - budgetNote

    func testBudgetNotesOnlyNearTheEnd() {
        let max = ParallelAgentPolicy.maxTurns
        XCTAssertNil(ParallelAgentPolicy.budgetNote(afterTurn: 0))
        XCTAssertNotNil(ParallelAgentPolicy.budgetNote(afterTurn: max - 1 - ParallelAgentPolicy.budgetWarningAt))
        let last = ParallelAgentPolicy.budgetNote(afterTurn: max - 2)
        XCTAssertTrue(last?.contains("最后一轮") == true, "倒数第二轮跑完要告诉模型下一轮直接给结论")
        XCTAssertNil(ParallelAgentPolicy.budgetNote(afterTurn: max - 1))
    }

    // MARK: - 提示词

    func testWorkingRulesAskToRecoverBeforeGivingUp() {
        let rules = ParallelAgentPolicy.workingRules(idleSeconds: 120, maxDurationSeconds: 1800)
        XCTAssertTrue(rules.contains("不要立刻放弃"))
        XCTAssertTrue(rules.contains("DEBIAN_FRONTEND=noninteractive"))
        XCTAssertTrue(rules.contains("连续约 120 秒没有任何输出"))
        XCTAssertTrue(rules.contains("\(ParallelAgentPolicy.maxTurns) 轮"))
    }

    func testMacPromptUsesSharedRules() {
        let prompt = ParallelAgentEngine.systemPrompt(host: "macOS 原生 SSH 终端", approval: .safety(.auto))
        XCTAssertTrue(prompt.contains("不要立刻放弃"))
        XCTAssertTrue(prompt.contains(#"{"status":"ok|failed""#))
    }
}

/// 线程安全计数器（`withRetry` 的闭包是 `@Sendable`）。
private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var log: [Int] = []
    var value: Int { lock.withLock { n } }
    var recorded: [Int] { lock.withLock { log } }
    func next() -> Int { lock.withLock { n += 1; return n } }
    func record(_ value: Int) { lock.withLock { log.append(value) } }
}
