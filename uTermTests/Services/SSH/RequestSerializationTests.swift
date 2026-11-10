import AgentKit
import XCTest
@testable import uTerm
@testable import USSHKit

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

    // MARK: - 工具循环中途并入的用户消息

    private func doneToolMessage() -> ChatMessage {
        ChatMessage(role: .assistant, text: "",
                    toolCalls: [ToolCallState(id: "tu1", name: "run_command", command: "ls",
                                              status: .done, output: "a", exitCode: 0)])
    }

    /// Anthropic：并进工具结果那条 user 消息，tool_result 在前、文字在后，不发连续两条 user。
    func testAnthropicMidLoopUserTextJoinsToolResultMessage() throws {
        var steer = ChatMessage(role: .user, text: "只看隐藏文件")
        steer.continuesTurn = true
        let msgs = AnthropicClient.buildMessages(conversation: [
            ChatMessage(role: .user, text: "hi"), doneToolMessage(), steer,
            ChatMessage(role: .user, text: "再补一句"),
        ])
        XCTAssertEqual(msgs.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let content = try XCTUnwrap(msgs[2]["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["tool_result", "text", "text"])
        XCTAssertEqual(content[1]["text"] as? String, "只看隐藏文件")
        XCTAssertEqual(content[2]["text"] as? String, "再补一句")
    }

    func testAnthropicConsecutivePlainUserMessagesMergeIntoTextBlocks() throws {
        let msgs = AnthropicClient.buildMessages(conversation: [
            ChatMessage(role: .user, text: "甲"), ChatMessage(role: .user, text: "乙"),
        ])
        XCTAssertEqual(msgs.count, 1)
        let content = try XCTUnwrap(msgs[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["text"] as? String }, ["甲", "乙"])
    }

    /// 中途并入的消息不算新一轮：它前面那一步的 thinking 仍要回传。
    func testAnthropicMidLoopUserMessageKeepsThinkingReplayForTheLoop() throws {
        var first = doneToolMessage()
        first.thinking = [LLMThinkingBlock(thinking: "", signature: "sig-1")]
        var steer = ChatMessage(role: .user, text: "只看隐藏文件")
        steer.continuesTurn = true
        let conversation = [ChatMessage(role: .user, text: "hi"), first, steer]

        let msgs = AnthropicClient.buildMessages(conversation: conversation, replayThinking: true)
        let content = try XCTUnwrap(msgs[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "thinking")
        XCTAssertEqual(content.first?["signature"] as? String, "sig-1")

        // 对照：同一条消息若是新一轮的起点，前面的 thinking 不回传。
        var plain = conversation
        plain[2].continuesTurn = false
        let plainMsgs = AnthropicClient.buildMessages(conversation: plain, replayThinking: true)
        let plainContent = try XCTUnwrap(plainMsgs[1]["content"] as? [[String: Any]])
        XCTAssertFalse(plainContent.contains { $0["type"] as? String == "thinking" })
    }

    /// OpenAI：tool 消息之后直接跟 user，本来就是合法形状。
    func testOpenAIMidLoopUserMessageFollowsToolMessages() {
        var steer = ChatMessage(role: .user, text: "只看隐藏文件")
        steer.continuesTurn = true
        let msgs = OpenAIClient.buildMessages(system: "", conversation: [
            ChatMessage(role: .user, text: "hi"), doneToolMessage(), steer,
        ])
        XCTAssertEqual(msgs.map { $0["role"] as? String }, ["user", "assistant", "tool", "user"])
    }

    /// 上下文压缩不把中途并入的消息当轮次边界。
    func testMidLoopUserMessageIsNotACompressionBoundary() {
        var steer = ChatMessage(role: .user, text: "x")
        steer.continuesTurn = true
        XCTAssertFalse(steer.isTurnBoundary)
        XCTAssertTrue(ChatMessage(role: .user, text: "x").isTurnBoundary)
    }
}
