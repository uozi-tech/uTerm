import AgentKit
import XCTest
@testable import uTerm

/// 思考深度从输入区的选择一路接到请求体：AssistantModel 取偏好 → LLMRequestConfig →
/// 两种 client 的请求体；Anthropic 的 thinking 块在本轮工具循环里原样回传。
@MainActor
final class AgentReasoningWiringTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.uninstall()
        super.tearDown()
    }

    // MARK: - 请求体

    private func capturedBody(_ client: LLMClient, config: LLMRequestConfig,
                              messages: [ChatMessage] = [ChatMessage(role: .user, text: "hi")])
        async throws -> [String: Any] {
        StubURLProtocol.install { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        for try await _ in client.stream(messages: messages, system: "S", config: config) {}
        let request = try XCTUnwrap(StubURLProtocol.capturedRequest())
        let body = try XCTUnwrap(request.httpBody ?? Self.drain(request.httpBodyStream))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func config(_ model: String, _ wire: AgentWireProtocol,
                        effort: AgentReasoningEffort?) -> LLMRequestConfig {
        var config = LLMRequestConfig(model: model, baseURL: URL(string: "https://api.example.com")!, apiKey: "k")
        config.reasoning = AgentReasoningRequest.make(protocol: wire, modelID: model, effort: effort)
        return config
    }

    func testAnthropicAdaptiveEffortGoesIntoBody() async throws {
        let body = try await capturedBody(AnthropicClient(session: makeStubbedSession()),
                                          config: config("claude-opus-4-7", .anthropic, effort: .high))
        XCTAssertEqual(body["thinking"] as? [String: String], ["type": "adaptive"])
        XCTAssertEqual(body["output_config"] as? [String: String], ["effort": "high"])
        XCTAssertEqual(body["max_tokens"] as? Int, AgentReasoningRequest.adaptiveMinimumMaxTokens)
    }

    func testAnthropicDefaultSendsNoThinkingFields() async throws {
        let body = try await capturedBody(AnthropicClient(session: makeStubbedSession()),
                                          config: config("claude-opus-4-7", .anthropic, effort: nil))
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
        XCTAssertEqual(body["max_tokens"] as? Int, AnthropicClient.maxTokens)
    }

    func testOpenAIReasoningEffortGoesIntoBody() async throws {
        let body = try await capturedBody(OpenAIClient(session: makeStubbedSession()),
                                          config: config("o3", .openAICompatible, effort: .low))
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
    }

    // MARK: - thinking 块回传

    private func assistant(_ text: String, thinking signature: String, callID: String?) -> ChatMessage {
        var message = ChatMessage(role: .assistant, text: text)
        message.thinking = [LLMThinkingBlock(thinking: "", signature: signature)]
        if let callID {
            message.toolCalls = [ToolCallState(from: LLMToolCall(
                id: callID, name: "run_command", argumentsJSON: #"{"command":"ls"}"#))]
        }
        return message
    }

    func testOnlyCurrentTurnThinkingIsReplayedBeforeToolUse() throws {
        let conversation = [
            ChatMessage(role: .user, text: "first"),
            assistant("old", thinking: "old-sig", callID: nil),
            ChatMessage(role: .user, text: "second"),
            assistant("", thinking: "new-sig", callID: "c1"),
        ]
        let msgs = AnthropicClient.buildMessages(conversation: conversation, replayThinking: true)
        // 旧轮次：只有文字块，不带 thinking。
        let oldContent = try XCTUnwrap(msgs[1]["content"] as? [[String: Any]])
        XCTAssertEqual(oldContent.map { $0["type"] as? String }, ["text"])
        XCTAssertEqual(oldContent.first?["text"] as? String, "old")
        // 本轮：thinking 在 tool_use 之前。
        let content = try XCTUnwrap(msgs[3]["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "thinking")
        XCTAssertEqual(content.first?["signature"] as? String, "new-sig")
        XCTAssertEqual(content.last?["type"] as? String, "tool_use")

        let plain = AnthropicClient.buildMessages(conversation: conversation, replayThinking: false)
        let plainContent = try XCTUnwrap(plain[3]["content"] as? [[String: Any]])
        XCTAssertFalse(plainContent.contains { $0["type"] as? String == "thinking" })
    }

    func testSSEParserEmitsThinkingBlock() {
        var parser = AnthropicSSEParser()
        let lines = [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"S1"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
        ]
        let events = lines.flatMap { parser.parse(line: $0) }
        XCTAssertEqual(events, [.thinking(LLMThinkingBlock(thinking: "hmm", signature: "S1"))])
    }

    // MARK: - AssistantModel

    private func preferences() throws -> AgentReasoningPreferences {
        let suite = "AgentReasoningWiringTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AgentReasoningPreferences(defaults: defaults)
    }

    func testAssistantModelSendsChosenEffortAndKeepsThinking() async throws {
        let provider = AIProvider(name: "a", kind: .anthropic, baseURL: "https://x", model: "claude-opus-4-7")
        let block = LLMThinkingBlock(thinking: "", signature: "sig")
        let client = MockLLMClient(events: [.thinking(block), .text("ok")])
        let model = AssistantModel(client: client, provider: provider, apiKey: "k")
        let prefs = try preferences()
        prefs.setEffort(.medium, providerID: provider.id, model: "claude-opus-4-7")
        model.reasoningPreferences = prefs

        model.input = "hi"
        await model.send(serverContext: "")
        XCTAssertEqual(client.captured.config?.reasoning?.effort, .medium)
        XCTAssertEqual(model.messages.last?.thinking, [block])
    }

    func testAssistantModelWithoutChoiceSendsNoReasoning() async throws {
        let provider = AIProvider(name: "a", kind: .anthropic, baseURL: "https://x", model: "claude-opus-4-7")
        let client = MockLLMClient(events: [.text("ok")])
        let model = AssistantModel(client: client, provider: provider, apiKey: "k")
        model.reasoningPreferences = try preferences()
        model.input = "hi"
        await model.send(serverContext: "")
        XCTAssertNil(client.captured.config?.reasoning)
    }

    func testEmptyModelFailsBeforeRequest() async {
        let provider = AIProvider(name: "a", kind: .openai, baseURL: "https://x", model: "")
        let client = MockLLMClient(events: [.text("ok")])
        let model = AssistantModel(client: client, provider: provider, apiKey: "k")
        model.input = "hi"
        await model.send(serverContext: "")
        guard case .failed(let message) = model.state else { return XCTFail("应为 .failed") }
        XCTAssertTrue(message.contains("模型菜单"))
        XCTAssertEqual(client.captured.callCount, 0)
    }

    // MARK: - 输入区下拉的分组

    func testMenuGroupsListEveryProviderWithSelectedModelKept() async throws {
        let suite = "AgentReasoningWiringTests-catalog-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = AgentModelCatalog(defaults: defaults, describe: { _ in "boom" })
        let a = AIProvider(name: "Anthropic", kind: .anthropic, baseURL: "", model: "claude-legacy", sortOrder: 1)
        let b = AIProvider(name: "DeepSeek", kind: .openai, baseURL: "", model: "", sortOrder: 0)
        catalog.refresh([
            .init(providerID: a.id, endpoint: "a") { ["claude-opus-4-7"] },
            .init(providerID: b.id, endpoint: "b") { throw URLError(.timedOut) },
        ])
        await catalog.waitUntilSettled()

        let groups = AgentComposerModelMenu.groups(providers: [a, b], catalog: catalog)
        XCTAssertEqual(groups.map(\.title), ["DeepSeek", "Anthropic"])
        XCTAssertEqual(groups[0].status, .failed("boom"))
        XCTAssertEqual(groups[1].items.map(\.title), ["claude-legacy", "claude-opus-4-7"])
        XCTAssertEqual(groups[1].items.first?.detail, "不在列表中")
        XCTAssertEqual(AgentComposerModelMenu.itemID(a), groups[1].items.first?.id)
        XCTAssertNil(AgentComposerModelMenu.itemID(b))
    }

    func testEffortOptionsStartWithDefault() throws {
        let support = try XCTUnwrap(AgentReasoningSupport.resolve(protocol: .anthropic, modelID: "claude-haiku-4-5"))
        XCTAssertEqual(AgentComposerModelMenu.effortOptions(support).map(\.label), ["默认", "关闭", "低", "中", "高"])
        XCTAssertNil(AgentComposerModelMenu.effortOptions(support).first?.value)
    }
}
