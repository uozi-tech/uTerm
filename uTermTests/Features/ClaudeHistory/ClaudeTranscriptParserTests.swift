import XCTest
@testable import uTerm

final class ClaudeTranscriptParserTests: XCTestCase {
    private func kinds(_ line: String) -> [AgentTranscriptItem.Kind] {
        ClaudeTranscriptParser.items(fromJSON: Data(line.utf8), idPrefix: "0").map(\.kind)
    }

    private func line(_ text: String, offset: UInt64 = 0, truncated: Bool = false, length: Int? = nil)
        -> ClaudeReverseLineScanner.Line {
        let bytes = Data(text.utf8)
        return ClaudeReverseLineScanner.Line(offset: offset, length: length ?? bytes.count, bytes: bytes,
                                             isTruncated: truncated)
    }

    // MARK: 用户行

    func testUserStringContent() {
        XCTAssertEqual(kinds(ClaudeFixture.userText("把 **README** 改一下")), [.userText("把 **README** 改一下")])
    }

    func testUserBlocksTextImageAndToolResult() {
        let content = #"[{"type":"text","text":"看这张图"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},{"tool_use_id":"toolu_1","type":"tool_result","content":[{"type":"text","text":"ok"},{"type":"image","source":{}}],"is_error":true}]"#
        let result = kinds(ClaudeFixture.user(content: content))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], .userText("看这张图"))
        XCTAssertEqual(result[1], .image)
        guard case .toolResult(let toolResult) = result[2] else { return XCTFail("\(result[2])") }
        XCTAssertEqual(toolResult.toolUseID, "toolu_1")
        XCTAssertEqual(toolResult.content.text, "ok")
        XCTAssertTrue(toolResult.isError)
        XCTAssertEqual(toolResult.imageCount, 1)
    }

    func testSystemInjectedTextIsHidden() {
        let text = "<system-reminder>\n内部提示\n</system-reminder>\n真正的问题"
        XCTAssertEqual(kinds(ClaudeFixture.userText(text)), [.userText("真正的问题")])
        XCTAssertEqual(kinds(ClaudeFixture.userText("<system-reminder>只有提示</system-reminder>")), [])
    }

    func testMetaAndSidechainLinesAreSkipped() {
        let meta = ClaudeFixture.user(content: ClaudeFixture.json("注入的内容"), flags: #","isMeta":true"#)
        XCTAssertEqual(kinds(meta), [])
        let sidechain = ClaudeFixture.assistant(ClaudeFixture.textBlock("子代理"), sidechain: true)
        XCTAssertEqual(kinds(sidechain), [])
        XCTAssertFalse(ClaudeTranscriptParser.isMessageCandidate(head: Data(sidechain.utf8)))
    }

    func testSlashCommandAndOutput() {
        let command = "<command-name>/compact</command-name>\n<command-message>compact</command-message>\n<command-args>保留接口</command-args>"
        XCTAssertEqual(kinds(ClaudeFixture.userText(command)), [.command("/compact 保留接口")])
        let output = "<local-command-stdout>\u{1B}[1mDone\u{1B}[22m</local-command-stdout>"
        XCTAssertEqual(kinds(ClaudeFixture.userText(output)),
                       [.commandOutput(AgentClippedText("Done", limit: 100))])
    }

    func testBashInputAndTaskNotification() {
        XCTAssertEqual(kinds(ClaudeFixture.userText("<bash-input>ls -la</bash-input>")), [.command("! ls -la")])
        let notice = "<task-notification>\n<task-id>t1</task-id>\n<status>completed</status>\n<summary>后台构建结束</summary>\n</task-notification>"
        XCTAssertEqual(kinds(ClaudeFixture.userText(notice)), [.notice("后台构建结束")])
    }

    func testCompactSummaryBecomesDivider() {
        let line = ClaudeFixture.user(content: ClaudeFixture.json("之前的对话摘要"), flags: #","isCompactSummary":true"#)
        XCTAssertEqual(kinds(line), [.compactSummary(AgentClippedText("之前的对话摘要", limit: 100))])
    }

    // MARK: 回答行

    func testAssistantBlocks() {
        let blocks = [ClaudeFixture.thinkingBlock("先看一下目录"),
                      ClaudeFixture.textBlock("好的，我来改。"),
                      ClaudeFixture.toolUse(id: "toolu_9", name: "Bash", input: #"{"command":"ls\n-la","description":"列目录"}"#),
                      #"{"type":"thinking","thinking":"","signature":"only-signature"}"#,
                      #"{"type":"future_block","x":1}"#].joined(separator: ",")
        let result = kinds(ClaudeFixture.assistant(blocks))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], .thinking(AgentClippedText("先看一下目录", limit: 100)))
        XCTAssertEqual(result[1], .assistantText("好的，我来改。"))
        XCTAssertEqual(result[2], .toolCall(AgentToolCall(toolUseID: "toolu_9", name: "Bash", summary: "ls -la", result: nil)))
    }

    func testToolSummaryPicksMeaningfulArgument() {
        XCTAssertEqual(ClaudeToolSummary.summary(name: "Read", input: ["file_path": "/a/b.swift", "limit": 10]), "/a/b.swift")
        XCTAssertEqual(ClaudeToolSummary.summary(name: "Grep", input: ["pattern": "foo", "path": "/a"]), "foo")
        XCTAssertEqual(ClaudeToolSummary.summary(name: "mcp__x__y", input: ["query": "天气"]), "天气")
        XCTAssertEqual(ClaudeToolSummary.summary(name: "Other", input: ["n": 1]), #"{"n":1}"#)
        XCTAssertEqual(ClaudeToolSummary.summary(name: "Other", input: [:]), "")
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(ClaudeToolSummary.summary(name: "Bash", input: ["command": long]).count,
                       AgentTranscriptLimits.summaryCharacters + 1)
    }

    // MARK: 不要的、坏的、超长的

    func testUnknownAndMetadataLinesAreSkipped() {
        XCTAssertEqual(kinds(ClaudeFixture.aiTitle("标题")), [])
        XCTAssertEqual(kinds(ClaudeFixture.noise(1)), [])
        XCTAssertEqual(kinds(#"{"type":"some-future-type","payload":{"type":"user"}}"#), [])
        XCTAssertFalse(ClaudeTranscriptParser.isMessageCandidate(head: Data(ClaudeFixture.aiTitle("x").utf8)))
        XCTAssertFalse(ClaudeTranscriptParser.isMessageCandidate(head: Data(#"{"type":"api-request","id":"1"}"#.utf8)))
        let attachment = #"{"parentUuid":"a","isSidechain":false,"attachment":{"type":"file","content":"…"},"type":"attachment"}"#
        XCTAssertFalse(ClaudeTranscriptParser.isMessageCandidate(head: Data(attachment.utf8)))
    }

    func testBrokenLinesDoNotCrash() {
        XCTAssertEqual(kinds(#"{"type":"user","message":"#), [])
        XCTAssertEqual(kinds("not json at all"), [])
        XCTAssertEqual(kinds(#"{"type":"user","message":{"content":42}}"#), [])
        XCTAssertEqual(kinds(#"{"type":"assistant","message":{"content":[1,"x",null]}}"#), [])
        XCTAssertEqual(kinds("[]"), [])
    }

    func testTruncatedMessageLineBecomesOversizedPlaceholder() {
        let head = String(ClaudeFixture.toolResult(id: "t", text: String(repeating: "y", count: 50)).prefix(300))
        let items = ClaudeTranscriptParser.items(from: line(head, offset: 77, truncated: true, length: 12_000_000))
        XCTAssertEqual(items.map(\.kind), [.oversized(bytes: 12_000_000)])
        XCTAssertEqual(items.first?.id, "77.0")
        // 截断的不是消息行：直接跳过。
        let noise = ClaudeTranscriptParser.items(from: line(String(ClaudeFixture.noise(1).prefix(40)), truncated: true))
        XCTAssertEqual(noise, [])
    }

    func testLongToolResultIsClipped() {
        let long = String(repeating: "行\n", count: 20_000)
        let result = kinds(ClaudeFixture.toolResult(id: "t", text: long))
        guard case .toolResult(let toolResult) = result.first else { return XCTFail() }
        XCTAssertTrue(toolResult.content.isClipped)
        XCTAssertEqual(toolResult.content.text.count, AgentTranscriptLimits.toolResultCharacters)
        XCTAssertEqual(toolResult.content.totalCount, long.count)
        XCTAssertEqual(toolResult.content.preview(lines: 6, characters: 600), Array(repeating: "行", count: 6).joined(separator: "\n"))
    }

    func testItemIDsAreStablePerLineOffset() {
        let blocks = [ClaudeFixture.textBlock("一"), ClaudeFixture.textBlock("二")].joined(separator: ",")
        let items = ClaudeTranscriptParser.items(from: line(ClaudeFixture.assistant(blocks), offset: 1234))
        XCTAssertEqual(items.map(\.id), ["1234.0", "1234.1"])
        XCTAssertNotNil(items.first?.timestamp)
    }

    func testAttachResultsToCalls() {
        let call = AgentTranscriptItem(id: "1", kind: .toolCall(AgentToolCall(toolUseID: "t1", name: "Bash", summary: "ls", result: nil)))
        let other = AgentTranscriptItem(id: "2", kind: .assistantText("中间"))
        let result = AgentToolResult(toolUseID: "t1", content: AgentClippedText("out", limit: 10), isError: false, imageCount: 0)
        let orphan = AgentToolResult(toolUseID: "t0", content: AgentClippedText("old", limit: 10), isError: false, imageCount: 0)
        let merged = AgentTranscriptAssembler.attachResults([
            AgentTranscriptItem(id: "0", kind: .toolResult(orphan)), call, other,
            AgentTranscriptItem(id: "3", kind: .toolResult(result)),
        ])
        XCTAssertEqual(merged.map(\.id), ["0", "1", "2"])
        guard case .toolCall(let attached) = merged[1].kind else { return XCTFail() }
        XCTAssertEqual(attached.result, result)
    }

    func testStripTerminalEscapes() {
        XCTAssertEqual(ClaudeUserText.stripTerminalEscapes("\u{1B}[31mred\u{1B}[0m \u{1B}]0;title\u{07}ok\u{1B}]8;;x\u{1B}\\l"), "red okl")
        XCTAssertEqual(ClaudeUserText.stripTerminalEscapes("plain"), "plain")
    }
}
