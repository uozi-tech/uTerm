import XCTest
@testable import uTerm

/// 列历史会话的两种读法在**这台 Mac 的真实记录**上对一遍：原来的（列全部目录、一份份读头尾）与读索引的
/// （Codex 的 `state_*.sqlite`、Claude Code 的 `history.jsonl` 与按偏移增量读标题）。列出来的会话集合与每一行的标题
/// 要一模一样；另外打印两种读法的耗时与跑命令、列目录、读文件的次数。
///
/// 默认跳过，开关同 `AgentHistoryAllToolsLocalLiveTests`（`UTERM_AGENT_HISTORY_LOCAL=1`，xcodebuild 传
/// `TEST_RUNNER_UTERM_AGENT_HISTORY_LOCAL=1`）。**只读**；输出里只有条数、次数与耗时，没有标题、路径或对话内容。
@MainActor
final class AgentHistoryIndexLocalLiveTests: XCTestCase {
    private var client: LocalShellAgentClient!
    private var base: RemoteMacFileProvider!

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["UTERM_AGENT_HISTORY_LOCAL"] == "1" else {
            throw XCTSkip("没设 UTERM_AGENT_HISTORY_LOCAL=1，跳过读本机真实记录的测试")
        }
        client = LocalShellAgentClient()
        base = RemoteMacFileProvider.localShellAgent(client: client)
    }

    override func tearDown() async throws {
        client?.invalidate()
        try await super.tearDown()
    }

    /// 一趟列表：项目、会话、每一份的信息。
    private struct Pass {
        var files: [AgentHistorySessionFile] = []
        var metadata: [String: AgentHistorySessionMetadata] = [:]
        var listing: Duration = .zero
        var reading: Duration = .zero
        var counts = ""
    }

    /// 同列表：列项目 → 列全部会话 → 读每一份的信息（读过、文件没变的数据源自己缓存）。
    private func pass(_ source: any AgentHistorySource, counter: AgentHistoryCountingProvider) async throws -> Pass {
        await counter.reset()
        var result = Pass()
        var started = ContinuousClock.now
        let projects = try await source.projects()
        result.files = await source.listAllSessions(in: projects).files
        result.listing = ContinuousClock.now - started
        started = ContinuousClock.now
        for file in result.files {
            if let info = try? await source.metadata(for: file) { result.metadata[file.path] = info }
        }
        result.reading = ContinuousClock.now - started
        result.counts = await counter.summary
        return result
    }

    /// 两趟列出来的东西要一样：列表里会出的会话（路径、大小、修改时间），每一份的标题、目录、分支、最后活动时间。
    /// 不列的（桌面版之类）只数条数：Codex 的库里规整过工作目录（`/tmp` → `/private/tmp`），它们分到哪个项目可能不同，
    /// 反正不显示。
    private func compare(_ old: Pass, _ new: Pass, tool: AgentHistoryTool) {
        func listed(_ pass: Pass) -> [AgentHistorySessionFile] { pass.files.filter { pass.metadata[$0.path]?.isListed == true } }
        let oldKeys = Set(listed(old).map(\.cacheKey)), newKeys = Set(listed(new).map(\.cacheKey))
        XCTAssertEqual(oldKeys.subtracting(newKeys).count, 0, "\(tool.rawValue)：新读法少了 \(oldKeys.subtracting(newKeys).count) 份")
        XCTAssertEqual(newKeys.subtracting(oldKeys).count, 0, "\(tool.rawValue)：新读法多了 \(newKeys.subtracting(oldKeys).count) 份")
        var differing: [String: Int] = [:]
        for file in listed(old) {
            guard let a = old.metadata[file.path], let b = new.metadata[file.path] else {
                differing["missing", default: 0] += 1
                continue
            }
            if a.title != b.title { differing["title", default: 0] += 1 }
            if a.resumeDirectory != b.resumeDirectory { differing["resumeDirectory", default: 0] += 1 }
            if a.lastDirectory != b.lastDirectory { differing["lastDirectory", default: 0] += 1 }
            if a.gitBranch != b.gitBranch { differing["gitBranch", default: 0] += 1 }
            if a.continuedIn != b.continuedIn { differing["continuedIn", default: 0] += 1 }
            if a.lastActivity != b.lastActivity { differing["lastActivity", default: 0] += 1 }
        }
        XCTAssertTrue(differing.isEmpty, "\(tool.rawValue)：两种读法的信息不同 \(differing.sorted { $0.key < $1.key })")
        print("""
            [history-index-live] \(tool.rawValue): sessions old=\(old.files.count) new=\(new.files.count) \
            listed old=\(oldKeys.count) new=\(newKeys.count) differing=\(differing.count)
            """)
    }

    private func report(_ label: String, _ pass: Pass) {
        print("[history-index-live] \(label): list \(pass.listing), metadata \(pass.reading); \(pass.counts)")
    }

    func testClaudeIndexMatchesFullScan() async throws {
        try await compareTool(.claude) { provider, indexed in
            ClaudeHistorySource(provider: provider, readsIndex: indexed)
        }
    }

    func testCodexIndexMatchesFullScan() async throws {
        try await compareTool(.codex) { provider, indexed in
            CodexHistorySource(provider: provider, readsIndex: indexed)
        }
    }

    /// 旧读法冷启动 + 重列一次；新读法冷启动 + 重列一次；两边的结果逐条对。
    private func compareTool(_ tool: AgentHistoryTool,
                             make: (any SFTPProviding, Bool) -> any AgentHistorySource) async throws {
        let oldCounter = AgentHistoryCountingProvider(base: base)
        let old = make(oldCounter, false)
        let oldCold = try await pass(old, counter: oldCounter)
        let oldWarm = try await pass(old, counter: oldCounter)
        report("\(tool.rawValue) old cold", oldCold)
        report("\(tool.rawValue) old relist", oldWarm)

        let newCounter = AgentHistoryCountingProvider(base: base)
        let new = make(newCounter, true)
        let newCold = try await pass(new, counter: newCounter)
        let newWarm = try await pass(new, counter: newCounter)
        report("\(tool.rawValue) new cold", newCold)
        report("\(tool.rawValue) new relist", newWarm)

        // 几趟是先后读的，中间可能有正在写的会话变了（大小、修改时间不同、新出现的）：这几份不算。
        let passes = [oldCold, oldWarm, newCold, newWarm]
        var changed: Set<String> = []
        for (a, b) in zip(passes, passes.dropFirst()) {
            changed.formUnion(Set(a.files.map(\.path)).symmetricDifference(Set(b.files.map(\.path))))
            changed.formUnion(Set(a.files.map(\.cacheKey)).symmetricDifference(Set(b.files.map(\.cacheKey))).map(\.path))
        }
        func stable(_ pass: Pass) -> Pass {
            var pass = pass
            pass.files.removeAll { changed.contains($0.path) }
            return pass
        }
        print("[history-index-live] \(tool.rawValue): changed while comparing=\(changed.count)")
        XCTAssertLessThan(changed.count, 10, "两趟之间变了太多份，比不出来")
        compare(stable(oldWarm), stable(newCold), tool: tool)
        compare(stable(newCold), stable(newWarm), tool: tool)
    }
}
