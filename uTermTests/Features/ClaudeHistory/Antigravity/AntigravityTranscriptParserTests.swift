import XCTest
@testable import uTerm

/// 一行 Antigravity 记录 → 条目。内容全是编的。
@MainActor
final class AntigravityTranscriptParserTests: XCTestCase {
    private typealias F = AntigravityFixture

    private func kinds(_ line: String, encodedArgs: Bool = false) -> [AgentTranscriptItem.Kind] {
        AntigravityTranscriptParser.items(fromJSON: Data(line.utf8), idPrefix: "7", encodedArgs: encodedArgs).map(\.kind)
    }

    func testUserInputKeepsOnlyTheRequest() {
        let items = AntigravityTranscriptParser.items(fromJSON: Data(F.userInput(3, "帮我看看 **这个** 文件").utf8), idPrefix: "120")
        XCTAssertEqual(items.map(\.kind), [.userText("帮我看看 **这个** 文件")])
        XCTAssertEqual(items.first?.id, "120.0")
        XCTAssertEqual(items.first?.timestamp, ClaudeTimestamp.parse(F.time(3)))
        XCTAssertEqual(items.first?.role, .user)
    }

    func testSettingsChangeBecomesOneShortNotice() {
        let change = "The user changed setting `Model Selection` from Model A to Model B. No need to comment on this change if the user doesn't ask about it."
        XCTAssertEqual(kinds(F.userInput(0, "继续", settingsChange: change)), [
            .userText("继续"),
            .notice("The user changed setting `Model Selection` from Model A to Model B."),
        ])
        // 只换了设置、没说话的那一步只剩通知。
        let line = F.userInput(0, "", settingsChange: change)
        XCTAssertEqual(kinds(line).count, 1)
    }

    func testUserInputWithoutRequestTagFallsBackToTheRest() {
        let line = #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-20T10:00:00Z","content":"<ADDITIONAL_METADATA>\nx\n</ADDITIONAL_METADATA>\n老格式的一句话"}"#
        XCTAssertEqual(kinds(line), [.userText("老格式的一句话")])
    }

    func testPlannerStepOrdersThinkingAnswerAndCalls() {
        let line = F.planner(5, thinking: "想一想", content: "这是回答",
                             calls: [F.command("make test"), F.readFile("/home/user/projects/demo/b.swift")])
        let items = AntigravityTranscriptParser.items(fromJSON: Data(line.utf8), idPrefix: "9")
        XCTAssertEqual(items.map(\.id), ["9.0", "9.1", "9.2", "9.3"])
        guard items.count == 4 else { return XCTFail() }
        XCTAssertEqual(items[0].kind, .thinking(AgentClippedText("想一想", limit: 100)))
        XCTAssertEqual(items[1].kind, .assistantText("这是回答"))
        // 第 5 步的第 0、1 个调用，结果在第 6、7 步。
        XCTAssertEqual(items[2].kind, .toolCall(AgentToolCall(toolUseID: "step-6", name: "run_command", summary: "make test", result: nil)))
        XCTAssertEqual(items[3].kind, .toolCall(AgentToolCall(toolUseID: "step-7", name: "read_file",
                                                              summary: "/home/user/projects/demo/b.swift", result: nil)))
    }

    func testResultsAttachToTheirCallsByStep() {
        let lines = F.conversation("看一下")
        var items: [AgentTranscriptItem] = []
        var offset = 0
        for line in lines {
            items += AntigravityTranscriptParser.items(fromJSON: Data(line.utf8), idPrefix: String(offset))
            offset += line.utf8.count + 1
        }
        let assembled = AgentTranscriptAssembler.attachResults(items)
        let calls = assembled.compactMap { item -> AgentToolCall? in
            if case .toolCall(let call) = item.kind { return call }
            return nil
        }
        XCTAssertEqual(calls.map(\.name), ["read_file", "run_command"])
        // 结果开头的起止时间不显示。
        XCTAssertEqual(calls.map { $0.result?.content.text }, [
            "Showing lines 1-2 of 2\n1: alpha\n2: beta", "Command exited with code 0.\n\nCommand output:\nfile.txt",
        ])
        XCTAssertFalse(assembled.contains { if case .toolResult = $0.kind { return true } else { return false } })
        XCTAssertEqual(assembled.last?.kind, .assistantText("做完了"))
    }

    func testFailedAndInvalidResultsAreErrors() {
        guard case .toolResult(let failed) = kinds(F.generic(4, "Encountered error in step execution: file does not exist",
                                                             status: "ERROR")).first else { return XCTFail() }
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.toolUseID, "step-4")
        XCTAssertEqual(failed.content.text, "Encountered error in step execution: file does not exist")

