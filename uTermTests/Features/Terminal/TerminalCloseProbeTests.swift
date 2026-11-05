import XCTest
@testable import uTerm

/// 两端共用的关标签前探测：防重复 + 结果交给调用方。
@MainActor
final class TerminalCloseProbeTests: XCTestCase {

    private actor ActivityBackend: TerminalBackend {
        nonisolated let outputStream = AsyncStream<Data> { $0.finish() }
        nonisolated let exitStream = AsyncStream<Void> { $0.finish() }
        let activity: TerminalActivity
        private(set) var asked = 0
        init(_ activity: TerminalActivity) { self.activity = activity }
        func connect() async throws {}
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {}
        func foregroundActivity() async -> TerminalActivity {
            asked += 1
            return activity
        }
    }

    func test_idle_activity_closes_without_prompt() async {
        let probe = TerminalCloseProbe()
        var decided: [TerminalClosePrompt?] = []
        let ran = await probe.probe("a", activity: { .idle }, then: { decided.append($0) })
        XCTAssertTrue(ran)
        XCTAssertEqual(decided.count, 1)
        XCTAssertNil(decided[0])
        XCTAssertFalse(probe.isProbing("a"))
    }

    func test_busy_activity_hands_prompt_to_caller() async {
        let probe = TerminalCloseProbe()
        var decided: TerminalClosePrompt?
        await probe.probe(1, activity: { .unknown }, then: { decided = $0 })
        XCTAssertEqual(decided, TerminalActivity.unknown.closePrompt)
        XCTAssertNotNil(decided)
    }

    /// 探测或确认还没结束时再点关闭：不重复发起；结束后才放行下一次。
    func test_second_request_while_probing_is_ignored() async {
        let probe = TerminalCloseProbe()
        let (gate, open) = AsyncStream<Void>.makeStream()
        var decisions = 0
        let first = Task {
            await probe.probe("tab", activity: {
                for await _ in gate { break }
                return .idle
            }, then: { _ in decisions += 1 })
        }
        while !probe.isProbing("tab") { await Task.yield() }
        let second = await probe.probe("tab", activity: { .idle }, then: { _ in decisions += 1 })
        XCTAssertFalse(second)
        open.yield()
        let firstRan = await first.value
        XCTAssertTrue(firstRan)
        XCTAssertEqual(decisions, 1)
        XCTAssertFalse(probe.isProbing("tab"))
        let third = await probe.probe("tab", activity: { .idle }, then: { _ in decisions += 1 })
        XCTAssertTrue(third)
        XCTAssertEqual(decisions, 2)
    }

    func test_not_connected_is_idle_without_asking_backend() async {
        let backend = ActivityBackend(.unknown)
        let activity = await TerminalCloseProbe.foregroundActivity(connected: false, backend: backend) { false }
        XCTAssertEqual(activity, .idle)
        let asked = await backend.asked
        XCTAssertEqual(asked, 0)
    }

    func test_connected_asks_backend() async {
        let backend = ActivityBackend(.unknown)
        let activity = await TerminalCloseProbe.foregroundActivity(connected: true, backend: backend) { false }
        XCTAssertEqual(activity, TerminalActivity.unknown.resolved(alternateScreen: false))
        let asked = await backend.asked
        XCTAssertEqual(asked, 1)
    }
}
