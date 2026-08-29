import AgentKit
import XCTest
@testable import uTerm

final class AnthropicToolCallParserTests: XCTestCase {
    private func events(_ lines: [String]) -> [LLMEvent] {
        var p = AnthropicSSEParser()
        return lines.flatMap { p.parse(line: $0) }
    }

    func testTextDelta() {
        let e = events([
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}"#,
        ])
        XCTAssertEqual(e, [.text("hi")])
    }

    func testToolUseAccumulatesAndFlushesOnStop() {
        let e = events([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"run_command"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"comm"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"and\":\"ls\"}"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
        ])
        XCTAssertEqual(e, [.toolCall(LLMToolCall(id: "tu_1", name: "run_command",
                                                 argumentsJSON: #"{"command":"ls"}"#))])
    }
}
