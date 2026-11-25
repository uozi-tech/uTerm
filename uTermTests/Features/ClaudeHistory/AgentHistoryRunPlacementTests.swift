import XCTest
@testable import uTerm

/// 跑着的会话在侧栏里放哪（`AgentHistoryRunPlacement`，两端共用）：列表里有它那份记录的在那份记录平常的位置
///（置顶了在「置顶」，否则在它那一组），不另起一块、不重复；列表里没有记录的才在最顶上。状态变了不挪。
final class AgentHistoryRunPlacementTests: XCTestCase {
    private struct Run: Equatable {
        let id: String
        let path: String?
        var status: CodeRunStatus = .unreported
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
        AgentHistoryRunPlacement(runs: runs, path: \.path, groups: groups)
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
