import XCTest
@testable import uTerm

final class RequestSerializationTests: XCTestCase {
    func testOpenAIAssistantToolCallThenResult() {
        let assistant = ChatMessage(role: .assistant, text: "run it",
            toolCalls: [ToolCallState(id: "c1", name: "run_command", command: "ls",
                                      status: .done, output: "a\nb", exitCode: 0)])
        let msgs = OpenAIClient.buildMessages(system: "sys", conversation: [
            ChatMessage(role: .user, text: "hi"), assistant])
        // [system, user, assistant(+tool_calls), tool(result)]
        XCTAssertEqual(msgs.count, 4)
        XCTAssertEqual(msgs[2]["role"] as? String, "assistant")
        let tcs = msgs[2]["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(tcs?.first?["id"] as? String, "c1")
        XCTAssertEqual(msgs[3]["role"] as? String, "tool")
        XCTAssertEqual(msgs[3]["tool_call_id"] as? String, "c1")
        XCTAssertEqual(msgs[3]["content"] as? String, "a\nb")
    }

    func testOpenAISkippedToolResultPlaceholder() {
        let assistant = ChatMessage(role: .assistant, text: "",
            toolCalls: [ToolCallState(id: "c1", name: "run_command", command: "rm -rf /",
                                      status: .skipped)])
        let msgs = OpenAIClient.buildMessages(system: "", conversation: [assistant])
        XCTAssertEqual(msgs.last?["content"] as? String, "(用户跳过了该命令)")
    }

    func testAnthropicToolUseThenResult() {
        let assistant = ChatMessage(role: .assistant, text: "run it",
            toolCalls: [ToolCallState(id: "tu1", name: "run_command", command: "ls",
                                      status: .done, output: "a", exitCode: 0)])
        let msgs = AnthropicClient.buildMessages(conversation: [
            ChatMessage(role: .user, text: "hi"), assistant])
        XCTAssertEqual(msgs.count, 3)   // user, assistant(text+tool_use), user(tool_result)
        let content = msgs[1]["content"] as? [[String: Any]]
        XCTAssertEqual(content?.last?["type"] as? String, "tool_use")
        XCTAssertEqual(content?.last?["id"] as? String, "tu1")
        let result = (msgs[2]["content"] as? [[String: Any]])?.first
        XCTAssertEqual(result?["type"] as? String, "tool_result")
        XCTAssertEqual(result?["tool_use_id"] as? String, "tu1")
        XCTAssertEqual(result?["content"] as? String, "a")
    }
}
