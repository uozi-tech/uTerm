import XCTest
@testable import uTerm

/// OSC 7501 的解析与状态板。
final class ProgramStatusTests: XCTestCase {

    private func parse(_ text: String) -> ProgramStatusMessage? {
        ProgramStatusMessage.parse(Array(text.utf8)[...])
    }

    private func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    private func report(_ state: ProgramState, app: String? = nil, message: String? = nil) -> ProgramStatusRecord {
        ProgramStatusRecord(state: state, app: app, message: message)
    }

    // MARK: 解析

    func testParsesQuery() {
        XCTAssertEqual(parse("?"), .query)
    }

    /// Claude Code 2.1.318 实际发出的权限等待报告。
    func testParsesClaudeCodeBlockedReport() {
        let text = "state=blocked:app=claude-code:kind=permission:msg=\(base64("approve Bash: touch x"))"
        XCTAssertEqual(parse(text), .report(id: "", record: ProgramStatusRecord(
            state: .blocked, kind: .permission, app: "claude-code", message: "approve Bash: touch x")))
    }

    func testBase64PaddingIsOptional() {
        let encoded = base64("ab").replacingOccurrences(of: "=", with: "")
        guard case .report(_, let record)? = parse("state=working:msg=\(encoded)") else {
            return XCTFail("应当解析成报告")
        }
        XCTAssertEqual(record.message, "ab")
    }

    func testClearWithAndWithoutID() {
        XCTAssertEqual(parse("state=clear"), .clear(id: nil))
        XCTAssertEqual(parse("state=clear:id=build/test"), .clear(id: "build/test"))
    }

    func testUnknownStateIsIgnored() {
        XCTAssertNil(parse("state=sleeping"))
        XCTAssertNil(parse("app=codex"))
    }

    func testMalformedPairsAreSkippedAndUnknownKeysIgnored() {
        guard case .report(_, let record)? = parse("nonsense:BAD=1:future=x:state=working:app=codex") else {
            return XCTFail("应当解析成报告")
        }
        XCTAssertEqual(record, report(.working, app: "codex"))
    }

    func testLastRepeatedKeyWins() {
        guard case .report(_, let record)? = parse("state=idle:state=working") else {
            return XCTFail("应当解析成报告")
        }
        XCTAssertEqual(record.state, .working)
    }

    /// 内容来自远端程序：换行能伪造通知版式，规格要求整条丢弃。
    func testControlCharacterDiscardsReport() {
        XCTAssertNil(parse("state=working:msg=\(base64("a\nb"))"))
        XCTAssertNil(parse("state=working:title=\(base64("a\u{85}b"))"))
    }

    func testInvalidBase64DiscardsReport() {
        XCTAssertNil(parse("state=working:msg=!!!"))
    }

    func testOverLimitDiscardsReport() {
        XCTAssertNil(parse("state=working:app=\(String(repeating: "a", count: 33))"))
        XCTAssertNil(parse("state=working:id=\(String(repeating: "a", count: 129))"))
        XCTAssertNil(parse("state=working:title=\(base64(String(repeating: "a", count: 193)))"))
        XCTAssertNil(parse("state=working:app=x:\(String(repeating: "y", count: 4096))"))
    }

    func testKindAndProgressOnlyApplyToTheirStates() {
        guard case .report(_, let done)? = parse("state=done:kind=auth:progress=50") else {
            return XCTFail("应当解析成报告")
        }
        XCTAssertNil(done.kind)
        XCTAssertNil(done.progress)

        guard case .report(_, let working)? = parse("state=working:progress=50") else {
            return XCTFail("应当解析成报告")
        }
        XCTAssertEqual(working.progress, 50)

        guard case .report(_, let outOfRange)? = parse("state=working:progress=101") else {
            return XCTFail("应当解析成报告")
        }
        XCTAssertNil(outOfRange.progress)
    }

    // MARK: 什么时候打断用户

