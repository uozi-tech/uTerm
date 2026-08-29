import AgentKit
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

    func testToolPresentationKeepsFailureAndSkipDistinctFromSuccess() {
        let failed = ToolCallState(id: "failed", name: "run_command", command: "false",
                                   status: .failed, output: "permission denied")
        let skipped = ToolCallState(id: "skipped", name: "run_command", command: "reboot",
                                    status: .skipped)

        XCTAssertEqual(AgentToolCallPresentation.resolve(failed).title, "执行失败")
        XCTAssertEqual(AgentToolCallPresentation.resolve(failed).tone, .danger)
        XCTAssertEqual(AgentToolCallPresentation.resolve(skipped).title, "已跳过")
        XCTAssertEqual(AgentToolCallPresentation.resolve(skipped).tone, .muted)
    }

    func testNonzeroExitCodeIsPresentedAsFailure() {
        let call = ToolCallState(id: "c3", name: "run_command", command: "nginx -t",
                                 status: .done, output: "syntax error", exitCode: 1)

        let presentation = AgentToolCallPresentation.resolve(call)
        XCTAssertEqual(presentation.title, "退出码 1")
        XCTAssertEqual(presentation.tone, .danger)
        XCTAssertFalse(presentation.isApprovalVisible)
    }
}
