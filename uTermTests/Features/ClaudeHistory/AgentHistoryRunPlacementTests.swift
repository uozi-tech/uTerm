import XCTest
@testable import uTerm

/// 跑着的会话在侧栏里放哪（`AgentHistoryRunPlacement`，两端共用）：列表里有它那份记录的在那份记录平常的位置
///（置顶了在「置顶」，否则在它那一组），不另起一块、不重复；列表里没有记录的才在最顶上。状态变了不挪。
final class AgentHistoryRunPlacementTests: XCTestCase {
    private struct Run: Equatable {
        let id: String
        let path: String?
        var status: CodeRunStatus = .unreported
        /// 在哪个目录里起的。默认是列表里没有的目录（放不进任何一组）。
        var directory = "/srv/elsewhere"
        var tool: AgentHistoryTool = .claude
    }

    private static let now = Date()

    private func file(_ id: String, in directory: String, ago seconds: TimeInterval) -> AgentHistorySessionFile {
        var project = AgentHistoryProject(id: ClaudeProjectPath.encode(directory), path: "/p" + directory,
                                          modifiedAt: nil)
        project.directory = directory
        return AgentHistorySessionFile(sessionID: id, project: project, path: "/p\(directory)/\(id).jsonl", size: 1,
                                       modifiedAt: Self.now.addingTimeInterval(-seconds))
    }

    /// shop 两个、infra 两个，shop 的新。
    private lazy var files = [
        file("s0", in: "/srv/shop", ago: 10), file("s1", in: "/srv/shop", ago: 20),
        file("i0", in: "/srv/infra", ago: 30), file("i1", in: "/srv/infra", ago: 40),
    ]

    private func path(_ id: String) -> String { files.first { $0.sessionID == id }!.path }

    private func groups(pinned: [String] = []) -> [AgentHistoryGroup] {
        AgentHistoryListing.groups(files, by: .project, metadata: [:],
                                   pinned: pinned.map { id in files.first { $0.sessionID == id }! })
    }

    private func place(_ runs: [Run], in groups: [AgentHistoryGroup]) -> AgentHistoryRunPlacement<Run> {
        AgentHistoryRunPlacement(runs: runs, path: \.path, directory: \.directory, tool: \.tool, groups: groups)
    }

    // MARK: 还没有记录行的会话放进它那一组

    /// 2026-11-26 实测：在 uTerm 目录里新开的会话，记录写出来之前单独摆在侧栏最顶上，看着不属于任何项目。
    /// 按项目分组时它在自己目录那一组的最上面（组里原来的行不动），收起的组标题上的点也算它。
    func testNewRunSitsAtTheTopOfItsProjectGroup() {
        let groups = groups()
        let fresh = Run(id: "new", path: nil, directory: "/srv/infra")
        let listed = Run(id: "listed", path: path("i1"))
        let placement = place([fresh, listed], in: groups)
        XCTAssertTrue(placement.top.isEmpty, "不在列表最顶上")
        let infra = groups.first { $0.id == "project:/srv/infra" }!
        XCTAssertEqual(placement.leading(in: infra), [fresh], "在它目录那一组的最上面")
        XCTAssertEqual(placement.runs(in: infra), [fresh, listed], "组标题上的点：组里最上面的那个在前")
        XCTAssertEqual(placement.leading(in: groups.first { $0.id == "project:/srv/shop" }!), [], "别的组没有它")
        XCTAssertEqual(placement.groupID(ofLeading: { $0.id == "new" }), "project:/srv/infra")
        // 目录写法不规整（结尾斜杠、`.`）也认。
        let messy = place([Run(id: "m", path: nil, directory: "/srv/./infra/")], in: groups)
        XCTAssertEqual(messy.leading(in: infra).map(\.id), ["m"])
    }

    /// 对不上的留在最顶上：列表里还没有的目录；上级目录那一组也不进（记录写出来后会单独成组，行会跳走）；
    /// 置顶、没有目录的那几组不进。
    func testNewRunWithoutAMatchingGroupStaysOnTop() {
        let groups = groups(pinned: ["s0"])
        for directory in ["/srv/elsewhere", "/srv/infra/sub", "/srv"] {
            let placement = place([Run(id: "new", path: nil, directory: directory)], in: groups)
            XCTAssertEqual(placement.top.map(\.id), ["new"], directory)
            XCTAssertTrue(placement.leading.isEmpty, directory)
        }
    }

    /// Claude Code 没对上真实目录的那种组（标题是记录目录的名字）：按目录名换算对上，只认 Claude Code 的会话。
    func testNewRunMatchesAnUnresolvedClaudeGroupByEncodedName() {
        var project = AgentHistoryProject(id: ClaudeProjectPath.encode("/srv/legacy"), path: "/p/legacy", modifiedAt: nil)
        project.tool = .claude
        let record = AgentHistorySessionFile(sessionID: "l0", project: project, path: "/p/legacy/l0.jsonl", size: 1,
                                             modifiedAt: Self.now)
        let groups = AgentHistoryListing.groups([record], by: .project, metadata: [:])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(place([Run(id: "c", path: nil, directory: "/srv/legacy")], in: groups).leading(in: groups[0]).map(\.id),
                       ["c"])
        XCTAssertEqual(place([Run(id: "x", path: nil, directory: "/srv/legacy", tool: .codex)], in: groups).top.map(\.id),
                       ["x"], "别的工具的会话不按 Claude Code 的目录名换算")
    }

