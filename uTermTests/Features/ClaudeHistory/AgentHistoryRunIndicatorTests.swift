import XCTest
@testable import uTerm

/// 侧栏一行上跑着的会话怎么标（用户要的：同 Claude Code Desktop）：运行中一个灰色的呼吸灯（名字不动），
/// 等人处理时黄点，出错一个警示图标；空闲、已完成、已结束、没报过状态的什么都不画。收起的组标题只有人等着时画黄点。
@MainActor
final class AgentHistoryRunIndicatorTests: XCTestCase {
    private func program(_ state: ProgramState, kind: ProgramBlockKind? = nil) -> CodeRunStatus {
        .program(ProgramStatusRecord(state: state, kind: kind, app: "claude-code"))
    }

    func testOnlyBlockedSessionsGetTheDot() {
        XCTAssertEqual(AgentHistoryRunIndicator(program(.working)), .working, "运行中：灰色呼吸灯")
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
