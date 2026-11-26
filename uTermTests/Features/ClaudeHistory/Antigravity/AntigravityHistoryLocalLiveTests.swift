import XCTest
@testable import uTerm

/// Antigravity 历史会话在**这台 Mac 的真实记录**上跑一遍（`~/.gemini/antigravity`、`~/.gemini/antigravity-cli`），
/// 读法同 App：经包内不带沙盒的辅助程序 `uTermShellAgent.xpc`。
///
/// 会读你自己的记录，所以**默认跳过**，开关是 `UTERM_ANTIGRAVITY_HISTORY_LOCAL=1`（xcodebuild 传环境变量要加
/// `TEST_RUNNER_` 前缀）。**只读**，不启动 Antigravity；日志与失败信息里只有条数、字节数和耗时，没有标题、路径或对话内容。
@MainActor
final class AntigravityHistoryLocalLiveTests: XCTestCase {
    private var client: LocalShellAgentClient!
    private var provider: RemoteMacFileProvider!

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["UTERM_ANTIGRAVITY_HISTORY_LOCAL"] == "1" else {
            throw XCTSkip("没设 UTERM_ANTIGRAVITY_HISTORY_LOCAL=1，跳过读本机真实记录的测试")
        }
        client = LocalShellAgentClient()
        provider = RemoteMacFileProvider.localShellAgent(client: client)
    }

    override func tearDown() async throws {
        client?.invalidate()
        try await super.tearDown()
    }

    private func loadedProjects(_ source: AntigravityHistorySource) async throws -> [AgentHistoryProject] {
        let projects = try await source.projects()
        guard !projects.isEmpty else { throw XCTSkip("这台 Mac 上没有 Antigravity 的记录") }
        return projects
    }

    func testReadsRealRecords() async throws {
        let source = AntigravityHistorySource(provider: provider)
        var started = ContinuousClock.now
        let projects = try await loadedProjects(source)
        let listProjects = ContinuousClock.now - started

        started = ContinuousClock.now
        let all = await source.allSessions(in: projects)
        let listSessions = ContinuousClock.now - started
        XCTAssertFalse(all.isEmpty, "有会话目录却一份记录都没列出来")
        XCTAssertEqual(all.map(\.modifiedAt), all.map(\.modifiedAt).sorted(by: >), "新的在前")
        let full = all.filter { $0.path.hasSuffix("/transcript_full.jsonl") }.count

        started = ContinuousClock.now
        var listed = 0, hidden = 0, untitled = 0, failed = 0
        for file in all {
            guard let info = try? await source.metadata(for: file) else {
                failed += 1
                continue
            }
            if info.isListed { listed += 1 } else { hidden += 1 }
            if info.title == nil { untitled += 1 }
        }
        let readMetadata = ContinuousClock.now - started
        XCTAssertEqual(failed, 0)
        print("""
            [antigravity-history-local] projects=\(projects.count) in \(listProjects), sessions=\(all.count) \
            (full=\(full)) in \(listSessions), bytes=\(all.map(\.size).reduce(0, +)), metadata in \(readMetadata): \
            listed=\(listed) hidden=\(hidden) untitled=\(untitled)
            """)

        started = ContinuousClock.now
        for file in all { _ = try? await source.metadata(for: file) }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "第二遍读标题没走缓存")
    }

    /// 每份记录从末尾读完整份：条目 ID 不重复，调用都挂上了结果（统计没挂上的有几个）。
    func testOpensRealTranscripts() async throws {
        let source = AntigravityHistorySource(provider: provider)
        let all = await source.allSessions(in: try await loadedProjects(source))
        for file in all {
            let pager = source.transcript(for: file)
            let started = ContinuousClock.now
            var items: [AgentTranscriptItem] = []
            var reachedStart = false
            var pages = 0
            var firstPage = Duration.zero
            while !reachedStart, pages < 400 {
                let page = try await pager.loadPrevious()
                if pages == 0 { firstPage = ContinuousClock.now - started }
                items = page.items + items
                reachedStart = page.reachedStart
                pages += 1
            }
            XCTAssertTrue(reachedStart)
            XCTAssertLessThan(firstPage, .seconds(3), "\(file.size) 字节的记录第一页用了 \(firstPage)")
            XCTAssertEqual(Set(items.map(\.id)).count, items.count, "条目的 ID 有重复")
            let assembled = AgentTranscriptAssembler.attachResults(items)
            var counts: [String: Int] = [:]
            for item in assembled {
                let key: String
                switch item.kind {
                case .userText: key = "user"
                case .assistantText: key = "answer"
                case .thinking: key = "thinking"
                case .toolCall(let call): key = call.result == nil ? "call-open" : "call"
                case .toolResult: key = "orphan-result"
                case .notice: key = "notice"
                case .compactSummary: key = "compact"
                case .oversized: key = "oversized"
                case .image: key = "image"
                case .command, .commandOutput: key = "command"
                case .usage: key = "usage"
                }
                counts[key, default: 0] += 1
            }
            let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print("[antigravity-history-local] transcript bytes=\(file.size) pages=\(pages) items=\(assembled.count) \(summary) in \(ContinuousClock.now - started)")
        }
    }

    /// 在真实记录上搜一个常见的英文词：跑得通、命中的行打开后能对上。只打印条数与耗时。
    func testSearchesRealRecords() async throws {
        let source = AntigravityHistorySource(provider: provider)
        let all = await source.allSessions(in: try await loadedProjects(source))
        let query = try AgentHistorySearchQuery.validate("the").get()
        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var sessions: [AgentHistorySearchSession] = []
        }
        let sink = Sink()
        let started = ContinuousClock.now
        try await source.search(query, in: all, limits: .standard) { event in
            if case .session(let session) = event { sink.lock.withLock { sink.sessions.append(session) } }
        }
        let elapsed = ContinuousClock.now - started
        let sessions = sink.lock.withLock { sink.sessions }
        let hits = sessions.flatMap(\.hits).count
        print("[antigravity-history-local] search: sessions=\(sessions.count) hits=\(hits) of \(all.count) records in \(elapsed)")
        if let session = sessions.first, let hit = session.hits.first {
            let page = try await source.transcript(for: session.file, around: hit.anchor).loadPrevious()
            XCTAssertTrue(page.items.contains { $0.id == hit.itemID }, "从命中处打开，第一页里没有那一条")
        }
    }
}