        guard case .toolResult(let invalid) = kinds(F.generic(4, "", status: "INVALID", error: "bad arguments")).first
        else { return XCTFail() }
        XCTAssertTrue(invalid.isError)
        XCTAssertEqual(invalid.content.text, "bad arguments")

        guard case .toolResult(let running) = kinds(F.generic(4, "Tool is running as a background task", status: "RUNNING",
                                                              media: 2)).first else { return XCTFail() }
        XCTAssertFalse(running.isError)
        XCTAssertEqual(running.imageCount, 2)
    }

    func testSystemInjectedStepsBecomeNotices() {
        XCTAssertEqual(kinds(F.systemMessage(8, "后台任务结束了\n退出码 0")), [.notice("后台任务结束了 退出码 0")])
        XCTAssertEqual(kinds(F.errorMessage(9, "API error (attempt 1): request failed")),
                       [.notice("API error (attempt 1): request failed")])
        guard case .compactSummary(let summary) = kinds(F.checkpoint(10, "# Resuming from a compaction\n前面做了这些")).first
        else { return XCTFail() }
        XCTAssertEqual(summary.text, "# Resuming from a compaction\n前面做了这些")
    }

    func testBadAndUnknownLinesAreSkipped() {
        XCTAssertEqual(kinds("{not json"), [])
        XCTAssertEqual(kinds(""), [])
        XCTAssertEqual(kinds(#"{"step_index":1,"source":"MODEL","type":"SOMETHING_NEW","status":"DONE","created_at":"2026-11-20T10:00:00Z"}"#), [])
        XCTAssertEqual(kinds(#"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-20T10:00:00Z","model":"m"}"#), [])
        // 坏行夹在中间不影响别的行（按行解析）。
        XCTAssertEqual(kinds(#"["array"]"#), [])
    }

    func testOversizedLineOnlyNeedsItsHead() {
        let line = ClaudeReverseLineScanner.Line(offset: 300, length: 9_000_000,
                                                 bytes: Data(F.generic(3, "x").utf8.prefix(200)), isTruncated: true)
        XCTAssertEqual(AntigravityTranscriptParser.items(from: line).map(\.kind), [.oversized(bytes: 9_000_000)])
        // 不显示的类型就算很大也不占位。
        let hidden = ClaudeReverseLineScanner.Line(offset: 0, length: 9_000_000,
                                                   bytes: Data(#"{"step_index":1,"source":"MODEL","type":"OTHER""#.utf8),
                                                   isTruncated: true)
        XCTAssertEqual(AntigravityTranscriptParser.items(from: hidden), [])
    }

    /// `transcript.jsonl`（删节版）里参数的值又编过一次 JSON。
    func testEncodedArgsFromTheShortTranscript() {
        let line = F.planner(2, calls: [("run_command", #"{"CommandLine":"\"git status\"","WaitMsBeforeAsync":"500"}"#)])
        guard case .toolCall(let call) = kinds(line, encodedArgs: true).first else { return XCTFail() }
        XCTAssertEqual(call.summary, "git status")
        guard case .toolCall(let raw) = kinds(line).first else { return XCTFail() }
        XCTAssertEqual(raw.summary, "\"git status\"")
    }

    func testToolSummaryFallbacks() {
        XCTAssertEqual(AntigravityToolSummary.summary(name: "search_web", args: ["query": "swift actors"]), "swift actors")
        XCTAssertEqual(AntigravityToolSummary.summary(name: "view_file", args: ["AbsolutePath": "/a/b"]), "/a/b")
        XCTAssertEqual(AntigravityToolSummary.summary(name: "ask_question",
                                                      args: ["questions": [["question": "选哪个？\n第二行", "options": ["a"]]]]),
                       "选哪个？ 第二行")
        XCTAssertEqual(AntigravityToolSummary.summary(name: "update_steps", args: ["Count": 3]), #"{"Count":3}"#)
        XCTAssertEqual(AntigravityToolSummary.summary(name: "noop", args: [:]), "")
    }

    func testResultHeaderStripping() {
        XCTAssertEqual(AntigravityTranscriptParser.stripResultHeader("Created At: x\nCompleted At: y\nCreated At: x\nCompleted At: y\nOK"), "OK")
        XCTAssertEqual(AntigravityTranscriptParser.stripResultHeader("no header\nCreated At: x"), "no header\nCreated At: x")
    }
}
