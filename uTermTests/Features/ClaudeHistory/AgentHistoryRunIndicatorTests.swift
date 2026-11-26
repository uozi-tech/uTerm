import XCTest
@testable import uTerm

/// 侧栏一行上跑着的会话怎么标（用户要的：同 Claude Code Desktop）：只有等人处理时出黄点；运行中是名字一明一暗，
/// 不画蓝点；空闲、已完成、已结束、没报过状态的什么都不画；出错是一个警示图标。收起的组标题同一条规则。
@MainActor
final class AgentHistoryRunIndicatorTests: XCTestCase {
    private func program(_ state: ProgramState, kind: ProgramBlockKind? = nil) -> CodeRunStatus {
        .program(ProgramStatusRecord(state: state, kind: kind, app: "claude-code"))
    }

    func testOnlyBlockedSessionsGetTheDot() {
        XCTAssertEqual(AgentHistoryRunIndicator(program(.working)), .working, "运行中：名字呼吸，不画点")
        if case .needsInput(let record) = AgentHistoryRunIndicator(program(.blocked, kind: .permission)) {
            XCTAssertEqual(record.statusLabel, String(localized: "等待确认"))
        } else {
            XCTFail("等人处理：黄点")
        }
        if case .error = AgentHistoryRunIndicator(program(.error)) {} else { XCTFail("出错：警示图标") }
        for quiet in [program(.idle), program(.done), CodeRunStatus.ended, CodeRunStatus.unreported] {
            XCTAssertEqual(AgentHistoryRunIndicator(quiet), AgentHistoryRunIndicator.none, "\(quiet) 不画任何东西")
        }
    }

    func testCollapsedGroupOnlyShowsTheDotWhenSomeoneWaits() {
        XCTAssertNil(CodeRunGroupMark([program(.working), program(.idle), .unreported])?.waitingRecord,
                     "没人等：收起的组标题上不画点")
        XCTAssertEqual(CodeRunGroupMark([program(.working), program(.blocked, kind: .question)])?.waitingRecord?.state,
                       .blocked)
    }
}
