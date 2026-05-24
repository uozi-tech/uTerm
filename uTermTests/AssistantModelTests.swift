import XCTest
@testable import uTerm

@MainActor
final class AssistantModelTests: XCTestCase {
    private func makeProvider() -> AIProvider {
        AIProvider(name: "Test", kind: .anthropic,
                    baseURL: ProviderPreset.anthropicBaseURL,
                    model: "claude-opus-4-7")
    }

    func testSendAppendsUserAndAssistantMessages() async {
        let backend = MockLLMClient(deltas: ["Hi", " there"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "server: cluster-main")
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages[0].role, .user)
        XCTAssertEqual(model.messages[0].text, "hello")
        XCTAssertEqual(model.messages[1].role, .assistant)
    }

    func testStreamedDeltasConcatenateIntoAssistantMessage() async {
        let backend = MockLLMClient(deltas: ["Hi", " there"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        XCTAssertEqual(model.messages.last?.text, "Hi there")
        XCTAssertEqual(model.state, .idle)
    }

    func testInputIsClearedOnSend() async {
        let backend = MockLLMClient(deltas: ["x"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        XCTAssertEqual(model.input, "")
    }

    func testEmptyInputDoesNothing() async {
        let backend = MockLLMClient(deltas: ["x"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "   "
        await model.send(serverContext: "")
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testBackendErrorReachesFailed() async {
        let backend = MockLLMClient(deltas: [], failWith: LLMClientError.invalidResponse)
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        guard case .failed = model.state else { return XCTFail("应为 .failed") }
    }

    func testServerContextGoesIntoSystemPrompt() async {
        let backend = MockLLMClient(deltas: ["x"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "server: cluster-main")
        XCTAssertTrue(backend.captured.system.contains("cluster-main"))
    }

    func testSecondSendIgnoredWhileStreaming() async {
        let model = AssistantModel(client: BlockingLLMClient(),
                                    provider: makeProvider(), apiKey: "sk-test")
        model.input = "first"
        let task = Task { await model.send(serverContext: "") }
        while model.state != .streaming { await Task.yield() }
        model.input = "second"
        await model.send(serverContext: "")
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages[0].text, "first")
        task.cancel()
        _ = await task.value
    }

    func testUnauthorizedErrorGivesAnthropicHint() async {
        let backend = MockLLMClient(deltas: [],
                                     failWith: LLMClientError.httpError(status: 401, body: "{}"))
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        guard case .failed(let message) = model.state else { return XCTFail("应为 .failed") }
        XCTAssertTrue(message.contains("Anthropic"))
    }

    func testUnauthorizedErrorGivesOpenAIHint() async {
        let openaiProvider = AIProvider(name: "X", kind: .openai,
                                          baseURL: ProviderPreset.openAIBaseURL,
                                          model: "gpt-5")
        let backend = MockLLMClient(deltas: [],
                                     failWith: LLMClientError.httpError(status: 401, body: "{}"))
        let model = AssistantModel(client: backend, provider: openaiProvider, apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        guard case .failed(let message) = model.state else { return XCTFail("应为 .failed") }
        XCTAssertTrue(message.contains("OpenAI"))
    }

    func testBackendReceivesOnlyRealMessagesNotEmptyAssistant() async {
        let backend = MockLLMClient(deltas: ["x"])
        let model = AssistantModel(client: backend, provider: makeProvider(), apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        XCTAssertEqual(backend.captured.messages.count, 1)
        XCTAssertEqual(backend.captured.messages[0].role, .user)
    }

    func testNoProvidersResultsInFailedState() async {
        let model = AssistantModel()
        model.input = "hello"
        await model.send(serverContext: "")
        guard case .failed(let m) = model.state else { return XCTFail("应为 .failed") }
        XCTAssertTrue(m.contains("provider"))
    }

    func testActiveProviderFallbackToLowestSortOrder() {
        let model = AssistantModel()
        let a = AIProvider(name: "A", kind: .anthropic, baseURL: "", model: "", sortOrder: 5)
        let b = AIProvider(name: "B", kind: .openai, baseURL: "", model: "", sortOrder: 1)
        model.providers = [a, b]
        model.activeProviderID = nil
        XCTAssertEqual(model.activeProvider?.id, b.id)
    }
}
