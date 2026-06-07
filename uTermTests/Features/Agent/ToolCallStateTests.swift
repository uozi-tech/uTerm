import XCTest
@testable import uTerm

final class ToolCallStateTests: XCTestCase {
    func testParseCommandFromArguments() {
        let s = ToolCallState(from: LLMToolCall(
            id: "c1", name: "run_command",
            argumentsJSON: #"{"command":"ls -la","explanation":"列目录"}"#))
        XCTAssertEqual(s.id, "c1")
        XCTAssertEqual(s.command, "ls -la")
        XCTAssertEqual(s.explanation, "列目录")
        XCTAssertEqual(s.status, .pending)
        XCTAssertNil(s.output)
    }

    func testMalformedArgumentsYieldsEmptyCommand() {
        let s = ToolCallState(from: LLMToolCall(id: "c2", name: "run_command",
                                                argumentsJSON: "{not json"))
        XCTAssertEqual(s.command, "")
        XCTAssertEqual(s.status, .pending)
    }

    func testChatMessageDefaultsToNoToolCalls() {
        XCTAssertTrue(ChatMessage(role: .user, text: "hi").toolCalls.isEmpty)
    }
}
