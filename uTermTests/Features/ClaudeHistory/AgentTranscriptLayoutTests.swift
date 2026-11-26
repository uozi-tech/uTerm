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

    private func group(_ row: AgentTranscriptLayout.Row) -> AgentToolGroup? {
        if case .tools(let group) = row.entry { return group }
        return nil
    }

    func testConsecutiveToolCallsFoldIntoOneRow() throws {
        let layout = AgentTranscriptLayout(items: [user("u"), answer("a1"), call("t1"), call("t2", "Read"), call("t3"), answer("a2")])
        XCTAssertEqual(layout.rows.map(\.id), ["u", "a1", "t1", "a2"])
        let tools = try XCTUnwrap(group(layout.rows[2]), "应折成一组")
        XCTAssertEqual(tools.items.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(tools.names, ["Bash", "Read"])
        XCTAssertEqual(tools.expansionKey, "t1.group")
    }

    func testSingleToolCallStaysItsOwnRow() {
        let layout = AgentTranscriptLayout(items: [answer("a1"), call("t1"), answer("a2")])
        XCTAssertEqual(layout.rows.map(\.id), ["a1", "t1", "a2"])
        XCTAssertNil(group(layout.rows[1]), "只有一次调用不折")
        var expanded: Set<String> = []
        XCTAssertEqual(layout.reveal("t1", expanding: &expanded), "t1")
        XCTAssertTrue(expanded.isEmpty)
    }

    /// 派出了子代理的调用单独一行，把前后两段隔开。
    func testUngroupableCallSplitsTheRun() {
        let items = [call("t1"), call("t2"), call("agent", "Agent"), call("t3"), call("t4")]
        let layout = AgentTranscriptLayout(items: items) { $0.name != "Agent" }
        XCTAssertEqual(layout.rows.map(\.id), ["t1", "agent", "t3"])
    }

    /// 搜索命中、往前加页时按消息找它所在的那一行；命中在折起来的组里就展开那一组。
    func testRowLookupForItemsInsideGroup() {
        let layout = AgentTranscriptLayout(items: [answer("a"), call("t1"), call("t2"), call("t3")])
        XCTAssertEqual(layout.rowID(for: "t3"), "t1")
        XCTAssertEqual(layout.rowID(for: "a"), "a")
        XCTAssertEqual(layout.rowID(for: "unknown"), "unknown")
        var expanded: Set<String> = []
        XCTAssertEqual(layout.reveal("t2", expanding: &expanded), "t1")
        XCTAssertEqual(expanded, ["t1.group"])
    }

    /// 工具调用算回答那一方：「回答 → 一组调用 → 回答」是同一方，中间不多空；第一行上面不空。
    /// 末尾整段排的那一段：从打开时那一页的第一条所在的行起；那一条并进了更早的组里就从那一组起。
    func testEagerTailStartsAtTheRowHoldingTheFirstOpenedItem() {
        let layout = AgentTranscriptLayout(items: [user("u0"), answer("a0"), call("t1"), call("t2"), answer("a1"), user("u1")])
        XCTAssertEqual(layout.rows.map(\.id), ["u0", "a0", "t1", "a1", "u1"])
        XCTAssertEqual(layout.eagerTailStart(from: "a1"), 3)
        XCTAssertEqual(layout.eagerTailStart(from: "t2"), 2, "那一条在折起来的组里：从那一组起")
        XCTAssertEqual(layout.eagerTailStart(from: nil), 0, "还没有第一页：全部")
        XCTAssertEqual(layout.eagerTailStart(from: "不认识"), 0)
        XCTAssertEqual(layout.eagerTailStart(from: "u1"), 4)
    }

    /// 实时跟随接了很久：末尾那一段只留最后若干行，前面的退回懒栈。
    func testEagerTailIsCapped() {
        let items = (0..<10).flatMap { [user("u\($0)"), answer("a\($0)")] }
        let layout = AgentTranscriptLayout(items: items)
        XCTAssertEqual(layout.eagerTailStart(from: "u0", limit: 6), 14)
        XCTAssertEqual(layout.eagerTailStart(from: "a8", limit: 6), 17, "不到上限：照第一条算")
        XCTAssertEqual(layout.eagerTailStart(from: nil, limit: 100), 0)
    }

    func testRunStartsTreatToolGroupsAsAssistant() {
        let layout = AgentTranscriptLayout(items: [user("u1"), answer("a1"), call("t1"), call("t2"), answer("a2"), user("u2")])
        XCTAssertEqual(layout.rows.filter(\.startsRun).map(\.id), ["u1", "a1", "u2"])
        XCTAssertEqual(layout.rows.filter(\.hasGapAbove).map(\.id), ["a1", "u2"])
    }

    func testGroupReportsErrors() {
        XCTAssertTrue(AgentToolGroup(items: [call("t1"), call("t2", error: true)]).hasError)
        XCTAssertFalse(AgentToolGroup(items: [call("t1"), call("t2")]).hasError)
    }

    /// 折起来那一行的摘要：第一行非空的字，最多 200 字。
    func testFirstLineSkipsBlankLinesAndCaps() {
        XCTAssertEqual(AgentClippedText("\n\nfirst\nsecond", limit: 100).firstLine, "first")
        XCTAssertEqual(AgentClippedText(String(repeating: "x", count: 5000), limit: 10_000).firstLine.count, 200)
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
