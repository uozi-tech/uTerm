import XCTest
@testable import uTerm

/// 对话记录排成行：连续的工具调用折成一组（同 Claude Code Desktop），换了说话的一方才多空一截（纯函数）。
final class AgentTranscriptLayoutTests: XCTestCase {
    private func call(_ id: String, _ name: String = "Bash", error: Bool = false) -> AgentTranscriptItem {
        let result = AgentToolResult(toolUseID: id, content: AgentClippedText("ok", limit: 100), isError: error, imageCount: 0)
        return AgentTranscriptItem(id: id, kind: .toolCall(AgentToolCall(toolUseID: id, name: name, summary: "ls", result: result)))
    }

    private func user(_ id: String) -> AgentTranscriptItem { AgentTranscriptItem(id: id, kind: .userText("hi")) }
    private func answer(_ id: String) -> AgentTranscriptItem { AgentTranscriptItem(id: id, kind: .assistantText("ok")) }

    func testConsecutiveToolCallsFoldIntoOneRow() {
        let layout = AgentTranscriptLayout(items: [user("u"), answer("a1"), call("t1"), call("t2", "Read"), call("t3"), answer("a2")])
        XCTAssertEqual(layout.rows.map(\.id), ["u", "a1", "t1", "a2"])
        guard case .tools(let id, let items) = layout.rows[2] else { return XCTFail("应折成一组") }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(items.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(AgentToolSymbol.distinctNames(items), ["Bash", "Read"])
    }

    func testSingleToolCallStaysItsOwnRow() {
        let layout = AgentTranscriptLayout(items: [answer("a1"), call("t1"), answer("a2")])
        XCTAssertEqual(layout.rows.map(\.id), ["a1", "t1", "a2"])
        guard case .item = layout.rows[1] else { return XCTFail("只有一次调用不折") }
        XCTAssertNil(layout.groupKey(containing: "t1"))
    }

    /// 派出了子代理的调用单独一行，把前后两段隔开。
    func testUngroupableCallSplitsTheRun() {
        let items = [call("t1"), call("t2"), call("agent", "Agent"), call("t3"), call("t4")]
        let layout = AgentTranscriptLayout(items: items) { $0.name != "Agent" }
        XCTAssertEqual(layout.rows.map(\.id), ["t1", "agent", "t3"])
    }

    /// 搜索命中、往前加页时按消息找它所在的那一行。
    func testRowLookupForItemsInsideGroup() {
        let layout = AgentTranscriptLayout(items: [answer("a"), call("t1"), call("t2"), call("t3")])
        XCTAssertEqual(layout.rowID(for: "t3"), "t1")
        XCTAssertEqual(layout.rowID(for: "a"), "a")
        XCTAssertEqual(layout.rowID(for: "unknown"), "unknown")
        XCTAssertEqual(layout.groupKey(containing: "t2"), "t1.group")
        XCTAssertNil(layout.groupKey(containing: "a"))
    }

    /// 工具调用算回答那一方：「回答 → 一组调用 → 回答」是同一方，中间不多空。
    func testRunStartsTreatToolGroupsAsAssistant() {
        let layout = AgentTranscriptLayout(items: [user("u1"), answer("a1"), call("t1"), call("t2"), answer("a2"), user("u2")])
        XCTAssertEqual(layout.runStarts, ["u1", "a1", "u2"])
    }

    func testGroupReportsErrors() {
        XCTAssertTrue(AgentToolSymbol.hasError([call("t1"), call("t2", error: true)]))
        XCTAssertFalse(AgentToolSymbol.hasError([call("t1"), call("t2")]))
    }

    func testToolSymbols() {
        XCTAssertEqual(AgentToolSymbol.systemImage(for: "Bash"), "terminal")
        XCTAssertEqual(AgentToolSymbol.systemImage(for: "shell"), "terminal")
        XCTAssertEqual(AgentToolSymbol.systemImage(for: "Read"), "doc.text")
        XCTAssertEqual(AgentToolSymbol.systemImage(for: "apply_patch"), "pencil")
        XCTAssertEqual(AgentToolSymbol.systemImage(for: "Grep"), "magnifyingglass")
        XCTAssertEqual(AgentToolSymbol.systemImage(for: "mcp__github__get_issue"), "puzzlepiece.extension")
        XCTAssertEqual(AgentToolSymbol.systemImage(for: "Whatever"), "wrench.and.screwdriver")
    }
}
