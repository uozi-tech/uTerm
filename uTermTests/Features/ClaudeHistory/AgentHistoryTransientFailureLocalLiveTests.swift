import XCTest
@testable import uTerm

/// 在**这台 Mac 的真实记录**上（四种工具、经包内的辅助程序读，同 Code 标签页），后台重列时让文件请求失败，
/// 看侧栏还剩什么。失败是在请求发出去之前拦下来的（`RemoteMacFileProvider(send:)` 包一层），不碰辅助程序本身。
///
/// 三种失败：只有 `~/.claude/projects` 这一个目录、Claude Code 的整棵记录、所有请求（辅助程序断了一下）。
/// 修之前（2026-11-25 实测）：第一、二种 Claude Code 的会话与置顶全没了；第三种列表换成「没有历史会话」；失败从
/// 一趟重列的中途开始时还会出现「就绪、一行都没有」（顶上只剩跑着的会话）。现在三种都留着上一次列到的。
///
/// 会读你自己的记录，所以**默认跳过**，开关是 `UTERM_AGENT_HISTORY_LOCAL=1`（xcodebuild 传环境变量要加
/// `TEST_RUNNER_` 前缀）。**只读**；日志里只有条数，没有标题、路径或对话内容。
@MainActor
final class AgentHistoryTransientFailureLocalLiveTests: XCTestCase {
    /// 哪些请求要失败（测试里随时换）。
    private final class FailureSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var rule: (@Sendable (RemoteFileRequest) -> Bool)?
        func set(_ rule: (@Sendable (RemoteFileRequest) -> Bool)?) {
            lock.lock()
            self.rule = rule
            lock.unlock()
        }
        func fails(_ request: RemoteFileRequest) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return rule?(request) ?? false
        }
    }

    private var client: LocalShellAgentClient!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["UTERM_AGENT_HISTORY_LOCAL"] == "1" else {
            throw XCTSkip("没设 UTERM_AGENT_HISTORY_LOCAL=1，跳过读本机真实记录的测试")
        }
        client = LocalShellAgentClient()
        suite = "transient-live-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        client?.invalidate()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testBackgroundReloadKeepsTheListWhileRequestsFail() async throws {
        let base = RemoteMacFileProvider.localShellAgent(client: client)
        let failures = FailureSwitch()
        let provider = RemoteMacFileProvider(send: { request, body, timeout in
            if failures.fails(request) { throw RemoteFileError(.unreachable, "辅助程序断了一下（模拟）") }
            return try await base.perform(request, body: body, timeout: timeout)
        })
        let root = ClaudeProjectPath.projectsRoot(home: try await base.realPath("."))
        let modes: [(String, @Sendable (RemoteFileRequest) -> Bool)] = [
            ("projects-root", { $0.path == root }),
            ("claude-tree", { $0.path?.hasPrefix(root) ?? false }),
            ("everything", { _ in true }),
        ]
        for (label, rule) in modes {
            failures.set(nil)
            let history = AgentHistoryModel(source: AgentHistorySources.make(tools: AgentHistoryTool.allCases, provider: provider),
                                            preferredDirectory: nil, followsCurrentProject: false)
            await history.start()
            for _ in 0..<3000 where history.hasMore && history.visibleFiles.count < 24 {
                try await Task.sleep(for: .milliseconds(20))
            }
            let before = history.visibleFiles.map(\.path)
            guard !before.isEmpty else { throw XCTSkip("这台 Mac 上没有列得出来的记录") }

            failures.set(rule)
            await history.reload(showsLoading: false)
            for _ in 0..<300 where history.hasMore { try await Task.sleep(for: .milliseconds(20)) }
            let during = history.visibleFiles.map(\.path)
            print("[agent-history-transient] \(label): phase=\(history.phase) visible \(before.count) → \(during.count)")
            XCTAssertEqual(history.phase, .ready, label)
            XCTAssertTrue(Set(before).isSubset(of: Set(during)), "\(label)：失败的那一趟，原来显示着的行一行都不少")

            failures.set(nil)
            await history.reload(showsLoading: false)
            XCTAssertEqual(history.phase, .ready, label)
            XCTAssertTrue(history.toolFailures.isEmpty, label)
        }
    }
}
