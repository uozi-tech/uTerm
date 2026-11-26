import XCTest
@testable import uTerm

/// 收起的组标题上那个点（`CodeRunGroupMark`）：组里有还在跑的会话才画，颜色照最需要人处理的那个，读屏与悬停说几个在跑。
@MainActor
final class CodeRunGroupMarkTests: XCTestCase {
    private func program(_ state: ProgramState, kind: ProgramBlockKind? = nil) -> CodeRunStatus {
        .program(ProgramStatusRecord(state: state, kind: kind, app: "claude-code"))
    }

    func test_no_running_session_draws_no_mark() {
        XCTAssertNil(CodeRunGroupMark([]))
        XCTAssertNil(CodeRunGroupMark([.ended, .ended]), "只剩已结束、留着画面的：不算在跑")
    }

    func test_unreported_sessions_draw_a_grey_mark() {
        let mark = CodeRunGroupMark([.unreported, .ended, .unreported])
        XCTAssertEqual(mark?.running, 2)
        XCTAssertEqual(mark?.status, .unreported)
    }

    func test_most_urgent_status_wins() {
        let mark = CodeRunGroupMark([program(.idle), .unreported, program(.working), program(.blocked, kind: .permission),
                                     program(.error), .ended])
        XCTAssertEqual(mark?.running, 5)
        XCTAssertEqual(mark?.status, program(.blocked, kind: .permission))

        XCTAssertEqual(CodeRunGroupMark([program(.done), program(.working), program(.idle)])?.status, program(.working))
        XCTAssertEqual(CodeRunGroupMark([.unreported, program(.idle)])?.status, program(.idle),
                       "报过空闲也比没报过的具体")
    }

    func test_note_names_the_count_and_the_urgent_status() {
        let waiting = CodeRunGroupMark([program(.working), program(.blocked, kind: .permission)])!
        XCTAssertEqual(AgentHistoryText.groupRunsNote(waiting),
                       String(localized: "\(String(localized: "\(2) 个会话正在运行"))：\(String(localized: "等待确认"))"))
        let quiet = CodeRunGroupMark([.unreported])!
        XCTAssertEqual(AgentHistoryText.groupRunsNote(quiet), String(localized: "\(1) 个会话正在运行"))
    }

    func test_group_accessibility_mentions_running_sessions_only_when_given() {
        let group = AgentHistoryGroup(id: "g", kind: .all, files: [])
        let plain = AgentHistoryText.groupAccessibility(group, collapsed: true)
        XCTAssertEqual(AgentHistoryText.groupAccessibility(group, collapsed: true, runs: nil), plain)
        let mark = CodeRunGroupMark([.unreported])!
        XCTAssertTrue(AgentHistoryText.groupAccessibility(group, collapsed: true, runs: mark)
            .hasSuffix(AgentHistoryText.groupRunsNote(mark)))
    }
}
