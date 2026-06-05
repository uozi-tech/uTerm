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
}
