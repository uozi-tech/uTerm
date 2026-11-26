import XCTest
@testable import uTerm

/// 读记录的通道一时不通（本机：辅助程序 `uTermShellAgent.xpc` 断了一下；SSH：断线）时，后台重列不能把侧栏清空。
///
/// 实测（2026-11-25，build 1500 / 1511）：Code 标签页里结束一个会话、或者「＋」新开一个会话之后，侧栏的分组、置顶全没了，
/// 只剩顶上跑着的那两行。复现（`AgentHistoryFailureLocalLiveTests` 那种探针，本机真实记录、四种工具）：后台重列时文件请求
/// 失败，四种数据源都把「列不出来、stat 也失败」当成「这台主机上没用过」，悄悄回空——
/// - 全部失败：项目一个都没有，列表换成「没有历史会话」；
/// - 有一种（Antigravity）在失败开始前列到了项目、之后的都失败：列表是「就绪」、一行记录都没有，顶上只剩跑着的会话；
/// - 只有 Claude Code 失败、别的工具照常：Claude Code 的会话与置顶全没了；它是抛错的话（`stat` 还通），上一次列到的
///   会话留着，可是四种工具都有记录时「显示」那一步又按「这一趟有记录的工具」把它们筛掉了。
///
/// 改法：「没用过」只认明确的「不存在」（`AgentHistoryMissingPath`），说不清的照常报错；一种工具这一趟列不出来，它仍算
/// 有记录的工具，留着的会话不被筛掉；Codex / Antigravity 列不出来的项目报出来，同 Claude Code。
@MainActor
final class AgentHistoryTransientFailureTests: XCTestCase {
    private static let home = "/home/user"
    private static let shop = "/home/user/shop"
    private static let blog = "/home/user/blog"
    // Claude Code 的会话 ID 是 UUID（继续会话的命令只认这种）。
    private static let running = "6d0608a6-76df-4181-a620-48e53965caba"
    private static let pinned = "3f2c8f87-b3ad-43be-bd14-6498e9b4b618"
    private static let draft = "0b0e5f3a-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
    private typealias Fake = AgentHistoryFakeSource.Session

