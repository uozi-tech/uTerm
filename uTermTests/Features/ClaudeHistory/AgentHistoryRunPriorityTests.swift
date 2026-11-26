import Foundation
import XCTest
@testable import uTerm

/// 运行中的会话始终排在前面（用户要的）：组里跑着的那几行挪到组的最前面，有跑着的会话的组排在没有的前面；
/// 「置顶」一组照旧在最上面、组里照用户排的顺序不动。跑着的会话之间，正在干活 / 等人处理的排在停在输入框（空闲）的前面
/// （用户报的：亮着呼吸灯的会话排在两个空闲的后面）；已结束、留着画面的不往前挪。
final class AgentHistoryRunPriorityTests: XCTestCase {
    private struct Run {
        let path: String?
        var status: CodeRunStatus = .program(ProgramStatusRecord(state: .working, app: "claude-code"))
    }

    private func ordered<R>(_ groups: [AgentHistoryGroup], _ placement: AgentHistoryRunPlacement<R>,
                            status: (R) -> CodeRunStatus) -> [AgentHistoryGroup] {
        AgentHistoryListing.prioritizingRuns(groups, placement: placement, status: status)
    }

    private static let idle = CodeRunStatus.program(ProgramStatusRecord(state: .idle, app: "claude-code"))

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

        let ordered = ordered(groups, placement, status: \.status)

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
        XCTAssertEqual(ordered([shop, infra], placement, status: \.status).map(\.id), ["infra", "shop"],
                       "还没对上记录的新会话在哪一组，那一组也排前面")
    }

    func testWorkingSessionsComeBeforeIdleOnes() {
        let files = (1...4).map { file("u\($0)", "uterm") }
        let uterm = group("uterm", files)
        let blog = group("blog", [file("b1", "blog")])
        let runs = [Run(path: files[0].path, status: Self.idle), Run(path: files[1].path, status: Self.idle),
                    Run(path: files[2].path),
                    Run(path: files[3].path, status: .program(ProgramStatusRecord(state: .blocked, kind: .permission)))]
        let placement = AgentHistoryRunPlacement(runs: runs, path: \.path, directory: { _ in "/srv/none" },
                                                 tool: { _ in .claude }, groups: [uterm, blog])
        XCTAssertEqual(ordered([uterm, blog], placement, status: \.status)[0].files.map(\.sessionID),
                       ["u4", "u3", "u1", "u2"], "等人处理 > 运行中 > 空闲（空闲的照原来的先后）")
    }

    func testGroupWithAWorkingSessionComesBeforeGroupWithOnlyIdleOnes() {
        let shop = group("shop", [file("s1", "shop")])
        let infra = group("infra", [file("i1", "infra")])
        let blog = group("blog", [file("b1", "blog")])
        let runs = [Run(path: file("s1", "shop").path, status: Self.idle), Run(path: file("i1", "infra").path),
                    Run(path: file("b1", "blog").path, status: .ended)]
        let placement = AgentHistoryRunPlacement(runs: runs, path: \.path, directory: { _ in "/srv/none" },
                                                 tool: { _ in .claude }, groups: [shop, infra, blog])
        XCTAssertEqual(ordered([shop, infra, blog], placement, status: \.status).map(\.id), ["infra", "shop", "blog"],
                       "有正在干活的组 > 只有空闲的组 > 只有已结束的（不往前挪）")
    }

}
