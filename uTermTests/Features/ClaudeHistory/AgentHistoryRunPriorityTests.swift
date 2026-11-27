import Foundation
import XCTest
@testable import uTerm

/// 侧栏的先后（用户要的，2026-11-27 起）：一律按最后活跃时间，新的在前，不按在不在跑另排。在干活的会话刚活跃过，
/// 自然在上面；跑完了停在原处（之前是跑着的挪到组的最前面，一跑完就掉下去）。只有还没对上记录行的新会话所在的组
/// 排在前面；「置顶」一组照旧在最上面、组里照用户排的顺序不动。最后活跃时间怎么来见 `AgentHistoryLiveRunsTests`。
final class AgentHistoryRunPriorityTests: XCTestCase {
    private struct Run {
        let path: String?
        var status: CodeRunStatus = .program(ProgramStatusRecord(state: .working, app: "claude-code"))
    }

    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func file(_ id: String, _ project: String, ago: TimeInterval = 0) -> AgentHistorySessionFile {
        let p = AgentHistoryProject(id: project, path: "/r/\(project)", modifiedAt: nil, directory: "/srv/\(project)")
        return AgentHistorySessionFile(sessionID: id, project: p, path: "/r/\(project)/\(id).jsonl", size: 1,
                                       modifiedAt: Self.base.addingTimeInterval(-ago))
    }

    private func group(_ id: String, _ files: [AgentHistorySessionFile]) -> AgentHistoryGroup {
        AgentHistoryGroup(id: id, kind: .project(directory: "/srv/\(id)", name: id), files: files)
    }

    func testOrdersByLastActivityAndKeepsTiesInPlace() {
        let files = [file("a", "shop", ago: 300), file("b", "shop", ago: 100), file("c", "shop", ago: 100),
                     file("d", "shop", ago: 200)]
        // c 看过、读到的比修改时间新。
        let seen = [files[2].path: Self.base.addingTimeInterval(10)]
        let ordered = AgentHistoryListing.orderedByActivity(files) { seen[$0.path] ?? $0.modifiedAt }
        XCTAssertEqual(ordered.map(\.sessionID), ["c", "b", "d", "a"], "新的在前；同一刻的照原来的先后")
        let tied = AgentHistoryListing.orderedByActivity([files[1], files[2]], activity: \.modifiedAt)
        XCTAssertEqual(tied.map(\.sessionID), ["b", "c"], "同一刻的不换位置")
    }

    /// 先按最后活跃时间排再分组：按项目分组时，组按组里最新的那一行排，组里的行也按时间。
    func testGroupsFollowTheActivityOrder() {
        let files = [file("s1", "shop", ago: 50), file("i1", "infra", ago: 100), file("s2", "shop", ago: 300),
                     file("i2", "infra", ago: 10)]
        let ordered = AgentHistoryListing.orderedByActivity(files, activity: \.modifiedAt)
        let groups = AgentHistoryListing.groups(ordered, by: .project, metadata: [:])
        XCTAssertEqual(groups.map { [$0.id] + $0.files.map(\.sessionID) },
                       [["project:/srv/infra", "i2", "i1"], ["project:/srv/shop", "s1", "s2"]])
    }

    /// 跑着的会话（不管在干活、等人还是空闲）不另排：行、组都照最后活跃时间，不挪。
    func testRunningRowsAreNotMoved() {
        let pinned = AgentHistoryGroup(id: AgentHistoryGroup.pinnedID, kind: .pinned,
                                       files: [file("p1", "shop"), file("p2", "shop")])
        let shop = group("shop", [file("s1", "shop"), file("s2", "shop"), file("s3", "shop")])
        let infra = group("infra", [file("i1", "infra"), file("i2", "infra")])
        let groups = [pinned, shop, infra]
        let runs = [Run(path: file("i2", "infra").path), Run(path: file("p2", "shop").path),
                    Run(path: file("s3", "shop").path, status: .program(ProgramStatusRecord(state: .blocked, kind: .permission)))]
        let placement = AgentHistoryRunPlacement(runs: runs, path: \.path, directory: { _ in "/srv/none" },
                                                 tool: { _ in .claude }, groups: groups)

        let ordered = AgentHistoryListing.liftingNewRuns(groups, placement: placement, status: \.status)

        XCTAssertEqual(ordered.map { [$0.id] + $0.files.map(\.sessionID) },
                       [[AgentHistoryGroup.pinnedID, "p1", "p2"], ["shop", "s1", "s2", "s3"], ["infra", "i1", "i2"]])
    }

    func testNewSessionWaitingInAGroupLiftsTheGroup() {
        let shop = group("shop", [file("s1", "shop")])
        let infra = group("infra", [file("i1", "infra")])
        let blog = group("blog", [file("b1", "blog")])
        let pinned = AgentHistoryGroup(id: AgentHistoryGroup.pinnedID, kind: .pinned, files: [file("p1", "shop")])
        let placement = AgentHistoryRunPlacement(runs: [Run(path: nil)], path: \.path, directory: { _ in "/srv/infra" },
                                                 tool: { _ in .claude }, groups: [pinned, shop, infra, blog])
        XCTAssertEqual(AgentHistoryListing.liftingNewRuns([pinned, shop, infra, blog], placement: placement,
                                                          status: \.status).map(\.id),
                       [AgentHistoryGroup.pinnedID, "infra", "shop", "blog"],
                       "还没对上记录的新会话刚开，比哪份记录都新：它那一组排前面（「置顶」照旧最上面）")
    }

    func testEndedNewSessionDoesNotLiftItsGroup() {
        let shop = group("shop", [file("s1", "shop")])
        let infra = group("infra", [file("i1", "infra")])
        let placement = AgentHistoryRunPlacement(runs: [Run(path: nil, status: .ended)], path: \.path,
                                                 directory: { _ in "/srv/infra" }, tool: { _ in .claude },
                                                 groups: [shop, infra])
        XCTAssertEqual(AgentHistoryListing.liftingNewRuns([shop, infra], placement: placement, status: \.status).map(\.id),
                       ["shop", "infra"], "已结束、留着画面的不往前挪")
    }
}