    func testBlockedNeedsAttentionOnlyWhenItChanges() {
        var board = ProgramStatusBoard()
        XCTAssertTrue(board.apply(id: "", record: report(.blocked, message: "a")))
        XCTAssertFalse(board.apply(id: "", record: report(.blocked, message: "a")))
        XCTAssertTrue(board.apply(id: "", record: report(.blocked, message: "b")))
    }

    /// Codex 没有 prompt 时启动也会走一遍 working → idle，用户取消也报 idle。
    func testWorkingAndIdleNeverNeedAttention() {
        var board = ProgramStatusBoard()
        XCTAssertFalse(board.apply(id: "", record: report(.idle)))
        XCTAssertFalse(board.apply(id: "", record: report(.working)))
        XCTAssertFalse(board.apply(id: "", record: report(.idle)))
    }

    func testRootDoneAndErrorNeedAttentionOnce() {
        var board = ProgramStatusBoard()
        XCTAssertTrue(board.apply(id: "", record: report(.done)))
        XCTAssertFalse(board.apply(id: "", record: report(.done)))
        XCTAssertTrue(board.apply(id: "", record: report(.error)))
    }

    /// 子记录是程序内部的后台任务：完成不用打断，卡住要。
    func testChildRecordsOnlyInterruptWhenBlocked() {
        var board = ProgramStatusBoard()
        XCTAssertFalse(board.apply(id: "task/1", record: report(.done)))
        XCTAssertFalse(board.apply(id: "task/2", record: report(.error)))
        XCTAssertTrue(board.apply(id: "task/3", record: report(.blocked)))
    }

    // MARK: 状态板

    func testSummaryShowsWhatNeedsAttentionMost() {
        var board = ProgramStatusBoard()
        _ = board.apply(id: "", record: report(.working))
        _ = board.apply(id: "a", record: report(.done))
        XCTAssertEqual(board.summary?.state, .working)
        _ = board.apply(id: "b", record: report(.blocked))
        XCTAssertEqual(board.summary?.state, .blocked)
    }

    func testChildInheritsNearestAncestorApp() {
        var board = ProgramStatusBoard()
        _ = board.apply(id: "", record: report(.idle, app: "root"))
        _ = board.apply(id: "a", record: report(.idle, app: "middle"))
        _ = board.apply(id: "a/b", record: report(.blocked))
        XCTAssertEqual(board.summary?.app, "middle")
        _ = board.apply(id: "c", record: report(.blocked))
        board.clear(id: "a")
        XCTAssertEqual(board.summary?.app, "root")
    }

    func testClearRemovesRecordAndChildrenButNotSiblings() {
        var board = ProgramStatusBoard()
        _ = board.apply(id: "a", record: report(.blocked))
        _ = board.apply(id: "a/b", record: report(.blocked))
        _ = board.apply(id: "ab", record: report(.working))
        board.clear(id: "a")
        XCTAssertEqual(board.summary?.state, .working)
    }

    func testProgramEndedDropsRunningStatesButKeepsResults() {
        var board = ProgramStatusBoard()
        _ = board.apply(id: "", record: report(.done))
        _ = board.apply(id: "a", record: report(.working))
        _ = board.apply(id: "b", record: report(.blocked))
        board.programEnded()
        XCTAssertEqual(board.summary?.state, .done)
    }

    func testAcknowledgeTurnsResultsIdleButLeavesBlocked() {
        var board = ProgramStatusBoard()
        _ = board.apply(id: "", record: report(.done))
        board.acknowledgeResults()
        XCTAssertEqual(board.summary?.state, .idle)
        _ = board.apply(id: "a", record: report(.blocked))
        board.acknowledgeResults()
        XCTAssertEqual(board.summary?.state, .blocked)
    }

    func testRecordCountIsCapped() {
        var board = ProgramStatusBoard()
        for index in 0..<256 { _ = board.apply(id: "\(index)", record: report(.idle)) }
        XCTAssertFalse(board.apply(id: "overflow", record: report(.blocked)))
        XCTAssertEqual(board.summary?.state, .idle)
        XCTAssertTrue(board.apply(id: "0", record: report(.blocked)))
    }
}
