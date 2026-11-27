import Foundation
import XCTest
@testable import uTerm

/// 侧栏的「在跑」两路合起来：本设备 Code 标签页里开的（OSC 7501 报状态）+ 主机上正在运行的（`AgentHistorySource.liveSessions`，
/// 在普通终端、iTerm、另一台设备开的也在里面）。
///
/// 用户报的：手机和电脑侧栏排序不一致（各自只把自己开的当在跑、排前面）；在别处开的 Claude Code 显示成没在跑；
/// 还没上报状态时也显示不出在跑。
@MainActor
final class AgentHistoryLiveRunsTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session

    private static let working = CodeRunStatus.program(ProgramStatusRecord(state: .working, app: "claude-code"))
    private static let idle = CodeRunStatus.program(ProgramStatusRecord(state: .idle, app: "claude-code"))
    private static let waiting = CodeRunStatus.program(ProgramStatusRecord(state: .blocked, kind: .permission,
                                                                           app: "claude-code"))

    override func setUp() async throws {
        try await super.setUp()
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        AgentHistoryListCache.shared.removeAll()
        try await super.tearDown()
    }

    // MARK: 合并规则

    func testMergeTakesTheMoreUrgentAndPrefersLocalOnATie() {
        XCTAssertEqual(CodeRunStatus.merging(nil, host: nil), .unreported, "两路都没有：没在跑")
        XCTAssertEqual(CodeRunStatus.merging(nil, host: Self.working), Self.working, "只在主机上跑着（别处开的）")
        XCTAssertEqual(CodeRunStatus.merging(Self.waiting, host: nil), Self.waiting)
        XCTAssertEqual(CodeRunStatus.merging(.unreported, host: Self.working), Self.working,
                       "Code 标签页里还没报状态、主机上已经在干活：运行中")
        XCTAssertEqual(CodeRunStatus.merging(Self.waiting, host: Self.working), Self.waiting, "等人处理更要紧")
        XCTAssertEqual(CodeRunStatus.merging(.ended, host: Self.idle), Self.idle, "本设备的画面结束了，主机上还在跑")
        let local = CodeRunStatus.program(ProgramStatusRecord(state: .working, app: "claude-code", message: "编译中"))
        XCTAssertEqual(CodeRunStatus.merging(local, host: Self.working), local, "一样要紧用本设备的（带着消息）")
        XCTAssertEqual(CodeRunStatus.merging(.unreported, host: Self.idle), Self.idle)

        XCTAssertEqual(CodeRunStatus.listRank(local: nil, host: nil), 0)
        XCTAssertEqual(CodeRunStatus.listRank(local: nil, host: Self.idle), 1, "主机上停在输入框的也算在跑")
        XCTAssertEqual(CodeRunStatus.listRank(local: .ended, host: Self.working), 3)
        XCTAssertEqual(CodeRunStatus.listRank(local: nil, host: AgentLiveSession(
            tool: .claude, sessionID: "a", pid: 1, directory: nil, state: .waiting).runStatus), 4)
    }

    func testRowMarksFollowTheHostStatus() {
        func mark(_ state: AgentLiveSession.State) -> AgentHistoryRunIndicator {
            AgentHistoryRunIndicator(AgentLiveSession(tool: .claude, sessionID: "a", pid: 1, directory: nil, state: state).runStatus)
        }
        XCTAssertEqual(mark(.working), .working, "busy：灰色呼吸灯")
        XCTAssertEqual(mark(.idle), .none, "空闲不标")
        guard case .needsInput = mark(.waiting) else { return XCTFail("等人处理：黄点") }
        XCTAssertEqual(mark(.unknown), .none)
    }

    // MARK: 对到记录上

    private func file(_ id: String, _ project: String, tool: AgentHistoryTool = .claude) -> AgentHistorySessionFile {
        let p = AgentHistoryProject(id: project, path: "/r/\(project)", modifiedAt: nil, directory: "/srv/\(project)", tool: tool)
        return AgentHistorySessionFile(sessionID: id, project: p, path: "/r/\(tool.rawValue)/\(project)/\(id).jsonl",
                                       size: 1, modifiedAt: Date())
    }

    private func live(_ id: String, _ state: AgentLiveSession.State, tool: AgentHistoryTool = .claude) -> AgentLiveSession {
        AgentLiveSession(tool: tool, sessionID: id, pid: 1, directory: nil, state: state)
    }

    func testLiveSessionsMapToTheirRecordsAndContinuations() {
        let old = file("old", "shop"), new = file("new", "shop"), other = file("x", "shop")
        let codex = file("x", "shop", tool: .codex)
        let metadata = ["\(old.path)": AgentHistorySessionMetadata(title: "t", isListed: true, continuedIn: "new"),
                        "\(new.path)": AgentHistorySessionMetadata(title: "t", isListed: true)]
        let statuses = AgentHistoryLiveRuns.statuses(
            [live("OLD", .working), live("x", .idle), live("gone", .working)],
            files: [old, new, other, codex], metadata: metadata)
        XCTAssertEqual(statuses[new.path], Self.working, "接着往下聊了的算到最新那一份上（列表里只出它）")
        XCTAssertNil(statuses[old.path])
        XCTAssertEqual(statuses[other.path], Self.idle)
        XCTAssertNil(statuses[codex.path], "别的工具同名的会话不算")
        XCTAssertEqual(statuses.count, 2, "列表里没有记录的不要")

        let both = AgentHistoryLiveRuns.statuses([live("old", .idle), live("new", .working)], files: [old, new],
                                                 metadata: metadata)
        XCTAssertEqual(both, [new.path: Self.working], "两个会话对到同一份记录：取更要紧的")
    }

    // MARK: 排序

    private struct Run {
        let path: String?
        var status: CodeRunStatus
    }

    private func group(_ id: String, _ files: [AgentHistorySessionFile]) -> AgentHistoryGroup {
        AgentHistoryGroup(id: id, kind: .project(directory: "/srv/\(id)", name: id), files: files)
    }

    func testCollapsedGroupMarkCountsSessionsRunningElsewhere() {
        let shop = group("shop", [file("s1", "shop"), file("s2", "shop"), file("s3", "shop")])
        let runs = [Run(path: file("s1", "shop").path, status: .unreported), Run(path: nil, status: Self.idle)]
        let placement = AgentHistoryRunPlacement(runs: runs, path: \.path, directory: { _ in "/srv/shop" },
                                                 tool: { _ in .claude }, groups: [shop])
        let host = [file("s1", "shop").path: Self.working, file("s3", "shop").path: Self.waiting]
        let statuses = placement.statuses(in: shop, status: \.status, host: { host[$0] })
        XCTAssertEqual(statuses, [Self.idle, Self.working, Self.waiting], "新会话、两路合起来的 s1、只在主机上跑的 s3")
        let mark = CodeRunGroupMark(statuses)
        XCTAssertEqual(mark?.running, 3)
        XCTAssertEqual(mark?.waitingRecord?.state, .blocked)
    }

    // MARK: 模型

    private func session(_ id: String, ago: TimeInterval) -> Session {
        Session(id: id, projectID: ClaudeProjectPath.encode("/srv/shop"), resumeDirectory: "/srv/shop", title: id,
                modifiedAt: Date().addingTimeInterval(-ago))
    }

    private func start(_ source: any AgentHistorySource) async -> AgentHistoryModel {
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(5)) }
        return history
    }

    /// 侧栏的先后：按模型给的最后活跃时间排好的会话 ID。
    private func order(_ history: AgentHistoryModel) -> [String] {
        AgentHistoryListing.orderedByActivity(history.visibleFiles, activity: history.lastActivity(of:)).map(\.sessionID)
    }

    /// 用户报的：一个运行中的会话跑完就直接掉到下面去了。要的是始终按最后活跃时间：在别处（或本设备）跑着、正在干活的
    /// 会话刚活跃过，排上去；跑完了停在原处，不跳。两台设备读的是同一张主机表，排出来一样。
    func testWorkingSessionRisesAndStaysAfterItFinishes() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", ago: 60), session("b", ago: 120),
                                                                        session("c", ago: 180)])
        let history = await start(source)
        XCTAssertEqual(order(history), ["a", "b", "c"], "都没在跑：按记录的修改时间")

        await source.setLiveSessions([source.liveSession("c", .working), source.liveSession("b", .idle)])
        let started = Date()
        await history.refreshLiveSessions(now: started)
        XCTAssertEqual(order(history), ["c", "a", "b"], "c 在干活：最后活跃就是这一刻，排最上面；停在输入框的 b 不挪")

        await source.setLiveSessions([source.liveSession("c", .idle), source.liveSession("b", .idle)])
        await history.refreshLiveSessions(now: started.addingTimeInterval(30))
        XCTAssertEqual(order(history), ["c", "a", "b"], "c 跑完了：停在最后一次看到它干活的位置，不掉下去")

        await source.setLiveSessions([])
        await history.refreshLiveSessions(now: started.addingTimeInterval(60))
        XCTAssertEqual(order(history), ["c", "a", "b"], "进程退出了也不动")

        await source.setLiveSessions([source.liveSession("b", .working)])
        await history.refreshLiveSessions(now: started.addingTimeInterval(90))
        XCTAssertEqual(order(history), ["b", "c", "a"], "b 又干起活来：它最新")
    }

    func testWaitingOrIdleSessionsDoNotJumpAhead() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", ago: 60), session("b", ago: 120)])
        let history = await start(source)
        await source.setLiveSessions([source.liveSession("b", .waiting)])
        await history.refreshLiveSessions(now: Date())
        XCTAssertEqual(order(history), ["a", "b"], "等人处理、停在输入框都不是新的活动，照最后活跃时间")
    }

    func testModelKeepsTheLastTableWhenAReadFails() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", ago: 60), session("b", ago: 120)])
        await source.setLiveSessions([source.liveSession("b", .working)])
        let history = await start(source)
        XCTAssertTrue(history.hostRunStatuses.isEmpty, "还没读过")

        let read = await history.refreshLiveSessions()
        XCTAssertTrue(read)
        let b = try XCTUnwrap(history.visibleFiles.first { $0.sessionID == "b" })
        XCTAssertEqual(history.hostRunStatuses, [b.path: Self.working])

        await source.setLiveError(URLError(.networkConnectionLost))
        let failed = await history.refreshLiveSessions()
        XCTAssertFalse(failed)
        XCTAssertEqual(history.hostRunStatuses, [b.path: Self.working], "读不到：留着上一次的，不清空")

        await source.setLiveError(nil)
        await source.setLiveSessions([])
        await history.refreshLiveSessions()
        XCTAssertTrue(history.hostRunStatuses.isEmpty, "读到了「没有在跑的」才清")
    }

    func testPollsOnlyWhileTheListIsVisible() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", ago: 60)])
        await source.setLiveSessions([source.liveSession("a", .idle)])
        let history = await start(source)
        history.liveTiming = AgentHistoryLiveTiming(interval: .milliseconds(10), maxBackoff: .milliseconds(40),
                                                    sleep: { try await Task.sleep(for: $0) })

        try await Task.sleep(for: .milliseconds(50))
        var reads = await source.liveReads
        XCTAssertEqual(reads, 0, "列表没露出来之前不读")

        history.setLiveSessionsVisible(true)
        for _ in 0..<200 where await source.liveReads < 3 { try await Task.sleep(for: .milliseconds(5)) }
        reads = await source.liveReads
        XCTAssertGreaterThanOrEqual(reads, 3, "露着时隔一会儿读一次")
        XCTAssertEqual(history.liveSessions.map(\.sessionID), ["a"])

        history.setLiveSessionsVisible(false)
        XCTAssertFalse(history.isPollingLiveSessions)
        try await Task.sleep(for: .milliseconds(30))
        let stopped = await source.liveReads
        try await Task.sleep(for: .milliseconds(60))
        reads = await source.liveReads
        XCTAssertEqual(reads, stopped, "不露（后台、切走了、窄屏被详情盖着）就不读")
    }

    func testDoesNotPollHostsThatCannotRunCommands() async {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", ago: 60)])
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, allowsSearch: false,
                                        followsCurrentProject: false)
        history.setLiveSessionsVisible(true)
        XCTAssertFalse(history.isPollingLiveSessions, "只许 SFTP 的主机跑不了命令")
    }

    func testCompositeSourceForwardsEveryTool() async throws {
        let claude = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", ago: 60)])
        let codex = AgentHistoryFakeSource(tool: .codex, sessions: [session("c", ago: 30)])
        await claude.setLiveSessions([claude.liveSession("a", .working)])
        let composite = AgentHistoryCompositeSource([claude, codex])
        let found = try await composite.liveSessions()
        XCTAssertEqual(found.map(\.sessionID), ["a"])

        await claude.setLiveError(URLError(.timedOut))
        do {
            _ = try await composite.liveSessions()
            XCTFail("有一种读不了就整个抛：模型留着上一次的")
        } catch {}
    }

    /// 真实的数据源里，Codex、Antigravity 不知道哪些在跑：默认的空表。
    func testToolsWithoutLiveSessionsReturnNothing() async throws {
        let provider = MockSFTP()
        let codex = CodexHistorySource(provider: provider, home: "/home/a")
        let found = try await codex.liveSessions()
        XCTAssertEqual(found, [])
    }
}
