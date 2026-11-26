import Foundation
import XCTest
@testable import uTerm

/// 运行中的会话始终排在前面（用户要的）：组里跑着的那几行挪到组的最前面，有跑着的会话的组排在没有的前面；
/// 「置顶」一组照旧在最上面、组里照用户排的顺序不动。
final class AgentHistoryRunPriorityTests: XCTestCase {
    private struct Run { let path: String? }

    private func file(_ id: String, _ project: String) -> AgentHistorySessionFile {
        let p = AgentHistoryProject(id: project, path: "/r/\(project)", modifiedAt: nil, directory: "/srv/\(project)")
        return AgentHistorySessionFile(sessionID: id, project: p, path: "/r/\(project)/\(id).jsonl", size: 1, modifiedAt: Date())
    }

    private func group(_ id: String, _ files: [AgentHistorySessionFile]) -> AgentHistoryGroup {
        AgentHistoryGroup(id: id, kind: .project(directory: "/srv/\(id)", name: id), files: files)
    }

    func testRunningRowsAndTheirGroupsComeFirst() {
        let pinned = AgentHistoryGroup(id: AgentHistoryGroup.pinnedID, kind: .pinned,
                                       files: [file("p1", "shop"), file("p2", "shop")])
        let shop = group("shop", [file("s1", "shop"), file("s2", "shop"), file("s3", "shop")])
        let infra = group("infra", [file("i1", "infra"), file("i2", "infra")])
        let blog = group("blog", [file("b1", "blog")])
        let groups = [pinned, shop, infra, blog]
        let runs = [Run(path: file("i2", "infra").path), Run(path: file("p2", "shop").path)]
        let placement = AgentHistoryRunPlacement(runs: runs, path: \.path, directory: { _ in "/srv/none" },
                                                 tool: { _ in .claude }, groups: groups)

        let ordered = AgentHistoryListing.prioritizingRuns(groups, placement: placement)

        XCTAssertEqual(ordered.map(\.id), [AgentHistoryGroup.pinnedID, "infra", "shop", "blog"],
                       "置顶照旧最上面；有跑着的会话的组排前面，其余照原来的先后")
        XCTAssertEqual(ordered[0].files.map(\.sessionID), ["p1", "p2"], "置顶里照用户排的顺序，不挪")
        XCTAssertEqual(ordered[1].files.map(\.sessionID), ["i2", "i1"], "组里跑着的那一行挪到最前面")
        XCTAssertEqual(ordered[2].files.map(\.sessionID), ["s1", "s2", "s3"])
    }

    func testNewSessionWaitingInAGroupLiftsTheGroup() {
        let shop = group("shop", [file("s1", "shop")])
        let infra = group("infra", [file("i1", "infra")])
        let runs = [Run(path: nil)]
        let placement = AgentHistoryRunPlacement(runs: runs, path: \.path, directory: { _ in "/srv/infra" },
                                                 tool: { _ in .claude }, groups: [shop, infra])
        XCTAssertEqual(AgentHistoryListing.prioritizingRuns([shop, infra], placement: placement).map(\.id), ["infra", "shop"],
                       "还没对上记录的新会话在哪一组，那一组也排前面")
    }
}
