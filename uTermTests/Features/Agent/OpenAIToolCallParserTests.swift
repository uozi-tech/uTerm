import AgentKit
import XCTest
@testable import uTerm

final class OpenAIToolCallParserTests: XCTestCase {
    private func events(_ lines: [String]) -> [LLMEvent] {
        var p = OpenAISSEParser()
        return lines.flatMap { p.parse(line: $0) }
    }

    func testTextDelta() {
        let e = events([#"data: {"choices":[{"delta":{"content":"hi"}}]}"#])
        XCTAssertEqual(e, [.text("hi")])
    }

    func testToolCallAccumulatesAndFlushesOnFinish() {
        let e = events([
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"run_command","arguments":"{\"comm"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ])
        XCTAssertEqual(e, [.toolCall(LLMToolCall(id: "call_1", name: "run_command",
                                                 argumentsJSON: #"{"command":"ls"}"#))])
    }

    func testTextThenToolCall() {
        let e = events([
            #"data: {"choices":[{"delta":{"content":"running "}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"run_command","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ])
        XCTAssertEqual(e, [.text("running "),
                           .toolCall(LLMToolCall(id: "c1", name: "run_command", argumentsJSON: "{}"))])
    }

    // MARK: - FIX #29: EOF 兜底 flush（幂等）

    /// 兼容端点以 finish_reason "stop" 收尾且不发 [DONE]：循环内永不 flush，
    /// 累积的工具调用必须靠 client 的 EOF flush 兜底产出。
    func testEofFlushEmitsToolCallWhenFinishReasonStopAndNoDone() {
        var p = OpenAISSEParser()
        // 工具调用增量 + 以 "stop" 收尾，且没有 [DONE]。
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x","function":{"name":"run_command","arguments":"{\"comm"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"pwd\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
        ]
        let mid = lines.flatMap { p.parse(line: $0) }
        // 循环内：finish_reason 非 "tool_calls" 且无 [DONE] → 尚未产出。
        XCTAssertEqual(mid, [])
        // client 在 EOF 后兜底 flush → 工具调用现身。
        XCTAssertEqual(p.flush(), [.toolCall(LLMToolCall(id: "call_x", name: "run_command",
                                                         argumentsJSON: #"{"command":"pwd"}"#))])
    }

    /// [DONE] 已 flush 后，client 的 EOF 兜底 flush 不得重复产出（幂等）。
    func testEofFlushDoesNotDoubleEmitAfterDone() {
        var p = OpenAISSEParser()
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"run_command","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ]
        let emitted = lines.flatMap { p.parse(line: $0) }
        XCTAssertEqual(emitted, [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                                       argumentsJSON: "{}"))])
        // EOF 兜底 flush：已 flush 过 → 返回空，不重复。
        XCTAssertEqual(p.flush(), [])
    }

    /// finish_reason == "tool_calls" 已 flush 后，EOF 兜底 flush 同样幂等不重复。
    func testEofFlushDoesNotDoubleEmitAfterToolCallsFinish() {
        var p = OpenAISSEParser()
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c2","function":{"name":"run_command","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ]
        let emitted = lines.flatMap { p.parse(line: $0) }
        XCTAssertEqual(emitted, [.toolCall(LLMToolCall(id: "c2", name: "run_command",
                                                       argumentsJSON: "{}"))])
        XCTAssertEqual(p.flush(), [])
    }
}