    private final class FakeTerminal: CodeTabTerminal {
        let id = UUID()
        var codeCommandHasEnded = false
        func runCodeCommand(_ command: String) {}
        func dispose() {}
    }

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        suite = "transient-failure-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suite)
        AgentHistoryListCache.shared.removeAll()
        try await super.tearDown()
    }

    // MARK: 数据源：「没用过」只认明确的「不存在」

    private static func claudePath(_ directory: String, _ id: String) -> String {
        ClaudeProjectPath.projectsRoot(home: home) + "/" + ClaudeProjectPath.encode(directory) + "/\(id).jsonl"
    }

    private func putClaude(_ host: SQLiteTestHost, _ directory: String, _ id: String, title: String, ago seconds: TimeInterval) async {
        let data = ClaudeFixture.file([ClaudeFixture.userText("问一句", cwd: directory), ClaudeFixture.aiTitle(title)])
        await host.put(Self.claudePath(directory, id), data, mtime: Date().addingTimeInterval(-seconds))
    }

    func testClaudeReportsAnUnreachableRootInsteadOfNoHistory() async throws {
        let host = SQLiteTestHost(home: Self.home)
        await putClaude(host, Self.shop, "a", title: "登录接口", ago: 60)
        let source = ClaudeHistorySource(provider: host, home: Self.home)
        await host.setUnreachable([Self.home])
        do {
            let projects = try await source.projects()
            XCTFail("辅助程序连不上不是「没用过」：应当报错，实际回了 \(projects.count) 个项目")
        } catch {}
        await host.setUnreachable([])
        let projects = try await source.projects()
        XCTAssertEqual(projects.count, 1)

        let fresh = ClaudeHistorySource(provider: SQLiteTestHost(home: Self.home), home: Self.home)
        let none = try await fresh.projects()
        XCTAssertEqual(none, [], "确实没有 ~/.claude/projects：没用过")
    }

    /// 另外两种工具同一条规矩：整个主目录一时连不上时报错；什么都没有的主机上回空。
    func testOtherToolsReportAnUnreachableHomeInsteadOfNoHistory() async throws {
        for tool in [AgentHistoryTool.codex, .antigravity] {
            let host = SQLiteTestHost(home: Self.home)
            let source = try XCTUnwrap(AgentHistorySources.make(tool, provider: host, home: Self.home))
            let none = try await source.projects()
            XCTAssertEqual(none, [], "\(tool.rawValue)：什么都没有的主机上没用过")
            await host.setUnreachable([Self.home])
            do {
                let projects = try await source.projects()
                XCTFail("\(tool.rawValue)：连不上不是「没用过」，实际回了 \(projects.count) 个项目")
            } catch {}
        }
    }

    /// Codex 的记录按日期分目录：某一天的目录一时列不出来，不能当成那天没有记录（会话从侧栏上消失），整趟照常报错；
    /// 那个目录确实不在了（刚被删）的照常跳过。
    func testCodexDoesNotSilentlyDropADayItCouldNotList() async throws {
        typealias F = CodexFixture
        let other = "019a0000-2222-7333-8444-555566667777"
        let date = Date(timeIntervalSince1970: 5_000)
        func host() async -> MockSFTP {
            await F.host([(F.path(id: F.threadID), F.session(), date),
                          (F.path(id: other, day: "19"), F.session(id: other, prompt: "第二个会话"), date)])
        }
        let flaky = await host()
        await flaky.setListError(RemoteFileError(.unreachable, "辅助程序断了一下"), at: "\(F.root)/2026/11/19")
        do {
            let projects = try await CodexHistorySource(provider: flaky).projects()
            XCTFail("少列了一天不能当成那天没有记录，实际回了 \(projects.count) 个项目")
        } catch {}

        let deleted = await host()
        await deleted.setListError(RemoteFileError(.notFound, "不存在"), at: "\(F.root)/2026/11/19")
        let source = CodexHistorySource(provider: deleted)
        let projects = try await source.projects()
        let sessions = await source.allSessions(in: projects)
        XCTAssertEqual(sessions.map(\.sessionID), [F.threadID], "刚被删的那天跳过")
    }

    // MARK: 模型：后台重列时一种工具列不出来

    private func fake(_ tool: AgentHistoryTool, _ id: String, ago seconds: TimeInterval) -> AgentHistoryFakeSource {
        AgentHistoryFakeSource(tool: tool, sessions: [
            Fake(id: id, projectID: "\(tool.rawValue)-blog", projectDirectory: Self.blog, resumeDirectory: Self.blog,
                 title: "\(tool.rawValue) 的会话", modifiedAt: Date().addingTimeInterval(-seconds)),
        ])
    }

    private func settle(_ history: AgentHistoryModel) async {
        for _ in 0..<400 where history.hasMore || history.isListing {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 四种工具都有记录（同实测的那台 Mac）：Claude Code 这一趟连项目都列不出来（抛错），它上一次列到的会话和置顶
    /// 都留在侧栏上，不被「显示」那一步按「这一趟有记录的工具」筛掉。以前只有两种工具的用例覆盖了「留着」，
    /// 剩一种时不筛，看不出来。
    func testBackgroundReloadKeepsAToolThatFailedWhenSeveralToolsAreShown() async throws {
        let claude = AgentHistoryFakeSource(tool: .claude, sessions: [
            Fake(id: "c1", projectID: ClaudeProjectPath.encode(Self.shop), resumeDirectory: Self.shop, title: "登录接口",
                 modifiedAt: Date().addingTimeInterval(-60)),
            Fake(id: "c2", projectID: ClaudeProjectPath.encode(Self.shop), resumeDirectory: Self.shop, title: "支付回调",
                 modifiedAt: Date().addingTimeInterval(-120)),
        ])
        let source = AgentHistoryCompositeSource([claude, fake(.codex, "x1", ago: 600), fake(.antigravity, "g1", ago: 1200)])
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        history.pins = AgentHistoryPins(host: .local, defaults: defaults)
        await history.start()
        await settle(history)
        history.pins?.toggle(try XCTUnwrap(history.files.first { $0.sessionID == "c2" }))
        await settle(history)
        let before = history.visibleFiles.map(\.sessionID)
        XCTAssertEqual(before, ["c1", "c2", "x1", "g1"])
        XCTAssertEqual(history.pinnedFiles.map(\.sessionID), ["c2"])

        await claude.setProjectsError(AgentHistoryFakeError.offline)
        await history.reload(showsLoading: false)
        await settle(history)
        XCTAssertNotNil(history.toolFailures[.claude])
        XCTAssertEqual(history.visibleFiles.map(\.sessionID), before, "列不出来的那种工具的会话留着，不被筛掉")
        XCTAssertEqual(history.pinnedFiles.map(\.sessionID), ["c2"], "置顶也还在")
        XCTAssertTrue(history.availableTools.contains(.claude))

        await claude.setProjectsError(nil)
        await history.reload(showsLoading: false)
        await settle(history)
        XCTAssertNil(history.toolFailures[.claude])
        XCTAssertEqual(history.visibleFiles.map(\.sessionID), before)
    }

    // MARK: Code 标签页：用户报的那一幕

    /// Code 标签页里一个会话在跑，「＋」新开一个会话；新会话还没对上记录，标签页每隔一会儿整个重列一次，正赶上
    /// 辅助程序一时连不上：侧栏的分组与置顶都留着，不是只剩顶上跑着的两行。连上之后照常。
    /// Claude Code 走真的数据源（读内存里的假主机），另外两种工具是假的、照常。
    func testStartingANewSessionWhileTheHelperHiccupsKeepsTheSidebar() async throws {
        let host = SQLiteTestHost(home: Self.home)
        await putClaude(host, Self.shop, Self.running, title: "Code 视图侧边栏与 Desktop 差异", ago: 30)
        await putClaude(host, Self.shop, Self.pinned, title: "支付回调", ago: 4000)
        await putClaude(host, Self.blog, Self.draft, title: "写一篇博客", ago: 8000)
        let source = AgentHistoryCompositeSource([ClaudeHistorySource(provider: host, home: Self.home),
                                                  fake(.codex, "x1", ago: 600), fake(.antigravity, "g1", ago: 1200)])
        let history = AgentHistoryModel(source: source, preferredDirectory: Self.shop, followsCurrentProject: false)
        history.pins = AgentHistoryPins(host: .local, defaults: defaults)
        await history.start()
        await settle(history)
        history.pins?.toggle(try XCTUnwrap(history.files.first { $0.sessionID == Self.pinned }))
        await settle(history)

        let code = CodeTabModel(hostName: "Mac", directory: Self.shop) { _ in FakeTerminal() }
        code.timing = .init(check: .milliseconds(20), refresh: .milliseconds(60))
        defer { code.close() }
        code.install(AgentHistoryConnection(history: history))
        _ = try XCTUnwrap(code.resume(try XCTUnwrap(history.files.first { $0.sessionID == Self.running })))
        let listed = Set(history.visibleFiles.map(\.sessionID))
        XCTAssertEqual(listed, [Self.running, Self.pinned, Self.draft, "x1", "g1"])

        // 辅助程序断了一下的时候点了「＋」→ 开始：新会话还没对上记录，标签页整个重列。
        await host.setUnreachable([Self.home])
        code.showNewSessionPage()
        code.chooseNewSessionDirectory(Self.blog)
        _ = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: Self.blog))
        await code.refreshList()
        await settle(history)
        XCTAssertNotNil(history.toolFailures[.claude], "这一趟 Claude Code 的记录列不出来：报错，不当成没用过")
        XCTAssertEqual(history.phase, .ready)
        XCTAssertEqual(Set(history.visibleFiles.map(\.sessionID)), listed, "分组里的会话都还在")
        XCTAssertEqual(history.pinnedFiles.map(\.sessionID), [Self.pinned], "置顶还在")
        XCTAssertEqual(code.runs.count, 2)

        // 连上了：照常。
        await host.setUnreachable([])
        await code.refreshList()
        await settle(history)
        XCTAssertNil(history.toolFailures[.claude])
        XCTAssertEqual(Set(history.visibleFiles.map(\.sessionID)), listed)
        XCTAssertEqual(history.pinnedFiles.map(\.sessionID), [Self.pinned])
    }
}