    /// 按日期分组在「今天」那组，按工具分组在它的工具那组，不分组就是那一组；对应的组不存在时在最顶上。
    func testNewRunFollowsOtherGroupings() {
        let fresh = Run(id: "new", path: nil, directory: "/srv/infra")
        let byDate = AgentHistoryListing.groups(files, by: .date, metadata: [:], now: Self.now)
        XCTAssertEqual(place([fresh], in: byDate).groupID(ofLeading: { $0.id == "new" }),
                       "date:\(AgentHistoryDateBucket.today.rawValue)")
        let old = AgentHistoryListing.groups(files, by: .date, metadata: [:], now: Self.now.addingTimeInterval(86_400 * 3))
        XCTAssertEqual(place([fresh], in: old).top.map(\.id), ["new"], "没有「今天」那组：在最顶上")

        let byTool = AgentHistoryListing.groups(files, by: .tool, metadata: [:])
        XCTAssertEqual(place([fresh], in: byTool).groupID(ofLeading: { $0.id == "new" }), "tool:claude")
        XCTAssertEqual(place([Run(id: "x", path: nil, tool: .codex)], in: byTool).top.map(\.id), ["x"],
                       "这台主机上还没有它那种工具的组：在最顶上")

        let flat = AgentHistoryListing.groups(files, by: .none, metadata: [:])
        XCTAssertEqual(place([fresh], in: flat).groupID(ofLeading: { $0.id == "new" }), "all")
    }

    /// 列表里有记录的：在它那一组那一行上，不在顶上；组里只出现一次、个数不变。
    func testListedRunStaysInItsGroup() {
        let groups = groups()
        let run = Run(id: "r", path: path("i1"))
        let placement = place([run], in: groups)
        XCTAssertTrue(placement.top.isEmpty, "不在顶上")
        XCTAssertEqual(placement.inList[path("i1")], run, "那一行画成跑着的样子")
        XCTAssertEqual(AgentHistoryListing.groupID(ofRecord: path("i1"), in: groups), "project:/srv/infra")
        XCTAssertEqual(groups.flatMap(\.files).filter { $0.path == path("i1") }.count, 1, "只出现一次")
        XCTAssertEqual(groups.map { $0.files.count }, [2, 2], "组里一个不少")
    }

    /// 列表里没有记录的：还没对上记录的新会话、对上了但没列出来的，放在顶上，按起来的先后。
    func testUnlistedRunsGoOnTop() {
        let fresh = Run(id: "new", path: nil)
        let hidden = Run(id: "hidden", path: "/p/srv/shop/filtered-out.jsonl")
        let listed = Run(id: "listed", path: path("s1"))
        let placement = place([fresh, listed, hidden], in: groups())
        XCTAssertEqual(placement.top, [fresh, hidden], "没有组可放的在顶上，先后不变")
        XCTAssertEqual(Array(placement.inList.values), [listed])
    }

    /// 置顶一个跑着的会话：它在「置顶」里（只在那里），不在顶上；取消置顶回到它那一组。
    func testPinningARunningSessionMovesItIntoPinnedAndBack() {
        let run = Run(id: "r", path: path("i1"), status: .program(ProgramStatusRecord(state: .idle, app: "claude-code")))
        let pinned = groups(pinned: ["i1"])
        let placement = place([run], in: pinned)
        XCTAssertTrue(placement.top.isEmpty, "置顶之后也不在顶上那一块")
        XCTAssertEqual(placement.inList[path("i1")], run)
        XCTAssertEqual(AgentHistoryListing.groupID(ofRecord: path("i1"), in: pinned), AgentHistoryGroup.pinnedID,
                       "在「置顶」里")
        XCTAssertEqual(pinned.flatMap(\.files).filter { $0.path == path("i1") }.count, 1, "原来那一组里不再出现")

        let unpinned = groups()
        let back = place([run], in: unpinned)
        XCTAssertTrue(back.top.isEmpty)
        XCTAssertEqual(AgentHistoryListing.groupID(ofRecord: path("i1"), in: unpinned), "project:/srv/infra",
                       "取消置顶回到它那一组")
    }

    /// 状态变了（运行中 → 空闲 → 已结束）不挪：位置只看有没有列出来的记录。
    func testStatusChangeDoesNotMoveTheRow() {
        let groups = groups()
        let statuses: [CodeRunStatus] = [
            .unreported, .program(ProgramStatusRecord(state: .working, app: "claude-code")),
            .program(ProgramStatusRecord(state: .idle, app: "claude-code")), .ended,
        ]
        for status in statuses {
            let run = Run(id: "r", path: path("s1"), status: status)
            let fresh = Run(id: "new", path: nil, status: status)
            let placement = place([fresh, run], in: groups)
            XCTAssertEqual(placement.top.map(\.id), ["new"], "\(status)")
            XCTAssertEqual(placement.inList[path("s1")]?.id, "r", "\(status)")
        }
    }

    /// 同一份记录有两个会话（不该有）：第二个放到顶上，不丢。
    func testSecondRunOnTheSameRecordIsNotDropped() {
        let first = Run(id: "a", path: path("s0")), second = Run(id: "b", path: path("s0"))
        let placement = place([first, second], in: groups())
        XCTAssertEqual(placement.inList[path("s0")], first)
        XCTAssertEqual(placement.top, [second])
    }
}
