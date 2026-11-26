import XCTest
@testable import uTerm

/// 在**这台 Mac 的真实** `~/.claude/sessions` 上读一遍正在运行的 Claude Code，读法同 App：经包内不带沙盒的辅助程序
/// `uTermShellAgent.xpc` 跑那条命令（`ClaudeHistorySource.liveSessions`）。顺带量一次要多久（定时读的间隔照它定）。
///
/// 会读你自己的记录，所以**默认跳过**，开关同 `AgentHistoryAllToolsLocalLiveTests`：`UTERM_AGENT_HISTORY_LOCAL=1`
/// （xcodebuild 传环境变量要加 `TEST_RUNNER_` 前缀）。**只读**；输出里只有条数与耗时，没有会话 ID、目录或名字。
@MainActor
final class ClaudeLiveSessionsLocalLiveTests: XCTestCase {
    private var client: LocalShellAgentClient!
    private var provider: RemoteMacFileProvider!

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["UTERM_AGENT_HISTORY_LOCAL"] == "1" else {
            throw XCTSkip("没设 UTERM_AGENT_HISTORY_LOCAL=1，跳过读本机真实记录的测试")
        }
        client = LocalShellAgentClient()
        provider = RemoteMacFileProvider.localShellAgent(client: client)
    }

    override func tearDown() async throws {
        client?.invalidate()
        try await super.tearDown()
    }

    func testReadsRunningSessions() async throws {
        let source = ClaudeHistorySource(provider: provider)
        // 第一次带着连辅助程序、问主目录，单独算。
        var started = ContinuousClock.now
        let first = try await source.liveSessions()
        let firstTime = ContinuousClock.now - started

        var times: [Duration] = []
        var sessions = first
        for _ in 0..<5 {
            started = ContinuousClock.now
            sessions = try await source.liveSessions()
            times.append(ContinuousClock.now - started)
        }
        let average = times.reduce(Duration.zero, +) / times.count
        let byState = Dictionary(grouping: sessions, by: { "\($0.state)" }).mapValues(\.count)
        print("[live-sessions] 在跑 \(sessions.count) 个：\(byState.sorted { $0.key < $1.key })；"
              + "第一次 \(firstTime)，之后平均 \(average)（最慢 \(times.max() ?? .zero)）")
        XCTAssertEqual(Set(sessions.map(\.key)).count, sessions.count, "同一会话只出一次")

        // 对到列表里的记录上：在跑的会话里，有多少在侧栏会列出来的那几行里。
        let projects = try await source.projects()
        let files = await source.allSessions(in: projects)
        let statuses = AgentHistoryLiveRuns.statuses(sessions, files: files, metadata: [:])
        print("[live-sessions] 对上记录的 \(statuses.count) 个（共 \(files.count) 份记录）")
    }
}
