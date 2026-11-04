import XCTest
@testable import uTerm

/// 关标签前的探测不能把用户挂住：Citadel 的 exec 不响应取消，通道卡住时只能靠超时。
final class TerminalActivityProbeRaceTests: XCTestCase {

    /// 不响应取消、由测试放行的探测。
    private actor Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func release() {
            released = true
            waiting?.resume()
            waiting = nil
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: TerminalActivity?
        var value: TerminalActivity? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// 回不来时返回 nil，用例照常失败，不会把整轮测试挂住。
    private func race(timeout: Duration, probe: @escaping @Sendable () async -> TerminalActivity) async -> TerminalActivity? {
        let finished = expectation(description: "探测返回")
        let box = Box()
        Task {
            box.value = await TerminalActivity.probed(timeout: timeout, probe: probe)
            finished.fulfill()
        }
        // 比超时宽裕得多：这里只防「永远回不来」，不量耗时。
        await fulfillment(of: [finished], timeout: 10)
        return box.value
    }

    func testProbeThatNeverAnswersBecomesUnknownAtTimeout() async {
        let gate = Gate()
        let activity = await race(timeout: .milliseconds(50)) {
            await gate.wait()
            return .running("late")
        }
        XCTAssertEqual(activity, .unknown)
        await gate.release()
    }

    func testAnswerBeforeTimeoutWins() async {
        let activity = await race(timeout: .seconds(30)) { .running("npm") }
        XCTAssertEqual(activity, .running("npm"))
    }

    func testIdleAnswerIsNotConfusedWithUnknown() async {
        let activity = await race(timeout: .seconds(30)) { .idle }
        XCTAssertEqual(activity, .idle)
    }

    /// 探测回来时结果已经没人要了，晚到的结果不能出问题。
    func testLateAnswerAfterTimeoutIsHarmless() async throws {
        let gate = Gate()
        let activity = await race(timeout: .milliseconds(20)) {
            await gate.wait()
            return .running("late")
        }
        XCTAssertEqual(activity, .unknown)
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
    }

    @MainActor
    func testUnknownOnAlternateScreenCountsAsRunningAtSessionLevel() async {
        let backend = MockBackend()
        await backend.setForegroundActivity(.unknown)
        let session = TerminalSession()
        await session.connect(using: backend)

        let onMainScreen = await session.foregroundActivity()
        XCTAssertEqual(onMainScreen, .unknown)

        session.terminalView.feed(text: "\u{1b}[?1049h")
        let onAlternateScreen = await session.foregroundActivity()
        XCTAssertEqual(onAlternateScreen, .running(nil))
        await session.close()
    }
}
