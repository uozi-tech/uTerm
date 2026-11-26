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

    private func order(_ groups: [AgentHistoryGroup], runs: [Run], host: [String: CodeRunStatus]) -> [[String]] {
        let placement = AgentHistoryRunPlacement(runs: runs, path: \.path, directory: { _ in "/srv/none" },
                                                 tool: { _ in .claude }, groups: groups)
        return AgentHistoryListing.prioritizingRuns(groups, placement: placement, status: \.status, host: { host[$0] })
            .map { [$0.id] + $0.files.map(\.sessionID) }
    }

    func testSessionsRunningElsewhereComeFirst() {
        let shop = group("shop", [file("s1", "shop"), file("s2", "shop")])
        let infra = group("infra", [file("i1", "infra"), file("i2", "infra")])
        let host = [file("i2", "infra").path: Self.working]
        XCTAssertEqual(order([shop, infra], runs: [], host: host), [["infra", "i2", "i1"], ["shop", "s1", "s2"]],
                       "在别处开的会话：它那一组、它那一行排前面")
    }

    /// 同一台主机：手机和电脑读到的是同一张活会话表，各自的 Code 标签页里开着不同的会话（状态是 Claude Code 还没报、
    /// 或者报的和主机上一样），排出来一样。
    func testBothDevicesOrderTheSameGivenTheSameHostTable() {
        let files = (1...5).map { file("u\($0)", "uterm") }
        let groups = [group("blog", [file("b1", "blog"), file("b2", "blog")]), group("uterm", files)]
        let host = [files[1].path: Self.idle, files[3].path: Self.working, files[4].path: Self.waiting,
                    file("b2", "blog").path: Self.idle]
        // 电脑：Code 标签页里开着 u2（还没报状态）、u4（报了在干活）；手机：开着 u5（报了等确认）和一个已结束的 b1。
        let mac = order(groups, runs: [Run(path: files[1].path, status: .unreported), Run(path: files[3].path, status: Self.working)],
                        host: host)
        let phone = order(groups, runs: [Run(path: files[4].path, status: Self.waiting),
                                         Run(path: file("b1", "blog").path, status: .ended)], host: host)
        let neither = order(groups, runs: [], host: host)
        XCTAssertEqual(mac, neither)
        XCTAssertEqual(phone, neither)
        XCTAssertEqual(neither, [["uterm", "u5", "u4", "u2", "u1", "u3"], ["blog", "b2", "b1"]],
                       "等人处理 > 运行中 > 停在输入框；没在跑的照原来的先后")
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
